import Darwin
import Foundation

/// The phone talks to the same ZCode session the desktop owns. Reads use native
/// SQLite pages; writes may only use a separately verified desktop adapter.
final class ZCodeBridge: @unchecked Sendable {
    /// Owner-only diagnostics retain readiness failures, never prompt or attachment fields.
    private final class CreationReadDiagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [[String: Any]] = []
        func record(client: String, result: [String: Any]) {
            lock.withLock {
                rows.removeAll { $0["client"] as? String == client }
                var row: [String: Any] = ["client": client, "ok": result["ok"] as? Bool ?? false]
                if let reason = result["error"] as? String { row["reason"] = String(reason.prefix(2048)) }
                rows.append(row)
                if rows.count > 16 { rows.removeFirst(rows.count - 16) }
            }
        }
        func snapshot() -> [[String: Any]] { lock.withLock { rows } }
    }
    private static let creationReadDiagnostics = CreationReadDiagnostics()
    private static let mutationDiagnostics = CreationReadDiagnostics()
    static func recentMutations() -> [[String: Any]] { mutationDiagnostics.snapshot() }
    static func recentCreationReads() -> [[String: Any]] { creationReadDiagnostics.snapshot() }

    struct DesktopAccess: @unchecked Sendable {
        let snapshot: @Sendable (String) throws -> [String: Any]
        let execute: @Sendable ([String: Any], String, String, String) throws -> [String: Any]
        let prepareSnapshot: (@Sendable (String) throws -> [String: Any])?
        init(
            snapshot: @escaping @Sendable (String) throws -> [String: Any],
            execute: @escaping @Sendable ([String: Any], String, String, String) throws -> [String: Any],
            prepareSnapshot: (@Sendable (String) throws -> [String: Any])? = nil
        ) {
            self.snapshot = snapshot
            self.execute = execute
            self.prepareSnapshot = prepareSnapshot
        }
    }
    private struct Cached {
        let version: String
        let summary: [String: Any]
        let turns: [ZCodeSessionStore.Turn]
        let hasOlder: Bool
    }
    private static let capabilityNames = [
        "send", "new", "interrupt", "settings", "modelSelection", "permissionMode", "executionMode", "attachments",
        "approvals", "queue",
    ]
    static let readOnlyCapabilities = Dictionary(uniqueKeysWithValues: capabilityNames.map { ($0, false) }).merging([
        "markdownFiles": true, "projectFiles": true,
    ]) { $1 }
    private let queue = DispatchQueue(label: "vibepier.zcode-bridge")
    private let store: ZCodeSessionStore
    private let desktop: DesktopAccess?
    private let markdownFiles = SessionMarkdownFiles()
    // ZCode keeps only its newest turn in memory. Preserve exact references from
    // trusted older pages this open view loaded, without loading all SQLite bodies.
    private var markdownReferences: [String: Set<String>] = [:]
    private var selected: [String: String] = [:]
    private var viewVersions: [String: Int64] = [:]
    private var updateIntervals: [String: Double] = [:]
    private var cached: [String: Cached] = [:]
    private var listCache: [String: (version: String, value: [String: Any])] = [:]
    private var emitted: [String: [String: Any]] = [:]
    private var revisions: [String: Int] = [:]
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var scheduled = false
    private let operationReceipts = ProviderOperationReceipts()
    var event: (@Sendable (String, Data) -> Void)?

    init(store: ZCodeSessionStore = ZCodeSessionStore(), desktop: DesktopAccess? = nil) {
        self.store = store
        self.desktop = desktop
    }
    func stop(_ client: String) { queue.async { self.unsubscribe(client) } }
    /// Desktop AX observers can report capability/busy changes without polling.
    func refresh() { queue.async { self.schedule() } }
    func stopAll() {
        queue.async {
            for client in Array(self.selected.keys) { self.unsubscribe(client) }
            self.cached.removeAll()
            self.listCache.removeAll()
        }
    }
    private let requestAdmission = SessionRequestAdmission()

    func perform(_ data: Data, client: String, completion: @escaping @Sendable (Data) -> Void) {
        if let cached = operationReceipts.cachedReply(data, client: client, provider: "zcode") {
            if let value = try? JSONSerialization.jsonObject(with: cached) as? [String: Any],
                let normalized = try? JSONSerialization.data(withJSONObject: Self.withMessageAnchor(value))
            {
                completion(normalized)
            } else {
                completion(cached)
            }
            return
        }
        requestAdmission.submit(on: queue) {
            completion(SessionRequestAdmission.rejection(provider: "zcode"))
        } work: { [self] in
            var result: [String: Any]
            var ticket: ProviderOperationReceipts.Ticket?
            var creationRead = false
            var mutationID: String?
            do {
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CLIError(L10n.text("core.invalid_request"))
                }
                creationRead = request["op"] as? String == "newOptions"
                if ProviderOperationReceipts.mutable(request["op"] as? String ?? "") {
                    mutationID = request["id"] as? String
                    switch try self.operationReceipts.begin(request, client: client) {
                    case .fresh(let fresh): ticket = fresh
                    case .cached(var cached):
                        cached = Self.withMessageAnchor(cached)
                        cached["provider"] = "zcode"
                        completion((try? JSONSerialization.data(withJSONObject: cached)) ?? Data())
                        return
                    }
                }
                result = try self.handle(request, client: client)
                if result["ok"] == nil { result["ok"] = true }
            } catch let file as SessionFileRequest {
                SessionFileLoader.shared.perform(file, provider: "zcode", completion: completion)
                return
            } catch let image as ConversationImageRequest {
                ConversationImageLoader.shared.perform(image, provider: "zcode", completion: completion)
                return
            } catch {
                result = ProviderFailure.reply(error, provider: "zcode")
            }
            result = Self.withMessageAnchor(result)
            if creationRead { Self.creationReadDiagnostics.record(client: client, result: result) }
            if let ticket { result = self.operationReceipts.finish(ticket, result: result) }
            if let mutationID { Self.mutationDiagnostics.record(client: client + ":" + mutationID, result: result) }
            result["provider"] = "zcode"
            completion((try? JSONSerialization.data(withJSONObject: result)) ?? Data())
        }
    }
    /// ZCode's verified human message is the same anchor exposed as activeTurnId.
    /// Preserve unknown results; an accepted message alone must not be mistaken for a native turn ID.
    static func withMessageAnchor(_ value: [String: Any]) -> [String: Any] {
        guard value["accepted"] as? Bool == true, value["unknown"] as? Bool != true,
            value["ok"] as? Bool != false,
            let session = value["threadId"] as? String ?? value["sessionId"] as? String,
            !session.isEmpty, session.utf8.count <= 200,
            let message = value["nativeMessageId"] as? String ?? value["messageId"] as? String,
            !message.isEmpty, message.utf8.count <= 256
        else { return value }
        guard (value["threadId"] as? String ?? session) == session,
            (value["sessionId"] as? String ?? session) == session,
            (value["messageId"] as? String ?? message) == message,
            (value["turnId"] as? String ?? message) == message,
            (value["nativeTurnId"] as? String ?? message) == message
        else { return value.merging(["unknown": true]) { $1 } }
        return value.merging([
            "threadId": session, "turnId": message, "turnIdentityKind": "nativeMessageAnchor",
        ]) { $1 }
    }

    private func capabilities(_ value: [String: Any]) -> [String: Bool] {
        let source = value["capabilities"] as? [String: Any] ?? [:]
        return Dictionary(
            uniqueKeysWithValues: Self.capabilityNames.map { ($0, desktop != nil && source[$0] as? Bool == true) }
        ).merging(["markdownFiles": true, "projectFiles": true]) { $1 }
    }
    private func live(_ session: String) -> [String: Any] { (try? desktop?.snapshot(session)) ?? [:] }
    private func state(_ session: String) throws -> Cached {
        let version = try store.version()
        if let saved = cached[session], saved.version == version { return saved }
        let summary = try store.summary(session)
        let window = try store.window(session)
        let value = Cached(version: version, summary: summary, turns: window.turns, hasOlder: window.hasOlder)
        if cached.count >= 16, let victim = cached.keys.first(where: { !selected.values.contains($0) && $0 != session })
        {
            cached.removeValue(forKey: victim)
        }
        cached[session] = value
        return value
    }
    private func page(_ session: String, prepareOwner: Bool = false) throws -> [String: Any] {
        let state = try state(session)
        let live: [String: Any]
        if prepareOwner, let prepare = desktop?.prepareSnapshot {
            live = try prepare(session)
        } else {
            live = self.live(session)
        }
        let flags = capabilities(live)
        let rows = ZCodeConversation.rows(state.turns)
        for (client, thread) in selected where thread == session { captureMarkdown(rows, client: client) }
        let reportedStatus = live["status"] as? String ?? state.summary["status"] as? String ?? "idle"
        let status = reportedStatus == "running" ? "active" : reportedStatus
        var value: [String: Any] = [
            "threadId": session, "title": state.summary["title"] ?? "ZCode", "cwd": state.summary["cwd"] ?? "",
            "messages": rows, "approvals": [], "queuedFollowUps": [], "queuedMessages": [],
            "loadedTurns": state.turns.count, "hasOlder": state.hasOlder, "status": status,
            "activeTurnId": live["activeTurnId"] ?? (status == "active" ? state.turns.last?.userID ?? "" : ""),
            "composer": live["composer"]
                ?? ZCodeConversation.composer(state.summary, latest: state.turns.last?.latest ?? [:]),
            "capabilities": flags, "canSend": flags["send"] == true && live["canSend"] as? Bool == true,
            "revision": revisions[session] ?? 0,
        ]
        for key in ["models", "permissionModes", "efforts", "executionModes", "executionModePermissionCoupled"] {
            if let current = live[key] { value[key] = current }
        }
        if let epoch = live["nativeOwnerEpoch"] as? String,
            AgentSessionProfile.bounded(epoch, maximum: 1024)
        {
            value["nativeOwnerEpoch"] = epoch
        }
        if value["canSend"] as? Bool != true {
            value["readOnlyReason"] =
                live["readOnlyReason"]
                ?? L10n.text("provider.native_zcode_history_is_available_the_original_desktop_session_on_the_mac_mu")
        }
        value = ConversationReply.versioned(value)
        return value
    }
    private func handle(_ request: [String: Any], client: String) throws -> [String: Any] {
        let op = request["op"] as? String ?? ""
        if ["receiptCheck", "newReceiptCheck", "settingsReceiptCheck", "interruptReceiptCheck"].contains(op) {
            let operation = request["operation"] as? String ?? request["id"] as? String ?? ""
            let session = request["threadId"] as? String ?? ""
            let kind =
                request["originalOperation"] as? String
                ?? [
                    "newReceiptCheck": "new", "settingsReceiptCheck": "settings", "interruptReceiptCheck": "interrupt",
                ][op] ?? "send"
            let cached = operationReceipts.lookup(client: client, operation: operation, thread: session, kind: kind)
            guard cached["unknown"] as? Bool == true, cached["retired"] as? Bool != true,
                ["send", "new"].contains(kind), let desktop
            else { return cached }
            var lookup = request
            lookup["op"] = "receiptCheck"
            var observed = try desktop.execute(lookup, session, request["cwd"] as? String ?? "", client)
            if observed["ok"] == nil { observed["ok"] = true }
            return operationReceipts.reconcile(
                client: client, operation: operation, thread: session, kind: kind, result: observed)
        }
        let version = (request["viewVersion"] as? NSNumber)?.int64Value ?? -1
        if op == "list" || op == "projects" {
            let stamp = try store.version()
            let key = CodexConversation.fingerprint(request.filter { !["id", "sentAt"].contains($0.key) })
            if let saved = listCache[key], saved.version == stamp {
                var value = saved.value
                value["capabilities"] = capabilities(live(""))
                return value
            }
            let search = String((request["search"] as? String ?? "").prefix(200))
            let offset = request["offset"] as? Int ?? 0
            var value =
                op == "list"
                ? try store.list(
                    search: search, offset: offset, cwd: request["cwd"] as? String,
                    limit: request["limit"] as? Int ?? 20)
                : try store.projects(search: search, offset: offset, limit: request["limit"] as? Int ?? 100)
            if listCache.count >= 32 { listCache.removeAll() }
            listCache[key] = (stamp, value)
            value["capabilities"] = capabilities(live(""))
            return value
        }
        if op == "close" {
            if let target = request["threadId"] as? String, selected[client] != target {
                throw CLIError(L10n.text("session.the_session_view_changed"))
            }
            guard version >= 0, version >= (viewVersions[client] ?? -1) else {
                throw CLIError(L10n.text("session.the_session_view_changed"))
            }
            viewVersions[client] = version
            unsubscribe(client)
            return [:]
        }
        if op == "new" || op == "newOptions" {
            guard let desktop, op == "newOptions" || capabilities(live(""))["new"] == true else {
                throw CLIError(L10n.text("provider.create_the_session_in_zcode_on_the_mac"))
            }
            if op == "newOptions" || request["draftId"] != nil {
                _ = try SessionCreationDraft(request, project: request["cwd"] as? String ?? "", provider: "zcode")
            }
            return try desktop.execute(request, "", request["cwd"] as? String ?? "", client)
        }
        guard let session = request["threadId"] as? String, !session.isEmpty, session.utf8.count <= 200 else {
            throw CLIError(L10n.text("provider.invalid_zcode_session"))
        }
        if op == "open" {
            guard version >= 0, version >= (viewVersions[client] ?? -1),
                version != viewVersions[client] || selected[client] == session
            else { throw CLIError(L10n.text("session.the_session_view_changed")) }
            _ = try state(session)
            if selected[client] != session {
                unsubscribe(client)
                selected[client] = session
            }
            viewVersions[client] = version
            updateIntervals[client] = min(1.5, max(0.25, Double(request["updatesIntervalMs"] as? Int ?? 250) / 1000))
            watch()
            var value = try page(session, prepareOwner: request["verifyNativeOwner"] as? Bool == true)
            value["viewVersion"] = version
            emitted[client] = value
            return ConversationReply.conditional(value, known: request["knownVersion"] as? String)
        }
        guard selected[client] == session, viewVersions[client] == version else {
            throw CLIError(L10n.text("session.the_session_is_not_ready_reopen_it"))
        }
        switch op {
        case "readMarkdownFile":
            let current = try state(session)
            throw try markdownFiles.request(
                request, cwd: current.summary["cwd"] as? String ?? "", device: client, thread: session,
                referencedPaths: (markdownReferences[client] ?? []).union(
                    SessionMarkdownFiles.referencedPaths(in: ZCodeConversation.rows(current.turns))))
        case "browseFiles":
            throw SessionProjectFiles.browseRequest(
                request["folder"] as? String ?? "", cwd: try state(session).summary["cwd"] as? String ?? "",
                thread: session)
        case _ where SessionProjectFiles.operations.contains(op):
            let current = try state(session)
            let projectCwd = current.summary["cwd"] as? String ?? ""
            if op == "openFile" {
                return try SessionProjectFiles.reply(
                    op, request, cwd: projectCwd, rows: { [] }, reader: markdownFiles, device: client, thread: session)
            }
            let rows = op == "fileChanges" ? ZCodeConversation.rows(Array(current.turns.suffix(2))) : []
            throw try SessionProjectFiles.request(
                op, request, cwd: projectCwd, rows: rows, reader: markdownFiles, device: client, thread: session)
        case "sync":
            var value = try page(session, prepareOwner: request["verifyNativeOwner"] as? Bool == true)
            value["viewVersion"] = version
            emitted[client] = value
            return ConversationReply.conditional(value, known: request["knownVersion"] as? String)
        case "history":
            guard let before = request["before"] as? String else {
                throw CLIError(L10n.text("session.update_the_phone_app_before_loading_earlier_messages"))
            }
            let window = try store.window(session, before: before, count: ConversationReply.olderTurns)
            let rows = ZCodeConversation.rows(window.turns)
            captureMarkdown(rows, client: client)
            return ["threadId": session, "messages": rows, "hasOlder": window.hasOlder]
        case "parts":
            let id = request["messageId"] as? String ?? ""
            guard id.hasPrefix("reply-") else {
                throw CLIError(L10n.text("provider.the_message_changed_refresh_to_continue"))
            }
            let turn = try store.turn(session, userID: String(id.dropFirst(6)))
            let start = max(0, min(request["offset"] as? Int ?? 0, turn.partCount))
            let end = min(start + 8, max(start, min(request["before"] as? Int ?? turn.partCount, turn.partCount)))
            let parts = try store.sequence(session, start: turn.start, end: turn.end, offset: start, limit: end - start)
            let sequence = ZCodeConversation.sequence(parts, offset: start)
            captureMarkdown([["text": "", "sequence": sequence]], client: client)
            return [
                "threadId": session, "messageId": id, "parts": sequence, "partCount": turn.partCount, "start": start,
                "nextOffset": end < turn.partCount ? end : -1,
            ]
        case "message": return try message(request, session: session, client: client)
        case "image": return try image(request, session: session, client: client)
        case "composerOptions":
            let state = try state(session)
            var value = live(session)
            if let desktop {
                value = try desktop.execute(request, session, state.summary["cwd"] as? String ?? "", client)
            }
            return [
                "threadId": session, "models": value["models"] ?? [], "permissionModes": value["permissionModes"] ?? [],
                "efforts": value["efforts"] ?? [],
                "executionModes": value["executionModes"] ?? [],
                "executionModePermissionCoupled": value["executionModePermissionCoupled"] ?? false,
                "composer": value["composer"]
                    ?? ZCodeConversation.composer(state.summary, latest: state.turns.last?.latest ?? [:]),
                "capabilities": capabilities(value),
            ]
        case "contextUsage":
            throw CLIError(
                L10n.text("provider.zcode_does_not_yet_provide_verifiable_context_capacity_view_it_on_the_mac"))
        case "send", "settings", "interrupt":
            let info = live(session)
            let flag = op == "settings" ? "settings" : op
            guard let desktop, capabilities(info)[flag] == true else {
                throw CLIError(
                    L10n.text("provider.this_operation_has_not_been_verified_in_the_original_zcode_desktop_session_h"))
            }
            if op == "send" {
                let text = (request["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.utf8.count <= 32_000, (request["attachments"] as? [String] ?? []).isEmpty
                else { throw CLIError(L10n.text("provider.zcode_currently_supports_text_replies_up_to_32_kb")) }
                guard info["canSend"] as? Bool == true else {
                    throw CLIError(
                        L10n.text("provider.zcode_is_working_or_the_session_is_not_yet_verified_wait_until_it_is_ready")
                    )
                }
            }
            if op == "interrupt" {
                guard request["expectedTurnId"] as? String == info["activeTurnId"] as? String else {
                    throw CLIError(L10n.text("session.the_running_task_changed_the_new_task_was_not_stopped"))
                }
            }
            let result = try scopedDesktopResult(
                desktop.execute(request, session, try state(session).summary["cwd"] as? String ?? "", client),
                session: session)
            schedule()
            return result
        default: throw CLIError(L10n.text("provider.zcode_does_not_support_this_phone_operation"))
        }
    }
    private func scopedDesktopResult(_ result: [String: Any], session: String) throws -> [String: Any] {
        // Native settings/stop replies omit a session field; bind them to the verified invocation.
        // If the adapter does supply an identity, never overwrite a conflicting one with the requested ID.
        for key in ["threadId", "sessionId"] where result[key] != nil {
            guard result[key] as? String == session else {
                throw UnconfirmedDesktopMutation(reason: L10n.text("core.invalid_receipt"))
            }
        }
        var reply = result
        reply["threadId"] = session
        return reply
    }
    private func message(_ request: [String: Any], session: String, client: String) throws -> [String: Any] {
        let id = request["messageId"] as? String ?? ""
        let text: String
        var detail: [String: Any]?
        if let native = try store.part(session, id: id) {
            let part = ZCodeConversation.part(native)
            text = part.text
            captureMarkdown([["text": "", "parts": [part.value]]], client: client)
            detail = ConversationReply.partDetails([["id": "reply", "parts": [part.value]]], id: id)
        } else if id.hasPrefix("reply-") {
            text = try store.replyText(session, turn: store.turn(session, userID: String(id.dropFirst(6))))
            captureMarkdown([["text": text]], client: client)
        } else {
            let parts = try store.messageParts(session, id: id)
            guard !parts.isEmpty else { throw CLIError(L10n.text("provider.the_message_changed_refresh_to_continue")) }
            text = ZCodeConversation.userText(parts)
            captureMarkdown([["text": text]], client: client)
        }
        let offset = max(0, min(request["offset"] as? Int ?? 0, text.count))
        let chunk = String(text.dropFirst(offset).prefix(12_000))
        var value: [String: Any] = [
            "threadId": session, "messageId": id, "text": chunk,
            "nextOffset": offset + chunk.count < text.count ? offset + chunk.count : -1,
        ]
        if offset == 0, request["withPart"] as? Bool == true, let detail { value["part"] = detail }
        return value
    }
    private func image(_ request: [String: Any], session: String, client: String) throws -> [String: Any] {
        let id = request["imageId"] as? String ?? ""
        let components = id.components(separatedBy: "#")
        guard components.count == 2, let offset = Int(components[1]), offset >= 0 else {
            throw CLIError(L10n.text("provider.invalid_image"))
        }
        var sources: [String]
        if let native = try store.part(session, id: components[0]) {
            sources = ZCodeConversation.imageSources(native)
        } else {
            sources = try store.messageParts(session, id: components[0]).flatMap(ZCodeConversation.imageSources)
        }
        guard offset < sources.count else {
            throw CLIError(L10n.text("provider.the_image_changed_refresh_to_continue"))
        }
        let source = sources[offset]
        throw ConversationImageRequest(
            thread: session, id: id, source: source,
            cwd: try store.summary(session)["cwd"] as? String ?? "",
            maxPixel: request["size"] as? String == "large"
                ? (request["binaryVersion"] as? Int == 1 ? 2048 : 1280) : 480,
            device: client, binary: request["binaryVersion"] as? Int == 1,
            zcodeArtifactRoot: source.hasPrefix("zcode-artifact://") ? store.artifactRoot : nil)
    }
    private func unsubscribe(_ client: String) {
        markdownFiles.remove(device: client)
        markdownReferences.removeValue(forKey: client)
        selected.removeValue(forKey: client)
        updateIntervals.removeValue(forKey: client)
        emitted.removeValue(forKey: client)
        if selected.isEmpty {
            for watcher in watchers.values { watcher.cancel() }
            watchers.removeAll()
        }
    }
    private func captureMarkdown(_ rows: [[String: Any]], client: String) {
        markdownReferences[client, default: []].formUnion(SessionMarkdownFiles.referencedPaths(in: rows))
    }
    private func watch() {
        let paths =
            [store.path, store.path + "-wal", URL(fileURLWithPath: store.path).deletingLastPathComponent().path]
            + (store.indexPath.map { [$0, $0 + "-wal", URL(fileURLWithPath: $0).deletingLastPathComponent().path] }
                ?? [])
        for path in paths where watchers[path] == nil {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let flags = self.watchers[path]?.data ?? []
                if flags.contains(.delete) || flags.contains(.rename) {
                    self.watchers.removeValue(forKey: path)?.cancel()
                }
                self.schedule()
            }
            source.setCancelHandler { Darwin.close(fd) }
            watchers[path] = source
            source.resume()
        }
    }
    private func schedule() {
        guard !scheduled, !selected.isEmpty else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + (updateIntervals.values.min() ?? 0.25)) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard !self.selected.isEmpty else { return }
            self.watch()
            for session in Set(self.selected.values) { self.revisions[session, default: 0] += 1 }
            for (client, session) in self.selected {
                do {
                    var value = try self.page(session)
                    value["viewVersion"] = self.viewVersions[client]
                    if self.emitted[client]?["cacheVersion"] as? String == value["cacheVersion"] as? String,
                        self.emitted[client]?["canSend"] as? Bool == value["canSend"] as? Bool
                    {
                        continue
                    }
                    let full = value
                    if let old = self.emitted[client] {
                        let previous = old["messages"] as? [[String: Any]] ?? []
                        let rows = value["messages"] as? [[String: Any]] ?? []
                        value["messages"] = rows.filter { row in
                            !previous.contains {
                                $0["id"] as? String == row["id"] as? String
                                    && NSDictionary(dictionary: $0).isEqual(NSDictionary(dictionary: row))
                            }
                        }
                        value["order"] = rows.compactMap { $0["id"] as? String }
                        value["event"] = "delta"
                        value["baseRevision"] = old["revision"] ?? 0
                    } else {
                        value["event"] = "snapshot"
                    }
                    self.emitted[client] = full
                    value["provider"] = "zcode"
                    if let data = try? JSONSerialization.data(withJSONObject: value) { self.event?(client, data) }
                } catch {
                    if let data = try? JSONSerialization.data(withJSONObject: [
                        "event": "unavailable", "provider": "zcode", "error": String(describing: error),
                    ]) {
                        self.event?(client, data)
                    }
                }
            }
        }
    }
}
