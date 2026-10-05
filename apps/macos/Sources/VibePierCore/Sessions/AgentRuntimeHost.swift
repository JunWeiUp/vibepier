import Darwin
import Foundation

/// Explicit local setup owns optional runtimes. The phone cannot configure or start them.
final class AgentRuntimeHost: @unchecked Sendable {
    struct Settings: Codable {
        var codex: CodexManagedRuntimeConfiguration?
        var workspaceRoots: [String] = []
        var mods: ClaudeModsBrokerDriver.Configuration?
    }
    private let queue = DispatchQueue(label: "vibepier.optional-agent-runtimes")
    private let directory: URL
    private let settingsURL: URL
    private var settings = Settings()
    private var drivers: [String: any AgentRuntimeDriver] = [:]
    private var retiredDrivers: [String: any AgentRuntimeDriver] = [:]
    private var errors: [String: String] = [:]
    private var configurationUnavailable = false
    private let nativeStartupEnabled: Bool
    private var views: [String: (String, Int64)] = [:]
    private var polls: [String: DispatchWorkItem] = [:]
    private var pageHashes: [String: String] = [:]
    private var creations: [String: (cwd: String, draft: String, revision: String)] = [:]
    var event: (@Sendable (String, String, Data) -> Void)?
    init(
        directory: URL = Paths.supportDirectory.appendingPathComponent("agent-runtimes"),
        initialSettings: Settings? = nil, injectedDrivers: [any AgentRuntimeDriver] = [],
        nativeStartupEnabled: Bool = true
    ) {
        self.directory = directory
        self.nativeStartupEnabled = nativeStartupEnabled
        settingsURL = directory.appendingPathComponent("settings.json")
        if let initialSettings { settings = initialSettings }
        for driver in injectedDrivers { drivers[driver.adapterID] = driver }
        // A missing file means disabled. Loading preferences never launches a process.
        var fileInfo = stat()
        if initialSettings == nil, lstat(settingsURL.path, &fileInfo) == 0 {
            do {
                settings = try JSONDecoder().decode(
                    Settings.self, from: RuntimePrivateStorage.read(settingsURL, limit: 32 * 1024))
            } catch {
                errors["configuration"] = "configuration_unavailable"
                configurationUnavailable = true
            }
        }
    }
    func restoreExplicitConfiguration() {
        queue.async { self.activateSaved() }
    }
    func adapterProviders() -> [String: String] {
        ["codex.managedAppServer": "codex", "claude.desktopMods": "claude"]
    }
    func descriptors() -> [[String: Any]] {
        queue.sync {
            drivers.values.map { driver in
                let value = driver.describe()
                return [
                    "id": value.adapterID, "provider": value.adapterID.hasPrefix("codex.") ? "codex" : "claude",
                    "backendKinds": [value.backendKind], "actions": actions(value, session: nil),
                    "available": value.available, "reason": value.reason,
                ]
            }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        }
    }
    func localCommand(_ request: [String: Any], completion: @escaping @Sendable (Data) -> Void) {
        let bytes = AgentSessionProfile.data(request)
        queue.async {
            let request = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
            do {
                let action = request["action"] as? String ?? "status"
                if action == "status" {
                    completion(self.status())
                    return
                }
                guard !self.configurationUnavailable else { throw RuntimeDriverError.storageUnavailable }
                let adapter = request["adapter"] as? String ?? ""
                if action == "enable", adapter == "codex" {
                    guard let path = request["executable"] as? String, path.hasPrefix("/"),
                        FileManager.default.isExecutableFile(atPath: path),
                        let root = request["workspace"] as? String, self.validRoot(root)
                    else { throw RuntimeDriverError.invalidRequest }
                    let configuration = CodexManagedRuntimeConfiguration(
                        enabled: true, executablePath: path,
                        directoryPath: self.directory.appendingPathComponent("codex").path)
                    let candidate = CodexManagedRuntimeDriver(
                        configuration: configuration,
                        ledgerURL: self.directory.appendingPathComponent("codex-operations.json"))
                    try candidate.connect()
                    var next = self.settings
                    next.codex = configuration
                    next.workspaceRoots = Array(
                        Set(next.workspaceRoots + [URL(fileURLWithPath: root).resolvingSymlinksInPath().path])
                    ).sorted()
                    try self.save(next)
                    self.drivers[candidate.adapterID]?.disconnect()
                    self.drivers[candidate.adapterID] = candidate
                } else if action == "enable", adapter == "claude-mods" {
                    guard let version = request["reviewedVersion"] as? String,
                        ClaudeModsBrokerDriver.minimumVersion(version)
                    else { throw RuntimeDriverError.incompatibleVersion }
                    let configuration = ClaudeModsBrokerDriver.Configuration(
                        enabled: true, reviewedRuntimeVersions: [version])
                    let candidate = ClaudeModsBrokerDriver(
                        configuration: configuration,
                        ledgerURL: self.directory.appendingPathComponent("mods-operations.json"))
                    try candidate.start()
                    var next = self.settings
                    next.mods = configuration
                    try self.save(next)
                    self.drivers[candidate.adapterID]?.disconnect()
                    self.drivers[candidate.adapterID] = candidate
                } else if action == "disable" {
                    var next = self.settings
                    let id: String
                    if adapter == "codex" {
                        next.codex?.enabled = false
                        id = "codex.managedAppServer"
                    } else if adapter == "claude-mods" {
                        next.mods?.enabled = false
                        id = "claude.desktopMods"
                    } else {
                        throw RuntimeDriverError.invalidRequest
                    }
                    try self.save(next)
                    if let old = self.drivers.removeValue(forKey: id) {
                        old.disconnect()
                        self.retiredDrivers[id] = old
                    }
                    self.stopViews(adapter: id)
                } else if action == "bind", adapter == "claude-mods" {
                    guard let driver = self.drivers["claude.desktopMods"] as? ClaudeModsBrokerDriver,
                        let session = request["session"] as? String, let cwd = request["workspace"] as? String,
                        self.validRoot(cwd), let version = request["runtimeVersion"] as? String,
                        let digest = request["contractDigest"] as? String
                    else { throw RuntimeDriverError.invalidRequest }
                    // The publicly documented API does not yet prove message correlation on this installed runtime.
                    // A binding is observation-only until a native evidence reader is independently accepted.
                    let bootstrap = try driver.issueBinding(
                        sessionID: session, cwd: cwd, runtimeVersion: version,
                        contractDigest: digest, nativeWritesVerified: false)
                    let output = self.directory.appendingPathComponent("claude-mods-bootstrap.json")
                    try driver.writeBootstrap(bootstrap, to: output)
                    completion(
                        AgentSessionProfile.data(["ok": true, "bootstrapFile": output.path, "writesEnabled": false]))
                    return
                } else {
                    throw RuntimeDriverError.invalidRequest
                }
                completion(self.status())
            } catch {
                completion(
                    AgentSessionProfile.data([
                        "ok": false, "code": self.code(error), "error": L10n.text("agent.runtime_unavailable"),
                    ]))
            }
        }
    }
    func perform(_ data: Data, adapter: String, client: String, completion: @escaping @Sendable (Data) -> Void) {
        queue.async {
            do {
                guard data.count <= 300_000,
                    let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let op = request["op"] as? String
                else { throw RuntimeDriverError.unavailable }
                let receiptQuery = ["receiptCheck", "newReceiptCheck", "interruptReceiptCheck"].contains(op)
                let queried = receiptQuery ? self.receiptDriver(adapter) : nil
                guard let driver = self.drivers[adapter] ?? queried,
                    receiptQuery || op == "close" || driver.describe().available
                else { throw RuntimeDriverError.unavailable }
                var reply = try self.execute(request, op: op, driver: driver, client: client)
                if reply["ok"] == nil { reply["ok"] = AgentSessionProfile.boolean(reply["unknown"]) != true }
                let bytes = AgentSessionProfile.data(reply)
                guard bytes.count <= 300_000 else { throw RuntimeDriverError.quotaExceeded }
                completion(bytes)
            } catch {
                completion(
                    AgentSessionProfile.data([
                        "ok": false, "code": self.code(error), "error": L10n.text("agent.runtime_unavailable"),
                    ]))
            }
        }
    }
    func stop(client: String) {
        queue.async {
            for key in self.views.keys.filter({ $0.hasPrefix(client + ":") }) {
                self.views.removeValue(forKey: key)
                self.polls.removeValue(forKey: key)?.cancel()
                self.pageHashes.removeValue(forKey: key)
            }
            self.creations = self.creations.filter { !$0.key.hasPrefix(client + ":") }
        }
    }
    /// Asynchronous so Service and transport queues never wait on this host queue.
    func freshMutationFailure(_ data: Data, client: String, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let op = request["op"] as? String,
                    let nativeDescriptor = SessionV1Contract.descriptor(op), nativeDescriptor.durableMutation,
                    let action = nativeDescriptor.capability,
                    AgentSessionProfile.integer(request["agentCapabilityVersion"]) == 1,
                    let adapter = request["agentAdapterId"] as? String,
                    let driver = self.drivers[adapter], driver.describe().available
                else {
                    completion("agent_capability_unavailable")
                    return
                }
                if op == "new" {
                    guard let issued = self.creations[client + ":" + adapter],
                        request["cwd"] as? String == issued.cwd, request["draftId"] as? String == issued.draft,
                        request["agentCapabilityRevision"] as? String == issued.revision,
                        self.settings.workspaceRoots.contains(issued.cwd),
                        driver.describe().capabilities.contains("session.create")
                    else {
                        completion("agent_capability_unavailable")
                        return
                    }
                    if let mode = request["executionMode"] as? String,
                        (driver as? CodexManagedRuntimeDriver)?.creationExecutionModes().contains(mode) != true
                    {
                        completion("agent_capability_unavailable")
                        return
                    }
                    completion(nil)
                    return
                }
                guard let nativeID = request["threadId"] as? String,
                    let session = try driver.discover().first(where: { $0.reference.nativeSessionID == nativeID }),
                    let view = self.views[client + ":" + adapter], view.0 == nativeID,
                    AgentSessionProfile.integer(request["viewVersion"]) == view.1
                else {
                    completion("agent_target_mismatch")
                    return
                }
                let snapshot = try driver.snapshot(session.reference)
                let page = self.project(snapshot, descriptor: driver.describe())
                let capabilities = page["agentCapabilities"] as? [String: Any] ?? [:]
                guard request["nativeOwnerEpoch"] as? String == page["nativeOwnerEpoch"] as? String,
                    request["agentCapabilityRevision"] as? String == capabilities["revision"] as? String,
                    let actions = capabilities["actions"] as? [String: [String: Any]],
                    AgentSessionProfile.boolean(actions[action]?["available"]) == true
                else {
                    completion("agent_capability_unavailable")
                    return
                }
                completion(nil)
            } catch { completion(self.code(error)) }
        }
    }
    private func execute(_ request: [String: Any], op: String, driver: any AgentRuntimeDriver, client: String) throws
        -> [String: Any]
    {
        let descriptor = driver.describe()
        if op == "close" {
            let key = client + ":" + driver.adapterID
            if let view = views[key] {
                guard request["threadId"] as? String == view.0,
                    AgentSessionProfile.integer(request["viewVersion"]) == view.1
                else { return ["released": false, "code": "observation_changed"] }
            }
            stopViews(client: client, adapter: driver.adapterID)
            return ["released": true]
        }
        if ["receiptCheck", "interruptReceiptCheck", "newReceiptCheck", "settingsReceiptCheck"].contains(op) {
            let parent = try context(request, client: client, session: nil)
            if op == "newReceiptCheck" {
                let created = try driver.reconcile(child(parent, stage: "create", session: nil))
                guard let reference = created.session else { return nativeReceipt(created) }
                var configured: RuntimeReceipt?
                if request["executionMode"] != nil {
                    configured = try driver.reconcile(child(parent, stage: "configure", session: reference))
                    if configured?.status != .confirmed {
                        var partial = nativeReceipt(configured!)
                        partial["threadId"] = reference.nativeSessionID
                        partial["cwd"] = request["cwd"]
                        return partial
                    }
                }
                if !(request["text"] as? String ?? "").isEmpty {
                    let initial = try driver.reconcile(child(parent, stage: "initial", session: reference))
                    var result = nativeReceipt(
                        initial.status == .rejected
                            ? RuntimeReceipt(
                                operationID: parent.operationID, status: .unknown, session: reference,
                                reason: "initial_message_rejected_after_creation") : initial)
                    result["threadId"] = reference.nativeSessionID
                    result["cwd"] = request["cwd"]
                    // Initial mode evidence comes from that immutable submission,
                    // never from an earlier settings change on a shared runtime.
                    return result
                }
                var result = nativeReceipt(created)
                if let configured { addModeEvidence(configured, to: &result) }
                return result
            }
            return nativeReceipt(try driver.reconcile(parent))
        }
        if op == "projects" {
            let roots =
                driver.adapterID.hasPrefix("codex.") ? settings.workspaceRoots : try driver.discover().map(\.cwd)
            return [
                "projects": Array(Set(roots)).sorted().map {
                    ["cwd": $0, "name": URL(fileURLWithPath: $0).lastPathComponent]
                }, "nextOffset": -1,
            ]
        }
        if op == "list" {
            return [
                "threads": try driver.discover().map { session in
                    [
                        "id": session.reference.nativeSessionID, "threadId": session.reference.nativeSessionID,
                        "title": URL(fileURLWithPath: session.cwd).lastPathComponent, "cwd": session.cwd,
                        "status": session.activeTurnID == nil ? "idle" : "active",
                    ] as [String: Any]
                }, "nextOffset": -1,
            ]
        }
        if op == "newOptions" {
            guard driver.adapterID.hasPrefix("codex."), let cwd = request["cwd"] as? String,
                settings.workspaceRoots.contains(cwd), let draft = request["draftId"] as? String,
                UUID(uuidString: draft) != nil
            else { throw RuntimeDriverError.invalidRequest }
            let revision = AgentSessionProfile.digest(
                AgentSessionProfile.data(["adapter": driver.adapterID, "cwd": cwd, "draft": draft]))
            creations[client + ":" + driver.adapterID] = (cwd, draft, revision)
            var capabilities = capability(descriptor, session: nil, creation: true)
            capabilities["revision"] = revision
            let modes = (driver as? CodexManagedRuntimeDriver)?.creationExecutionModes() ?? []
            if modes.isEmpty, var actions = capabilities["actions"] as? [String: Any] {
                actions["executionMode"] = [
                    "supported": false, "available": false, "reason": "native_model_unavailable",
                ]
                capabilities["actions"] = actions
            }
            return [
                "creationVersion": 1, "draftId": draft,
                "models": [["id": "default", "name": L10n.text("agent.option.default_model"), "efforts": ["default"]]],
                "composer": ["model": "default", "mode": "default", "effort": "default", "executionMode": "default"],
                "permissionModes": [["id": "default", "name": L10n.text("agent.option.read_only")]],
                "executionModes": executionModeOptions(modes),
                "agentCapabilities": capabilities,
            ]
        }
        if op == "new" {
            guard let cwd = request["cwd"] as? String, settings.workspaceRoots.contains(cwd),
                (request["attachments"] as? [String] ?? []).isEmpty,
                ["model", "mode", "effort"].allSatisfy({ request[$0] == nil || request[$0] as? String == "default" })
            else { throw RuntimeDriverError.invalidRequest }
            let parent = try context(request, client: client, session: nil)
            let created = try driver.execute(.create(cwd: cwd), context: child(parent, stage: "create", session: nil))
            guard let reference = created.session else { return nativeReceipt(created) }
            var result = nativeReceipt(created)
            result["threadId"] = reference.nativeSessionID
            result["cwd"] = cwd
            var configured: RuntimeReceipt?
            if let mode = request["executionMode"] as? String, created.status == .confirmed {
                do {
                    configured = try driver.execute(
                        .configureExecutionMode(mode: mode),
                        context: child(parent, stage: "configure", session: reference))
                } catch {
                    configured = RuntimeReceipt(
                        operationID: parent.operationID, status: .unknown, session: reference,
                        reason: "native_execution_mode_confirmation_pending", executionMode: mode)
                }
                guard configured?.status == .confirmed else {
                    result = nativeReceipt(configured!)
                    result["threadId"] = reference.nativeSessionID
                    result["cwd"] = cwd
                    return result
                }
                addModeEvidence(configured!, to: &result)
            }
            let text = request["text"] as? String ?? ""
            if !text.isEmpty, created.status == .confirmed {
                do {
                    let submitted = try driver.execute(
                        (request["executionMode"] as? String).map {
                            .submitConfigured(text: text, executionMode: $0)
                        } ?? .submit(text: text), context: child(parent, stage: "initial", session: reference))
                    result = nativeReceipt(
                        submitted.status == .rejected
                            ? RuntimeReceipt(
                                operationID: parent.operationID, status: .unknown, session: reference,
                                reason: "initial_message_rejected_after_creation") : submitted)
                } catch {
                    result = nativeReceipt(
                        RuntimeReceipt(
                            operationID: parent.operationID, status: .unknown,
                            session: reference, reason: "initial_native_confirmation_unavailable"))
                }
                result["threadId"] = reference.nativeSessionID
                result["cwd"] = cwd
            }
            return result
        }
        guard let native = request["threadId"] as? String,
            let session = try driver.discover().first(where: { $0.reference.nativeSessionID == native })
        else { throw RuntimeDriverError.staleOwner }
        if op == "open" || op == "sync" {
            let value = try driver.snapshot(session.reference)
            let page = project(value, descriptor: descriptor)
            if op == "open" {
                views[client + ":" + driver.adapterID] = (
                    native, (request["viewVersion"] as? NSNumber)?.int64Value ?? 0
                )
                pageHashes[client + ":" + driver.adapterID] = AgentSessionProfile.digest(AgentSessionProfile.data(page))
                schedule(client: client, driver: driver, reference: session.reference)
            }
            return page
        }
        if ["history", "parts", "message", "approvalDetails"].contains(op) {
            let snapshot = try driver.snapshot(session.reference)
            let object = (try? JSONSerialization.jsonObject(with: snapshot.nativeJSON) as? [String: Any]) ?? [:]
            let thread = object["thread"] as? [String: Any] ?? object
            let turns = (thread["turns"] as? [[String: Any]] ?? []).map(CodexConversation.messages)
            let rows = turns.flatMap { $0 }
            if op == "history" {
                guard let before = request["before"] as? String,
                    let window = ConversationReply.older(turns, before: before)
                else { throw RuntimeDriverError.staleOwner }
                return [
                    "threadId": native, "messages": window.rows, "hasOlder": window.start > 0,
                    "contentState": snapshot.partial ? "partial" : "complete", "historyCoverage": "nativeRead",
                ]
            }
            if op == "approvalDetails" {
                guard let fingerprint = request["fingerprint"] as? String,
                    let pending = approvals(snapshot).first(where: { $0["fingerprint"] as? String == fingerprint })
                else { throw RuntimeDriverError.staleOwner }
                return ["threadId": native, "approval": pending]
            }
            guard let id = request["messageId"] as? String else { throw RuntimeDriverError.invalidRequest }
            if op == "parts" {
                guard
                    var value = ConversationReply.partPage(
                        rows, id: id,
                        offset: AgentSessionProfile.integer(request["offset"]).flatMap(Int.init(exactly:)) ?? 0,
                        headersOnly: AgentSessionProfile.boolean(request["headersOnly"]) ?? false,
                        sequence: AgentSessionProfile.boolean(request["sequence"]) ?? false,
                        before: AgentSessionProfile.integer(request["before"]).flatMap(Int.init(exactly:)))
                else { throw RuntimeDriverError.staleOwner }
                value["threadId"] = native
                value["messageId"] = id
                return value
            }
            guard let text = ConversationReply.fullText(rows, id: id) else { throw RuntimeDriverError.staleOwner }
            let offset = max(
                0, min(AgentSessionProfile.integer(request["offset"]).flatMap(Int.init(exactly:)) ?? 0, text.count))
            let part = String(text.dropFirst(offset).prefix(12_000))
            return [
                "threadId": native, "messageId": id, "text": part,
                "nextOffset": offset + part.count < text.count ? offset + part.count : -1,
            ]
        }
        if let expected = request["nativeOwnerEpoch"] as? String, expected != ownerEpoch(session.reference) {
            throw RuntimeDriverError.staleOwner
        }
        let context = try context(request, client: client, session: session.reference)
        switch op {
        case "configure", "settings":
            guard let mode = request["executionMode"] as? String,
                ["default", "plan"].contains(mode),
                ["model", "mode", "effort"].allSatisfy({ request[$0] == nil || request[$0] as? String == "default" })
            else { throw RuntimeDriverError.invalidRequest }
            var result = nativeReceipt(try driver.execute(.configureExecutionMode(mode: mode), context: context))
            result["configured"] = result["ok"]
            return result
        case "send":
            guard (request["attachments"] as? [String] ?? []).isEmpty,
                request["submissionMode"] as? String == "start", let text = request["text"] as? String
            else { throw RuntimeDriverError.invalidRequest }
            return nativeReceipt(try driver.execute(.submit(text: text), context: context))
        case "interrupt":
            guard let turn = request["expectedTurnId"] as? String else { throw RuntimeDriverError.invalidRequest }
            var result = nativeReceipt(try driver.execute(.interrupt(turnID: turn), context: context))
            result["interruptRequested"] = true
            return result
        case "approve":
            guard let nativeRequestID = request["nativeRequestId"] as? String,
                let fingerprint = request["nativeRequestFingerprint"] as? String,
                let pending = nativeRequests(try driver.snapshot(session.reference)).first(where: {
                    $0.id == nativeRequestID && $0.fingerprint == fingerprint
                }),
                !pending.nativeTurnID.isEmpty
            else { throw RuntimeDriverError.staleOwner }
            let command: RuntimeCommand
            if let values = request["answers"] as? [String: String] {
                command = .answerQuestion(
                    requestID: pending.id, fingerprint: pending.fingerprint, answers: values.mapValues { [$0] })
            } else {
                guard let allow = AgentSessionProfile.boolean(request["allow"]), !pending.allowedDecisions.isEmpty
                else { throw RuntimeDriverError.invalidRequest }
                command = .resolveApproval(
                    requestID: pending.id, fingerprint: pending.fingerprint, decision: allow ? "accept" : "decline")
            }
            return nativeReceipt(try driver.execute(command, context: context))
        default: throw RuntimeDriverError.invalidRequest
        }
    }
    private func project(_ snapshot: RuntimeSnapshot, descriptor: RuntimeDriverDescriptor) -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: snapshot.nativeJSON) as? [String: Any]) ?? [:]
        let thread = object["thread"] as? [String: Any] ?? object
        let turns = thread["turns"] as? [[String: Any]] ?? []
        var page = CodexConversation.page(["turns": turns, "cwd": snapshot.session.cwd])
        page["threadId"] = snapshot.session.reference.nativeSessionID
        page["cwd"] = snapshot.session.cwd
        page["title"] = URL(fileURLWithPath: snapshot.session.cwd).lastPathComponent
        page["status"] = snapshot.session.activeTurnID == nil ? "idle" : "active"
        page["activeTurnId"] = snapshot.session.activeTurnID ?? ""
        page["canSend"] = snapshot.session.writable && descriptor.available && snapshot.session.activeTurnID == nil
        page["nativeOwnerEpoch"] = ownerEpoch(snapshot.session.reference)
        page["agentCapabilities"] = capability(descriptor, session: snapshot.session, creation: false)
        let modes = object["executionModes"] as? [String] ?? []
        page["executionModes"] = executionModeOptions(modes)
        page["executionModeVerified"] = object["executionModeVerified"] as? Bool == true
        let mode = object["executionMode"] as? String ?? "default"
        page["composer"] = ["model": "default", "mode": "default", "effort": "default", "executionMode": mode]
        page["permissionModes"] = [["id": "default", "name": L10n.text("agent.option.read_only")]]
        page["models"] = [["id": "default", "name": L10n.text("agent.option.default_model"), "efforts": ["default"]]]
        if var capability = page["agentCapabilities"] as? [String: Any] {
            capability["revision"] =
                (capability["revision"] as? String ?? "") + ":" + mode
                + ":" + (object["executionModeVerified"] as? Bool == true ? "verified" : "unverified")
            if var actions = capability["actions"] as? [String: Any] {
                if modes.isEmpty {
                    actions["executionMode"] = [
                        "supported": false, "available": false, "reason": "native_model_unavailable",
                    ]
                    actions["settings"] = [
                        "supported": false, "available": false, "reason": "native_model_unavailable",
                    ]
                }
                if object["executionModePending"] as? Bool == true {
                    actions["send"] = [
                        "supported": true, "available": false, "reason": "native_execution_mode_confirmation_pending",
                    ]
                    page["canSend"] = false
                }
                capability["actions"] = actions
            }
            page["agentCapabilities"] = capability
        }
        page["contentState"] = snapshot.partial ? "partial" : "complete"
        page["approvals"] = approvals(snapshot)
        if let messages = object["messages"] as? [[String: Any]], descriptor.adapterID.hasPrefix("claude.") {
            page["messages"] = messages.enumerated().compactMap { index, raw -> [String: Any]? in
                guard let role = raw["role"] as? String, ["user", "assistant"].contains(role),
                    let text = raw["text"] as? String
                else { return nil }
                // Display-only stable content identities; never used as native receipts.
                let id = AgentSessionProfile.digest(
                    AgentSessionProfile.data(["role": role, "text": text, "index": index]))
                return [
                    "id": "mods-observed:" + id, "role": role, "text": String(text.prefix(12_000)), "partial": true,
                ]
            }
            page["hasOlder"] = true
        }
        return page
    }
    private func nativeRequests(_ snapshot: RuntimeSnapshot) -> [RuntimeNativeRequest] {
        guard let object = try? JSONSerialization.jsonObject(with: snapshot.nativeJSON) as? [String: Any],
            let raw = object["pendingRequests"], let data = try? JSONSerialization.data(withJSONObject: raw),
            data.count <= 2_097_152, let requests = try? JSONDecoder().decode([RuntimeNativeRequest].self, from: data)
        else { return [] }
        return Array(requests.prefix(32))
    }
    private func approvals(_ snapshot: RuntimeSnapshot) -> [[String: Any]] {
        let object = (try? JSONSerialization.jsonObject(with: snapshot.nativeJSON) as? [String: Any]) ?? [:]
        let thread = object["thread"] as? [String: Any] ?? [:]
        let nativeItems = (thread["turns"] as? [[String: Any]] ?? []).flatMap { $0["items"] as? [[String: Any]] ?? [] }
        return nativeRequests(snapshot).map { pending in
            var params = (try? JSONSerialization.jsonObject(with: pending.nativeParamsJSON) as? [String: Any]) ?? [:]
            if let item = nativeItems.first(where: { $0["id"] as? String == pending.nativeItemID }) {
                params["itemDetails"] = item
            }
            let details = AgentSessionProfile.data(params)
            var complete = !pending.questions.isEmpty
            if pending.method == "item/commandExecution/requestApproval" {
                complete = !(params["command"] as? String ?? "").isEmpty
            } else if pending.method == "item/fileChange/requestApproval" {
                let changes = (params["itemDetails"] as? [String: Any])?["changes"] as? [[String: Any]] ?? []
                complete =
                    !changes.isEmpty
                    && changes.allSatisfy { $0["path"] is String && $0["diff"] is String && $0["kind"] != nil }
            }
            var result: [String: Any] = [
                "id": pending.id, "fingerprint": pending.fingerprint,
                "nativeRequestId": pending.id, "nativeRequestFingerprint": pending.fingerprint,
                "method": pending.method,
                "title": L10n.text(pending.questions.isEmpty ? "session.run_command" : "session.request_permission"),
                "details": details.count <= 60_000
                    ? String(decoding: details, as: UTF8.self) : L10n.text("session.handle_this_on_the_mac"),
                "canDecide": complete && details.count <= 60_000
                    && snapshot.session.activeTurnID == pending.nativeTurnID,
                "allowedDecisions": pending.allowedDecisions.isEmpty ? [] : ["allow", "deny"], "decisionScope": "once",
            ]
            if !pending.questions.isEmpty {
                result["kind"] = "questions"
                result["questions"] = pending.questions.map { question in
                    [
                        "id": question.id, "header": question.header, "question": question.question,
                        "isOther": question.allowsOther,
                        "options": question.options.map { ["label": $0, "description": ""] },
                    ] as [String: Any]
                }
            }
            return result
        }
    }
    private func capability(_ descriptor: RuntimeDriverDescriptor, session: RuntimeSession?, creation: Bool) -> [String:
        Any]
    {
        [
            "version": 1, "adapterId": descriptor.adapterID,
            "provider": descriptor.adapterID.hasPrefix("codex.") ? "codex" : "claude",
            "revision": session.map { ownerEpoch($0.reference) + ":" + ($0.activeTurnID ?? "idle") } ?? descriptor
                .adapterID + ":creation",
            "actions": actions(descriptor, session: session, creation: creation),
        ]
    }
    private func actions(_ descriptor: RuntimeDriverDescriptor, session: RuntimeSession?, creation: Bool = false)
        -> [String: Any]
    {
        Dictionary(
            uniqueKeysWithValues: SessionV1Contract.capabilityKeys.map { name in
                let method = [
                    "send": "message.submit.start", "new": "session.create", "interrupt": "turn.interrupt",
                    "approvals": "approval.resolve", "questions": "question.answer",
                    "executionMode": "session.executionMode.configure",
                    "settings": "session.executionMode.configure",
                ][name]
                let supported = method.map(descriptor.capabilities.contains) ?? false
                let stateAllowed =
                    creation
                    ? ["new", "executionMode"].contains(name)
                    : (session == nil ? name == "new" : session?.writable == true)
                        && (["send", "executionMode", "settings"].contains(name)
                            ? session?.activeTurnID == nil : name == "interrupt" ? session?.activeTurnID != nil : true)
                let available = supported && descriptor.available && stateAllowed
                return (
                    name,
                    [
                        "supported": supported, "available": available,
                        "reason": available ? "available" : (supported ? "session_unavailable" : "unsupported"),
                    ] as [String: Any]
                )
            })
    }
    private func context(_ request: [String: Any], client: String, session: RuntimeSessionReference?) throws
        -> RuntimeOperationContext
    {
        guard let operation = request["id"] as? String,
            let hash = request["agentOperationFingerprint"] as? String, hash.count == 64,
            let reservation = request["agentJournalReservationID"] as? String, reservation == client + ":" + operation
        else { throw RuntimeDriverError.unauthorized }
        return RuntimeOperationContext(
            trustedDeviceID: client, operationID: operation, requestFingerprint: hash,
            journalReservationID: reservation, session: session)
    }
    private func child(_ parent: RuntimeOperationContext, stage: String, session: RuntimeSessionReference?)
        -> RuntimeOperationContext
    {
        RuntimeOperationContext(
            trustedDeviceID: parent.trustedDeviceID, operationID: parent.operationID + "." + stage,
            requestFingerprint: parent.requestFingerprint, journalReservationID: parent.journalReservationID,
            session: session)
    }
    private func nativeReceipt(_ receipt: RuntimeReceipt) -> [String: Any] {
        var result: [String: Any] = [
            "ok": receipt.status == .confirmed, "accepted": receipt.status == .confirmed,
            "unknown": receipt.status == .unknown,
            "threadId": receipt.session?.nativeSessionID ?? "", "code": receipt.reason,
        ]
        if let id = receipt.nativeTurnID {
            result["turnId"] = id
            result["turnIdentityKind"] = "nativeTurn"
        }
        if let id = receipt.nativeMessageID { result["nativeMessageId"] = id }
        addModeEvidence(receipt, to: &result)
        return result
    }
    private func addModeEvidence(_ receipt: RuntimeReceipt, to result: inout [String: Any]) {
        guard let mode = receipt.executionMode else { return }
        result["effectiveExecutionMode"] = mode
        result["composer"] = ["model": "default", "mode": "default", "effort": "default", "executionMode": mode]
        let verified = receipt.status == .confirmed && receipt.nativeSettingsJSON != nil
        result["executionModeVerified"] = verified
        if verified, let proof = receipt.nativeSettingsJSON,
            let native = try? JSONSerialization.jsonObject(with: proof) as? [String: Any]
        {
            result["nativeSettingsProof"] = native
        }
    }
    private func executionModeOptions(_ modes: [String]) -> [[String: String]] {
        modes.filter { ["default", "plan"].contains($0) }.map {
            ["id": $0, "name": L10n.text($0 == "plan" ? "agent.execution_mode.plan" : "agent.execution_mode.default")]
        }
    }
    private func ownerEpoch(_ reference: RuntimeSessionReference) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return AgentSessionProfile.digest((try? encoder.encode(reference)) ?? Data())
    }
    private func schedule(client: String, driver: any AgentRuntimeDriver, reference: RuntimeSessionReference) {
        let key = client + ":" + driver.adapterID
        polls[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.views[key]?.0 == reference.nativeSessionID else { return }
            if let snapshot = try? driver.snapshot(reference) {
                var page = self.project(snapshot, descriptor: driver.describe())
                let hash = AgentSessionProfile.digest(AgentSessionProfile.data(page))
                let changed = self.pageHashes[key] != hash
                self.pageHashes[key] = hash
                page["event"] = "snapshot"
                page["viewVersion"] = self.views[key]?.1
                if changed { self.event?(client, driver.adapterID, AgentSessionProfile.data(page)) }
            }
            self.schedule(client: client, driver: driver, reference: reference)
        }
        polls[key] = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }
    private func stopViews(client: String? = nil, adapter: String) {
        for key in views.keys.filter({ $0.hasSuffix(":" + adapter) && (client == nil || $0.hasPrefix(client! + ":")) })
        {
            views.removeValue(forKey: key)
            polls.removeValue(forKey: key)?.cancel()
            pageHashes.removeValue(forKey: key)
        }
    }
    private func activateSaved() {
        guard nativeStartupEnabled, !configurationUnavailable else { return }
        if let config = settings.codex, config.enabled {
            let driver = CodexManagedRuntimeDriver(
                configuration: config, ledgerURL: directory.appendingPathComponent("codex-operations.json"))
            do {
                try driver.connect()
                drivers[driver.adapterID] = driver
            } catch { errors["codex"] = code(error) }
        }
        if let config = settings.mods, config.enabled {
            let driver = ClaudeModsBrokerDriver(
                configuration: config, ledgerURL: directory.appendingPathComponent("mods-operations.json"))
            do {
                try driver.start()
                drivers[driver.adapterID] = driver
            } catch { errors["claude-mods"] = code(error) }
        }
    }
    private func receiptDriver(_ adapter: String) -> (any AgentRuntimeDriver)? {
        if let driver = retiredDrivers[adapter] { return driver }
        // Restarted/disabled hosts query the existing local ledger without
        // opening a native connection, registering an instance or resending.
        let driver: any AgentRuntimeDriver
        if adapter == "codex.managedAppServer", let old = settings.codex {
            driver = CodexManagedRuntimeDriver(
                configuration: .init(
                    enabled: false, executablePath: old.executablePath,
                    directoryPath: old.directoryPath),
                ledgerURL: directory.appendingPathComponent("codex-operations.json"))
        } else if adapter == "claude.desktopMods", settings.mods != nil {
            driver = ClaudeModsBrokerDriver(
                configuration: .init(enabled: false),
                ledgerURL: directory.appendingPathComponent("mods-operations.json"))
        } else {
            return nil
        }
        retiredDrivers[adapter] = driver
        return driver
    }
    private func status() -> Data {
        // Refresh only an existing private connection. Status never activates
        // disabled/saved runtimes, refreshes OAuth tokens or starts a model task.
        if let codex = drivers["codex.managedAppServer"] as? CodexManagedRuntimeDriver {
            try? codex.refreshAccountStatus()
        }
        var result: [String: Any] = [
            "ok": true,
            "configured": ["codex": settings.codex?.enabled == true, "claude-mods": settings.mods?.enabled == true],
            "errors": errors,
        ]
        if let configuration = settings.codex {
            result["codexProxyArguments"] = configuration.sharedProxyArguments
            result["codexHomePath"] = configuration.codexHomePath
            result["codexLoginArguments"] = configuration.loginArguments
            result["codexLoginEnvironment"] = ["CODEX_HOME": configuration.codexHomePath]
        }
        result["drivers"] = drivers.values.compactMap {
            try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0.describe()))
        }
        return AgentSessionProfile.data(result)
    }
    private func save(_ next: Settings) throws {
        guard !configurationUnavailable else { throw RuntimeDriverError.storageUnavailable }
        try RuntimePrivateStorage.write(try JSONEncoder().encode(next), to: settingsURL)
        settings = next
    }
    private func validRoot(_ value: String) -> Bool {
        guard value.hasPrefix("/"), AgentSessionProfile.bounded(value, maximum: 4096) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    private func code(_ error: Error) -> String {
        if let error = error as? RuntimeDriverError {
            switch error {
            case .incompatibleVersion: return "native_interface_incompatible"
            case .operationConflict: return "operation_conflict"
            case .staleOwner: return "owner_changed"
            case .unauthorized: return "unauthorized"
            default: return "runtime_unavailable"
            }
        }
        return "runtime_unavailable"
    }
}
