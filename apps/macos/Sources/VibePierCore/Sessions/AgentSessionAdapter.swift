import Foundation

/// currentV1 wraps the existing native contract without rewriting its request or receipt.
protocol AgentSessionAdapter: AnyObject, Sendable {
    var providerID: String { get }
    var adapterID: String { get }
    var backendKinds: [String] { get }
    var event: (@Sendable (String, Data) -> Void)? { get set }
    func performCurrentV1(_ data: Data, client: String, completion: @escaping @Sendable (Data) -> Void)
    func stopObservation(client: String)
    func stopAllObservations()
    func creationRuntimeAvailable() -> Bool
}

/// These closures preserve each Bridge's queue, admission, native evidence and process lifetime.
final class CurrentV1AgentAdapter: AgentSessionAdapter, @unchecked Sendable {
    let providerID: String
    var adapterID: String { providerID + ".currentV1" }
    let backendKinds: [String]
    private let execute: @Sendable (Data, String, @escaping @Sendable (Data) -> Void) -> Void
    private let stopClient: @Sendable (String) -> Void
    private let stopEverything: @Sendable () -> Void
    private let creationHealth: @Sendable () -> Bool
    private let lock = NSLock()
    private var sink: (@Sendable (String, Data) -> Void)?
    var event: (@Sendable (String, Data) -> Void)? {
        get { lock.withLock { sink } }
        set { lock.withLock { sink = newValue } }
    }

    init(
        provider: String, backendKinds: [String],
        execute: @escaping @Sendable (Data, String, @escaping @Sendable (Data) -> Void) -> Void,
        stop: @escaping @Sendable (String) -> Void,
        stopAll: @escaping @Sendable () -> Void,
        creationAvailable: @escaping @Sendable () -> Bool = { true }
    ) {
        providerID = provider
        self.backendKinds = backendKinds
        self.execute = execute
        stopClient = stop
        stopEverything = stopAll
        creationHealth = creationAvailable
    }
    func performCurrentV1(_ data: Data, client: String, completion: @escaping @Sendable (Data) -> Void) {
        execute(data, client, completion)
    }
    func stopObservation(client: String) { stopClient(client) }
    func stopAllObservations() { stopEverything() }
    func creationRuntimeAvailable() -> Bool { creationHealth() }
    func emit(client: String, data: Data) { event?(client, data) }

    static func production() -> [any AgentSessionAdapter] {
        let codex = CodexBridge()
        let claude = ClaudeBridge()
        let zcode = ZCodeBridge(desktop: ZCodeDesktop.access)
        let adapters = [
            CurrentV1AgentAdapter(
                provider: "codex", backendKinds: ["desktopAttached"],
                execute: { codex.perform($0, client: $1, completion: $2) },
                stop: { codex.stop($0) }, stopAll: { codex.stopAll() }),
            CurrentV1AgentAdapter(
                provider: "claude", backendKinds: ["desktopAttached", "managedRuntime"],
                execute: { claude.perform($0, client: $1, completion: $2) },
                stop: { claude.stop($0) }, stopAll: { claude.stopAll() },
                creationAvailable: { ClaudeBridge.executable() != nil }),
            CurrentV1AgentAdapter(
                provider: "zcode", backendKinds: ["desktopAttached"],
                execute: { zcode.perform($0, client: $1, completion: $2) },
                stop: { zcode.stop($0) }, stopAll: { zcode.stopAll() }),
        ]
        codex.event = { [weak adapter = adapters[0]] client, data in adapter?.emit(client: client, data: data) }
        claude.event = { [weak adapter = adapters[1]] client, data in adapter?.emit(client: client, data: data) }
        zcode.event = { [weak adapter = adapters[2]] client, data in adapter?.emit(client: client, data: data) }
        return adapters
    }
}

struct AgentAdapterRegistry: Sendable {
    enum Failure: Error { case duplicateProvider, unsupportedProvider }
    private let adapters: [String: any AgentSessionAdapter]
    init(_ values: [any AgentSessionAdapter]) throws {
        var entries: [String: any AgentSessionAdapter] = [:]
        for adapter in values {
            guard SessionV1Contract.providers.contains(adapter.providerID) else { throw Failure.unsupportedProvider }
            guard entries[adapter.providerID] == nil else { throw Failure.duplicateProvider }
            entries[adapter.providerID] = adapter
        }
        adapters = entries
    }
    var all: [any AgentSessionAdapter] { SessionV1Contract.providers.compactMap { adapters[$0] } }
    func adapter(provider: String?) -> (any AgentSessionAdapter)? {
        adapters[provider == nil || provider == "" ? "codex" : provider!]
    }
}
