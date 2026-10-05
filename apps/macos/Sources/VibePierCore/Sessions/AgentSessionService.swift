import Foundation

/// Profile 2 is a product protocol over verified adapters. Every effect uses the same device journal as v1.
/// All injected operations are asynchronous so the session and transport queues never synchronously wait on each other.
final class AgentSessionService: @unchecked Sendable {
    struct Journal: Sendable {
        struct Record: Sendable {
            let hash: String
            let thread: String
            let result: Data?
            let intent: Data?
            let retired: Bool
            let evidence: Data?
        }
        enum Reservation: Sendable {
            case fresh
            case complete(Data)
            case unknown, conflict
        }
        let read: @Sendable (String, @escaping @Sendable (Result<Record?, Error>) -> Void) -> Void
        let reserve:
            @Sendable (String, String, String, Data, @escaping @Sendable (Result<Reservation, Error>) -> Void) -> Void
        let complete: @Sendable (String, Data, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void
        let recordEvidence: @Sendable (String, Data, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void
    }
    typealias Execute = @Sendable (Data, String, String, @escaping @Sendable (Data) -> Void) -> Void
    typealias Describe = @Sendable (String, @escaping @Sendable (Data) -> Void) -> Void
    typealias FreshGate = @Sendable (Data, String, @escaping @Sendable (String?) -> Void) -> Void
    private struct Key: Hashable {
        let client: String
        let adapter: String
    }
    private struct State: @unchecked Sendable {
        let session: AgentSessionDirectory.Session
        let epoch: String
        let view: Int64
        let page: [String: Any]
        let capabilities: [String: Any]
        let controlDigest: String?
        let bytes: Int
    }
    private final class SnapshotRead: @unchecked Sendable {
        struct Waiter {
            let request: AgentSessionProfile.Request
            let completion: @Sendable (Data) -> Void
        }
        let session: AgentSessionDirectory.Session
        let view: Int64
        let token = UUID()
        var waiters: [Waiter]
        init(
            session: AgentSessionDirectory.Session, request: AgentSessionProfile.Request,
            completion: @escaping @Sendable (Data) -> Void
        ) {
            self.session = session
            view = request.viewVersion
            waiters = [Waiter(request: request, completion: completion)]
        }
    }
    private struct Creation: @unchecked Sendable {
        let workspace: AgentSessionDirectory.Workspace
        let draft: String
        let revision: String
        let options: [String: Any]
        let capabilities: [String: Any]
        let bytes: Int
    }
    private final class CreationRead: @unchecked Sendable {
        let workspace: String
        let draft: String
        let refresh: Bool
        let token = UUID()
        var waiters: [SnapshotRead.Waiter]
        init(
            workspace: String, draft: String, request: AgentSessionProfile.Request,
            completion: @escaping @Sendable (Data) -> Void
        ) {
            self.workspace = workspace
            self.draft = draft
            refresh = AgentSessionProfile.boolean(request.params["refreshOptions"]) == true
            waiters = [.init(request: request, completion: completion)]
        }
    }
    private struct Lease: Sendable {
        let client: String
        let adapter: String
        let target: String
        let epoch: String
        let capability: String
        let options: String
        var expires: Double
    }
    private struct Subscription: Sendable {
        let client: String
        let ref: String
        let id: String
    }
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.withLock {
                guard !used else { return false }
                used = true
                return true
            }
        }
    }
    private let queue = DispatchQueue(label: "vibepier.agent-session-service")
    private let directory: AgentSessionDirectory?
    private let execute: Execute
    private let journal: Journal
    private let describe: Describe
    private let freshGate: FreshGate
    private let eventSink: @Sendable (String, Data) -> Void
    private let now: @Sendable () -> Double
    private let additionalAdapters: @Sendable () -> [String: String]
    private var policy = SessionProviderPolicy()
    private var states: [Key: State] = [:]
    private var creations: [Key: Creation] = [:]
    private var epochs: [String: String] = [:]
    private var leases: [String: Lease] = [:]
    private var streams: [String: AgentObservationStream] = [:]
    private var subscriptions: [String: Subscription] = [:]
    private var nativeCalls: [UUID: (client: String, bytes: Int)] = [:]
    private var activeOperations = Set<String>()
    private var pendingReads: [Key: UUID] = [:]
    private var pendingViews: [Key: (ref: String, view: Int64)] = [:]
    private var snapshotReads: [Key: SnapshotRead] = [:]
    private var creationReads: [Key: CreationRead] = [:]
    private var nativeViews: [Key: (session: AgentSessionDirectory.Session, view: Int64)] = [:]

    init(
        directory: AgentSessionDirectory?, execute: @escaping Execute, journal: Journal,
        describe: @escaping Describe, freshMutationFailure: @escaping FreshGate,
        eventSink: @escaping @Sendable (String, Data) -> Void,
        additionalAdapters: @escaping @Sendable () -> [String: String] = { [:] },
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.directory = directory
        self.execute = execute
        self.journal = journal
        self.describe = describe
        freshGate = freshMutationFailure
        self.eventSink = eventSink
        self.now = now
        self.additionalAdapters = additionalAdapters
    }

    func perform(_ request: AgentSessionProfile.Request, client: String, completion: @escaping @Sendable (Data) -> Void)
    {
        let once = Once()
        let final: @Sendable (Data) -> Void = { data in if once.claim() { completion(data) } }
        queue.async {
            guard self.directory?.reliable == true else {
                self.fail(request, code: "agent_index_invalid", completion: final)
                return
            }
            if request.mutable {
                self.mutate(request, client: client, completion: final)
            } else {
                self.read(request, client: client, completion: final)
            }
        }
    }

    /// The transport derives budgets from the private target index, never a phone-supplied provider or lane.
    func admissionProvider(
        _ request: AgentSessionProfile.Request, client: String, completion: @escaping @Sendable (String?) -> Void
    ) {
        queue.async { [self] in
            if request.method == "agent.describe" {
                completion(nil)
                return
            }
            if request.method == "operation.get" {
                guard let operation = request.params["operationId"] as? String, UUID(uuidString: operation) != nil
                else {
                    completion(nil)
                    return
                }
                self.journal.read(client + ":" + operation) { [weak self] result in
                    self?.queue.async { [weak self] in
                        guard let self else {
                            completion(nil)
                            return
                        }
                        guard let record = try? result.get() else {
                            completion(nil)
                            return
                        }
                        if let intent = record.intent.flatMap(self.object),
                            let provider = intent["provider"] as? String,
                            SessionV1Contract.providers.contains(provider)
                        {
                            completion(provider)
                            return
                        }
                        if let session = self.directory?.session(record.thread) {
                            completion(session.provider)
                            return
                        }
                        if let workspace = self.directory?.workspace(record.thread) {
                            completion(workspace.provider)
                            return
                        }
                        completion(nil)
                    }
                }
                return
            }
            if request.target["sessionRef"] != nil {
                completion((try? self.resolveSession(request))?.provider)
                return
            }
            if let (adapter, provider) = try? self.resolveAdapter(request.target["adapterId"]) {
                if let ref = request.target["workspaceRef"] as? String ?? request.params["workspaceRef"] as? String {
                    guard self.directory?.workspace(ref)?.adapterID == adapter else {
                        completion(nil)
                        return
                    }
                }
                completion(provider)
                return
            }
            completion(nil)
        }
    }

    func configurePolicy(_ value: SessionProviderPolicy) {
        queue.async {
            self.policy = value
            let disabled = Set(SessionV1Contract.providers.filter { !value.isEnabled($0) })
            self.leases = self.leases.filter { lease in
                guard let provider = try? self.resolveAdapter(lease.value.adapter).1 else { return false }
                return !disabled.contains(provider)
            }
            self.states = self.states.filter { !disabled.contains($0.value.session.provider) }
            self.creations = self.creations.filter { !disabled.contains($0.value.workspace.provider) }
            self.subscriptions = self.subscriptions.filter { _, value in
                guard let provider = self.directory?.session(value.ref)?.provider else { return false }
                return !disabled.contains(provider)
            }
            self.pendingReads = self.pendingReads.filter { key, _ in
                let provider = key.adapter.components(separatedBy: ".").first ?? ""
                return !disabled.contains(provider)
            }
            self.pendingViews = self.pendingViews.filter { key, _ in self.pendingReads[key] != nil }
            self.snapshotReads = self.snapshotReads.filter { key, _ in self.pendingReads[key] != nil }
            self.creationReads = self.creationReads.filter { key, _ in self.pendingReads[key] != nil }
            self.nativeViews = self.nativeViews.filter { !disabled.contains($0.value.session.provider) }
            self.pruneStreams()
        }
    }
    /// Releases observation and ephemeral control permissions, never a native process or unknown operation.
    func close(client: String) {
        queue.async {
            self.states = self.states.filter { $0.key.client != client }
            self.creations = self.creations.filter { $0.key.client != client }
            self.leases = self.leases.filter { $0.value.client != client }
            self.subscriptions = self.subscriptions.filter { $0.value.client != client }
            self.pendingReads = self.pendingReads.filter { $0.key.client != client }
            self.pendingViews = self.pendingViews.filter { $0.key.client != client }
            self.snapshotReads = self.snapshotReads.filter { $0.key.client != client }
            self.creationReads = self.creationReads.filter { $0.key.client != client }
            self.nativeViews = self.nativeViews.filter { $0.key.client != client }
            self.pruneStreams()
        }
    }

