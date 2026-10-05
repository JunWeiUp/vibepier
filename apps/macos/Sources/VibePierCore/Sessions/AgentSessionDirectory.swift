import Foundation

/// Private bounded identity index. It stores no prompts, credentials or provider configuration.
final class AgentSessionDirectory {
    struct Session: Codable, Sendable {
        let ref: String
        let adapterID: String
        let provider: String
        let nativeID: String
        let cwd: String
    }
    struct Workspace: Codable, Sendable {
        let ref: String
        let adapterID: String
        let provider: String
        let cwd: String
    }
    private struct Store: Codable {
        var hostRef: String
        var sessions: [String: Session] = [:]
        var workspaces: [String: Workspace] = [:]
    }
    private let file: URL?
    private var store: Store
    private var revision: Data?
    private(set) var reliable = true
    var hostRef: String { store.hostRef }
    init(file: URL? = nil) throws {
        self.file = file
        if let file, let bytes = try ReceiptJournalFile.read(file, limit: 2 * 1024 * 1024) {
            let value = try JSONDecoder().decode(Store.self, from: bytes)
            guard UUID(uuidString: value.hostRef) != nil, value.sessions.count <= 4096, value.workspaces.count <= 1024,
                value.sessions.allSatisfy({ key, value in
                    key == value.ref && AgentSessionProfile.bounded(value.nativeID, maximum: 1024)
                        && Self.valid(value.cwd) && AgentSessionProfile.bounded(value.adapterID, maximum: 128)
                }), value.workspaces.allSatisfy({ $0.key == $0.value.ref && Self.valid($0.value.cwd) })
            else { throw AgentSessionProfile.Failure(code: "agent_index_invalid") }
            guard
                value.sessions.allSatisfy({ key, session in
                    Self.valid(adapter: session.adapterID, provider: session.provider)
                        && key
                            == Self.reference(
                                host: value.hostRef,
                                fields: ["session", session.adapterID, session.nativeID, session.cwd])
                }),
                value.workspaces.allSatisfy({ key, workspace in
                    Self.valid(adapter: workspace.adapterID, provider: workspace.provider)
                        && key
                            == Self.reference(
                                host: value.hostRef, fields: ["workspace", workspace.adapterID, workspace.cwd])
                })
            else { throw AgentSessionProfile.Failure(code: "agent_index_invalid") }
            store = value
            revision = SessionReceiptJournal.digest(bytes)
        } else {
            store = Store(hostRef: UUID().uuidString.lowercased())
        }
    }
    func session(_ ref: String) -> Session? { store.sessions[ref] }
    func workspace(_ ref: String) -> Workspace? { store.workspaces[ref] }
    func registerSession(adapter: String, provider: String, native: String, cwd: String) throws -> Session {
        guard Self.valid(cwd), Self.valid(adapter: adapter, provider: provider),
            AgentSessionProfile.bounded(native, maximum: 1024), reliable
        else {
            throw AgentSessionProfile.Failure(code: "agent_index_invalid")
        }
        let ref = reference(["session", adapter, native, cwd])
        if let known = store.sessions[ref] { return known }
        guard store.sessions.count < 4096 else { throw AgentSessionProfile.Failure(code: "capacity_exceeded") }
        let value = Session(ref: ref, adapterID: adapter, provider: provider, nativeID: native, cwd: cwd)
        var next = store
        next.sessions[ref] = value
        try publish(next)
        return value
    }
    func registerWorkspace(adapter: String, provider: String, cwd: String) throws -> Workspace {
        guard Self.valid(cwd), Self.valid(adapter: adapter, provider: provider), reliable else {
            throw AgentSessionProfile.Failure(code: "agent_index_invalid")
        }
        let ref = reference(["workspace", adapter, cwd])
        if let known = store.workspaces[ref] { return known }
        guard store.workspaces.count < 1024 else { throw AgentSessionProfile.Failure(code: "capacity_exceeded") }
        let value = Workspace(ref: ref, adapterID: adapter, provider: provider, cwd: cwd)
        var next = store
        next.workspaces[ref] = value
        try publish(next)
        return value
    }
    private func reference(_ fields: [String]) -> String {
        Self.reference(host: store.hostRef, fields: fields)
    }
    private static func reference(host: String, fields: [String]) -> String {
        AgentSessionProfile.digest(AgentSessionProfile.data(["host": host, "identity": fields]))
    }
    private static func valid(adapter: String, provider: String) -> Bool {
        [
            "codex.currentV1": "codex", "claude.currentV1": "claude", "zcode.currentV1": "zcode",
            "codex.managedAppServer": "codex", "claude.desktopMods": "claude",
        ][adapter] == provider
    }
    private func publish(_ next: Store) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(next)
        guard bytes.count <= 2 * 1024 * 1024 else { throw AgentSessionProfile.Failure(code: "capacity_exceeded") }
        if let file {
            do { try ReceiptJournalFile.commit(bytes, to: file, expected: revision, limit: 2 * 1024 * 1024) } catch {
                reliable = false
                throw error
            }
        }
        store = next
        revision = SessionReceiptJournal.digest(bytes)
    }
    private static func valid(_ cwd: String) -> Bool {
        cwd.hasPrefix("/") && AgentSessionProfile.bounded(cwd, maximum: 4096)
    }
}
