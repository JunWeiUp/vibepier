import CoreFoundation
import Foundation

/// Version-gated native catalog. Permission profiles and collaboration modes are independent.
struct CodexRuntimeModeCatalog {
    let modes: [String]
    let defaultModel: String
    let efforts: [String: Set<String>]

    init(modesJSON: Data, modelsJSON: Data) throws {
        guard modesJSON.count <= 65_536, modelsJSON.count <= 1_048_576,
            let modeRoot = try JSONSerialization.jsonObject(with: modesJSON) as? [String: Any],
            let modeRows = modeRoot["data"] as? [[String: Any]], modeRows.count <= 16,
            let modelRoot = try JSONSerialization.jsonObject(with: modelsJSON) as? [String: Any],
            modelRoot["nextCursor"] == nil || modelRoot["nextCursor"] is NSNull,
            let modelRows = modelRoot["data"] as? [[String: Any]], modelRows.count <= 100
        else { throw RuntimeDriverError.unavailable }
        let found = modeRows.compactMap { $0["mode"] as? String }
        guard found.count == modeRows.count, Set(found) == Set(["default", "plan"]), found.count == 2,
            modeRows.allSatisfy({ ($0["name"] as? String)?.isEmpty == false })
        else { throw RuntimeDriverError.unavailable }
        var parsed: [String: Set<String>] = [:]
        var defaults: [String] = []
        for row in modelRows {
            guard let model = row["model"] as? String, Self.valid(model), parsed[model] == nil,
                let values = row["supportedReasoningEfforts"] as? [[String: Any]], values.count <= 32,
                let isDefault = row["isDefault"] as? NSNumber, CFGetTypeID(isDefault) == CFBooleanGetTypeID(),
                let hidden = row["hidden"] as? NSNumber, CFGetTypeID(hidden) == CFBooleanGetTypeID()
            else { throw RuntimeDriverError.unavailable }
            let allowed = values.compactMap { $0["reasoningEffort"] as? String }
            guard allowed.count == values.count, allowed.allSatisfy(Self.valid), Set(allowed).count == allowed.count,
                let effort = row["defaultReasoningEffort"] as? String, allowed.contains(effort)
            else { throw RuntimeDriverError.unavailable }
            parsed[model] = Set(allowed)
            if isDefault.boolValue && !hidden.boolValue { defaults.append(model) }
        }
        guard defaults.count == 1 else { throw RuntimeDriverError.unavailable }
        modes = ["default", "plan"]
        defaultModel = defaults[0]
        efforts = parsed
    }
    func selection(mode: String, model: Any?, effort: Any?) throws -> CodexRuntimeModeSelection {
        guard modes.contains(mode), let model = model as? String, let allowed = efforts[model],
            effort == nil || effort is NSNull || (effort as? String).map(allowed.contains) == true
        else { throw RuntimeDriverError.unavailable }
        return CodexRuntimeModeSelection(mode: mode, model: model, effort: effort as? String)
    }
    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
    }
}

struct CodexRuntimeModeSelection: Codable, Equatable {
    let mode: String
    let model: String
    let effort: String?
    var native: [String: Any] {
        [
            "mode": mode,
            "settings": [
                "model": model, "reasoning_effort": effort as Any? ?? NSNull(),
                "developer_instructions": NSNull(),
            ],
        ]
    }
}

