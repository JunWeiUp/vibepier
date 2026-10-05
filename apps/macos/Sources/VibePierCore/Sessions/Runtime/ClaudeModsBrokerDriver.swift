import CoreFoundation
import Foundation
import Security

/// Local broker for an explicitly bound Claude Code Mods instance. No native
/// credentials are shared; bootstrap tokens are scoped to one approved session.
public final class ClaudeModsBrokerDriver: AgentRuntimeDriver, @unchecked Sendable {
    public struct Configuration: Codable, Sendable {
        public var enabled: Bool
        /// Exact versions whose target-generated types have been reviewed.
        public var reviewedRuntimeVersions: [String]
        public init(enabled: Bool = false, reviewedRuntimeVersions: [String] = []) {
            self.enabled = enabled
            self.reviewedRuntimeVersions = reviewedRuntimeVersions
        }
    }
    public struct Bootstrap: Codable, Sendable {
        public let endpoint: String
        public let token: String
        public let sessionID: String
        public let cwd: String
        public let runtimeVersion: String
        public let contractDigest: String
        public let expiresAt: TimeInterval
    }
    public struct HTTPRequest: Sendable {
        public let remoteAddress: String
        public let method: String
        public let path: String
        public let host: String
        public let origin: String?
        public let authorization: String?
        public let body: Data
        public init(
            remoteAddress: String, method: String, path: String, host: String,
            origin: String? = nil, authorization: String?, body: Data
        ) {
            self.remoteAddress = remoteAddress
            self.method = method
            self.path = path
            self.host = host
            self.origin = origin
            self.authorization = authorization
            self.body = body
        }
    }
    public struct HTTPResponse: Sendable {
        public let status: Int
        public let body: Data
    }
    private struct Binding {
        let bootstrap: Bootstrap
        let writesVerified: Bool
        var reference: RuntimeSessionReference?
        var activeTurnID: String?
        var idleVerified = false
        var snapshot = Data("{}".utf8)
        var lastSeen: TimeInterval
        var queued: [QueuedCommand] = []
    }
    private struct QueuedCommand {
        let command: RuntimeCommand
        let context: RuntimeOperationContext
        let fingerprint: String
    }
    public let adapterID = "claude.desktopMods"
    public let configuration: Configuration
    private let ledger: RuntimeOperationLedger
    private let events: RuntimeEventBuffer
    private let lock = NSLock()
    private let operations = NSLock()
    private var bindings: [String: Binding] = [:]
    private var delivered: [String: QueuedCommand] = [:]
    private var server: RuntimeLoopbackHTTPServer?
    private var endpoint = ""
    private let now: @Sendable () -> TimeInterval
    public init(
        configuration: Configuration, ledgerURL: URL, eventBuffer: RuntimeEventBuffer = RuntimeEventBuffer(),
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.configuration = configuration
        ledger = RuntimeOperationLedger(url: ledgerURL)
        events = eventBuffer
        self.now = now
    }
    deinit { disconnect() }
    /// The broker is never started by init/discover/status. Loopback only.
    public func start() throws {
        guard configuration.enabled else { throw RuntimeDriverError.disabled }
        lock.lock()
        defer { lock.unlock() }
        guard server == nil else { return }
        let candidate = RuntimeLoopbackHTTPServer { [weak self] request in
            self?.handle(request) ?? HTTPResponse(status: 503, body: Data("{}".utf8))
        }
        let port = try candidate.start()
        server = candidate
        endpoint = "http://127.0.0.1:\(port)"
    }
    /// Pure injected HTTP boundary for unit tests; production uses start().
    func setTestEndpoint(port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        if server == nil { endpoint = "http://127.0.0.1:\(port)" }
    }
    public func issueBinding(
        sessionID: String, cwd: String, runtimeVersion: String,
        contractDigest: String, nativeWritesVerified: Bool = false
    ) throws -> Bootstrap {
        guard configuration.enabled else { throw RuntimeDriverError.disabled }
        guard Self.minimumVersion(runtimeVersion), configuration.reviewedRuntimeVersions.contains(runtimeVersion)
        else { throw RuntimeDriverError.incompatibleVersion }
        guard validID(sessionID), cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.utf8.count <= 4096,
            contractDigest.count == 64, contractDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw RuntimeDriverError.invalidRequest }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw RuntimeDriverError.unavailable }
        let token = Data(bytes).base64EncodedString()
        lock.lock()
        defer { lock.unlock() }
        expireBindings()
        guard !endpoint.isEmpty, bindings.count < 16 else { throw RuntimeDriverError.unavailable }
        // A fresh explicit binding invalidates old instance tokens and queued
        // commands for the same native session, without interrupting its task.
        let oldKeys = bindings.filter { $0.value.bootstrap.sessionID == sessionID }.map(\.key)
        for key in oldKeys { retireBinding(key) }
        let bootstrap = Bootstrap(
            endpoint: endpoint, token: token, sessionID: sessionID, cwd: cwd,
            runtimeVersion: runtimeVersion, contractDigest: contractDigest, expiresAt: now() + 600)
        bindings[token] = Binding(bootstrap: bootstrap, writesVerified: nativeWritesVerified, lastSeen: now())
        return bootstrap
    }
    public func writeBootstrap(_ bootstrap: Bootstrap, to url: URL) throws {
        try RuntimePrivateStorage.write(try JSONEncoder().encode(bootstrap), to: url)
    }
    public func describe() -> RuntimeDriverDescriptor {
        lock.lock()
        defer { lock.unlock() }
        expireBindings()
        let active = bindings.values.filter { $0.reference != nil && now() - $0.lastSeen <= 30 }
        let writable = active.contains { $0.writesVerified }
        return RuntimeDriverDescriptor(
            adapterID: adapterID, backendKind: "desktopAttached",
            enabled: configuration.enabled, available: !active.isEmpty,
            reason: configuration.enabled ? (active.isEmpty ? "no_verified_mods_instance" : "") : "disabled",
            capabilities: active.isEmpty
                ? [] : ["session.observe"] + (writable ? ["message.submit.start", "turn.interrupt"] : []))
    }
    public func discover() throws -> [RuntimeSession] {
        lock.lock()
        defer { lock.unlock() }
        expireBindings()
        return bindings.values.compactMap { binding in
            guard let reference = binding.reference, now() - binding.lastSeen <= 30 else { return nil }
            return RuntimeSession(
                reference: reference, cwd: binding.bootstrap.cwd, runtimeVersion: binding.bootstrap.runtimeVersion,
                activeTurnID: binding.activeTurnID, writable: binding.writesVerified)
        }.sorted { $0.reference.nativeSessionID < $1.reference.nativeSessionID }
    }
    public func snapshot(_ session: RuntimeSessionReference) throws -> RuntimeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        expireBindings()
        guard let binding = bindings.values.first(where: { $0.reference == session }), now() - binding.lastSeen <= 30
        else { throw RuntimeDriverError.staleOwner }
        return RuntimeSnapshot(
            session: RuntimeSession(
                reference: session, cwd: binding.bootstrap.cwd,
                runtimeVersion: binding.bootstrap.runtimeVersion, activeTurnID: binding.activeTurnID,
                writable: binding.writesVerified),
            cursor: events.replay(session, after: nil).cursor, nativeJSON: binding.snapshot, partial: true)
    }
    public func execute(_ command: RuntimeCommand, context: RuntimeOperationContext) throws -> RuntimeReceipt {
        operations.lock()
        defer { operations.unlock() }
        guard configuration.enabled, let session = context.session, session.adapterID == adapterID else {
            throw RuntimeDriverError.disabled
        }
        switch command {
        case .create, .configureExecutionMode, .submitConfigured, .resolveApproval, .answerQuestion:
            throw RuntimeDriverError.invalidRequest
        case .submit(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 240_000 else {
                throw RuntimeDriverError.invalidRequest
            }
        case .interrupt(let turnID): guard validID(turnID) else { throw RuntimeDriverError.invalidRequest }
        }
        if let prior = try ledger.reserve(command, context: context) { return prior }
        lock.lock()
        defer { lock.unlock() }
        expireBindings()
        guard let key = bindings.first(where: { $0.value.reference == session })?.key,
            var binding = bindings[key], binding.writesVerified, now() - binding.lastSeen <= 5,
            binding.queued.count < 16, delivered.count < 128
        else {
            return RuntimeReceipt(
                operationID: context.operationID, status: .unknown, session: session,
                reason: "mods_instance_unavailable")
        }
        switch command {
        case .submit:
            guard binding.idleVerified, binding.activeTurnID == nil else { throw RuntimeDriverError.staleOwner }
        case .interrupt(let id): guard binding.activeTurnID == id else { throw RuntimeDriverError.staleOwner }
        case .create, .configureExecutionMode, .submitConfigured, .resolveApproval, .answerQuestion:
            throw RuntimeDriverError.invalidRequest
        }
        let queuedBytes = bindings.values.reduce(0) {
            $0
                + $1.queued.reduce(0) { count, queued in
                    count + ((try? JSONEncoder().encode(queued.command).count) ?? 300_000)
                }
        }
        guard queuedBytes + (try JSONEncoder().encode(command).count) <= 2_097_152 else {
            throw RuntimeDriverError.quotaExceeded
        }
        binding.queued.append(
            QueuedCommand(
                command: command, context: context,
                fingerprint: context.requestFingerprint))
        bindings[key] = binding
        return RuntimeReceipt(
            operationID: context.operationID, status: .unknown, session: session,
            reason: "mods_native_confirmation_pending")
    }
    public func reconcile(_ context: RuntimeOperationContext) throws -> RuntimeReceipt { try ledger.lookup(context) }
    public func replay(_ session: RuntimeSessionReference, after: RuntimeCursor?) -> RuntimeReplay {
        events.replay(session, after: after)
    }
    public func disconnect() {
        lock.lock()
        let old = server
        server = nil
        endpoint = ""
        bindings.removeAll()
        delivered.removeAll()
        lock.unlock()
        old?.stop()
    }
    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard configuration.enabled, request.remoteAddress == "127.0.0.1", request.origin == nil,
            request.method == "POST", request.body.count <= 300_000,
            let authorization = request.authorization, authorization.hasPrefix("Bearer ")
        else { return response(403) }
        lock.lock()
        defer { lock.unlock() }
        expireBindings()
        guard let host = URL(string: endpoint)?.host, let port = URL(string: endpoint)?.port,
            request.host == "\(host):\(port)",
            let key = bindings.keys.first(where: { Self.constantTime($0, String(authorization.dropFirst(7))) }),
            var binding = bindings[key],
            let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
            body["sessionID"] as? String == binding.bootstrap.sessionID,
            let instance = body["instanceID"] as? String, validID(instance)
        else { return response(403) }
        if request.path == "/v1/register" {
            guard body["cwd"] as? String == binding.bootstrap.cwd,
                body["runtimeVersion"] as? String == binding.bootstrap.runtimeVersion,
                body["contractDigest"] as? String == binding.bootstrap.contractDigest
            else { return response(409) }
            if let reference = binding.reference, reference.instanceID != instance { return response(409) }
            if binding.reference == nil {
                binding.reference = RuntimeSessionReference(
                    adapterID: adapterID, instanceID: instance,
                    nativeSessionID: binding.bootstrap.sessionID, ownershipEpoch: UUID().uuidString)
            }
            binding.lastSeen = now()
            bindings[key] = binding
            return response(
                200,
                [
                    "ownershipEpoch": binding.reference!.ownershipEpoch,
                    "writesVerified": binding.writesVerified,
                ])
        }
        guard let reference = binding.reference, reference.instanceID == instance,
            body["ownershipEpoch"] as? String == reference.ownershipEpoch
        else { return response(409) }
        binding.lastSeen = now()
        switch request.path {
        case "/v1/poll":
            guard let boolean = body["idle"] as? NSNumber,
                CFGetTypeID(boolean) == CFBooleanGetTypeID(),
                let idle = body["idle"] as? Bool,
                body["activeTurnID"] == nil || body["activeTurnID"] is NSNull
                    || validID(body["activeTurnID"] as? String ?? "")
            else { return response(400) }
            binding.idleVerified = idle
            binding.activeTurnID = body["activeTurnID"] as? String
            guard !(idle && binding.activeTurnID != nil) else { return response(400) }
            if !binding.queued.isEmpty {
                let queued = binding.queued.removeFirst()
                let operationKey = Self.operationKey(queued.context)
                // Delivery is one-shot. Lost HTTP responses remain unknown;
                // polling again never redelivers the native side effect.
                delivered[operationKey] = queued
                bindings[key] = binding
                var command: [String: Any] = [
                    "operationID": queued.context.operationID,
                    "operationKey": operationKey, "fingerprint": queued.fingerprint,
                    "sessionID": reference.nativeSessionID, "instanceID": reference.instanceID,
                    "ownershipEpoch": reference.ownershipEpoch,
                ]
                switch queued.command {
                case .submit(let text):
                    command["action"] = "submit"
                    command["text"] = text
                case .interrupt(let turnID):
                    command["action"] = "interrupt"
                    command["turnID"] = turnID
                case .create, .configureExecutionMode, .submitConfigured, .resolveApproval, .answerQuestion:
                    return response(400)
                }
                return response(200, ["command": command])
            }
            bindings[key] = binding
            return response(200, ["command": NSNull()])
        case "/v1/events":
            guard let batch = body["events"] as? [[String: Any]], batch.count <= 32 else { return response(400) }
            for event in batch {
                guard let method = event["method"] as? String,
                    ["session.append", "turn.start", "turn.complete", "session.snapshot", "resync"].contains(method),
                    let payload = event["payload"], let data = try? JSONSerialization.data(withJSONObject: payload),
                    data.count <= 280_000
                else { return response(400) }
                events.append(reference, method: method, payload: data)
                if method == "session.snapshot" { binding.snapshot = data }
            }
            bindings[key] = binding
            return response(200)
        case "/v1/result":
            guard let operationKey = body["operationKey"] as? String,
                let queued = delivered[operationKey], queued.context.session == reference,
                body["fingerprint"] as? String == queued.fingerprint
            else { return response(409) }
            // Public Mods messages() lacks proven native message identities.
            // Plugin ACK, turn.start and pre-storage append are never confirmation.
            let receipt = RuntimeReceipt(
                operationID: queued.context.operationID, status: .unknown,
                session: reference, nativeTurnID: body["nativeTurnID"] as? String,
                reason: "native_authoritative_evidence_required")
            do { try ledger.record(receipt, context: queued.context) } catch { return response(503) }
            delivered.removeValue(forKey: operationKey)
            bindings[key] = binding
            return response(200)
        case "/v1/end":
            retireBinding(key)
            return response(200)
        default: return response(404)
        }
    }
    /// An independently verified native transcript/turn reader supplied by the
    /// adapter promotes a pending result. HTTP plugin claims cannot call this.
    public func confirmNativeEvidence(
        context: RuntimeOperationContext, nativeTurnID: String,
        nativeMessageID: String?, evidence: Data,
        verify: (RuntimeOperationContext, Data) throws -> Bool
    ) throws -> RuntimeReceipt {
        guard validID(nativeTurnID), evidence.count <= 300_000, try verify(context, evidence)
        else { throw RuntimeDriverError.unavailable }
        let prior = try ledger.lookup(context)
        guard prior.status == .unknown else { return prior }
        let receipt = RuntimeReceipt(
            operationID: context.operationID, status: .confirmed,
            session: context.session, nativeTurnID: nativeTurnID, nativeMessageID: nativeMessageID)
        try ledger.record(receipt, context: context)
        return receipt
    }
    private func expireBindings() {
        let expired = bindings.filter { now() >= $0.value.bootstrap.expiresAt }.map(\.key)
        for key in expired { retireBinding(key) }
    }
    private func retireBinding(_ key: String) {
        guard let old = bindings.removeValue(forKey: key) else { return }
        if let reference = old.reference {
            events.retire(reference)
            delivered = delivered.filter { $0.value.context.session != reference }
        }
    }
    private func response(_ status: Int, _ value: [String: Any] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8))
    }
    private func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0") }
    public static func minimumVersion(_ version: String) -> Bool {
        let values = version.split(separator: ".").compactMap { Int($0) }
        guard values.count == 3 else { return false }
        return values.lexicographicallyPrecedes([2, 1, 287]) == false
    }
    private static func operationKey(_ context: RuntimeOperationContext) -> String {
        RuntimeOperationLedger.hash(Data((context.trustedDeviceID + "\0" + context.operationID).utf8))
    }
    private static func constantTime(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
