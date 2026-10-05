import Foundation

struct AgentActionCapability: Equatable, Sendable {
    let supported: Bool
    let available: Bool
    let reason: String
    var object: [String: Any] { ["supported": supported, "available": available, "reason": reason] }
}

/// Native Bridges own sessions and processes. This layer owns adapter selection and issued capabilities.
/// A capability is advisory until this layer and the Bridge both validate the original action.
final class AgentSessionCoordinator: @unchecked Sendable {
    private struct Context: Sendable {
        let operation: String
        let thread: String
        let cwd: String
        let draft: String
        let view: Int64
        init(_ value: [String: Any]) {
            operation = value["op"] as? String ?? ""
            thread = value["threadId"] as? String ?? ""
            cwd = value["cwd"] as? String ?? ""
            draft = (value["draftId"] as? String).flatMap { UUID(uuidString: $0)?.uuidString.lowercased() } ?? ""
            view = (value["viewVersion"] as? NSNumber)?.int64Value ?? -1
        }
    }
    private struct Scope: Equatable, Sendable {
        let thread: String
        let cwd: String
        let draft: String
        let view: Int64
    }
    private struct Issued: Sendable {
        let scope: Scope
        let actions: [String: AgentActionCapability]
        let revision: String
    }
    private struct Key: Hashable {
        let client: String
        let provider: String
        let creation: Bool
    }
    let registry: AgentAdapterRegistry
    private let lock = NSLock()
    private var negotiated = Set<String>()
    private var issued: [Key: Issued] = [:]
    private var expected: [Key: Scope] = [:]
    private var enabled: [String: Bool] = [:]
    private var sink: (@Sendable (String, String, Data) -> Void)?
    private let discoveryRevision = UUID().uuidString
    var event: (@Sendable (String, String, Data) -> Void)? {
        get { lock.withLock { sink } }
        set { lock.withLock { sink = newValue } }
    }

    init(registry: AgentAdapterRegistry) {
        self.registry = registry
        for adapter in registry.all {
            let provider = adapter.providerID
            adapter.event = { [weak self] client, data in
                guard let self else { return }
                let bytes = self.enrich(data, client: client, provider: provider, context: nil)
                self.event?(client, provider, bytes)
            }
        }
    }

    /// Called only after the device envelope has been authenticated. No probe starts a native turn.
    func describe(client: String, requestedVersion: Any?, policy: SessionProviderPolicy) -> [String: Any]? {
        guard Self.isVersionOne(requestedVersion) else { return nil }
        let accepted = lock.withLock {
            guard negotiated.contains(client) || negotiated.count < 512 else { return false }
            negotiated.insert(client)
            enabled = policy.enabled
            return true
        }
        guard accepted else { return nil }
        return [
            "version": 1, "revision": discoveryRevision + ":" + String(policy.revision),
            "adapters": registry.all.map { adapter -> [String: Any] in
                let actions = capabilities(
                    provider: adapter.providerID, page: [:], creation: false,
                    enabled: policy.isEnabled(adapter.providerID))
                return [
                    "id": adapter.adapterID, "provider": adapter.providerID,
                    "backendKinds": adapter.backendKinds, "actions": actions.mapValues(\.object),
                ]
            },
        ]
    }

    /// Existing journal records bypass this fresh-admission check; reconciliation never calls a mutation.
    func freshMutationFailure(_ request: [String: Any], client: String) -> String? {
        guard let operation = request["op"] as? String,
            let descriptor = SessionV1Contract.descriptor(operation),
            descriptor.routeDomain == "session", descriptor.durableMutation,
            let action = descriptor.capability
        else { return nil }
        return lock.withLock {
            guard negotiated.contains(client), Self.isVersionOne(request["agentCapabilityVersion"]) else {
                return "agent_upgrade_required"
            }
            guard let adapter = registry.adapter(provider: request["provider"] as? String),
                request["agentAdapterId"] as? String == adapter.adapterID,
                let capability = issued[
                    Key(client: client, provider: adapter.providerID, creation: operation == "new")],
                request["agentCapabilityRevision"] as? String == capability.revision,
                capability.actions[action]?.available == true,
                request["executionMode"] == nil || capability.actions["executionMode"]?.available == true
            else { return "agent_capability_unavailable" }
            if operation == "new" {
                guard request["cwd"] as? String == capability.scope.cwd,
                    Context(request).draft == capability.scope.draft
                else { return "agent_capability_unavailable" }
            } else {
                guard request["threadId"] as? String == capability.scope.thread,
                    (request["viewVersion"] as? NSNumber)?.int64Value == capability.scope.view
                else { return "agent_capability_unavailable" }
            }
            return nil
        }
    }

