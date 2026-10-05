import Darwin
import Foundation

/// Read-only recovery from the reviewed native rollout. The caller must first
/// verify registry membership, live native identity and the database's path.
enum CodexBackgroundTurnEvidence {
    struct Proof {
        let mode: [String: Any]
        let serviceTier: String
    }
    private struct Settings {
        let mode: [String: Any]
        let serviceTier: String
        let model: String
        let effort: String
    }
    private static let fileLimit = 8 * 1024 * 1024
    private static let lineLimit = 2 * 1024 * 1024

    static func read(
        file: URL, thread: String, cwd: String, turn: String, marker: String, inputHash: String
    ) -> Proof? {
        guard file.isFileURL, file.path.hasPrefix("/"), UUID(uuidString: thread) != nil,
            UUID(uuidString: turn) != nil, cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.utf8.count <= 4096,
            !marker.isEmpty, marker.utf8.count <= 256, !marker.contains("\0"), inputHash.count == 64,
            inputHash.allSatisfy(\.isHexDigit)
        else { return nil }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
            info.st_size >= 0, info.st_size <= fileLimit
        else { return nil }
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard bytes.count + count <= fileLimit else { return nil }
            bytes.append(contentsOf: chunk.prefix(count))
        }
        return parse(bytes, thread: thread, cwd: cwd, turn: turn, marker: marker, inputHash: inputHash)
    }

    private static func parse(
        _ bytes: Data, thread: String, cwd: String, turn: String, marker: String, inputHash: String
    ) -> Proof? {
        var start = bytes.startIndex
        var sawMeta = false
        var latestSettings: Settings?
        var boundSettings: Settings?
        var contextMode: [String: Any]?
        var sawStarted = false
        var sawUser = false
        for end in bytes.indices where bytes[end] == 0x0a {
            guard end - start > 0, end - start <= lineLimit,
                let record = try? JSONSerialization.jsonObject(with: bytes[start..<end]) as? [String: Any],
                let kind = record["type"] as? String, let payload = record["payload"] as? [String: Any]
            else { return nil }
            start = end + 1
            if !sawMeta {
                guard kind == "session_meta", payload["id"] as? String == thread,
                    payload["cwd"] as? String == cwd, payload["originator"] as? String == "vibepier",
                    payload["cli_version"] as? String == CodexHeadlessRuntimeContract.version
                else { return nil }
                sawMeta = true
                continue
            }
            if kind == "session_meta" { return nil }
            if kind == "event_msg", payload["type"] as? String == "thread_settings_applied" {
                guard payload["thread_id"] as? String == thread,
                    let raw = payload["thread_settings"] as? [String: Any], raw["cwd"] as? String == cwd,
                    let settings = settings(raw)
                else { return nil }
                latestSettings = settings
            } else if kind == "event_msg", payload["type"] as? String == "task_started",
                payload["turn_id"] as? String == turn
            {
                guard !sawStarted, payload["root_turn_id"] as? String == turn, let settings = latestSettings else {
                    return nil
                }
                boundSettings = settings
                sawStarted = true
            } else if kind == "turn_context", payload["turn_id"] as? String == turn {
                guard sawStarted, contextMode == nil, !sawUser, payload["root_turn_id"] as? String == turn,
                    payload["cwd"] as? String == cwd, let settings = boundSettings,
                    let mode = mode(payload["collaboration_mode"]), payload["model"] as? String == settings.model,
                    payload["effort"] as? String == settings.effort,
                    NSDictionary(dictionary: mode).isEqual(to: settings.mode)
                else { return nil }
                contextMode = mode
            } else if kind == "event_msg", payload["type"] as? String == "item_completed" {
                guard payload["thread_id"] as? String == thread else { return nil }
                guard let item = payload["item"] as? [String: Any] else { return nil }
                if item["type"] as? String == "UserMessage", item["client_id"] as? String == marker {
                    guard sawStarted, contextMode != nil, !sawUser, payload["turn_id"] as? String == turn,
                        let content = item["content"] as? [[String: Any]],
                        let canonical = CodexConfiguredCreation.Observation.canonicalInput(content),
                        CodexConversation.dataHash(canonical) == inputHash
                    else { return nil }
                    sawUser = true
                }
            }
        }
        // A native writer may still be appending its last record. Never interpret
        // that incomplete line; the same bounded read can be retried later.
        guard bytes.endIndex - start <= lineLimit, sawMeta, sawStarted, sawUser,
            let mode = contextMode, let settings = boundSettings
        else { return nil }
        return Proof(mode: mode, serviceTier: settings.serviceTier)
    }

    private static func settings(_ raw: [String: Any]) -> Settings? {
        guard let mode = mode(raw["collaboration_mode"]), let model = raw["model"] as? String,
            let effort = raw["reasoning_effort"] as? String,
            let options = mode["settings"] as? [String: Any], options["model"] as? String == model,
            options["reasoning_effort"] as? String == effort, let tier = raw["service_tier"] as? String
        else { return nil }
        let serviceTier: String
        switch tier {
        case "default": serviceTier = "standard"
        case "priority": serviceTier = "priority"
        default: return nil
        }
        return Settings(mode: mode, serviceTier: serviceTier, model: model, effort: effort)
    }
    private static func mode(_ value: Any?) -> [String: Any]? {
        guard let value = value as? [String: Any], Set(value.keys) == ["mode", "settings"],
            let name = value["mode"] as? String, ["default", "plan"].contains(name),
            let options = value["settings"] as? [String: Any],
            Set(options.keys) == ["model", "reasoning_effort", "developer_instructions"],
            let model = options["model"] as? String, !model.isEmpty, model.utf8.count <= 1024,
            let effort = options["reasoning_effort"] as? String, !effort.isEmpty, effort.utf8.count <= 64,
            let instructions = options["developer_instructions"],
            instructions is NSNull
                || (instructions as? String).map({ $0.utf8.count <= 128_000 }) == true
        else { return nil }
        return value
    }
}
