import CoreFoundation
import Foundation

public final class CodexManagedRuntimeDriver: AgentRuntimeDriver, @unchecked Sendable {
    public let adapterID = "codex.managedAppServer"
    public let configuration: CodexManagedRuntimeConfiguration
    private let ledger: RuntimeOperationLedger
    private let eventBuffer: RuntimeEventBuffer
    private let modeStore: CodexRuntimeModeStore
    private var modeCatalog: CodexRuntimeModeCatalog?
    private let reverseRequests = CodexRuntimePendingRequests()
    private let lock = NSLock()
    private let operations = NSLock()
    private var connection: CodexRuntimeConnection?
    private var epoch = UUID().uuidString
    private var sessions: [String: RuntimeSession] = [:]
    private var healthReason = "disabled"
    private var accountVerified = false
    /// Injection makes ordinary tests independent of accounts, native apps and processes.
    private let connectNative: (CodexManagedRuntimeConfiguration) throws -> CodexRuntimeConnection

    public init(
        configuration: CodexManagedRuntimeConfiguration, ledgerURL: URL,
        eventBuffer: RuntimeEventBuffer = RuntimeEventBuffer(),
        connectNative: ((CodexManagedRuntimeConfiguration) throws -> CodexRuntimeConnection)? = nil
    ) {
        self.configuration = configuration
        self.ledger = RuntimeOperationLedger(url: ledgerURL)
        self.eventBuffer = eventBuffer
        self.modeStore = CodexRuntimeModeStore(url: ledgerURL.appendingPathExtension("execution-modes.json"))
        self.connectNative = connectNative ?? { try CodexSocketRuntimeConnection(configuration: $0) }
        if configuration.enabled { healthReason = "not_connected" }
    }
    /// Explicit enable/start boundary; init/status/discover never launch a server.
    public func connect() throws {
        operations.lock()
        defer { operations.unlock() }
        guard configuration.enabled else { throw RuntimeDriverError.disabled }
        lock.lock()
        let existing = connection
        lock.unlock()
        if existing != nil {
            try refreshAccountStatus()
            return
        }
        let candidate = try connectNative(configuration)
        guard candidate.runtimeVersion == CodexManagedRuntimeContract.version else {
            candidate.disconnect()
            throw RuntimeDriverError.incompatibleVersion
        }
        let newEpoch = UUID().uuidString
        let known = try ledger.knownSessions(adapterID: adapterID, instanceID: candidate.instanceID)
        candidate.onNotification = { [weak self] method, data in self?.receive(method, data: data) }
        candidate.onServerRequest = { [weak self] id, method, params in
            self?.receiveServerRequest(id, method: method, params: params) == true
        }
        lock.lock()
        connection = candidate
        epoch = newEpoch
        sessions.removeAll()
        healthReason = ""
        lock.unlock()
        try refreshAccountStatus()
        // Hydrate only VibePier-created IDs. Never thread/list/resume arbitrary
        // desktop history or seize an existing external writer.
        for old in known {
            let reference = RuntimeSessionReference(
                adapterID: adapterID, instanceID: candidate.instanceID,
                nativeSessionID: old.nativeSessionID, ownershipEpoch: newEpoch)
            if let data = try? request(
                candidate, "thread/read", ["threadId": old.nativeSessionID, "includeTurns": false]),
                let session = try? projectSession(data, reference: reference, runtimeVersion: candidate.runtimeVersion)
            {
                lock.lock()
                sessions[old.nativeSessionID] = session
                lock.unlock()
            }
        }
    }
    public func describe() -> RuntimeDriverDescriptor {
        lock.lock()
        defer { lock.unlock() }
        return RuntimeDriverDescriptor(
            adapterID: adapterID, backendKind: "managedRuntime",
            enabled: configuration.enabled,
            available: configuration.enabled && connection?.connected == true && accountVerified,
            reason: connection != nil && connection?.connected == false ? "runtime_unavailable" : healthReason,
            capabilities: connection?.connected != true
                ? []
                : [
                    "session.create", "message.submit.start", "turn.interrupt", "approval.resolve", "question.answer",
                    "session.observe",
                ] + (modeCatalog == nil ? [] : ["session.executionMode.configure"]))
    }
    /// Read-only account metadata; no refresh, login, tokens or model task.
    public func refreshAccountStatus() throws {
        lock.lock()
        let native = connection
        lock.unlock()
        guard let native else { throw RuntimeDriverError.unavailable }
        let data = try request(native, "account/read", ["refreshToken": false])
        let value = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let requiresAuth = value["requiresOpenaiAuth"] as? NSNumber
        let type = (value["account"] as? [String: Any])?["type"] as? String
        let verified =
            requiresAuth.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
            && ["apiKey", "chatgpt"].contains(type ?? "")
        lock.lock()
        accountVerified = verified
        healthReason = verified ? "" : "managed_account_login_required"
        modeCatalog = nil
        lock.unlock()
        if verified, native.supportsExecutionModes {
            let catalog = try? CodexRuntimeModeCatalog(
                modesJSON: request(native, "collaborationMode/list", [:]),
                modelsJSON: request(native, "model/list", ["limit": 100, "includeHidden": false]))
            lock.lock()
            modeCatalog = catalog
            lock.unlock()
        }
    }
    public func discover() throws -> [RuntimeSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.sorted { $0.reference.nativeSessionID < $1.reference.nativeSessionID }
    }
    public func snapshot(_ reference: RuntimeSessionReference) throws -> RuntimeSnapshot {
        let native = try validatedConnection(reference)
        let data = try request(native, "thread/read", ["threadId": reference.nativeSessionID, "includeTurns": true])
        let session = try projectSession(data, reference: reference, runtimeVersion: native.runtimeVersion)
        lock.lock()
        sessions[reference.nativeSessionID] = session
        lock.unlock()
        let after = eventBuffer.replay(reference, after: nil).cursor
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["pendingRequests"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(reverseRequests.pending(reference)))
        object["runtimeConstraints"] = ["sandbox": "read-only", "approvalScope": "turn", "persistentRules": false]
        let modes = try executionModes(reference, nativeData: data)
        object["executionModes"] = modes
        if let selection = try modeStore.entry(reference) {
            object["executionMode"] = selection.selection.mode
            object["executionModeVerified"] = selection.proof != nil
            object["executionModePending"] = selection.proof == nil
        } else {
            object["executionMode"] = "default"
            object["executionModeVerified"] = false
        }
        return RuntimeSnapshot(
            session: session, cursor: after,
            nativeJSON: try JSONSerialization.data(withJSONObject: object), partial: true)
    }
    public func pendingRequests(_ reference: RuntimeSessionReference) -> [RuntimeNativeRequest] {
        reverseRequests.pending(reference)
    }
    public func creationExecutionModes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return modeCatalog?.modes ?? []
    }
    public func executionModes(_ reference: RuntimeSessionReference) throws -> [String] {
        let native = try validatedConnection(reference)
        let data = try request(native, "thread/read", ["threadId": reference.nativeSessionID, "includeTurns": false])
        return try executionModes(reference, nativeData: data)
    }
    private func executionModes(_ reference: RuntimeSessionReference, nativeData: Data) throws -> [String] {
        guard (try? modeSelection("default", reference: reference, nativeData: nativeData)) != nil else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return modeCatalog?.modes ?? []
    }
    private func modeSelection(_ mode: String, reference: RuntimeSessionReference, nativeData: Data) throws
        -> CodexRuntimeModeSelection
    {
        lock.lock()
        let catalog = modeCatalog
        lock.unlock()
        guard let catalog, let value = try JSONSerialization.jsonObject(with: nativeData) as? [String: Any],
            let thread = value["thread"] as? [String: Any], thread["id"] as? String == reference.nativeSessionID
        else { throw RuntimeDriverError.unavailable }
        return try catalog.selection(mode: mode, model: thread["model"], effort: thread["reasoningEffort"])
    }
    public func execute(_ command: RuntimeCommand, context: RuntimeOperationContext) throws -> RuntimeReceipt {
        operations.lock()
        defer { operations.unlock() }
        guard configuration.enabled else { throw RuntimeDriverError.disabled }
        if let previous = try ledger.reserve(command, context: context) { return previous }
        do {
            let receipt = try perform(command, context: context)
            do {
                try ledger.record(receipt, context: context)
                return receipt
            } catch {
                return RuntimeReceipt(
                    operationID: context.operationID, status: .unknown, session: receipt.session,
                    nativeTurnID: receipt.nativeTurnID, reason: "receipt_storage_unavailable")
            }
        } catch {
            // Once reserved, transport errors cannot prove that the server did not
            // receive the operation. No second driver, resend, or resume follows.
            return (try? ledger.lookup(context))
                ?? RuntimeReceipt(
                    operationID: context.operationID, status: .unknown,
                    session: context.session, reason: "native_confirmation_unavailable")
        }
    }
    public func reconcile(_ context: RuntimeOperationContext) throws -> RuntimeReceipt {
        let prior = try ledger.lookup(context)
        if prior.status == .unknown, prior.reason == "native_execution_mode_confirmation_pending",
            let reference = prior.session, let entry = try modeStore.entry(reference),
            entry.operationID == context.operationID, let proof = entry.proof
        {
            let confirmed = RuntimeReceipt(
                operationID: context.operationID, status: .confirmed, session: reference,
                executionMode: entry.selection.mode, nativeSettingsJSON: proof)
            try ledger.record(confirmed, context: context)
            return confirmed
        }
        guard prior.status == .unknown, let reference = prior.session, let turnID = prior.nativeTurnID else {
            return prior
        }
        // Pure native read. A stale owner can still be queried through the new
        // registered reference for that same server and VibePier-created thread.
        lock.lock()
        let current = sessions[reference.nativeSessionID]?.reference
        lock.unlock()
        guard let current, current.instanceID == reference.instanceID,
            let data = try? snapshot(current).nativeJSON
        else { return prior }
        if prior.reason == "native_interrupt_confirmation_pending", try interrupted(data, turnID: turnID) {
            let receipt = RuntimeReceipt(
                operationID: context.operationID, status: .confirmed, session: reference, nativeTurnID: turnID)
            try ledger.record(receipt, context: context)
            return receipt
        }
        if prior.reason == "native_message_confirmation_pending",
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let thread = value["thread"] as? [String: Any], let turns = thread["turns"] as? [[String: Any]],
            let turn = turns.first(where: { $0["id"] as? String == turnID }),
            let items = turn["items"] as? [[String: Any]]
        {
            let marker =
                "vibepier_"
                + RuntimeOperationLedger.hash(Data((context.trustedDeviceID + "\0" + context.operationID).utf8))
            let matching = items.filter { $0["type"] as? String == "userMessage" && $0["id"] as? String == marker }
            if matching.count == 1, let content = matching[0]["content"] as? [[String: Any]], content.count == 1,
                content[0]["type"] as? String == "text", let text = content[0]["text"] as? String,
                try ledger.matchesCommand(
                    prior.executionMode.map { .submitConfigured(text: text, executionMode: $0) }
                        ?? .submit(text: text), context: context)
            {
                var modeProof = prior.nativeSettingsJSON
                if let expected = prior.executionMode, modeProof == nil {
                    let entry = try modeStore.entry(current)
                    guard entry?.operationID == context.operationID, entry?.selection.mode == expected,
                        let proof = entry?.proof
                    else { return prior }
                    modeProof = proof
                }
                let receipt = RuntimeReceipt(
                    operationID: context.operationID, status: .confirmed, session: reference,
                    nativeTurnID: turnID, nativeMessageID: marker,
                    executionMode: prior.executionMode, nativeSettingsJSON: modeProof)
                try ledger.record(receipt, context: context)
                return receipt
            }
        }
        return prior
    }
    public func replay(_ session: RuntimeSessionReference, after: RuntimeCursor?) -> RuntimeReplay {
        eventBuffer.replay(session, after: after)
    }
    public func disconnect() {
        lock.lock()
        let old = connection
        connection = nil
        accountVerified = false
        modeCatalog = nil
        epoch = UUID().uuidString
        healthReason = configuration.enabled ? "disconnected" : "disabled"
        lock.unlock()
        old?.onNotification = nil
        old?.onServerRequest = nil
        old?.disconnect()
        reverseRequests.reset()
    }
    private func validatedConnection(_ reference: RuntimeSessionReference) throws -> CodexRuntimeConnection {
        lock.lock()
        defer { lock.unlock() }
        guard let native = connection, native.connected else { throw RuntimeDriverError.unavailable }
        guard reference.adapterID == adapterID, reference.instanceID == native.instanceID,
            reference.ownershipEpoch == epoch, sessions[reference.nativeSessionID]?.reference == reference
        else { throw RuntimeDriverError.staleOwner }
        return native
    }
    private func perform(_ command: RuntimeCommand, context: RuntimeOperationContext) throws -> RuntimeReceipt {
        lock.lock()
        let canWrite = accountVerified
        lock.unlock()
        guard canWrite else { throw RuntimeDriverError.unavailable }
        switch command {
        case .create(let cwd):
            guard context.session == nil, cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.utf8.count <= 4096
            else { throw RuntimeDriverError.invalidRequest }
            lock.lock()
            let native = connection
            let ownerEpoch = epoch
            let count = sessions.count
            lock.unlock()
            guard let native, count < 64 else { throw RuntimeDriverError.unavailable }
            // Preserve native approval and sandbox enforcement. Configuration is
            // deliberately narrow; no arbitrary config, env, tools or permissions.
            let data = try request(
                native, "thread/start", ["cwd": cwd, "approvalPolicy": "on-request", "sandbox": "read-only"])
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let thread = value["thread"] as? [String: Any], let id = validID(thread["id"]),
                value["cwd"] as? String == cwd
            else { throw RuntimeDriverError.unavailable }
            let reference = RuntimeSessionReference(
                adapterID: adapterID, instanceID: native.instanceID,
                nativeSessionID: id, ownershipEpoch: ownerEpoch)
            let session = RuntimeSession(
                reference: reference, cwd: cwd, runtimeVersion: native.runtimeVersion,
                activeTurnID: nil, writable: true)
            lock.lock()
            sessions[id] = session
            lock.unlock()
            eventBuffer.append(reference, method: "thread/created", payload: data)
            return RuntimeReceipt(operationID: context.operationID, status: .confirmed, session: reference)
        case .submit(let text), .submitConfigured(let text, _):
            guard let reference = context.session, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                text.utf8.count <= 240_000
            else { throw RuntimeDriverError.invalidRequest }
            let native = try validatedConnection(reference)
            let before = try snapshot(reference)
            guard before.session.writable, before.session.activeTurnID == nil else {
                throw RuntimeDriverError.staleOwner
            }
            let marker =
                "vibepier_"
                + RuntimeOperationLedger.hash(Data((context.trustedDeviceID + "\0" + context.operationID).utf8))
            var parameters: [String: Any] = [
                "threadId": reference.nativeSessionID,
                "clientUserMessageId": marker, "input": [["type": "text", "text": text]],
            ]
            let expectedMode: String?
            if case .submitConfigured(_, let mode) = command {
                guard ["default", "plan"].contains(mode) else { throw RuntimeDriverError.invalidRequest }
                expectedMode = mode
            } else {
                expectedMode = nil
            }
            if let entry = try modeStore.entry(reference) {
                guard entry.proof != nil else { throw RuntimeDriverError.unavailable }
                if let expectedMode, entry.selection.mode != expectedMode { throw RuntimeDriverError.staleOwner }
                let current = try modeSelection(
                    expectedMode ?? entry.selection.mode, reference: reference, nativeData: before.nativeJSON)
                parameters["collaborationMode"] = current.native
                if expectedMode != nil {
                    // A fresh operation phase: old setter notifications cannot
                    // confirm the settings carried by this specific submission.
                    try modeStore.begin(current, reference: reference, operationID: context.operationID)
                }
            } else if expectedMode != nil {
                throw RuntimeDriverError.unavailable
            }
            let data = try request(native, "turn/start", parameters)
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let turn = value["turn"] as? [String: Any], let turnID = validID(turn["id"])
            else { throw RuntimeDriverError.unavailable }
            try ledger.record(
                RuntimeReceipt(
                    operationID: context.operationID, status: .unknown,
                    session: reference, nativeTurnID: turnID, reason: "native_message_confirmation_pending",
                    executionMode: expectedMode),
                context: context)
            let modeProof: Data?
            if expectedMode != nil {
                modeProof = try modeStore.waitForProof(reference, operationID: context.operationID)?.proof
            } else {
                modeProof = nil
            }
            // A turn/start acknowledgement alone does not prove exact prompt
            // delivery. Verify its native user item through authoritative history.
            let history = try snapshot(reference)
            let messageID = try nativeMessageID(history.nativeJSON, turnID: turnID, marker: marker, text: text)
            let confirmed = messageID != nil && (expectedMode == nil || modeProof != nil)
            return RuntimeReceipt(
                operationID: context.operationID, status: confirmed ? .confirmed : .unknown,
                session: reference, nativeTurnID: turnID, nativeMessageID: messageID,
                reason: confirmed ? "" : "native_message_confirmation_pending",
                executionMode: expectedMode, nativeSettingsJSON: modeProof)
        case .configureExecutionMode(let mode):
            guard let reference = context.session, ["default", "plan"].contains(mode) else {
                throw RuntimeDriverError.invalidRequest
            }
            let native = try validatedConnection(reference)
            let before = try snapshot(reference)
            guard before.session.writable, before.session.activeTurnID == nil else {
                throw RuntimeDriverError.staleOwner
            }
            let selection = try modeSelection(mode, reference: reference, nativeData: before.nativeJSON)
            try modeStore.begin(selection, reference: reference, operationID: context.operationID)
            try ledger.record(
                RuntimeReceipt(
                    operationID: context.operationID, status: .unknown, session: reference,
                    reason: "native_execution_mode_confirmation_pending", executionMode: mode), context: context)
            let response = try request(
                native, "thread/settings/update",
                ["threadId": reference.nativeSessionID, "collaborationMode": selection.native])
            guard let acknowledgement = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                acknowledgement.isEmpty
            else { throw RuntimeDriverError.unavailable }
            let entry = try modeStore.waitForProof(reference, operationID: context.operationID)
            return RuntimeReceipt(
                operationID: context.operationID, status: entry?.proof == nil ? .unknown : .confirmed,
                session: reference, reason: entry?.proof == nil ? "native_execution_mode_confirmation_pending" : "",
                executionMode: mode, nativeSettingsJSON: entry?.proof)
        case .interrupt(let turnID):
            guard let reference = context.session, validID(turnID) != nil else {
                throw RuntimeDriverError.invalidRequest
            }
            let native = try validatedConnection(reference)
            let before = try snapshot(reference)
            guard before.session.activeTurnID == turnID else { throw RuntimeDriverError.staleOwner }
            _ = try request(native, "turn/interrupt", ["threadId": reference.nativeSessionID, "turnId": turnID])
            try ledger.record(
                RuntimeReceipt(
                    operationID: context.operationID, status: .unknown,
                    session: reference, nativeTurnID: turnID, reason: "native_interrupt_confirmation_pending"),
                context: context)
            let after = try snapshot(reference)
            let confirmed = try interrupted(after.nativeJSON, turnID: turnID)
            return RuntimeReceipt(
                operationID: context.operationID, status: confirmed ? .confirmed : .unknown,
                session: reference, nativeTurnID: turnID,
                reason: confirmed ? "" : "native_interrupt_confirmation_pending")
        case .resolveApproval, .answerQuestion:
            guard let reference = context.session else { throw RuntimeDriverError.invalidRequest }
            let native = try validatedConnection(reference)
            let requestID: String
            switch command {
            case .resolveApproval(let id, _, _), .answerQuestion(let id, _, _): requestID = id
            default: throw RuntimeDriverError.invalidRequest
            }
            guard let pending = reverseRequests.pending(reference).first(where: { $0.id == requestID }),
                try snapshot(reference).session.activeTurnID == pending.nativeTurnID
            else { throw RuntimeDriverError.staleOwner }
            let (id, result) = try reverseRequests.claim(command: command, context: context)
            try ledger.record(
                RuntimeReceipt(
                    operationID: context.operationID, status: .unknown,
                    session: reference, reason: "native_approval_confirmation_pending"), context: context)
            try native.respond(requestID: id, result: result)
            return try ledger.lookup(context)
        }
    }
    private func request(_ native: CodexRuntimeConnection, _ method: String, _ params: [String: Any]) throws -> Data {
        try native.request(method, params: JSONSerialization.data(withJSONObject: params))
    }
    private func projectSession(_ data: Data, reference: RuntimeSessionReference, runtimeVersion: String) throws
        -> RuntimeSession
    {
        guard data.count <= 8_388_608,
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let thread = value["thread"] as? [String: Any], validID(thread["id"]) == reference.nativeSessionID,
            let cwd = thread["cwd"] as? String, cwd.hasPrefix("/"),
            let status = thread["status"] as? [String: Any], let type = status["type"] as? String,
            ["idle", "active", "notLoaded", "systemError"].contains(type)
        else { throw RuntimeDriverError.unavailable }
        let turns = thread["turns"] as? [[String: Any]] ?? []
        let active = turns.last(where: { $0["status"] as? String == "inProgress" }).flatMap { validID($0["id"]) }
        return RuntimeSession(
            reference: reference, cwd: cwd, runtimeVersion: runtimeVersion,
            activeTurnID: active, writable: type == "idle" || (type == "active" && active != nil))
    }
    private func nativeMessageID(_ data: Data, turnID: String, marker: String, text: String) throws -> String? {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let thread = value["thread"] as? [String: Any], let turns = thread["turns"] as? [[String: Any]],
            let turn = turns.first(where: { $0["id"] as? String == turnID }),
            let items = turn["items"] as? [[String: Any]]
        else { return nil }
        let matches = items.filter { item in
            guard item["type"] as? String == "userMessage", item["id"] as? String == marker,
                let content = item["content"] as? [[String: Any]], content.count == 1,
                content[0]["type"] as? String == "text", content[0]["text"] as? String == text
            else { return false }
            return true
        }
        return matches.count == 1 ? marker : nil
    }
    private func interrupted(_ data: Data, turnID: String) throws -> Bool {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let thread = value["thread"] as? [String: Any], let turns = thread["turns"] as? [[String: Any]]
        else { return false }
        return turns.contains { $0["id"] as? String == turnID && $0["status"] as? String == "interrupted" }
    }
    private func receive(_ method: String, data: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let threadID = value["threadId"] as? String ?? (value["thread"] as? [String: Any])?["id"] as? String
        else { return }
        lock.lock()
        let session = sessions[threadID]
        lock.unlock()
        guard let session else { return }
        if method == "thread/settings/updated",
            (value["threadSettings"] as? [String: Any])?["cwd"] as? String == session.cwd
        {
            modeStore.observe(data, reference: session.reference)
        }
        if method == "serverRequest/resolved", let id = value["requestId"],
            let idJSON = try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed),
            let context = reverseRequests.resolved(nativeIDJSON: idJSON, sessionID: threadID)
        {
            // Native event lacks the adopted decision/client identity. It can be
            // a competing desktop reply; never promote it to confirmed.
            try? ledger.record(
                RuntimeReceipt(
                    operationID: context.operationID, status: .unknown,
                    session: context.session, reason: "native_approval_resolution_observed"), context: context)
        }
        if method == "turn/completed", let turnID = (value["turn"] as? [String: Any])?["id"] as? String {
            reverseRequests.closeTurn(threadID, turnID: turnID)
        }
        eventBuffer.append(session.reference, method: method, payload: data)
    }
    private func receiveServerRequest(_ id: Data, method: String, params: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
            let threadID = value["threadId"] as? String
        else { return false }
        lock.lock()
        let session = sessions[threadID]
        lock.unlock()
        guard let session else { return false }
        let accepted = reverseRequests.register(
            nativeIDJSON: id, method: method, params: params, session: session.reference)
        if accepted { eventBuffer.append(session.reference, method: method, payload: params) }
        return accepted
    }
    private func validID(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty, string.utf8.count <= 256,
            !string.contains("\0")
        else { return nil }
        return string
    }
}