/// Durable selections survive gateway/view restarts. Pending changes never become
/// defaults for a later send until a matching native settings notification arrives.
final class CodexRuntimeModeStore {
    struct Entry: Codable {
        let selection: CodexRuntimeModeSelection
        let operationID: String
        var proof: Data?
    }
    private struct State: Codable {
        let version: Int
        var entries: [String: Entry]
    }
    private let url: URL
    private let condition = NSCondition()
    private var state: State
    private var reliable = true
    init(url: URL) {
        self.url = url
        state = State(version: 1, entries: [:])
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                state = try JSONDecoder().decode(State.self, from: RuntimePrivateStorage.read(url, limit: 1_048_576))
                guard state.version == 1, state.entries.count <= 64,
                    state.entries.allSatisfy({ key, entry in
                        key.count == 64 && key.allSatisfy(\.isHexDigit)
                            && ["default", "plan"].contains(entry.selection.mode)
                            && !entry.selection.model.isEmpty && entry.selection.model.utf8.count <= 256
                            && entry.selection.effort.map({ !$0.isEmpty && $0.utf8.count <= 256 }) != false
                            && !entry.operationID.isEmpty && entry.operationID.utf8.count <= 256
                            && (entry.proof?.count ?? 0) <= 65_536
                    })
                else { throw RuntimeDriverError.storageUnavailable }
            } catch { reliable = false }
        }
    }
    func entry(_ reference: RuntimeSessionReference) throws -> Entry? {
        condition.lock()
        defer { condition.unlock() }
        guard reliable else { throw RuntimeDriverError.storageUnavailable }
        let entry = state.entries[key(reference)]
        if let proof = entry?.proof {
            guard let value = try? JSONSerialization.jsonObject(with: proof) as? [String: Any],
                value["threadId"] as? String == reference.nativeSessionID,
                let settings = value["threadSettings"] as? [String: Any],
                let collaboration = settings["collaborationMode"] as? [String: Any],
                collaboration["mode"] as? String == entry?.selection.mode,
                (collaboration["settings"] as? [String: Any])?["model"] as? String == entry?.selection.model
            else { throw RuntimeDriverError.storageUnavailable }
        }
        return entry
    }
    func begin(_ selection: CodexRuntimeModeSelection, reference: RuntimeSessionReference, operationID: String) throws {
        condition.lock()
        defer { condition.unlock() }
        guard reliable, state.entries[key(reference)] != nil || state.entries.count < 64 else {
            throw RuntimeDriverError.storageUnavailable
        }
        state.entries[key(reference)] = Entry(selection: selection, operationID: operationID, proof: nil)
        try save()
    }
    func observe(_ data: Data, reference: RuntimeSessionReference) {
        guard data.count <= 65_536,
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["threadId"] as? String == reference.nativeSessionID,
            let settings = value["threadSettings"] as? [String: Any],
            settings["cwd"] as? String != nil, settings["approvalPolicy"] as? String == "on-request",
            (settings["sandboxPolicy"] as? [String: Any])?["type"] as? String == "readOnly",
            let collaboration = settings["collaborationMode"] as? [String: Any],
            let mode = collaboration["mode"] as? String, ["default", "plan"].contains(mode),
            let nested = collaboration["settings"] as? [String: Any], let model = nested["model"] as? String,
            settings["model"] as? String == model,
            nested["developer_instructions"] == nil || nested["developer_instructions"] is NSNull,
            nested["reasoning_effort"] == nil || nested["reasoning_effort"] is NSNull
                || nested["reasoning_effort"] is String,
            (settings["effort"] as? String) == (nested["reasoning_effort"] as? String)
        else { return }
        let observed = CodexRuntimeModeSelection(
            mode: mode, model: model, effort: nested["reasoning_effort"] as? String)
        condition.lock()
        defer { condition.unlock() }
        guard reliable, let entry = state.entries[key(reference)] else { return }
        if entry.selection == observed {
            var updated = entry
            updated.proof = data
            state.entries[key(reference)] = updated
        } else {
            // A desktop may update this shared runtime. Follow verified native
            // changes after a completed selection; never resolve a pending intent
            // with a different mode/model/effort.
            guard entry.proof != nil else { return }
            state.entries[key(reference)] = Entry(selection: observed, operationID: "native-observation", proof: data)
        }
        do { try save() } catch { reliable = false }
        condition.broadcast()
    }
    func waitForProof(_ reference: RuntimeSessionReference, operationID: String) throws -> Entry? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(1)
        while reliable, let entry = state.entries[key(reference)], entry.operationID == operationID, entry.proof == nil
        {
            if !condition.wait(until: deadline) { break }
        }
        guard reliable else { throw RuntimeDriverError.storageUnavailable }
        return state.entries[key(reference)].flatMap { $0.operationID == operationID ? $0 : nil }
    }
    private func key(_ reference: RuntimeSessionReference) -> String {
        RuntimeOperationLedger.hash(Data((reference.instanceID + "\0" + reference.nativeSessionID).utf8))
    }
    private func save() throws {
        do {
            let bytes = try JSONEncoder().encode(state)
            guard bytes.count <= 1_048_576 else { throw RuntimeDriverError.storageUnavailable }
            try RuntimePrivateStorage.write(bytes, to: url)
        } catch {
            reliable = false
            throw error
        }
    }
}