    /// v1 events are dirty notifications. Their arrival order cannot establish a native snapshot barrier.
    func receiveCurrentV1Event(_ data: Data, provider: String, client: String) {
        receiveAdapterEvent(data, adapterID: provider + ".currentV1", provider: provider, client: client)
    }
    func receiveAdapterEvent(_ data: Data, adapterID: String, provider: String, client: String) {
        queue.async {
            guard let page = self.object(data),
                let state = self.states[Key(client: client, adapter: adapterID)], state.session.provider == provider,
                page["threadId"] == nil || page["threadId"] as? String == state.session.nativeID,
                page["viewVersion"] == nil || AgentSessionProfile.integer(page["viewVersion"]) == state.view
            else { return }
            let digest = self.controlDigest(page, session: state.session, view: state.view)
            let controlDirty = digest == nil || state.controlDigest == nil || digest != state.controlDigest
            if controlDirty { self.invalidate(client: client, ref: state.session.ref) }
            self.appendEvent(
                ref: state.session.ref,
                body: [
                    "event": "session.stateChanged", "sessionRef": state.session.ref,
                    "entityRevision": AgentSessionProfile.integer(page["revision"]) ?? 0,
                    "data": [
                        "dirty": true, "controlDirty": controlDirty, "requiresSnapshot": true,
                        "consistency": "reconciled", "provider": provider,
                    ],
                ])
        }
    }

