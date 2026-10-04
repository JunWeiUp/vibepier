import AppKit
import CoreGraphics
import Foundation

final class CodexBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vibepier.codex-bridge")
    private let creationQueue = DispatchQueue(label: "vibepier.codex-creation")
    private let ipc = CodexIPC()
    private let store = CodexThreadStore()
    private let composer = CodexComposer()
    private let followUps = CodexFollowUps()
    private let attachments = try? CodexAttachments()
    private let markdownFiles = SessionMarkdownFiles()
    private var selected: [String: String] = [:]
    private var viewVersions: [String: Int64] = [:]
    private var states: [String: [String: Any]] = [:]
    private var owners: [String: String] = [:]
    private var revisions: [String: Int] = [:]
    private var scheduled = Set<String>()
    private var emittedPages: [String: [String: Any]] = [:]
    private var updateIntervals: [String: TimeInterval] = [:]
    private var knownVersions: [String: String] = [:]
    private var creationInFlight = false
    private let creationReceipts = ProviderOperationReceipts()

    private enum CreationReply: Sendable {
        case success(CodexCreationReceipt)
        case configured(Data)
        case failure(String, uncertain: Bool)
        var value: [String: Any] {
            switch self {
            case .success(let receipt): return receipt.reply
            case .configured(let data):
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [
                    "ok": false, "unknown": true,
                ]
            case .failure(let message, let uncertain):
                var value: [String: Any] = ["ok": false, "error": message, "provider": "codex"]
                if uncertain { value["unknown"] = true }
                return value
            }
        }
    }
    var event: (@Sendable (String, Data) -> Void)?
    init() {
        ipc.broadcast = { [weak self] data in self?.queue.async { [weak self] in self?.receive(data) } }
        ipc.disconnected = { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.owners.removeAll()
                self.states.removeAll()
                self.revisions.removeAll()
                for client in self.selected.keys {
                    self.emit(
                        client,
                        [
                            "event": "unavailable",
                            "error": L10n.text("session.codex_disconnected_open_codex_on_the_mac_and_retry"),
                        ])
                }
            }
        }
    }
    func stop(_ client: String) { queue.async { self.unsubscribe(client) } }
    func stopAll() {
        queue.async {
            for client in Array(self.selected.keys) { self.unsubscribe(client) }
            self.ipc.close()
        }
    }
    private let requestAdmission = SessionRequestAdmission()

    func perform(_ data: Data, client: String, completion: @escaping @Sendable (Data) -> Void) {
        if let cached = creationReceipts.cachedReply(
            data, client: client, provider: "codex", operations: ["newReceiptCheck"])
        {
            completion(cached)
            return
        }
        requestAdmission.submit(on: queue) {
            completion(SessionRequestAdmission.rejection(provider: "codex"))
        } work: { [self] in
            var result: [String: Any]
            var creationTicket: ProviderOperationReceipts.Ticket?
            do {
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CLIError(L10n.text("core.invalid_request"))
                }
                if request["op"] as? String == "new" {
                    switch try self.creationReceipts.begin(request, client: client) {
                    case .cached(let cached):
                        completion((try? JSONSerialization.data(withJSONObject: cached)) ?? Data())
                        return
                    case .fresh(let ticket): creationTicket = ticket
                    }
                    let ticket = creationTicket!
                    try self.create(request, ticket: ticket) { value in
                        let value = self.creationReceipts.finish(ticket, result: value)
                        completion((try? JSONSerialization.data(withJSONObject: value)) ?? Data())
                    }
                    return
                }
                result = try self.handle(request, client: client)
                if result["ok"] == nil { result["ok"] = true }
            } catch let file as SessionFileRequest {
                SessionFileLoader.shared.perform(file, provider: "codex", completion: completion)
                return
            } catch let image as ConversationImageRequest {
                ConversationImageLoader.shared.perform(image, provider: "codex", completion: completion)
                return
            } catch { result = ProviderFailure.reply(error, provider: "codex") }
            if let creationTicket { result = self.creationReceipts.finish(creationTicket, result: result) }
            completion((try? JSONSerialization.data(withJSONObject: result)) ?? Data())
        }
    }
    // Checked against packaged protocol versions and the real desktop subscription/open path.
    private static let supportedBuilds: Set<String> = ["11645", "12404", "12553", "12947"]
    // The new-composer labels, project catalog and native first-message metadata were inspected for this build.
    private static let creationBuilds: Set<String> = ["12553"]
    // thread/start schema plus desktop v2 start-turn / v11 snapshot contracts.
    // This path does not use the legacy AX new-composer flow.
    static func supportsConfiguredCreation(build: String?) -> Bool {
        guard let build else { return false }
        return ["12553", "12947"].contains(build)
    }

    private func requireConfiguredCreation() throws {
        guard compatible() else { throw compatibilityError() }
        guard Self.supportsConfiguredCreation(build: desktopBuild()) else {
            throw CLIError(L10n.text("session.codex_creation_build_unverified"))
        }
    }
    private func desktopBuild() -> String? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first?
            .bundleURL
        guard let url = running ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
            let bundle = Bundle(url: url)
        else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
    private func compatible() -> Bool { desktopBuild().map(Self.supportedBuilds.contains) ?? false }
    private func compatibilityError() -> CLIError {
        CLIError(
            L10n.text(
                "session.codex_desktop_build_0_is_not_supported_yet_update_vibepier_and_retry",
                desktopBuild() ?? L10n.text("session.unknown")))
    }
    /// The link only prefills. A verified native Send element is invoked once,
    /// then a fresh thread and its exact first native user record provide the receipt.
    /// SessionRemote's durable, device-scoped journal owns retries, including unknown results.
    private func create(
        _ request: [String: Any], ticket: ProviderOperationReceipts.Ticket,
        reply: @escaping @Sendable ([String: Any]) -> Void
    ) throws {
        guard let operation = request["id"] as? String, UUID(uuidString: operation) != nil else {
            throw CLIError(L10n.text("core.invalid_request"))
        }
        if ["model", "effort", "mode", "draftId", "attachments"].contains(where: { request[$0] != nil }) {
            try createConfigured(request, ticket: ticket, reply: reply)
            return
        }
        guard !creationInFlight else { throw CLIError(L10n.text("session.codex_creation_busy")) }
        let cwd = request["cwd"] as? String ?? ""
        let text = (request["text"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 32_000 else {
            throw CLIError(L10n.text("session.the_first_message_must_not_be_empty_or_exceed_32_kb"))
        }
        guard try store.isProject(cwd), FileManager.default.fileExists(atPath: cwd) else {
            throw CLIError(L10n.text("session.the_project_directory_no_longer_exists_0", cwd))
        }
        guard compatible() else { throw compatibilityError() }
        guard desktopBuild().map(Self.creationBuilds.contains) ?? false else {
            throw CLIError(L10n.text("session.codex_creation_build_unverified"))
        }
        // Resolve before unlocking/opening. Duplicate names and multi-root projects require native clarification.
        _ = try store.creationProject(cwd: cwd)
        creationInFlight = true
        creationQueue.async { [self] in
            let outcome: CreationReply
            do {
                let receipt = try DesktopInteractions.perform {
                    guard compatible() else { throw compatibilityError() }
                    guard desktopBuild().map(Self.creationBuilds.contains) ?? false else {
                        throw CLIError(L10n.text("session.codex_creation_build_unverified"))
                    }
                    let project = try store.creationProject(cwd: cwd)
                    let url = try CodexCreationFlow.url(project: project, text: text)
                    return try ScreenLock.unlocked {
                        let snapshot = try store.creationSnapshot(cwd: cwd)
                        let proofBytes = snapshot.existingIDs.reduce(text.utf8.count + cwd.utf8.count + 512) {
                            $0 + $1.utf8.count + 64
                        }
                        try creationReceipts.observe(ticket, bytes: proofBytes) { [weak self] in
                            try self?.store.created(snapshot: snapshot, text: text)?.reply
                        }
                        return try CodexCreationFlow.run(
                            open: {
                                guard DispatchQueue.main.sync(execute: { NSWorkspace.shared.open(url) }) else {
                                    throw CLIError(L10n.text("session.could_not_open_codex"))
                                }
                            },
                            prepare: {
                                guard
                                    let prepared = DispatchQueue.main.sync(execute: {
                                        CodexNewComposer.prepare(text: text, projectName: project.name)
                                    })
                                else { return nil }
                                return {
                                    guard try self.store.creationProject(cwd: cwd) == project else {
                                        throw CLIError(L10n.text("session.codex_creation_project_unverified"))
                                    }
                                    try DispatchQueue.main.sync { try prepared.submit() }
                                    self.creationReceipts.arm(ticket)
                                }
                            },
                            receipt: {
                                try store.created(snapshot: snapshot, text: text)
                            }, wait: { Thread.sleep(forTimeInterval: 0.4) })
                    }
                }
                outcome = .success(receipt)
            } catch {
                outcome = .failure(String(describing: error), uncertain: error is UnconfirmedDesktopMutation)
            }
            queue.async { [self] in
                creationInFlight = false
                reply(outcome.value)
            }
        }
    }

    private func createConfigured(
        _ request: [String: Any], ticket: ProviderOperationReceipts.Ticket,
        reply: @escaping @Sendable ([String: Any]) -> Void
    ) throws {
        guard !creationInFlight else { throw CLIError(L10n.text("session.codex_creation_busy")) }
        try requireConfiguredCreation()
        guard ["model", "effort", "mode"].allSatisfy({ request[$0] == nil || request[$0] is String }),
            request["attachments"] == nil || request["attachments"] is [String]
        else { throw CLIError(L10n.text("core.invalid_request")) }
        let cwd = request["cwd"] as? String ?? ""
        guard try store.isProject(cwd) else { throw CLIError(L10n.text("session.codex_creation_project_unverified")) }
        let project = try store.creationProject(cwd: cwd)
        let draft = try SessionCreationDraft(request, project: project.cwd, provider: "codex")
        let settings = try composer.settings(request, state: [:])
        let text = (request["text"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = request["attachments"] as? [String] ?? []
        guard !text.isEmpty || !ids.isEmpty, text.utf8.count <= 32_000 else {
            throw CLIError(L10n.text("session.the_reply_must_not_be_empty_or_exceed_32_kb"))
        }
        guard let attachments else { throw CLIError(L10n.text("session.attachment_storage_is_unavailable")) }
        let selected = try attachments.selected(ids, device: ticket.key.client, thread: draft.scope)
        let input = CodexConfiguredCreation.Input(
            project: project, settings: try JSONSerialization.data(withJSONObject: settings),
            attachments: try JSONSerialization.data(withJSONObject: ["input": selected.input, "files": selected.files]),
            text: text, client: ticket.key.client, operation: ticket.key.operation)
        let observation = CodexConfiguredCreation.Observation()
        try creationReceipts.observe(ticket, bytes: cwd.utf8.count + 2048) { try observation.nativeReceipt() }
        creationInFlight = true
        creationQueue.async { [self] in
            let outcome: CreationReply
            do {
                guard DesktopInteractions.lock.lock(before: Date().addingTimeInterval(2)) else {
                    throw CLIError(L10n.text("session.codex_creation_busy"))
                }
                defer { DesktopInteractions.lock.unlock() }
                outcome = .configured(
                    try ScreenLock.unlocked {
                        try CodexConfiguredCreation.perform(input, observation: observation) {
                            creationReceipts.arm(ticket)
                        }
                    })
            } catch {
                outcome = .failure(String(describing: error), uncertain: error is UnconfirmedDesktopMutation)
            }
            queue.async { [self] in
                creationInFlight = false
                reply(outcome.value)
            }
        }
    }
    private func handle(_ request: [String: Any], client: String) throws -> [String: Any] {
        let op = request["op"] as? String ?? ""
        if op == "newReceiptCheck" {
            return creationReceipts.lookup(
                client: client, operation: request["operation"] as? String ?? "",
                thread: request["threadId"] as? String ?? "", kind: "new")
        }
        if op == "newOptions" || SessionCreationDraft.attachmentOperations.contains(op) {
            let cwd = request["cwd"] as? String ?? ""
            guard try store.isProject(cwd) else {
                throw CLIError(L10n.text("session.codex_creation_project_unverified"))
            }
            guard let attachments else { throw CLIError(L10n.text("session.attachment_storage_is_unavailable")) }
            let draft = try SessionCreationDraft(request, project: cwd, provider: "codex")
            if op == "newOptions" {
                try requireConfiguredCreation()
                let models = try composer.models()
                let first = models.first ?? [:]
                return [
                    "creationVersion": 1, "draftId": draft.id, "models": models,
                    "composer": [
                        "model": first["id"] as? String ?? "", "effort": first["defaultEffort"] as? String ?? "medium",
                        "mode": "auto",
                    ],
                    "capabilities": ["attachments": true],
                    "permissionModes": [
                        ["id": "auto", "name": "Default permissions"],
                        ["id": "guardian-approvals", "name": "Approve for me"],
                        ["id": "full-access", "name": "Full access", "requiresConfirmation": true],
                    ],
                ]
            }
            return try draft.attachment(request, storage: attachments, device: client)
        }
        let search = String((request["search"] as? String ?? "").prefix(200))
        if op == "list" || op == "projects" {
            var value =
                op == "list"
                ? try store.list(
                    search: search, offset: request["offset"] as? Int ?? 0, cwd: request["cwd"] as? String,
                    limit: request["limit"] as? Int ?? 20)
                : try store.projects(
                    search: search, offset: request["offset"] as? Int ?? 0, limit: request["limit"] as? Int ?? 100)
            value["capabilities"] = ["markdownFiles": true, "projectFiles": true, "videoFiles": true]
            return value
        }
        let viewVersion = (request["viewVersion"] as? NSNumber)?.int64Value ?? -1
        if op == "close" {
            guard viewVersion >= 0, viewVersion >= (viewVersions[client] ?? -1) else {
                throw CLIError(L10n.text("session.the_session_view_changed"))
            }
            viewVersions[client] = viewVersion
            unsubscribe(client)
            return [:]
        }
        guard let thread = request["threadId"] as? String, UUID(uuidString: thread) != nil else {
            throw CLIError(L10n.text("session.invalid_session"))
        }
        if op == "attachmentRemove" {
            guard let attachments else { throw CLIError(L10n.text("session.attachment_storage_is_unavailable")) }
            try attachments.remove(request["attachmentId"] as? String ?? "", device: client, thread: thread)
            return [:]
        }
        if op == "open" {
            guard viewVersion >= 0, viewVersion >= (viewVersions[client] ?? -1) else {
                throw CLIError(L10n.text("session.the_session_view_changed"))
            }
            let interval = min(1.5, max(0.25, Double(request["updatesIntervalMs"] as? Int ?? 250) / 1000))
            updateIntervals[client] = interval
            let known = request["knownVersion"] as? String ?? ""
            knownVersions[client] = known
            if viewVersions[client] == viewVersion {
                guard selected[client] == thread else {
                    throw CLIError(L10n.text("session.the_session_view_is_closed"))
                }
                if let state = states[thread] {
                    var page = conversationPage(state, thread: thread)
                    page["viewVersion"] = viewVersion
                    page["revision"] = revisions[thread] ?? 0
                    page["canSend"] = compatible()
                    emittedPages[client] = page
                    return ConversationReply.conditional(page, known: request["knownVersion"] as? String)
                }
                return ["threadId": thread, "opening": true]
            }
            viewVersions[client] = viewVersion
            guard compatible() else { throw compatibilityError() }
            if selected[client] == thread, let state = states[thread], let owner = owners[thread],
                (try? ipc.request(
                    "thread-owner-discovery", ["hostId": "local", "conversationId": thread], version: 1, timeout: 2)[
                        "handledByClientId"] as? String) == owner
            {
                var page = conversationPage(state, thread: thread)
                page["viewVersion"] = viewVersion
                page["revision"] = revisions[thread] ?? 0
                page["canSend"] = true
                emittedPages[client] = page
                return ConversationReply.conditional(page, known: request["knownVersion"] as? String)
            }
            unsubscribe(client, closeIPC: false)
            selected[client] = thread
            updateIntervals[client] = interval
            knownVersions[client] = known
            try ipc.connect()
            DispatchQueue.main.async {
                if let url = URL(string: "codex://threads/\(thread)") { NSWorkspace.shared.open(url) }
            }
            resolveOwner(thread, client: client, viewVersion: viewVersion, attempts: 5)
            return ["threadId": thread, "opening": true]
        }
        guard
            ["receiptCheck", "settingsReceiptCheck", "interruptReceiptCheck", "queueReceiptCheck"].contains(op)
                || viewVersions[client] == viewVersion, selected[client] == thread, let state = states[thread],
            let owner = owners[thread]
        else { throw CLIError(L10n.text("session.the_session_is_not_ready_reopen_it")) }
        if op == "readMarkdownFile" {
            // Resolve permissions from prose and structured file edits without
            // materializing unrelated command/tool bodies for a document tap.
            let turns = CodexConversation.turns(state).map { turn in
                var turn = turn
                turn["items"] = (turn["items"] as? [[String: Any]] ?? []).filter {
                    ["userMessage", "steeringUserMessage", "agentMessage", "reasoning", "plan", "fileChange"].contains(
                        $0["type"] as? String ?? "")
                }
                return turn
            }
            let references = SessionMarkdownFiles.referencedPaths(in: turns.flatMap(CodexConversation.messages))
            throw try markdownFiles.request(
                request, cwd: state["cwd"] as? String ?? "", device: client, thread: thread, referencedPaths: references
            )
        }
        if op == "browseFiles" {
            throw SessionProjectFiles.browseRequest(
                request["folder"] as? String ?? "", cwd: state["cwd"] as? String ?? "", thread: thread)
        }
        if SessionProjectFiles.operations.contains(op) {
            let cwd = state["cwd"] as? String ?? ""
            if op == "openFile" {
                return try SessionProjectFiles.reply(
                    op, request, cwd: cwd, rows: { [] }, reader: markdownFiles, device: client, thread: thread)
            }
            let rows =
                op == "fileChanges" ? CodexConversation.turns(state).suffix(2).flatMap(CodexConversation.messages) : []
            throw try SessionProjectFiles.request(
                op, request, cwd: cwd, rows: rows, reader: markdownFiles, device: client, thread: thread)
        }
        if op == "composerOptions" {
            return ["threadId": thread, "models": try composer.models(), "composer": CodexConversation.composer(state)]
        }
        if op == "contextUsage" {
            guard var usage = CodexConversation.contextUsage(state) else {
                throw CLIError(
                    L10n.text("session.the_desktop_has_not_provided_context_usage_yet_check_after_the_first"))
            }
            usage["threadId"] = thread
            usage["composer"] = CodexConversation.composer(state)
            return usage
        }
        if op == "settingsReceiptCheck" {
            let selection = CodexComposer.selection(state)
            let keys = ["model", "effort", "mode"].filter { request[$0] != nil }
            return [
                "accepted": !keys.isEmpty && keys.allSatisfy { request[$0] as? String == selection[$0] as? String },
                "threadId": thread,
            ]
        }
        if op == "appshotApps" { return ["apps": CodexAppshot.apps()] }
        if op == "appshot" {
            guard let attachments, let bundle = request["bundleID"] as? String,
                let id = request["attachmentId"] as? String
            else { throw CLIError(L10n.text("session.choose_an_application")) }
            let bytes = try CodexAppshot.capture(bundleID: bundle)
            _ = try attachments.start(
                ["attachmentId": id, "name": bundle + ".jpg", "mime": "image/jpeg", "size": bytes.count],
                device: client, thread: thread)
            for offset in stride(from: 0, to: bytes.count, by: 128 * 1024) {
                _ = try attachments.chunk(
                    [
                        "attachmentId": id, "offset": offset,
                        "data": bytes.subdata(in: offset..<min(offset + 128 * 1024, bytes.count)).base64EncodedString(),
                    ], device: client, thread: thread)
            }
            return try attachments.complete(
                ["attachmentId": id, "sha256": CodexConversation.dataHash(bytes)], device: client, thread: thread)
        }
        if op.hasPrefix("attachment") {
            guard let attachments else {
                throw CLIError(L10n.text("session.attachment_storage_is_unavailable_check_on_the_mac"))
            }
            switch op {
            case "attachmentPreview":
                return try attachments.preview(request["attachmentId"] as? String ?? "", device: client, thread: thread)
            case "attachmentStart": return try attachments.start(request, device: client, thread: thread)
            case "attachmentChunk": return try attachments.chunk(request, device: client, thread: thread)
            case "attachmentComplete": return try attachments.complete(request, device: client, thread: thread)
            case "attachmentRemove":
                try attachments.remove(request["attachmentId"] as? String ?? "", device: client, thread: thread)
                return [:]
            case "attachmentReference":
                return try attachments.reference(
                    request["path"] as? String ?? "", cwd: state["cwd"] as? String ?? "",
                    id: request["attachmentId"] as? String ?? "", device: client, thread: thread)
            default: throw CLIError(L10n.text("session.unsupported_attachment_operation"))
            }
        }
        if op == "interruptReceiptCheck" {
            let expected = request["expectedTurnId"] as? String ?? ""
            let old = CodexConversation.turns(state).first { $0["turnId"] as? String == expected }
            return ["accepted": old != nil && old?["status"] as? String != "inProgress", "threadId": thread]
        }
        if op == "sync" {
            var page = conversationPage(state, thread: thread)
            page["revision"] = revisions[thread] ?? 0
            page["canSend"] = compatible()
            page["viewVersion"] = viewVersions[client]
            emittedPages[client] = page
            return ConversationReply.conditional(page, known: request["knownVersion"] as? String)
        }
        if op == "receiptCheck" {
            let identity = try CodexMessageIdentity(
                client: client, thread: thread, operation: request["operation"] as? String ?? "")
            let queued = try followUps.messages(thread)
            let found = identity.delivered(in: state) || identity.queued(in: queued)
            return ["accepted": found, "threadId": thread]
        }
        if op == "history" {
            guard let before = request["before"] as? String else {
                throw CLIError(L10n.text("session.update_the_phone_app_before_loading_earlier_messages"))
            }
            func oldest(_ state: [String: Any]) -> Bool {
                (state["turnsPagination"] as? [String: Any])?["hasLoadedOldest"] as? Bool == true
            }
            var current = state
            var window = ConversationReply.older(
                CodexConversation.turns(current).map(CodexConversation.messages), before: before)
            if (window?.rows.isEmpty ?? true) && !oldest(current) {
                _ = try ipc.request(
                    "thread-follower-load-complete-history", ["conversationId": thread], version: 1, target: owner,
                    timeout: 30)
                if let snapshot = ipc.latestSnapshot(thread) { receive(snapshot) }
                current = states[thread] ?? current
                window = ConversationReply.older(
                    CodexConversation.turns(current).map(CodexConversation.messages), before: before)
            }
            guard let window else { throw CLIError(L10n.text("session.the_session_changed_reopen_it")) }
            return ["threadId": thread, "messages": window.rows, "hasOlder": window.start > 0 || !oldest(current)]
        }
        if op == "approvalDetails" {
            guard
                let item = CodexConversation.approvals(state).first(where: {
                    $0["fingerprint"] as? String == request["fingerprint"] as? String
                })
            else { throw CLIError(L10n.text("session.the_approval_changed_or_expired_refresh_it")) }
            return ["threadId": thread, "approval": item]
        }
        if op == "parts" {
            let id = request["messageId"] as? String ?? ""
            guard
                var result = ConversationReply.partPage(
                    CodexConversation.turns(state).flatMap(CodexConversation.messages), id: id,
                    offset: request["offset"] as? Int ?? 0, headersOnly: request["headersOnly"] as? Bool ?? false,
                    sequence: request["sequence"] as? Bool ?? false, before: request["before"] as? Int)
            else { throw CLIError(L10n.text("session.the_message_changed_refresh_it")) }
            result["threadId"] = thread
            result["messageId"] = id
            return result
        }
        if op == "message" {
            let id = request["messageId"] as? String ?? ""
            let rows = CodexConversation.turns(state).flatMap(CodexConversation.messages)
            guard let text = ConversationReply.fullText(rows, id: id) else {
                throw CLIError(L10n.text("session.the_message_changed_refresh_it"))
            }
            let offset = max(0, min(request["offset"] as? Int ?? 0, text.count))
            let part = String(text.dropFirst(offset).prefix(12_000))
            var reply: [String: Any] = [
                "threadId": thread, "messageId": id, "text": part,
                "nextOffset": offset + part.count < text.count ? offset + part.count : -1,
            ]
            if offset == 0, request["withPart"] as? Bool == true {
                reply["part"] = ConversationReply.partDetails(rows, id: id)
            }
            return reply
        }
        if op == "image" {
            let id = request["imageId"] as? String ?? ""
            guard
                let source = ConversationReply.image(
                    CodexConversation.turns(state).flatMap(CodexConversation.messages), id: id)
            else { throw CLIError(L10n.text("session.the_image_changed_refresh_it")) }
            throw ConversationImageRequest(
                thread: thread, id: id, source: source,
                cwd: state["cwd"] as? String ?? "",
                maxPixel: request["size"] as? String == "large" ? 1280 : 480)
        }
        guard compatible() else { throw CLIError(L10n.text("session.the_codex_version_changed_sending_is_disabled")) }
        if op == "settings" {
            let settings = try composer.settings(request, state: state)
            var params: [String: Any] = ["conversationId": thread, "threadSettings": settings]
            if request["mode"] != nil,
                let active = CodexConversation.turns(state).last(where: { $0["status"] as? String == "inProgress" }),
                let turn = active["turnId"] as? String
            {
                params["activeTurnId"] = turn
            }
            // The desktop settings handler may suspend while the session is locked; use the same unlock lease as desktop actions.
            let response = try ScreenLock.unlocked {
                try ipc.request("thread-follower-update-thread-settings", params, version: 2, target: owner)
            }
            guard (response["result"] as? [String: Any])?["applied"] as? Bool == true else {
                throw CLIError(L10n.text("session.codex_did_not_apply_this_setting_refresh_and_retry"))
            }
            var confirmed = CodexConversation.composer(state)
            for key in ["model", "effort"] { if let value = settings[key] { confirmed[key] = value } }
            if let mode = request["mode"] { confirmed["mode"] = mode }
            // Return the applied choice in the receipt, so the phone need not wait for a background stream update.
            return ["accepted": true, "threadId": thread, "composer": confirmed]
        }
        if op == "interrupt" {
            guard let active = CodexConversation.turns(state).last(where: { $0["status"] as? String == "inProgress" }),
                let turn = active["turnId"] as? String
            else { throw CLIError(L10n.text("session.there_is_no_running_task_in_this_session")) }
            guard request["expectedTurnId"] as? String == turn else {
                throw CLIError(L10n.text("session.the_running_task_changed_the_new_task_was_not_stopped"))
            }
            _ = try ipc.request(
                "thread-follower-interrupt-turn", ["conversationId": thread, "expectedTurnId": turn], version: 4,
                target: owner)
            return ["accepted": true, "threadId": thread]
        }
        if op == "send" {
            let text = (request["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let attachmentIDs = request["attachments"] as? [String] ?? []
            guard !text.isEmpty || !attachmentIDs.isEmpty, text.utf8.count <= 32_000,
                let operation = request["id"] as? String, UUID(uuidString: operation) != nil
            else { throw CLIError(L10n.text("session.the_reply_must_not_be_empty_or_exceed_32_kb")) }
            let identity = try CodexMessageIdentity(client: client, thread: thread, operation: operation)
            if identity.delivered(in: state) {
                return ["accepted": true, "threadId": thread]
            }
            guard let attachments else { throw CLIError(L10n.text("session.attachment_storage_is_unavailable")) }
            let selected = try attachments.selected(attachmentIDs, device: client, thread: thread)
            let input: [[String: Any]] =
                (text.isEmpty ? [] : [["type": "text", "text": text, "text_elements": []]]) + selected.input
            let queued = try followUps.messages(thread)
            if identity.queued(in: queued) {
                return [
                    "accepted": true, "queued": true, "threadId": thread,
                    "queuedMessages": CodexFollowUps.project(queued),
                ]
            }
            let active = CodexConversation.turns(state).contains { $0["status"] as? String == "inProgress" }
            if active || !queued.isEmpty {
                let message = CodexFollowUps.message(
                    id: identity.nativeID, text: text, cwd: state["cwd"] as? String ?? "/", files: selected.files,
                    images: selected.images)
                try setFollowUps(queued + [message], thread: thread, owner: owner)
                let confirmed = try UnconfirmedDesktopMutation.attempting { try followUps.messages(thread) }
                return [
                    "accepted": true, "queued": true, "threadId": thread,
                    "queuedMessages": CodexFollowUps.project(confirmed),
                ]
            }
            _ = try ipc.request(
                "thread-follower-start-turn",
                [
                    "conversationId": thread,
                    "turnStart": [
                        "request": ["threadId": thread, "input": input, "clientUserMessageId": identity.nativeID],
                        "context": ["inheritThreadSettings": true, "attachments": selected.files],
                    ],
                ], version: 2, target: owner)
            return ["accepted": true, "threadId": thread]
        }
        if op == "queueReceiptCheck" {
            let id = request["messageId"] as? String ?? ""
            let rows = try followUps.messages(thread)
            let delivered = CodexConversation.turns(state).flatMap(CodexConversation.messages).contains {
                $0["clientId"] as? String == id
            }
            let queued = rows.first { $0["id"] as? String == id }
            let status = (queued?["submission"] as? [String: Any])?["status"] as? String ?? ""
            let deleting = request["action"] as? String == "delete"
            let accepted =
                deleting
                ? queued == nil && !delivered
                : delivered || ["pending", "sending", "outcome-unknown"].contains(status)
                    || queued?["submissionIntent"] as? String == "send-now"
            var receipt: [String: Any] = ["accepted": accepted, "threadId": thread]
            if deleting && delivered {
                receipt["resolved"] = true
                receipt["ok"] = false
                receipt["error"] = L10n.text("session.this_message_was_already_sent_and_cannot_be_deleted")
            }
            return receipt
        }
        if op == "queueSteer" || op == "queueDelete" {
            let id = request["messageId"] as? String ?? ""
            guard !id.isEmpty, id.count <= 200 else { throw CLIError(L10n.text("session.invalid_queued_message")) }
            var rows = try followUps.messages(thread)
            if op == "queueDelete" {
                if let row = rows.first(where: { $0["id"] as? String == id }),
                    ["pending", "sending"].contains((row["submission"] as? [String: Any])?["status"] as? String ?? "")
                {
                    throw CLIError(L10n.text("session.this_message_is_being_sent_and_cannot_be_deleted"))
                }
                let reply = try ipc.request(
                    "thread-follower-remove-queued-message", ["conversationId": thread, "messageId": id], version: 1,
                    target: owner)
                guard (reply["result"] as? [String: Any])?["removed"] as? [String: Any] != nil else {
                    throw CLIError(L10n.text("session.this_message_was_sent_or_removed_refresh_the_queue"))
                }
            } else {
                guard let index = rows.firstIndex(where: { $0["id"] as? String == id }) else {
                    throw CLIError(L10n.text("session.this_message_was_sent_or_removed_refresh_the_queue"))
                }
                rows[index] = try CodexFollowUps.steer(rows[index])
                try setFollowUps(rows, thread: thread, owner: owner)
            }
            let confirmed = try UnconfirmedDesktopMutation.attempting { try followUps.messages(thread) }
            return [
                "accepted": true, "threadId": thread,
                "queuedMessages": CodexFollowUps.project(confirmed),
            ]
        }
        if op == "approve" {
            let fingerprint = request["fingerprint"] as? String ?? ""
            if let question = CodexConversation.approvals(state).first(where: {
                $0["fingerprint"] as? String == fingerprint && $0["kind"] as? String == "questions"
            }) {
                let submission = try CodexQuestions.submission(
                    request, projected: question, thread: thread, cwd: state["cwd"] as? String ?? "/")
                _ = try ipc.request(submission.method, submission.params, version: 1, target: owner)
                return ["submitted": true, "threadId": thread, "fingerprint": fingerprint]
            }
            guard
                let projected = CodexConversation.approvals(state).first(where: {
                    $0["fingerprint"] as? String == fingerprint
                }),
                let approval = (state["requests"] as? [[String: Any]])?.first(where: {
                    ($0["id"] as? NSObject) == (projected["id"] as? NSObject)
                }),
                projected["canDecide"] as? Bool == true, let requestID = approval["id"]
            else { throw CLIError(L10n.text("session.the_approval_expired_or_must_be_handled_on_the_mac_refresh_it")) }
            guard let allow = request["allow"] as? Bool else {
                throw CLIError(L10n.text("session.choose_allow_once_or_deny"))
            }
            let method = approval["method"] as? String ?? ""
            var params: [String: Any] = ["conversationId": thread, "requestId": requestID]
            let name: String
            if method == "item/permissions/requestApproval" {
                name = "thread-follower-permissions-request-approval-response"
                params["response"] = [
                    "permissions": allow
                        ? ((approval["params"] as? [String: Any])?["permissions"] as? [String: Any] ?? [:]) : [:],
                    "scope": "turn",
                ]
            } else {
                name =
                    method == "item/fileChange/requestApproval"
                    ? "thread-follower-file-approval-decision" : "thread-follower-command-approval-decision"
                params["decision"] = allow ? "accept" : "decline"
            }
            _ = try ipc.request(name, params, version: 1, target: owner)
            return ["submitted": true, "threadId": thread, "fingerprint": fingerprint]
        }
        throw CLIError(L10n.text("session.unsupported_session_operation"))
    }
    private func resolveOwner(_ thread: String, client: String, viewVersion: Int64, attempts: Int) {
        guard selected[client] == thread, viewVersions[client] == viewVersion else { return }
        do {
            let reply = try ipc.request(
                "thread-owner-discovery", ["hostId": "local", "conversationId": thread], version: 1, timeout: 2)
            guard let owner = reply["handledByClientId"] as? String else {
                throw CLIError(L10n.text("session.the_session_has_not_loaded_yet"))
            }
            owners[thread] = owner
            try ipc.follow(thread, owner: owner, on: true)
        } catch {
            if attempts > 1 {
                queue.asyncAfter(deadline: .now() + 0.4) {
                    self.resolveOwner(thread, client: client, viewVersion: viewVersion, attempts: attempts - 1)
                }
            } else {
                emit(
                    client,
                    [
                        "event": "unavailable", "threadId": thread,
                        "error": L10n.text("session.open_this_session_on_the_mac_then_retry"),
                    ])
            }
        }
    }
    private func unsubscribe(_ client: String, closeIPC: Bool = true) {
        markdownFiles.remove(device: client)
        guard let thread = selected.removeValue(forKey: client) else { return }
        emittedPages.removeValue(forKey: client)
        updateIntervals.removeValue(forKey: client)
        knownVersions.removeValue(forKey: client)
        if !selected.values.contains(thread) {
            try? ipc.follow(thread, owner: owners[thread], on: false)
            states.removeValue(forKey: thread)
            owners.removeValue(forKey: thread)
            revisions.removeValue(forKey: thread)
        }
        if selected.isEmpty && closeIPC { ipc.close() }
    }
    private func conversationPage(_ state: [String: Any], thread: String) -> [String: Any] {
        var page = CodexConversation.page(state)
        var capabilities = page["capabilities"] as? [String: Any] ?? [:]
        capabilities["markdownFiles"] = true
        capabilities["projectFiles"] = true
        capabilities["videoFiles"] = true
        page["capabilities"] = capabilities
        page["queuedMessages"] = CodexFollowUps.project((try? followUps.messages(thread)) ?? [])
        return ConversationReply.versioned(page)
    }
    private func setFollowUps(_ rows: [[String: Any]], thread: String, owner: String) throws {
        let reply = try ipc.request(
            "thread-follower-set-queued-follow-ups-state", ["conversationId": thread, "state": [thread: rows]],
            version: 1, target: owner)
        guard (reply["result"] as? [String: Any])?["ok"] as? Bool == true else {
            throw CLIError(L10n.text("session.the_desktop_did_not_confirm_the_send_queue"))
        }
    }
    private func receive(_ data: Data) {
        if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            message["method"] as? String == "thread-queued-followups-changed", message["version"] as? Int == 2,
            let params = message["params"] as? [String: Any], params["hostId"] as? String == "local",
            let thread = params["conversationId"] as? String, message["sourceClientId"] as? String == owners[thread],
            let rows = params["messages"] as? [[String: Any]]
        {
            for (client, selected) in selected where selected == thread {
                emit(client, ["event": "queue", "threadId": thread, "queuedMessages": CodexFollowUps.project(rows)])
            }
            return
        }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            message["method"] as? String == "thread-stream-state-changed",
            message["version"] as? Int == 11, let params = message["params"] as? [String: Any],
            params["hostId"] as? String == "local",
            let thread = params["conversationId"] as? String, selected.values.contains(thread),
            message["sourceClientId"] as? String == owners[thread],
            let change = params["change"] as? [String: Any], let revision = change["revision"] as? Int
        else { return }
        if let old = revisions[thread], revision <= old { return }
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            states[thread] = state
        } else if let state = states[thread], change["baseRevision"] as? Int == revisions[thread],
            let patches = change["patches"] as? [[String: Any]]
        {
            do {
                var updated: Any = state
                for patch in patches {
                    guard let path = patch["path"] as? [Any], let op = patch["op"] as? String,
                        ["add", "remove", "replace"].contains(op)
                    else { throw CLIError(L10n.text("session.invalid_update")) }
                    updated = try CodexConversation.patch(
                        updated, path: path[...], operation: op, value: patch["value"])
                }
                states[thread] = updated as? [String: Any]
            } catch {
                try? ipc.follow(thread, owner: owners[thread], on: false)
                try? ipc.follow(thread, owner: owners[thread], on: true)
                return
            }
        } else {
            try? ipc.follow(thread, owner: owners[thread], on: false)
            try? ipc.follow(thread, owner: owners[thread], on: true)
            return
        }
        revisions[thread] = revision
        guard scheduled.insert(thread).inserted else { return }
        let clients = selected.filter { $0.value == thread }.map(\.key)
        let delay =
            clients.contains { emittedPages[$0] == nil } ? 0 : clients.compactMap { updateIntervals[$0] }.min() ?? 0.25
        queue.asyncAfter(deadline: .now() + delay) {
            self.scheduled.remove(thread)
            guard let state = self.states[thread] else { return }
            for (client, selected) in self.selected where selected == thread {
                var result = self.conversationPage(state, thread: thread)
                result["viewVersion"] = self.viewVersions[client]
                result["revision"] = self.revisions[thread] ?? revision
                result["canSend"] = self.compatible()
                let full = result
                if let previous = self.emittedPages[client] {
                    if previous["cacheVersion"] as? String == full["cacheVersion"] as? String
                        && previous["canSend"] as? Bool == full["canSend"] as? Bool
                    {
                        continue
                    }
                    let oldMessages = previous["messages"] as? [[String: Any]] ?? []
                    let messages = result["messages"] as? [[String: Any]] ?? []
                    result["messages"] = messages.filter { item in
                        guard let old = oldMessages.first(where: { $0["id"] as? String == item["id"] as? String })
                        else { return true }
                        return !NSDictionary(dictionary: old).isEqual(NSDictionary(dictionary: item))
                    }
                    result["order"] = messages.compactMap { $0["id"] as? String }
                    result["baseRevision"] = previous["revision"] ?? 0
                    result["event"] = "delta"
                } else {
                    result = ConversationReply.conditional(full, known: self.knownVersions[client])
                    result["event"] = "snapshot"
                }
                self.emittedPages[client] = full
                self.emit(client, result)
            }
        }
    }
    private func emit(_ client: String, _ value: [String: Any]) {
        var value = value
        value["viewVersion"] = viewVersions[client]
        if let data = try? JSONSerialization.data(withJSONObject: value) { event?(client, data) }
    }
}