    func performCurrentV1(
        _ data: Data, provider: String?, trustedClient: String, completion: @escaping @Sendable (Data) -> Void
    ) {
        guard let adapter = registry.adapter(provider: provider) else {
            completion(
                (try? JSONSerialization.data(withJSONObject: [
                    "ok": false, "error": L10n.text("control.unsupported_session_provider"),
                ])) ?? Data())
            return
        }
        let request = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let context = Context(request)
        let key = Key(client: trustedClient, provider: adapter.providerID, creation: context.operation == "newOptions")
        if ["open", "newOptions"].contains(context.operation) {
            lock.withLock {
                guard expected[key] != nil || expected.count < 512 else { return }
                expected[key] = Scope(
                    thread: context.operation == "open" ? context.thread : "",
                    cwd: context.operation == "newOptions" ? context.cwd : "",
                    draft: context.operation == "newOptions" ? context.draft : "",
                    view: context.operation == "open" ? context.view : -1)
                issued.removeValue(forKey: key)
            }
        }
        if context.operation == "close" {
            lock.withLock {
                issued.removeValue(forKey: key)
                expected.removeValue(forKey: key)
            }
        }
        adapter.performCurrentV1(data, client: trustedClient) { [weak self] reply in
            guard let self else {
                completion(reply)
                return
            }
            completion(self.enrich(reply, client: trustedClient, provider: adapter.providerID, context: context))
        }
    }

    func stopObservation(client: String, providers: Set<String>? = nil, forgetNegotiation: Bool = false) {
        lock.withLock {
            issued = issued.filter {
                $0.key.client != client || (providers != nil && !providers!.contains($0.key.provider))
            }
            expected = expected.filter {
                $0.key.client != client || (providers != nil && !providers!.contains($0.key.provider))
            }
            if forgetNegotiation { negotiated.remove(client) }
        }
        for adapter in registry.all where providers == nil || providers!.contains(adapter.providerID) {
            adapter.stopObservation(client: client)
        }
    }
    func stopAllObservations() {
        lock.withLock {
            issued.removeAll()
            expected.removeAll()
            negotiated.removeAll()
        }
        for adapter in registry.all { adapter.stopAllObservations() }
    }