    private func read(
        _ request: AgentSessionProfile.Request, client: String, completion: @escaping @Sendable (Data) -> Void
    ) {
        if request.method == "operation.get" {
            operation(request, client: client, completion: completion)
            return
        }
        if request.method == "agent.describe" {
            describe(client) { [weak self] bytes in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    guard let native = self.object(bytes), let directory = self.directory else {
                        self.fail(request, code: "agent_native_unavailable", completion: completion)
                        return
                    }
                    self.success(
                        request,
                        result: [
                            "hostRef": directory.hostRef, "methods": AgentSessionProfile.methods,
                            "agentCapabilities": native, "messageModes": ["start", "queue"],
                        ], completion: completion)
                }
            }
            return
        }
        if ["workspace.list", "session.list"].contains(request.method) {
            discover(request, client: client, completion: completion)
            return
        }
        if request.method == "session.creationOptions" {
            creationOptions(request, client: client, completion: completion)
            return
        }
        do {
            let session = try resolveSession(request)
            guard request.method == "session.unobserve" || policy.isEnabled(session.provider) else {
                throw AgentSessionProfile.Failure(code: "provider_disabled")
            }
            switch request.method {
            case "session.open", "session.snapshot":
                snapshot(request, session: session, client: client, completion: completion)
            case "session.items": items(request, session: session, client: client, completion: completion)
            case "session.observe": observe(request, session: session, client: client, completion: completion)
            case "session.unobserve":
                let id = try required(request.params["subscriptionId"])
                let key = client + ":" + id
                if let known = subscriptions[key], known.ref != session.ref {
                    throw AgentSessionProfile.Failure(code: "agent_target_mismatch")
                }
                subscriptions.removeValue(forKey: key)
                releaseObservation(request, session: session, client: client, completion: completion)
            default: throw AgentSessionProfile.Failure(code: "agent_method_unsupported")
            }
        } catch {
            fail(
                request, code: code(error), diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic,
                completion: completion)
        }
    }

    private func discover(
        _ request: AgentSessionProfile.Request, client: String, completion: @escaping @Sendable (Data) -> Void
    ) {
        do {
            let (adapter, provider) = try resolveAdapter(request.target["adapterId"])
            guard policy.isEnabled(provider) else { throw AgentSessionProfile.Failure(code: "provider_disabled") }
            var native: [String: Any] = [
                "id": request.id, "op": request.method == "workspace.list" ? "projects" : "list",
            ]
            for key in ["search", "offset", "limit"] { native[key] = request.params[key] }
            if let ref = request.params["workspaceRef"] as? String {
                guard let workspace = directory?.workspace(ref), workspace.adapterID == adapter else {
                    throw AgentSessionProfile.Failure(code: "agent_target_mismatch")
                }
                native["cwd"] = workspace.cwd
            }
            call(native, provider: provider, client: client, adapter: adapter) { [weak self] result in
                guard let self else { return }
                do {
                    let value = try self.nativeRead(result)
                    guard let directory = self.directory else {
                        throw AgentSessionProfile.Failure(code: "agent_index_invalid")
                    }
                    let rows =
                        value[request.method == "workspace.list" ? "projects" : "threads"] as? [[String: Any]] ?? []
                    guard rows.count <= 100 else { throw AgentSessionProfile.Failure(code: "agent_result_invalid") }
                    let projected = try rows.map { row -> [String: Any] in
                        let cwd = try self.required(row["cwd"], limit: 4096)
                        if request.method == "workspace.list" {
                            let workspace = try directory.registerWorkspace(
                                adapter: adapter, provider: provider, cwd: cwd)
                            var item = row.filter { ["project", "count", "updatedAt", "running"].contains($0.key) }
                            item.merge(["workspaceRef": workspace.ref, "adapterId": adapter, "cwd": cwd]) { $1 }
                            return item
                        }
                        let id = try self.required(row["id"])
                        let session = try directory.registerSession(
                            adapter: adapter, provider: provider, native: id, cwd: cwd)
                        var item = row.filter {
                            ["title", "project", "pinned", "updatedAt", "status"].contains($0.key)
                        }
                        item.merge(self.descriptor(session, state: self.states[Key(client: client, adapter: adapter)]))
                        { $1 }
                        return item
                    }
                    self.success(
                        request,
                        result: [
                            request.method == "workspace.list" ? "workspaces" : "sessions": projected,
                            "nextOffset": value["nextOffset"] ?? -1,
                        ], completion: completion)
                } catch {
                    self.fail(
                        request, code: self.code(error),
                        diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic, completion: completion)
                }
            }
        } catch {
            fail(
                request, code: code(error), diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic,
                completion: completion)
        }
    }

    private func snapshot(
        _ request: AgentSessionProfile.Request, session: AgentSessionDirectory.Session, client: String,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        // Opening uses the phone's monotonic view version, shared with v1 file/media reads.
        let native: [String: Any] = [
            "id": request.id, "op": "open", "threadId": session.nativeID, "viewVersion": request.viewVersion,
            // Both read methods have the same verification scope, including when they share a pending read.
            "verifyNativeOwner": true,
        ]
        let key = Key(client: client, adapter: session.adapterID)
        if let pending = snapshotReads[key], pending.session.ref == session.ref, pending.view == request.viewVersion,
            pendingReads[key] == pending.token
        {
            guard pending.waiters.count < 16 else {
                fail(request, code: "capacity_exceeded", completion: completion)
                return
            }
            pending.waiters.append(.init(request: request, completion: completion))
            return
        }
        let read = SnapshotRead(session: session, request: request, completion: completion)
        let token = read.token
        if let observation = nativeViews[key],
            observation.session.ref != session.ref || observation.view != request.viewVersion
        {
            // The new open can already replace the adapter's selection before its reply is verified.
            // Never restore the old read route if a dirty event cancels this pending snapshot.
            nativeViews.removeValue(forKey: key)
        }
        if let prior = states[key], prior.session.ref != session.ref || prior.view != request.viewVersion {
            leases = leases.filter {
                $0.value.client != client || $0.value.adapter != session.adapterID || !$0.value.options.isEmpty
            }
        }
        pendingReads[key] = token
        pendingViews[key] = (session.ref, request.viewVersion)
        snapshotReads[key] = read
        call(native, provider: session.provider, client: client, adapter: session.adapterID) { [weak self] result in
            guard let self else { return }
            do {
                guard self.snapshotReads[key] === read, self.pendingReads[key] == token,
                    self.pendingViews[key]?.ref == session.ref,
                    self.pendingViews[key]?.view == request.viewVersion, self.policy.isEnabled(session.provider)
                else {
                    throw AgentSessionProfile.Failure(code: "agent_session_view_closed")
                }
                self.pendingReads.removeValue(forKey: key)
                self.pendingViews.removeValue(forKey: key)
                self.snapshotReads.removeValue(forKey: key)
                var page = try self.nativeRead(result)
                guard page["threadId"] as? String == session.nativeID,
                    AgentSessionProfile.integer(page["viewVersion"]) == request.viewVersion
                        || (page["opening"] as? Bool == true && page["viewVersion"] == nil)
                else {
                    throw AgentSessionProfile.Failure(code: "agent_target_mismatch")
                }
                page["contentState"] =
                    page["opening"] as? Bool == true || page["messages"] == nil
                    ? "partial" : page["contentState"] ?? "complete"
                let controlDigest = self.controlDigest(page, session: session, view: request.viewVersion)
                page = self.normalizedApprovals(page, session: session)
                let caps = page["agentCapabilities"] as? [String: Any] ?? [:]
                let state = State(
                    session: session, epoch: self.epoch(session.ref), view: request.viewVersion, page: page,
                    capabilities: caps,
                    controlDigest: controlDigest,
                    bytes: AgentSessionProfile.data(page).count)
                let key = Key(client: client, adapter: session.adapterID)
                let others = self.states.filter { $0.key != key }
                guard others.count < 512, others.values.reduce(state.bytes, { $0 + $1.bytes }) <= 8 * 1024 * 1024,
                    others.filter({ $0.key.client == client }).values.reduce(state.bytes, { $0 + $1.bytes }) <= 2 * 1024
                        * 1024
                else { throw AgentSessionProfile.Failure(code: "capacity_exceeded") }
                self.states[key] = state
                self.nativeViews[key] = (session, request.viewVersion)
                self.pruneStreams()
                if self.streams[session.ref] == nil {
                    guard self.streams.count < 16 else { throw AgentSessionProfile.Failure(code: "capacity_exceeded") }
                    self.streams[session.ref] = AgentObservationStream()
                }
                let stream = self.streams[session.ref]!
                var output: [String: Any] = [
                    "session": self.descriptor(session, state: state), "snapshot": page,
                    "streamEpoch": stream.epoch, "throughSequence": stream.sequence,
                    "consistency": page["opening"] as? Bool == true ? "partial" : "reconciled",
                ]
                if page["opening"] as? Bool == true {
                    self.leases = self.leases.filter {
                        $0.value.client != client || $0.value.adapter != session.adapterID || !$0.value.options.isEmpty
                    }
                }
                if page["opening"] as? Bool != true,
                    let token = self.issueLease(
                        client: client, adapter: session.adapterID, target: session.ref, epoch: state.epoch,
                        capability: caps["revision"] as? String ?? "", options: "")
                {
                    output["controlLease"] = token
                }
                for waiter in read.waiters {
                    self.success(waiter.request, result: output, completion: waiter.completion)
                }
            } catch {
                if self.snapshotReads[key] === read {
                    self.snapshotReads.removeValue(forKey: key)
                    self.pendingReads.removeValue(forKey: key)
                    self.pendingViews.removeValue(forKey: key)
                }
                for waiter in read.waiters {
                    self.fail(
                        waiter.request, code: self.code(error),
                        diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic, completion: waiter.completion)
                }
            }
        }
    }

    private func creationOptions(
        _ request: AgentSessionProfile.Request, client: String, completion: @escaping @Sendable (Data) -> Void
    ) {
        do {
            let (adapter, provider) = try resolveAdapter(request.target["adapterId"])
            guard policy.isEnabled(provider), let ref = request.params["workspaceRef"] as? String,
                let workspace = directory?.workspace(ref), workspace.adapterID == adapter,
                let draft = request.params["draftId"] as? String, let uuid = UUID(uuidString: draft)
            else { throw AgentSessionProfile.Failure(code: "agent_target_mismatch") }
            let normalized = uuid.uuidString.lowercased()
            let key = Key(client: client, adapter: adapter + ":creation")
            if let pending = creationReads[key], pending.workspace == ref, pending.draft == normalized,
                pending.refresh == (AgentSessionProfile.boolean(request.params["refreshOptions"]) == true),
                pendingReads[key] == pending.token
            {
                guard pending.waiters.count < 16 else { throw AgentSessionProfile.Failure(code: "capacity_exceeded") }
                pending.waiters.append(.init(request: request, completion: completion))
                return
            }
            guard creationReads[key] != nil || creationReads.count < 512 else {
                throw AgentSessionProfile.Failure(code: "capacity_exceeded")
            }
            let read = CreationRead(workspace: ref, draft: normalized, request: request, completion: completion)
            let token = read.token
            creationReads[key] = read
            if let prior = creations[Key(client: client, adapter: adapter)],
                prior.workspace.ref != ref || prior.draft != normalized
            {
                leases = leases.filter {
                    $0.value.client != client || $0.value.adapter != adapter || $0.value.options.isEmpty
                }
            }
            pendingReads[key] = token
            call(
                [
                    "id": request.id, "op": "newOptions", "cwd": workspace.cwd, "draftId": normalized,
                    "refreshOptions": AgentSessionProfile.boolean(request.params["refreshOptions"]) == true,
                ], provider: provider,
                client: client, adapter: adapter
            ) { [weak self] result in
                guard let self else { return }
                do {
                    guard self.creationReads[key] === read, self.pendingReads[key] == token,
                        self.policy.isEnabled(provider)
                    else {
                        throw AgentSessionProfile.Failure(code: "agent_session_view_closed")
                    }
                    self.creationReads.removeValue(forKey: key)
                    self.pendingReads.removeValue(forKey: key)
                    let options = try self.nativeRead(result)
                    guard AgentSessionProfile.integer(options["creationVersion"]) == 1,
                        options["draftId"] as? String == normalized
                    else { throw AgentSessionProfile.Failure(code: "agent_result_invalid") }
                    let caps = options["agentCapabilities"] as? [String: Any] ?? [:]
                    // Correlation fields describe the read, not the native choices it authorizes.
                    let catalog = options.filter { !["id", "viewVersion", "op", "sentAt"].contains($0.key) }
                    let revision = AgentSessionProfile.digest(try AgentSessionProfile.canonical(catalog))
                    let state = Creation(
                        workspace: workspace, draft: normalized, revision: revision, options: options,
                        capabilities: caps, bytes: AgentSessionProfile.data(options).count)
                    let key = Key(client: client, adapter: adapter)
                    let others = self.creations.filter { $0.key != key }
                    guard others.count < 512, others.values.reduce(state.bytes, { $0 + $1.bytes }) <= 8 * 1024 * 1024,
                        others.filter({ $0.key.client == client }).values.reduce(state.bytes, { $0 + $1.bytes }) <= 2
                            * 1024 * 1024
                    else {
                        throw AgentSessionProfile.Failure(code: "capacity_exceeded")
                    }
                    self.creations[key] = state
                    var output: [String: Any] = ["options": options]
                    if let token = self.issueLease(
                        client: client, adapter: adapter, target: ref, epoch: normalized,
                        capability: caps["revision"] as? String ?? "", options: revision)
                    {
                        output["creationLease"] = [
                            "target": [
                                "adapterId": adapter, "workspaceRef": ref, "draftId": normalized,
                                "optionsRevision": revision,
                            ], "controlLease": token,
                        ]
                    }
                    for waiter in read.waiters {
                        self.success(waiter.request, result: output, completion: waiter.completion)
                    }
                } catch {
                    if self.creationReads[key] === read {
                        self.creationReads.removeValue(forKey: key)
                        self.pendingReads.removeValue(forKey: key)
                    }
                    for waiter in read.waiters {
                        self.fail(
                            waiter.request, code: self.code(error),
                            diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic,
                            completion: waiter.completion)
                    }
                }
            }
        } catch {
            fail(
                request, code: code(error), diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic,
                completion: completion)
        }
    }

    private func items(
        _ request: AgentSessionProfile.Request, session: AgentSessionDirectory.Session, client: String,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        let key = Key(client: client, adapter: session.adapterID)
        let kind = request.params["kind"] as? String ?? "recent"
        let allowsDirtyView = ["history", "parts", "message"].contains(kind)
        let state = states[key].flatMap {
            $0.session.ref == session.ref && $0.view == request.viewVersion ? $0 : nil
        }
        // Dirty events revoke write authority, while the verified native observation still owns read routing.
        guard itemViewMatches(session, key: key, view: request.viewVersion), state != nil || allowsDirtyView
        else {
            fail(request, code: "agent_session_not_open", completion: completion)
            return
        }
        if kind == "recent" {
            success(
                request,
                result: [
                    "items": state?.page["messages"] ?? [], "hasOlder": state?.page["hasOlder"] ?? true,
                    "consistency": "partial",
                ], completion: completion)
            return
        }
        let op: String
        switch kind {
        case "history": op = "history"
        case "message": op = "message"
        case "parts": op = "parts"
        case "composerOptions": op = "composerOptions"
        case "approvalDetails": op = "approvalDetails"
        default:
            fail(request, code: "agent_method_unsupported", completion: completion)
            return
        }
        var native: [String: Any] = [
            "id": request.id, "op": op, "threadId": session.nativeID, "viewVersion": request.viewVersion,
        ]
        for key in ["messageId", "before", "offset", "limit", "headersOnly", "sequence", "refreshOptions"] {
            native[key] = request.params[key]
        }
        if kind == "approvalDetails" {
            guard let id = request.params["messageId"] as? String,
                let pending = (state?.page["approvals"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }
                )
            else {
                fail(request, code: "agent_approval_changed", completion: completion)
                return
            }
            native["fingerprint"] = pending["fingerprint"]
        }
        call(native, provider: session.provider, client: client, adapter: session.adapterID) { [weak self] result in
            guard let self else { return }
            do {
                guard self.itemViewMatches(session, key: key, view: request.viewVersion),
                    allowsDirtyView || self.states[key]?.epoch == state?.epoch
                else { throw AgentSessionProfile.Failure(code: "agent_session_view_closed") }
                self.success(
                    request,
                    result: try self.nativeRead(result).merging(["consistency": "partial", "contentState": "partial"]) {
                        $1
                    },
                    completion: completion)
            } catch {
                self.fail(
                    request, code: self.code(error), diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic,
                    completion: completion)
            }
        }
    }

    private func itemViewMatches(_ session: AgentSessionDirectory.Session, key: Key, view: Int64) -> Bool {
        guard let observation = nativeViews[key], observation.session.ref == session.ref, observation.view == view,
            policy.isEnabled(session.provider)
        else { return false }
        if let pending = pendingViews[key] { return pending.ref == session.ref && pending.view == view }
        return true
    }

    private func releaseObservation(
        _ request: AgentSessionProfile.Request, session: AgentSessionDirectory.Session, client: String,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        guard !subscriptions.values.contains(where: { $0.client == client && $0.ref == session.ref }) else {
            success(
                request,
                result: ["released": true, "nativeObservationReleased": false, "reason": "other_subscription_active"],
                completion: completion)
            return
        }
        let key = Key(client: client, adapter: session.adapterID)
        let state = states[key].flatMap { $0.session.ref == session.ref ? $0 : nil }
        let pending = pendingViews[key]
        let observation = nativeViews[key].flatMap { $0.session.ref == session.ref ? $0 : nil }
        if state != nil {
            states.removeValue(forKey: key)
            leases = leases.filter { $0.value.client != client || $0.value.target != session.ref }
        }
        // A new B may already be in the native adapter while its reply is still pending. Releasing A
        // cannot cancel that read or submit a close against B, including equal caller view versions.
        if let pending, pending.ref != session.ref {
            pruneStreams()
            success(
                request, result: ["released": true, "nativeObservationReleased": false, "reason": "view_replaced"],
                completion: completion)
            return
        }
        guard let view = state?.view ?? observation?.view ?? (pending?.ref == session.ref ? pending?.view : nil) else {
            success(
                request,
                result: ["released": true, "nativeObservationReleased": false, "reason": "view_already_released"],
                completion: completion)
            return
        }
        pendingReads.removeValue(forKey: key)
        pendingViews.removeValue(forKey: key)
        snapshotReads.removeValue(forKey: key)
        nativeViews.removeValue(forKey: key)
        leases = leases.filter { $0.value.client != client || $0.value.target != session.ref }
        pruneStreams()
        call(
            ["id": request.id, "op": "close", "threadId": session.nativeID, "viewVersion": view],
            provider: session.provider, client: client, adapter: session.adapterID
        ) { [weak self] reply in
            guard let self else { return }
            let value = self.object(reply) ?? [:]
            let released =
                AgentSessionProfile.boolean(value["ok"]) == true
                && AgentSessionProfile.boolean(value["released"]) != false
            self.success(
                request,
                result: [
                    "released": true, "nativeObservationReleased": released,
                    "reason": released ? "released" : value["code"] as? String ?? "native_cleanup_unverified",
                ], completion: completion)
        }
    }

    private func observe(
        _ request: AgentSessionProfile.Request, session: AgentSessionDirectory.Session, client: String,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        do {
            let id = try required(request.params["subscriptionId"])
            guard let state = states[Key(client: client, adapter: session.adapterID)], state.session.ref == session.ref,
                let stream = streams[session.ref]
            else { throw AgentSessionProfile.Failure(code: "agent_session_not_open") }
            let key = client + ":" + id
            guard subscriptions[key] == nil || subscriptions[key]?.ref == session.ref else {
                throw AgentSessionProfile.Failure(code: "agent_target_mismatch")
            }
            guard
                subscriptions[key] != nil
                    || (subscriptions.count < 512 && subscriptions.values.filter({ $0.client == client }).count < 128)
            else { throw AgentSessionProfile.Failure(code: "capacity_exceeded") }
            subscriptions[key] = Subscription(client: client, ref: session.ref, id: id)
            var output: [String: Any] = [
                "subscriptionId": id, "streamEpoch": stream.epoch, "throughSequence": stream.sequence,
            ]
            if let epoch = request.params["streamEpoch"] as? String,
                let after = AgentSessionProfile.integer(request.params["afterSequence"])
            {
                if let events = stream.replay(epoch: epoch, after: after) {
                    output["events"] = events.compactMap { self.object($0.body) }
                    output["resyncRequired"] = false
                } else {
                    output["resyncRequired"] = true
                    output["events"] = []
                }
            } else {
                output["events"] = []
                output["resyncRequired"] = true
            }
            success(request, result: output, completion: completion)
        } catch {
            fail(
                request, code: code(error), diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic,
                completion: completion)
        }
    }

    private func mutate(
        _ request: AgentSessionProfile.Request, client: String, completion: @escaping @Sendable (Data) -> Void
    ) {
        guard let operation = request.operationID else {
            fail(request, code: "agent_request_invalid", completion: completion)
            return
        }
        let key = client + ":" + operation
        let scope = request.target["sessionRef"] as? String ?? request.target["workspaceRef"] as? String ?? ""
        journal.read(key) { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self else { return }
                do {
                    if let record = try result.get() {
                        guard record.hash == request.fingerprint, record.thread == scope else {
                            throw AgentSessionProfile.Failure(code: "operation_id_conflict")
                        }
                        if let bytes = record.result {
                            completion(self.replay(bytes, request: request))
                            return
                        }
                        completion(
                            self.mutationReply(
                                request, status: "unknown",
                                result: record.evidence.flatMap(self.object) ?? ["retired": record.retired]))
                        return
                    }
                    try self.prepareMutation(request, client: client, completion: completion)
                } catch {
                    self.fail(
                        request, code: self.code(error),
                        diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic, completion: completion)
                }
            }
        }
    }

    private func prepareMutation(
        _ request: AgentSessionProfile.Request, client: String, completion: @escaping @Sendable (Data) -> Void
    ) throws {
        let (native, provider) = try translate(request, client: client)
        let data = AgentSessionProfile.data(native)
        let intent = AgentSessionProfile.data([
            "op": "agentRequest", "id": request.id, "viewVersion": request.viewVersion,
            "body": request.body, "nativeRequest": native, "provider": provider,
        ])
        guard intent.count <= 300_000 else { throw AgentSessionProfile.Failure(code: "agent_request_too_large") }
        freshGate(data, client) { [weak self] failure in
            self?.queue.async { [weak self] in
                guard let self else { return }
                if let failure {
                    self.fail(request, code: failure, completion: completion)
                    return
                }
                let operation = request.operationID!
                let key = client + ":" + operation
                let scope = request.target["sessionRef"] as? String ?? request.target["workspaceRef"] as? String ?? ""
                self.journal.reserve(key, request.fingerprint, scope, intent) { [weak self] result in
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        do {
                            switch try result.get() {
                            case .complete(let bytes): completion(self.replay(bytes, request: request))
                            case .unknown: completion(self.mutationReply(request, status: "unknown", result: [:]))
                            case .conflict: self.fail(request, code: "operation_id_conflict", completion: completion)
                            case .fresh:
                                guard self.activeOperations.insert(key).inserted else {
                                    completion(self.mutationReply(request, status: "unknown", result: [:]))
                                    return
                                }
                                do { _ = try self.translate(request, client: client) } catch {
                                    self.activeOperations.remove(key)
                                    self.finishMutation(
                                        request, client: client, native: self.object(data) ?? [:],
                                        reply: AgentSessionProfile.data(["ok": false, "code": self.code(error)]),
                                        completion: completion)
                                    return
                                }
                                self.call(self.object(data) ?? [:], provider: provider, client: client) {
                                    [weak self] bytes in
                                    guard let self else { return }
                                    self.activeOperations.remove(key)
                                    self.finishMutation(
                                        request, client: client, native: self.object(data) ?? [:], reply: bytes,
                                        completion: completion)
                                }
                            }
                        } catch {
                            self.fail(
                                request, code: self.code(error),
                                diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic, completion: completion)
                        }
                    }
                }
            }
        }
    }

    private func translate(_ request: AgentSessionProfile.Request, client: String) throws -> ([String: Any], String) {
        guard let token = request.lease, let lease = leases[token], lease.client == client, lease.expires > now() else {
            throw AgentSessionProfile.Failure(code: "agent_lease_expired")
        }
        var native: [String: Any] = [
            "id": request.operationID!, "agentCapabilityVersion": 1, "agentAdapterId": lease.adapter,
            "agentCapabilityRevision": lease.capability,
            "agentOperationFingerprint": request.fingerprint,
            "agentJournalReservationID": client + ":" + request.operationID!,
        ]
        if request.method == "session.create" {
            guard let state = creations[Key(client: client, adapter: lease.adapter)],
                lease.target == state.workspace.ref,
                request.target["adapterId"] as? String == lease.adapter,
                request.target["workspaceRef"] as? String == state.workspace.ref,
                request.target["draftId"] as? String == state.draft,
                request.target["optionsRevision"] as? String == state.revision,
                lease.options == state.revision, lease.epoch == state.draft, policy.isEnabled(state.workspace.provider)
            else { throw AgentSessionProfile.Failure(code: "agent_target_mismatch") }
            native["op"] = "new"
            native["cwd"] = state.workspace.cwd
            native["draftId"] = state.draft
            if let initial = request.params["initialMessage"] {
                guard let initial = initial as? [String: Any], Set(initial.keys) == ["content"] else {
                    throw AgentSessionProfile.Failure(code: "agent_request_invalid")
                }
                try content(initial["content"], into: &native)
            }
            try options(request.params["options"], advertised: state.options, into: &native)
            native["provider"] = state.workspace.provider
            return (native, state.workspace.provider)
        }
        let session = try resolveSession(request)
        guard policy.isEnabled(session.provider), lease.adapter == session.adapterID, lease.target == session.ref,
            let state = states[Key(client: client, adapter: session.adapterID)], state.session.ref == session.ref,
            lease.epoch == state.epoch, request.target["ownershipEpoch"] as? String == state.epoch,
            request.target["capabilityRevision"] as? String == lease.capability,
            state.capabilities["revision"] as? String == lease.capability
        else { throw AgentSessionProfile.Failure(code: "agent_target_mismatch") }
        native["threadId"] = session.nativeID
        native["viewVersion"] = state.view
        native["provider"] = session.provider
        native["nativeOwnerEpoch"] = state.page["nativeOwnerEpoch"]
        switch request.method {
        case "message.submit":
            let mode = request.params["mode"] as? String ?? ""
            guard ["start", "queue"].contains(mode) else {
                throw AgentSessionProfile.Failure(code: "agent_mode_unsupported")
            }
            let active = state.page["status"] as? String == "active"
            let queued = !(state.page["queuedMessages"] as? [[String: Any]] ?? []).isEmpty
            guard
                mode == "start"
                    ? state.page["status"] as? String == "idle" && !queued
                    : session.provider == "codex" && (active || queued)
            else { throw AgentSessionProfile.Failure(code: "agent_state_changed") }
            if mode == "queue" {
                let action = (state.capabilities["actions"] as? [String: [String: Any]])?["queue"] ?? [:]
                guard AgentSessionProfile.boolean(action["supported"]) == true,
                    AgentSessionProfile.boolean(action["available"]) == true
                else { throw AgentSessionProfile.Failure(code: "agent_mode_unsupported") }
            }
            native["op"] = "send"
            native["submissionMode"] = mode
            try content(request.params["content"], into: &native)
        case "queue.cancel":
            guard session.provider == "codex", let id = request.params["queueId"] as? String,
                (state.page["queuedMessages"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == id })
            else { throw AgentSessionProfile.Failure(code: "agent_queue_changed") }
            native["op"] = "queueDelete"
            native["messageId"] = id
        case "queue.steer":
            // Sends a queued follow-up into the running turn now; the same native queue the desktop shows.
            guard session.provider == "codex", let id = request.params["queueId"] as? String,
                (state.page["queuedMessages"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == id })
            else { throw AgentSessionProfile.Failure(code: "agent_queue_changed") }
            if let turn = request.params["expectedTurnId"] as? String {
                guard state.page["activeTurnId"] as? String == turn else {
                    throw AgentSessionProfile.Failure(code: "agent_turn_changed")
                }
                native["expectedTurnId"] = turn
            }
            native["op"] = "queueSteer"
            native["messageId"] = id
        case "turn.interrupt":
            let turn = try required(request.params["expectedTurnId"])
            guard state.page["status"] as? String == "active", state.page["activeTurnId"] as? String == turn else {
                throw AgentSessionProfile.Failure(code: "agent_turn_changed")
            }
            native["op"] = "interrupt"
            native["expectedTurnId"] = turn
        case "session.configure":
            native["op"] = "settings"
            // The driver revalidates its actual menu/catalog. No opaque remote flags pass through.
            try options(request.params["options"], advertised: state.page, into: &native, requireCatalog: false)
        case "approval.resolve", "question.answer":
            let field = request.method == "question.answer" ? "questionId" : "approvalId"
            let id = try required(request.params[field])
            guard
                let pending = (state.page["approvals"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }
                ),
                pending["fingerprint"] as? String == request.params["fingerprint"] as? String,
                pending["revision"] as? String == request.params["revision"] as? String,
                AgentSessionProfile.boolean(pending["canDecide"]) == true,
                (pending["kind"] as? String == "questions") == (request.method == "question.answer")
            else { throw AgentSessionProfile.Failure(code: "agent_approval_changed") }
            native["op"] = "approve"
            native["fingerprint"] = pending["fingerprint"]
            native["nativeRequestId"] = pending["nativeRequestId"]
            native["nativeRequestFingerprint"] = pending["nativeRequestFingerprint"]
            if request.method == "approval.resolve" {
                let decision = try required(request.params["decision"])
                guard (pending["allowedDecisions"] as? [String] ?? []).contains(decision),
                    ["allow", "deny"].contains(decision)
                else { throw AgentSessionProfile.Failure(code: "agent_decision_unsupported") }
                native["allow"] = decision == "allow"
            } else {
                guard let answers = request.params["answers"] as? [String: String], !answers.isEmpty,
                    AgentSessionProfile.data(["answers": answers]).count <= 32_000
                else { throw AgentSessionProfile.Failure(code: "agent_request_invalid") }
                if session.provider == "claude" {
                    guard answers.count == 1, let answer = answers[id],
                        (pending["options"] as? [String] ?? []).contains(answer)
                    else { throw AgentSessionProfile.Failure(code: "agent_answer_invalid") }
                    native["option"] = answer
                } else {
                    native["answers"] = answers
                }
            }
        default: throw AgentSessionProfile.Failure(code: "agent_method_unsupported")
        }
        return (native, session.provider)
    }

    private func finishMutation(
        _ request: AgentSessionProfile.Request, client: String, native: [String: Any], reply: Data,
        reconciling: Bool = false, priorEvidence: Data? = nil,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        let value = object(reply) ?? [:]
        var outcome = proof(request, native: native, value: value)
        if reconciling && outcome.status == "rejected" && AgentSessionProfile.boolean(value["resolved"]) != true
            && AgentSessionProfile.boolean(value["definitive"]) != true
        {
            outcome = ("unknown", [:])
        }
        if outcome.status == "unknown", outcome.result.isEmpty, let previous = priorEvidence.flatMap(object) {
            outcome.result = previous
        }
        let response = mutationReply(request, status: outcome.status, result: outcome.result)
        let key = client + ":" + request.operationID!
        guard outcome.status == "confirmed" || outcome.status == "rejected" else {
            let evidence = AgentSessionProfile.data(outcome.result)
            if outcome.result.isEmpty || evidence.count > 8192 {
                completion(response)
                return
            }
            journal.recordEvidence(key, evidence) { [weak self] saved in
                self?.queue.async {
                    switch saved {
                    case .success: completion(response)
                    case .failure: completion(response)
                    }
                }
            }
            return
        }
        let failed = mutationReply(
            request, status: "unknown", result: outcome.result.merging(["code": "agent_receipt_save_failed"]) { $1 })
        journal.complete(key, response) { [weak self] saved in
            self?.queue.async {
                switch saved {
                case .success: completion(response)
                case .failure: completion(failed)
                }
            }
        }
    }

    private func proof(_ request: AgentSessionProfile.Request, native: [String: Any], value: [String: Any]) -> (
        status: String, result: [String: Any]
    ) {
        guard value["unknown"] == nil || AgentSessionProfile.boolean(value["unknown"]) == false else {
            var partial =
                AgentSessionProfile.boolean(value["unknown"]) == true
                ? partialIdentity(request, native: native, value: value) : [:]
            if let error = value["error"] as? String, AgentSessionProfile.bounded(error, maximum: 4096),
                error.count <= 2048,
                !error.unicodeScalars.contains(where: {
                    ($0.value < 32 && $0.value != 10 && $0.value != 9) || $0.value == 127
                })
            {
                partial["error"] = error
            }
            if let code = value["code"] as? String, AgentSessionProfile.bounded(code, maximum: 256) {
                partial["code"] = code
            }
            return ("unknown", partial)
        }
        if AgentSessionProfile.boolean(value["ok"]) == false {
            var rejected: [String: Any] = [
                "code": value["code"] ?? "agent_native_rejected", "error": value["error"] ?? "",
            ]
            // A definitive creation failure may leave an empty native session; report it without claiming input.
            if request.method == "session.create", AgentSessionProfile.boolean(value["definitive"]) == true {
                let partial = partialIdentity(request, native: native, value: value)
                if let session = partial["session"] { rejected["partialSession"] = session }
            }
            return ("rejected", rejected)
        }
        guard AgentSessionProfile.boolean(value["ok"]) == true else { return ("unknown", [:]) }
        if request.method == "session.create" {
            guard let id = value["threadId"] as? String, !id.isEmpty,
                value["cwd"] as? String == native["cwd"] as? String,
                let workspace = request.target["workspaceRef"] as? String, let known = directory?.workspace(workspace),
                let session = try? directory?.registerSession(
                    adapter: known.adapterID, provider: known.provider, native: id, cwd: known.cwd)
            else { return ("unknown", [:]) }
            let initial = request.params["initialMessage"] != nil
            let hasInput = nativeMessage(value) != nil && nativeTurn(value) != nil
            var result: [String: Any] = [
                "sessionCreated": true,
                "session": descriptor(session, state: nil).merging(["workspaceRef": workspace]) { $1 },
                "initialInput": initial ? hasInput ? "confirmed" : "unknown" : "none",
            ]
            if initial && hasInput {
                result["messageId"] = nativeMessage(value)
                result["turnId"] = nativeTurn(value)
                result["turnIdentityKind"] = value["turnIdentityKind"] as? String ?? "nativeTurn"
            }
            let modeVerified = verifiedExecutionMode(native: native, value: value)
            var warnings = Self.warnings(value)
            if let requested = native["executionMode"] as? String {
                result["executionMode"] = requested
                result["executionModeState"] = modeVerified ? "confirmed" : "unverified"
                if !modeVerified { warnings.append(["field": "executionMode", "requested": requested]) }
            }
            // The native thread and turn identities are the proof; option readback only adds warnings.
            if !warnings.isEmpty { result["warnings"] = warnings }
            return (initial && !hasInput ? "unknown" : "confirmed", result)
        }
        guard value["threadId"] as? String == native["threadId"] as? String else { return ("unknown", [:]) }
        switch request.method {
        case "message.submit":
            guard AgentSessionProfile.boolean(value["accepted"]) == true else { return ("unknown", [:]) }
            if request.params["mode"] as? String == "queue" {
                guard AgentSessionProfile.boolean(value["queued"]) == true, let id = value["queueId"] as? String,
                    !id.isEmpty
                else { return ("unknown", [:]) }
                return ("confirmed", ["queueId": id])
            }
            guard AgentSessionProfile.boolean(value["queued"]) != true, let message = nativeMessage(value),
                let turn = nativeTurn(value)
            else {
                return ("unknown", value["nativeMessageId"].map { ["messageId": $0] } ?? [:])
            }
            return (
                "confirmed",
                [
                    "messageId": message, "nativeMessageId": message, "turnId": turn,
                    "turnIdentityKind": value["turnIdentityKind"] as? String ?? "nativeTurn",
                ]
            )
        case "turn.interrupt":
            guard AgentSessionProfile.boolean(value["accepted"]) == true,
                value["turnId"] as? String == native["expectedTurnId"] as? String
            else { return ("unknown", [:]) }
            return (
                "confirmed",
                [
                    "turnId": value["turnId"]!, "interruptRequested": true,
                    "turnIdentityKind": value["turnIdentityKind"] as? String ?? "nativeTurn",
                ]
            )
        case "queue.cancel":
            guard AgentSessionProfile.boolean(value["accepted"]) == true,
                let rows = value["queuedMessages"] as? [[String: Any]],
                !rows.contains(where: { $0["id"] as? String == native["messageId"] as? String })
            else { return ("unknown", [:]) }
            return ("confirmed", ["queueId": native["messageId"]!, "cancelled": true])
        case "queue.steer":
            guard AgentSessionProfile.boolean(value["accepted"]) == true else { return ("unknown", [:]) }
            return ("confirmed", ["queueId": native["messageId"]!, "steered": true])
        case "session.configure":
            guard AgentSessionProfile.boolean(value["accepted"]) == true,
                verifiedExecutionMode(native: native, value: value),
                let effective = value["composer"] as? [String: Any],
                ["model", "effort", "mode", "executionMode", "serviceTier"].filter({ native[$0] != nil }).allSatisfy({
                    effective[$0] as? String == native[$0] as? String
                })
            else { return ("unknown", [:]) }
            return ("confirmed", ["effectiveOptions": effective])
        case "approval.resolve", "question.answer":
            guard AgentSessionProfile.boolean(value["submitted"]) == true,
                value["fingerprint"] as? String == native["fingerprint"] as? String
            else { return ("unknown", [:]) }
            let field = request.method == "question.answer" ? "questionId" : "approvalId"
            return (
                "confirmed", [field: request.params[field]!, "fingerprint": native["fingerprint"]!, "submitted": true]
            )
        default: return ("unknown", [:])
        }
    }

    /// Bounded, string-only readback mismatches reported by an adapter alongside a confirmed native effect.
    static func warnings(_ value: [String: Any]) -> [[String: Any]] {
        guard let rows = value["warnings"] as? [[String: Any]] else { return [] }
        return rows.prefix(8).compactMap { row in
            guard let field = row["field"] as? String, AgentSessionProfile.bounded(field, maximum: 64) else {
                return nil
            }
            var warning: [String: Any] = ["field": field]
            for key in ["requested", "observed"] {
                if let text = row[key] as? String, AgentSessionProfile.bounded(text, maximum: 256) {
                    warning[key] = text
                }
            }
            return warning
        }
    }

    private func verifiedExecutionMode(native: [String: Any], value: [String: Any]) -> Bool {
        guard let requested = native["executionMode"] as? String else { return true }
        let actual =
            value["effectiveExecutionMode"] as? String
            ?? (value["composer"] as? [String: Any])?["executionMode"] as? String
        return AgentSessionProfile.boolean(value["executionModeVerified"]) == true && actual == requested
    }

    /// Partial native identity is durable evidence, never a claim that every requested effect succeeded.
    private func partialIdentity(_ request: AgentSessionProfile.Request, native: [String: Any], value: [String: Any])
        -> [String: Any]
    {
        var partial: [String: Any] = [:]
        if request.method == "session.create" {
            guard let id = value["threadId"] as? String, AgentSessionProfile.bounded(id, maximum: 1024),
                value["cwd"] as? String == native["cwd"] as? String,
                let ref = request.target["workspaceRef"] as? String, let workspace = directory?.workspace(ref),
                let session = try? directory?.registerSession(
                    adapter: workspace.adapterID, provider: workspace.provider, native: id, cwd: workspace.cwd)
            else { return [:] }
            partial["sessionCreated"] = true
            partial["session"] = descriptor(session, state: nil).merging(["workspaceRef": ref]) { $1 }
            partial["initialInput"] = request.params["initialMessage"] == nil ? "none" : "unknown"
        } else if value["threadId"] as? String != native["threadId"] as? String {
            return [:]
        }
        for key in ["messageId", "nativeMessageId", "queueId", "turnId", "nativeTurnId"] {
            if let id = value[key] as? String, AgentSessionProfile.bounded(id, maximum: 1024) { partial[key] = id }
        }
        if let kind = value["turnIdentityKind"] as? String,
            ["nativeTurn", "nativeMessageAnchor", "managedRun"].contains(kind)
        {
            partial["turnIdentityKind"] = kind
        }
        if AgentSessionProfile.boolean(value["queued"]) == true { partial["queued"] = true }
        return partial
    }

    private func operation(
        _ request: AgentSessionProfile.Request, client: String, completion: @escaping @Sendable (Data) -> Void
    ) {
        guard let operation = request.params["operationId"] as? String, UUID(uuidString: operation) != nil else {
            fail(request, code: "agent_request_invalid", completion: completion)
            return
        }
        let key = client + ":" + operation
        journal.read(key) { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self else { return }
                do {
                    guard let record = try result.get() else {
                        self.success(
                            request, result: ["operation": ["operationId": operation, "status": "notFound"]],
                            completion: completion)
                        return
                    }
                    if let bytes = record.result, let body = self.object(bytes)?["body"] as? [String: Any],
                        AgentSessionProfile.integer(body["agentProtocol"]) == 2
                    {
                        self.success(request, result: ["operation": body], completion: completion)
                        return
                    }
                    guard !record.retired, let data = record.intent, let intent = self.object(data),
                        let original = try? AgentSessionProfile.decode(intent),
                        original.operationID == operation, original.fingerprint == record.hash,
                        let native = intent["nativeRequest"] as? [String: Any],
                        let provider = intent["provider"] as? String,
                        SessionV1Contract.providers.contains(provider)
                    else {
                        self.success(
                            request,
                            result: [
                                "operation": ["operationId": operation, "status": "unknown", "retired": record.retired]
                            ], completion: completion)
                        return
                    }
                    if self.activeOperations.contains(key) {
                        self.success(
                            request,
                            result: [
                                "operation": [
                                    "operationId": operation, "status": "accepted", "target": original.target,
                                ]
                            ], completion: completion)
                        return
                    }
                    var lookup = native
                    let op = native["op"] as? String ?? ""
                    lookup["operation"] = operation
                    lookup["originalOperation"] = op
                    switch op {
                    case "new": lookup["op"] = "newReceiptCheck"
                    case "settings": lookup["op"] = "settingsReceiptCheck"
                    case "interrupt": lookup["op"] = "interruptReceiptCheck"
                    case "queueDelete":
                        lookup["op"] = "queueReceiptCheck"
                        lookup["action"] = "delete"
                    case "queueSteer":
                        lookup["op"] = "queueReceiptCheck"
                        lookup["action"] = "steer"
                    default: lookup["op"] = "receiptCheck"
                    }
                    let nativeData = AgentSessionProfile.data(native)
                    self.call(lookup, provider: provider, client: client) { [weak self] bytes in
                        guard let self else { return }
                        self.finishMutation(
                            original, client: client, native: self.object(nativeData) ?? [:], reply: bytes,
                            reconciling: true, priorEvidence: record.evidence
                        ) {
                            [weak self] final in
                            self?.queue.async { [weak self] in
                                guard let self else { return }
                                let body =
                                    self.object(final)?["body"] as? [String: Any] ?? [
                                        "operationId": operation, "status": "unknown",
                                    ]
                                self.success(request, result: ["operation": body], completion: completion)
                            }
                        }
                    }
                } catch {
                    self.fail(
                        request, code: self.code(error),
                        diagnostic: (error as? AgentSessionProfile.Failure)?.diagnostic, completion: completion)
                }
            }
        }
    }

    private func call(
        _ native: [String: Any], provider: String, client: String, adapter: String? = nil,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        var scoped = native
        scoped["provider"] = provider
        scoped["agentAdapterId"] = native["agentAdapterId"] ?? adapter ?? provider + ".currentV1"
        let bytes = AgentSessionProfile.data(scoped)
        guard bytes.count <= 300_000, nativeCalls.count < 64,
            nativeCalls.values.filter({ $0.client == client }).count < 16,
            nativeCalls.values.reduce(bytes.count, { $0 + $1.bytes }) <= 8 * 1024 * 1024,
            nativeCalls.values.filter({ $0.client == client }).reduce(bytes.count, { $0 + $1.bytes }) <= 2 * 1024 * 1024
        else {
            completion(AgentSessionProfile.data(["ok": false, "code": "capacity_exceeded"]))
            return
        }
        let token = UUID()
        nativeCalls[token] = (client, bytes.count)
        execute(bytes, provider, client) { [weak self] reply in
            self?.queue.async { [weak self] in
                guard let self, self.nativeCalls.removeValue(forKey: token) != nil else { return }
                completion(reply.count <= 300_000 ? reply : Data())
            }
        }
    }
    private func resolveAdapter(_ value: Any?) throws -> (String, String) {
        let adapter = try required(value, limit: 128)
        guard
            let provider = SessionV1Contract.providers.first(where: { adapter == $0 + ".currentV1" })
                ?? additionalAdapters()[adapter], SessionV1Contract.providers.contains(provider)
        else {
            throw AgentSessionProfile.Failure(code: "agent_adapter_unsupported")
        }
        return (adapter, provider)
    }
    private func resolveSession(_ request: AgentSessionProfile.Request) throws -> AgentSessionDirectory.Session {
        guard let ref = request.target["sessionRef"] as? String, let session = directory?.session(ref),
            request.target["adapterId"] == nil || request.target["adapterId"] as? String == session.adapterID
        else { throw AgentSessionProfile.Failure(code: "agent_target_mismatch") }
        return session
    }
    private func descriptor(_ session: AgentSessionDirectory.Session, state: State?) -> [String: Any] {
        let current = state?.session.ref == session.ref ? state : nil
        return [
            "sessionRef": session.ref, "adapterId": session.adapterID, "nativeThreadId": session.nativeID,
            "cwd": session.cwd, "ownershipEpoch": current?.epoch ?? epoch(session.ref),
            "capabilityRevision": current?.capabilities["revision"] as? String ?? "unavailable",
            "actions": current?.capabilities["actions"] ?? [:],
        ]
    }
    private func epoch(_ ref: String) -> String {
        if let value = epochs[ref] { return value }
        let value = UUID().uuidString.lowercased()
        epochs[ref] = value
        return value
    }
    /// Only a complete control projection can prove that a native event changed content alone. Token counters,
    /// reply text, revisions and composer usage summaries are deliberately excluded from write authority.
    private func controlDigest(_ source: [String: Any], session: AgentSessionDirectory.Session, view: Int64)
        -> String?
    {
        // Output normalization bounds cards and supplies an empty list for older read projections. Neither
        // fallback can prove that the raw native event carried every pending approval.
        guard let rawApprovals = source["approvals"] as? [[String: Any]], rawApprovals.count <= 128 else {
            return nil
        }
        let page = normalizedApprovals(source, session: session)
        guard page["event"] as? String != "unavailable", page["opening"] as? Bool != true,
            AgentSessionProfile.boolean(page["ok"]) != false,
            page["contentState"] == nil || page["contentState"] as? String == "complete",
            page["threadId"] as? String == session.nativeID,
            AgentSessionProfile.integer(page["viewVersion"]) == view,
            page["provider"] == nil || page["provider"] as? String == session.provider,
            let canSend = AgentSessionProfile.boolean(page["canSend"]),
            let status = page["status"] as? String, ["idle", "active"].contains(status),
            let turn = page["activeTurnId"] as? String, status != "active" || !turn.isEmpty,
            let composer = page["composer"] as? [String: Any],
            ["model", "mode", "effort"].allSatisfy({ composer[$0] is String }),
            let approvals = page["approvals"] as? [[String: Any]], approvals.count <= 128,
            let caps = page["agentCapabilities"] as? [String: Any],
            AgentSessionProfile.integer(caps["version"]) == 1,
            caps["adapterId"] as? String == session.adapterID,
            caps["provider"] as? String == session.provider,
            let revision = caps["revision"] as? String, !revision.isEmpty,
            let actions = caps["actions"] as? [String: [String: Any]],
            SessionV1Contract.capabilityKeys.allSatisfy({ key in
                AgentSessionProfile.boolean(actions[key]?["supported"]) != nil
                    && AgentSessionProfile.boolean(actions[key]?["available"]) != nil
                    && actions[key]?["reason"] is String
            }),
            AgentSessionProfile.bounded(page["nativeOwnerEpoch"] as? String, maximum: 1024)
                || AgentSessionProfile.bounded(page["owner"] as? String, maximum: 1024)
        else { return nil }
        let queued: [[String: Any]]
        if let nativeQueue = page["queuedMessages"] {
            guard let rows = nativeQueue as? [[String: Any]] else { return nil }
            queued = rows
        } else {
            // Claude and ZCode omit this Codex field when their adapter explicitly has no queue contract.
            guard AgentSessionProfile.boolean(actions["queue"]?["supported"]) == false else { return nil }
            queued = []
        }
        let choices = composer.filter {
            ["model", "mode", "effort", "executionMode", "serviceTier", "locked", "executionModePermissionCoupled"]
                .contains($0.key)
                || $0.key.hasSuffix("Locked")
        }
        var controls: [String: Any] = [
            "session": session.ref, "provider": session.provider, "view": view, "canSend": canSend,
            "status": status, "activeTurnId": turn, "composer": choices, "approvals": approvals,
            "queuedMessages": queued, "agentCapabilities": caps,
        ]
        for key in ["nativeOwnerEpoch", "owner", "executionModePermissionCoupled"] { controls[key] = page[key] }
        guard let data = try? AgentSessionProfile.canonical(controls) else { return nil }
        return AgentSessionProfile.digest(data)
    }
    private func invalidate(client: String, ref: String) {
        epochs[ref] = UUID().uuidString.lowercased()
        for (key, state) in states where state.session.ref == ref {
            if let pending = pendingViews[key], pending.ref == ref, pending.view == state.view {
                pendingReads.removeValue(forKey: key)
                pendingViews.removeValue(forKey: key)
                snapshotReads.removeValue(forKey: key)
            }
        }
        leases = leases.filter { $0.value.target != ref }
        states = states.filter { $0.value.session.ref != ref }
    }
    private func pruneStreams() {
        let needed = Set(states.values.map { $0.session.ref } + subscriptions.values.map(\.ref))
        streams = streams.filter { needed.contains($0.key) }
    }
    private func issueLease(
        client: String, adapter: String, target: String, epoch: String, capability: String, options: String
    ) -> String? {
        leases = leases.filter { $0.value.expires > now() }
        if let existing = leases.first(where: { _, lease in
            lease.client == client && lease.adapter == adapter && lease.target == target && lease.epoch == epoch
                && lease.capability == capability && lease.options == options
        }) {
            var renewed = existing.value
            renewed.expires = now() + 60
            leases[existing.key] = renewed
            return existing.key
        }
        // Only one current session and one creation scope are live for a client/adapter. Superseded tokens
        // cannot accumulate merely because native capabilities change during frequent refreshes.
        leases = leases.filter { _, lease in
            lease.client != client || lease.adapter != adapter || lease.options.isEmpty != options.isEmpty
        }
        guard !capability.isEmpty, leases.count < 512, leases.values.filter({ $0.client == client }).count < 128 else {
            return nil
        }
        let id = UUID().uuidString.lowercased()
        leases[id] = Lease(
            client: client, adapter: adapter, target: target, epoch: epoch, capability: capability, options: options,
            expires: now() + 60)
        return id
    }
    private func normalizedApprovals(_ source: [String: Any], session: AgentSessionDirectory.Session) -> [String: Any] {
        var page = source
        page["approvals"] = (source["approvals"] as? [[String: Any]] ?? []).prefix(128).map {
            original -> [String: Any] in
            var item = original
            let fingerprint = original["fingerprint"] as? String ?? ""
            let id = AgentSessionProfile.digest(
                AgentSessionProfile.data([
                    "session": session.ref, "nativeId": original["id"] ?? original["requestId"] ?? "",
                    "fingerprint": fingerprint,
                ]))
            item["id"] = id
            item["nativeRequestId"] = original["nativeRequestId"] ?? original["id"] ?? original["requestId"]
            item["nativeRequestFingerprint"] = original["nativeRequestFingerprint"] ?? fingerprint
            item["revision"] = AgentSessionProfile.digest(AgentSessionProfile.data(original))
            if original["options"] is [String] { item["kind"] = "questions" }
            let safePlan =
                session.adapterID == "claude.currentV1"
                && AgentSessionProfile.boolean(original["plan"]) == true
                && original["planApprovalScope"] as? String == "once"
                && AgentSessionProfile.bounded(original["toolUseId"] as? String, maximum: 256)
            let unsupportedScope =
                original["method"] as? String == "item/permissions/requestApproval"
                || (AgentSessionProfile.boolean(original["plan"]) == true && !safePlan)
            let verifiedOnce =
                session.adapterID == "codex.currentV1"
                ? ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(
                    original["method"] as? String ?? "")
                : session.adapterID == "claude.currentV1"
                    && AgentSessionProfile.bounded(original["toolUseId"] as? String, maximum: 1024)
            let explicit = original["allowedDecisions"] as? [String] ?? []
            item["allowedDecisions"] =
                AgentSessionProfile.boolean(original["canDecide"]) == true && item["kind"] as? String != "questions"
                    && !unsupportedScope
                ? verifiedOnce ? ["allow", "deny"] : explicit.filter { ["allow", "deny"].contains($0) } : []
            item["decisionScope"] = "once"
            if unsupportedScope {
                item["canDecide"] = false
                item["reason"] = "permission_scope_unsupported"
            }
            return item
        }
        return page
    }
    private func appendEvent(ref: String, body: [String: Any]) {
        guard var stream = streams[ref], let event = stream.append(body) else { return }
        streams[ref] = stream
        for subscription in subscriptions.values where subscription.ref == ref {
            guard var content = object(event.body) else { continue }
            content["agentProtocol"] = 2
            content["subscriptionId"] = subscription.id
            eventSink(subscription.client, AgentSessionProfile.data(["event": "agentEvent", "body": content]))
        }
    }
    private func options(
        _ raw: Any?, advertised: [String: Any], into native: inout [String: Any], requireCatalog: Bool = true
    ) throws {
        guard let raw else { return }
        guard let values = raw as? [String: Any], !values.isEmpty else {
            throw AgentSessionProfile.Failure(code: "agent_options_invalid")
        }
        let composer = advertised["composer"] as? [String: Any] ?? [:]
        for field in ["model", "mode", "effort"] where values[field] != nil {
            let choice = try required(values[field], limit: 256)
            var known: [String] = []
            if field == "model" {
                known = (advertised["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            if field == "mode" {
                known = (advertised["permissionModes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            if field == "effort" {
                let selected = values["model"] as? String ?? composer["model"] as? String ?? ""
                known =
                    ((advertised["models"] as? [[String: Any]] ?? []).first { $0["id"] as? String == selected }?[
                        "efforts"] as? [String]) ?? []
                known += (advertised["efforts"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            if requireCatalog && !known.contains(choice) {
                throw AgentSessionProfile.Failure(code: "agent_options_changed")
            }
            let permissionChoice = (advertised["permissionModes"] as? [[String: Any]] ?? []).first {
                $0["id"] as? String == choice
            }
            if field == "mode"
                && (["full-access", "bypassPermissions", "yolo"].contains(choice)
                    || AgentSessionProfile.boolean(permissionChoice?["requiresConfirmation"]) == true)
            {
                guard AgentSessionProfile.boolean(values["confirmation"]) == true else {
                    throw AgentSessionProfile.Failure(code: "agent_confirmation_required")
                }
                native["confirmFullAccess"] = true
            }
            native[field] = choice
        }
        if let raw = values["serviceTier"] {
            let choice = try required(raw, limit: 256)
            guard ["standard", "priority"].contains(choice),
                composer["serviceTier"] is String
            else { throw AgentSessionProfile.Failure(code: "agent_options_changed") }
            if requireCatalog {
                let model = values["model"] as? String ?? composer["model"] as? String ?? ""
                let entry = (advertised["models"] as? [[String: Any]] ?? []).first { $0["id"] as? String == model }
                guard (entry?["serviceTiers"] as? [String] ?? []).contains(choice) else {
                    throw AgentSessionProfile.Failure(code: "agent_options_changed")
                }
            }
            native["serviceTier"] = choice
        }
        if let raw = values["executionMode"] {
            let choice = try required(raw, limit: 256)
            let catalog = advertised["executionModes"] as? [[String: Any]] ?? []
            let capabilities = advertised["agentCapabilities"] as? [String: Any] ?? [:]
            let actions = capabilities["actions"] as? [String: [String: Any]] ?? [:]
            guard ["default", "plan"].contains(choice), catalog.contains(where: { $0["id"] as? String == choice }),
                AgentSessionProfile.boolean(actions["executionMode"]?["supported"]) == true,
                AgentSessionProfile.boolean(actions["executionMode"]?["available"]) == true
            else { throw AgentSessionProfile.Failure(code: "agent_capability_unavailable") }
            native["executionMode"] = choice
        }
        guard ["model", "mode", "effort", "executionMode", "serviceTier"].contains(where: { values[$0] != nil }) else {
            throw AgentSessionProfile.Failure(code: "agent_options_invalid")
        }
    }
    private func content(_ raw: Any?, into native: inout [String: Any]) throws {
        guard let values = raw as? [[String: Any]], !values.isEmpty, values.count <= 64 else {
            throw AgentSessionProfile.Failure(code: "agent_content_invalid")
        }
        var text: [String] = []
        var attachments: [String] = []
        for value in values {
            switch value["type"] as? String {
            case "text":
                guard Set(value.keys) == ["type", "text"], let value = value["text"] as? String, !value.contains("\0")
                else { throw AgentSessionProfile.Failure(code: "agent_content_invalid") }
                text.append(value)
            case "attachment":
                guard Set(value.keys) == ["type", "attachmentId"] else {
                    throw AgentSessionProfile.Failure(code: "agent_content_invalid")
                }
                attachments.append(try required(value["attachmentId"], limit: 256))
            default: throw AgentSessionProfile.Failure(code: "agent_content_unsupported")
            }
        }
        let joined = text.joined(separator: "\n")
        guard joined.utf8.count <= 32_000,
            !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
            attachments.count <= 32, Set(attachments).count == attachments.count
        else { throw AgentSessionProfile.Failure(code: "agent_content_invalid") }
        native["text"] = joined
        if !attachments.isEmpty { native["attachments"] = attachments }
    }
    private func nativeDiagnostic(_ value: Any?) -> String? {
        guard let value = value as? String, AgentSessionProfile.bounded(value, maximum: 4096), value.count <= 2048,
            !value.unicodeScalars.contains(where: {
                ($0.value < 32 && $0.value != 10 && $0.value != 9) || $0.value == 127
            })
        else { return nil }
        return value
    }
    private func nativeRead(_ data: Data) throws -> [String: Any] {
        guard let value = object(data) else { throw AgentSessionProfile.Failure(code: "agent_native_unavailable") }
        guard AgentSessionProfile.boolean(value["ok"]) == true else {
            let code = (value["code"] as? String).flatMap { AgentSessionProfile.bounded($0, maximum: 256) ? $0 : nil }
            throw AgentSessionProfile.Failure(
                code: code ?? "agent_native_unavailable", diagnostic: nativeDiagnostic(value["error"]))
        }
        return value
    }
    private func nativeMessage(_ value: [String: Any]) -> String? {
        let id = value["messageId"] as? String ?? value["nativeMessageId"] as? String
        return AgentSessionProfile.bounded(id, maximum: 1024) ? id : nil
    }
    private func nativeTurn(_ value: [String: Any]) -> String? {
        let turn = value["turnId"] as? String
        let native = value["nativeTurnId"] as? String
        guard turn == nil || native == nil || turn == native,
            let id = turn ?? native, AgentSessionProfile.bounded(id, maximum: 1024)
        else { return nil }
        if id.hasPrefix("transcript:") {
            guard value["turnIdentityKind"] as? String == "nativeMessageAnchor",
                let message = nativeMessage(value), let session = value["threadId"] as? String,
                id == "transcript:" + session + ":" + message
            else { return nil }
        } else if id.hasPrefix("desktop:") {
            guard value["turnIdentityKind"] as? String == "nativeMessageAnchor",
                let message = nativeMessage(value), id.hasSuffix(":" + message)
            else { return nil }
        }
        return id
    }
    private func object(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= 300_000 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private func required(_ value: Any?, limit: Int = 1024) throws -> String {
        guard let value = value as? String, AgentSessionProfile.bounded(value, maximum: limit) else {
            throw AgentSessionProfile.Failure(code: "agent_request_invalid")
        }
        return value
    }
    private func code(_ error: Error) -> String {
        (error as? AgentSessionProfile.Failure)?.code
            ?? ((error as? SessionReceiptJournal.Failure) == .full
                ? "capacity_exceeded" : "agent_receipt_storage_unavailable")
    }
    private func effect(_ request: AgentSessionProfile.Request) -> String {
        switch request.method {
        case "session.create": return "session.created"
        case "session.configure": return "session.configured"
        case "message.submit":
            return request.params["mode"] as? String == "queue" ? "message.queued" : "message.submitted"
        case "turn.interrupt": return "turn.interruptRequested"
        case "approval.resolve": return "approval.resolved"
        case "question.answer": return "question.answered"
        case "queue.cancel": return "queue.cancelled"
        case "queue.steer": return "queue.steered"
        default: return "unknown"
        }
    }
    private func mutationReply(_ request: AgentSessionProfile.Request, status: String, result: [String: Any]) -> Data {
        let unknown = ["accepted", "unknown"].contains(status)
        var outer: [String: Any] = [
            "id": request.id, "ok": status == "confirmed",
            "body": [
                "agentProtocol": 2, "requestId": request.id, "operationId": request.operationID ?? "", "status": status,
                "effect": effect(request), "target": request.target, "result": result,
            ],
        ]
        if unknown { outer["unknown"] = true }
        return AgentSessionProfile.data(outer)
    }
    private func replay(_ data: Data, request: AgentSessionProfile.Request) -> Data {
        guard var value = object(data), var body = value["body"] as? [String: Any],
            AgentSessionProfile.integer(body["agentProtocol"]) == 2
        else {
            return mutationReply(request, status: "unknown", result: ["code": "agent_legacy_receipt"])
        }
        value["id"] = request.id
        body["requestId"] = request.id
        value["body"] = body
        return AgentSessionProfile.data(value)
    }
    private func success(
        _ request: AgentSessionProfile.Request, result: [String: Any], completion: @escaping @Sendable (Data) -> Void
    ) {
        let output = AgentSessionProfile.data([
            "id": request.id, "ok": true, "body": ["agentProtocol": 2, "requestId": request.id, "result": result],
        ])
        if output.count > 300_000 {
            fail(request, code: "agent_result_too_large", completion: completion)
        } else {
            completion(output)
        }
    }
    private func fail(
        _ request: AgentSessionProfile.Request, code: String, diagnostic: String? = nil,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        if request.mutable && ["agent_receipt_storage_unavailable", "agent_index_invalid"].contains(code) {
            completion(mutationReply(request, status: "unknown", result: ["code": code]))
            return
        }
        var body: [String: Any] = ["agentProtocol": 2, "requestId": request.id, "code": code]
        if let diagnostic = nativeDiagnostic(diagnostic) { body["error"] = diagnostic }
        if request.mutable {
            body["operationId"] = request.operationID
            body["status"] = "rejected"
            body["target"] = request.target
        }
        completion(
            AgentSessionProfile.data([
                "id": request.id, "ok": false, "code": code, "error": L10n.text("agent.capability_unavailable"),
                "body": body,
            ]))
    }
}