    private func enrich(_ data: Data, client: String, provider: String, context: Context?) -> Data {
        guard data.count <= 300_000,
            var page = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return data }
        if context == nil { page["provider"] = provider }
        let creation = context?.operation == "newOptions"
        let isPage =
            context.map { ["open", "sync"].contains($0.operation) }
            ?? ["snapshot", "delta", "unavailable"].contains(page["event"] as? String ?? "")
        guard creation || isPage else {
            return context == nil ? (try? JSONSerialization.data(withJSONObject: page)) ?? data : data
        }
        let key = Key(client: client, provider: provider, creation: creation)
        let activeScope = lock.withLock { expected[key] }
        let unavailable = page["event"] as? String == "unavailable"
        let thread = page["threadId"] as? String ?? context?.thread ?? (unavailable ? activeScope?.thread : nil) ?? ""
        let view =
            (page["viewVersion"] as? NSNumber)?.int64Value ?? context?.view ?? (unavailable ? activeScope?.view : nil)
            ?? -1
        let scope = Scope(
            thread: creation ? "" : thread, cwd: creation ? context?.cwd ?? "" : "",
            draft: creation ? page["draftId"] as? String ?? "" : "", view: creation ? -1 : view)
        let policyEnabled = lock.withLock { enabled[provider] != false }
        let actions = capabilities(provider: provider, page: page, creation: creation, enabled: policyEnabled)
        let capability: Issued? = lock.withLock {
            guard negotiated.contains(client), expected[key] == scope, issued[key] != nil || issued.count < 512 else {
                return nil
            }
            if let context, !creation, thread != context.thread || view != context.view { return nil }
            let previous = issued[key]
            let revision =
                previous?.scope == scope && previous?.actions == actions ? previous!.revision : UUID().uuidString
            let value = Issued(scope: scope, actions: actions, revision: revision)
            issued[key] = value
            return value
        }
        guard let capability, let adapter = registry.adapter(provider: provider) else {
            return context == nil ? (try? JSONSerialization.data(withJSONObject: page)) ?? data : data
        }
        page["agentCapabilities"] = [
            "version": 1, "adapterId": adapter.adapterID, "provider": provider,
            "revision": capability.revision, "actions": capability.actions.mapValues(\.object),
        ]
        return (try? JSONSerialization.data(withJSONObject: page, options: [.withoutEscapingSlashes])) ?? data
    }

    private func capabilities(provider: String, page: [String: Any], creation: Bool, enabled: Bool) -> [String:
        AgentActionCapability]
    {
        let flags = page["capabilities"] as? [String: Any] ?? [:]
        let usable = SessionProviderReply.boolean(page["ok"]) != false && page["event"] as? String != "unavailable"
        let ready = usable && SessionProviderReply.boolean(page["canSend"]) == true
        let idle = page["status"] as? String == "idle"
        let active = page["status"] as? String == "active" && !(page["activeTurnId"] as? String ?? "").isEmpty
        let knownStatus = ["idle", "active"].contains(page["status"] as? String ?? "")
        let externalTerminal = provider == "claude" && page["owner"] as? String == "terminal"
        let hasComposer = !(page["composer"] as? [String: Any] ?? [:]).isEmpty
        let hasApproval = !(page["approvals"] as? [[String: Any]] ?? []).isEmpty
        return Dictionary(
            uniqueKeysWithValues: SessionV1Contract.capabilityKeys.map { action in
                let contract: Bool
                switch provider {
                case "codex":
                    contract = [
                        "send", "new", "settings", "interrupt", "approvals", "questions", "queue", "queueDelete",
                        "queueSteer", "attachments", "newAttachments", "modelSelection", "permissionMode",
                        "effortSelection", "executionMode", "contextUsage", "markdownFiles", "projectFiles",
                        "videoFiles",
                    ].contains(action)
                case "claude":
                    contract = [
                        "send", "new", "settings", "interrupt", "approvals", "questions", "attachments",
                        "newAttachments", "modelSelection", "permissionMode", "effortSelection", "executionMode",
                        "contextUsage",
                        "markdownFiles", "projectFiles", "videoFiles",
                    ].contains(action)
                default:
                    contract =
                        SessionProviderReply.boolean(flags[action]) == true
                        || (provider == "zcode"
                            && [
                                "send", "new", "settings", "interrupt", "modelSelection", "permissionMode",
                                "effortSelection", "markdownFiles", "projectFiles",
                            ].contains(action))
                }
                var available = usable && SessionProviderReply.boolean(flags[action]) == true
                // Missing flags remain false unless this exact legacy native contract supplies its proof.
                if provider == "codex" || provider == "claude" {
                    switch action {
                    case "send": available = ready && knownStatus && !externalTerminal && (provider == "codex" || idle)
                    case "new":
                        available =
                            creation && usable && Self.isVersionOne(page["creationVersion"])
                            && !(page["draftId"] as? String ?? "").isEmpty
                            && registry.adapter(provider: provider)?.creationRuntimeAvailable() == true
                    case "settings", "modelSelection", "permissionMode", "effortSelection":
                        available = ready && knownStatus && hasComposer && !externalTerminal
                    case "interrupt": available = ready && active && !externalTerminal
                    case "approvals":
                        available =
                            ready && hasApproval && (provider == "codex" || page["owner"] as? String == "desktop")
                    case "queue": available = ready && knownStatus && provider == "codex"
                    case "queueDelete", "queueSteer":
                        available =
                            ready && knownStatus && provider == "codex"
                            && !(page["queuedMessages"] as? [[String: Any]] ?? []).isEmpty
                    case "questions":
                        available =
                            ready
                            && (page["approvals"] as? [[String: Any]] ?? []).contains {
                                $0["kind"] as? String == "questions"
                            } && (provider == "codex" || page["owner"] as? String == "desktop")
                    case "attachments": available = ready && knownStatus && !externalTerminal
                    case "newAttachments":
                        available = creation && usable && SessionProviderReply.boolean(flags["attachments"]) == true
                    default: break
                    }
                }
                if provider == "zcode" {
                    switch action {
                    case "send": available = available && ready && idle
                    case "interrupt": available = available && active
                    case "approvals": available = available && hasApproval
                    case "new":
                        available =
                            creation && usable && SessionProviderReply.boolean(flags["new"]) == true
                            && !(page["draftId"] as? String ?? "").isEmpty
                    default: break
                    }
                }
                if action == "executionMode" {
                    let catalog = page["executionModes"] as? [[String: Any]] ?? []
                    available =
                        usable && SessionProviderReply.boolean(flags[action]) == true
                        && catalog.contains(where: { $0["id"] as? String == "plan" })
                        && (creation || (ready && idle && hasComposer && !externalTerminal))
                }
                available = available && contract && enabled
                let reason =
                    !enabled
                    ? "provider_disabled"
                    : !contract ? "unsupported" : available ? "available" : "native_state_unavailable"
                return (action, AgentActionCapability(supported: contract, available: available, reason: reason))
            })
    }
    private static func isVersionOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue == 1,
            number.doubleValue == 1, !["d", "f"].contains(String(cString: number.objCType))
        else { return false }
        return true
    }
}
