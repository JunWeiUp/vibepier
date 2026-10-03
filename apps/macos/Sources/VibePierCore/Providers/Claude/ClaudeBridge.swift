import Darwin
import Foundation

/// Claude Code keeps each session as an append-only JSONL transcript; only the conversation — messages and the steps of each reply — leaves this adapter.
enum ClaudeTranscript {
    /// What the person sent: typed text and attached images, as the sources the page later serves by id.
    static func userMessage(_ entry: [String: Any]) -> (text: String, images: [String])? {
        guard entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
            entry["isCompactSummary"] as? Bool != true, entry["isSidechain"] as? Bool != true,
            let message = entry["message"] as? [String: Any]
        else { return nil }
        let text: String
        var images: [String] = []
        if let value = message["content"] as? String {
            text = value
        } else if let blocks = message["content"] as? [[String: Any]] {
            // Tool results are protocol traffic, not something the person typed.
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(
                separator: "\n")
            images = blocks.compactMap(imageSource)
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash-command wrappers, caveats and reminders are injected markup; an interrupt marker is not a message either.
        guard !trimmed.isEmpty || !images.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix(interrupted) else {
            return nil
        }
        return (trimmed, images)
    }
    static func userText(_ entry: [String: Any]) -> String? {
        userMessage(entry).flatMap { $0.text.isEmpty ? nil : $0.text }
    }
    static func imageSource(_ block: [String: Any]) -> String? {
        ConversationReply.imageContentSources([block]).first
    }
    static let interrupted = "[Request interrupted by user"
    /// Only the latest unresolved API error is a current blocker. Historical failures stay in the timeline.
    static func blocker(_ entries: [[String: Any]]) -> [String: Any]? {
        for entry in entries.reversed() where entry["isSidechain"] as? Bool != true {
            if entry["type"] as? String == "system", entry["subtype"] as? String == "api_error" {
                let limited = (entry["error"] as? [String: Any])?["status"] as? Int == 429
                return [
                    "code": limited ? "rateLimit" : "apiError",
                    "message": L10n.text(limited ? "provider.claude_rate_limited" : "provider.claude_api_unavailable"),
                ]
            }
            if entry["type"] as? String == "assistant" || userMessage(entry) != nil { return nil }
            if entry["type"] as? String == "user",
                let content = (entry["message"] as? [String: Any])?["content"],
                (content as? String ?? (content as? [[String: Any]])?.first?["text"] as? String ?? "")
                    .hasPrefix(interrupted)
            {
                return nil
            }
        }
        return nil
    }
    /// Ordered chat rows: each person's message, then one reply with its text, thinking and tool calls with results.
    static func messages(_ entries: [[String: Any]]) -> [[String: Any]] { turns(entries).flatMap { $0 } }
    static func turns(_ entries: [[String: Any]]) -> [[[String: Any]]] {
        var result: [[[String: Any]]] = []
        var builder = ConversationReply.Builder()
        var apiErrorID: String?
        func close() {
            let rows = builder.finish()
            if !rows.isEmpty { result.append(rows) }
            builder = .init()
            apiErrorID = nil
        }
        for (index, entry) in entries.enumerated() {
            let uuid = entry["uuid"] as? String ?? "entry-\(index)"
            if let message = userMessage(entry) {
                close()
                builder.user(
                    uuid, text: message.text,
                    extra: message.images.isEmpty ? [:] : [ConversationReply.imageKey: message.images])
                continue
            }
            if entry["type"] as? String == "system", entry["subtype"] as? String == "api_error",
                entry["isSidechain"] as? Bool != true
            {
                let status = (entry["error"] as? [String: Any])?["status"] as? Int
                // Native gateway errors can contain URLs and credentials. Show a fixed diagnostic,
                // coalescing retries within this turn without resubmitting or changing its receipt.
                let text = L10n.text(
                    status == 429 ? "provider.claude_rate_limited" : "provider.claude_api_unavailable")
                if let apiErrorID {
                    builder.update(apiErrorID) { $0.text = text }
                } else {
                    apiErrorID = uuid
                    builder.add(
                        .init(
                            id: uuid, kind: "notice", title: L10n.text("provider.run_failed"),
                            status: "failed", text: text, extra: ["groupType": "notice:api-error"]))
                }
                continue
            }
            if entry["type"] as? String == "user", entry["isSidechain"] as? Bool != true,
                let content = (entry["message"] as? [String: Any])?["content"],
                (content as? String ?? (content as? [[String: Any]])?.first?["text"] as? String ?? "").hasPrefix(
                    interrupted)
            {
                builder.settleRunning("declined")
                builder.add(
                    .init(
                        id: uuid, kind: "notice", title: L10n.text("provider.interrupted_by_you"), status: "declined",
                        extra: ["groupType": "notice:interrupted"]))
                continue
            }
            guard entry["isSidechain"] as? Bool != true,
                let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { continue }
            if entry["type"] as? String == "assistant" {
                for (offset, block) in blocks.enumerated() {
                    let id = uuid + "-\(offset)"
                    switch block["type"] as? String {
                    case "text":
                        let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { builder.add(.init(id: id, kind: "text", text: text)) }
                    case "thinking":
                        let text = (block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            builder.add(
                                .init(
                                    id: id, kind: "thinking", title: L10n.text("session.thinking"), text: text,
                                    extra: ["groupType": "thinking"])
                            )
                        }
                    case "tool_use":
                        builder.add(toolPart(block, cwd: entry["cwd"] as? String))
                    default: break
                    }
                }
            } else if entry["type"] as? String == "user" {
                for block in blocks {
                    guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else {
                        continue
                    }
                    let output = resultText(block["content"])
                    let failed = block["is_error"] as? Bool == true
                    let images = (block["content"] as? [[String: Any]] ?? []).compactMap(imageSource)
                    builder.update(id) { part in
                        if !images.isEmpty { part.extra[ConversationReply.imageKey] = images }
                        part.status = failed ? "failed" : "completed"
                        switch part.kind {
                        case "command": part.text = output
                        case "plan": break
                        case "file": if failed { part.text += L10n.text("session.error_2") + output }
                        default:
                            part.text +=
                                (part.text.isEmpty ? "" : "\n\n")
                                + (failed ? L10n.text("provider.error") : L10n.text("provider.result")) + output
                        }
                    }
                }
            }
        }
        close()
        return result
    }
    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        // Images are shown as images; other non-text blocks keep a marker.
        return (content as? [[String: Any]] ?? []).compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return block["text"] as? String ?? ""
            case "image": return nil
            default: return "[\(block["type"] as? String ?? L10n.text("provider.content_2"))]"
            }
        }.joined(separator: "\n")
    }
    /// A tool call shaped like the desktop's row for it: commands, edits as diffs, todos as a checklist.
    static func toolPart(_ block: [String: Any], cwd: String?) -> ConversationReply.Part {
        let name = block["name"] as? String ?? ""
        let input = block["input"] as? [String: Any] ?? [:]
        var part = ConversationReply.Part(
            id: block["id"] as? String ?? UUID().uuidString, kind: "tool",
            title: name.isEmpty ? L10n.text("session.tool") : name, status: "running")
        func string(_ key: String) -> String { input[key] as? String ?? "" }
        func edit(_ path: String, _ diff: String, kind: String) {
            let counts = ConversationReply.lineCounts(diff)
            part.kind = "file"
            part.title = path
            part.text = "*** \(kind) \(path)\n" + diff
            part.extra = [
                "added": counts.added, "removed": counts.removed,
                "files": [["path": path, "kind": kind, "added": counts.added, "removed": counts.removed]],
            ]
        }
        switch name {
        case "Bash":
            part.kind = "command"
            part.title = string("command")
            if !string("description").isEmpty { part.extra["description"] = string("description") }
            if let cwd { part.extra["cwd"] = cwd }
        case "Edit":
            edit(
                string("file_path"), ConversationReply.replacement(string("old_string"), string("new_string")),
                kind: "update")
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).map {
                ConversationReply.replacement($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "")
            }
            edit(string("file_path"), edits.joined(separator: "\n@@\n"), kind: "update")
        case "Write":
            edit(string("file_path"), ConversationReply.replacement("", string("content")), kind: "add")
        case "NotebookEdit":
            edit(string("notebook_path"), ConversationReply.replacement("", string("new_source")), kind: "update")
        case "TodoWrite":
            part.kind = "plan"
            part.title = L10n.text("provider.to_do")
            part.text = (input["todos"] as? [[String: Any]] ?? []).map { todo in
                let mark =
                    todo["status"] as? String == "completed"
                    ? "[x]" : todo["status"] as? String == "in_progress" ? "[~]" : "[ ]"
                return "- \(mark) " + (todo["content"] as? String ?? "")
            }.joined(separator: "\n")
        case "Read": part.title = L10n.text("provider.read") + string("file_path")
        case "Grep":
            part.title =
                L10n.text("provider.search") + string("pattern")
                + (string("path").isEmpty ? "" : " · " + string("path"))
        case "Glob": part.title = L10n.text("provider.find") + string("pattern")
        case "WebFetch":
            part.title = L10n.text("provider.visit") + string("url")
            part.text = string("prompt")
        case "WebSearch": part.title = L10n.text("provider.search_web") + string("query")
        case "Task", "Agent":
            part.title = L10n.text("provider.subtask") + string("description")
            part.text = string("prompt")
        default:
            if name.hasPrefix("mcp__") {
                part.title = name.dropFirst(5).components(separatedBy: "__").joined(separator: " · ")
            }
            part.text = input.isEmpty ? "" : L10n.text("session.arguments") + ConversationReply.json(input)
        }
        if part.kind != "plan" { part.extra.merge(ConversationReply.toolGrouping(name)) { _, new in new } }
        return part
    }
    /// The latest `/model` or `/effort` run in the session: its position, arguments and printed result.
    static func command(_ name: String, in entries: [[String: Any]], after start: Int = 0) -> (
        index: Int, args: String, output: String
    )? {
        guard start < entries.count else { return nil }
        for index in (start..<entries.count).reversed() {
            let entry = entries[index]
            guard entry["subtype"] as? String == "local_command", let run = entry["commandRun"] as? [String: Any],
                run["command"] as? String == name
            else { continue }
            let output = (entry["content"] as? String ?? "").replacingOccurrences(
                of: "<local-command-stdout>", with: ""
            ).replacingOccurrences(of: "</local-command-stdout>", with: "")
            return (index, run["args"] as? String ?? "", output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
    static func title(_ entries: [[String: Any]]) -> String {
        if let custom = entries.last(where: { $0["type"] as? String == "custom-title" })?["customTitle"] as? String,
            !custom.isEmpty
        {
            return custom
        }
        if let generated = entries.last(where: { $0["type"] as? String == "ai-title" })?["aiTitle"] as? String,
            !generated.isEmpty
        {
            return generated
        }
        if let first = entries.lazy.compactMap(userText).first { return String(first.prefix(80)) }
        return "Claude Code"
    }
    static func page(_ entries: [[String: Any]], projected: [[[String: Any]]]? = nil) -> [String: Any] {
        let all = projected ?? turns(entries)
        let count = ConversationReply.recentTurns
        let rows = ConversationReply.preview(all.suffix(count).flatMap { $0 })
        return ["messages": rows, "approvals": [], "hasOlder": all.count > count, "loadedTurns": count]
    }
}

/// Lists local Claude Code sessions and continues one headlessly with `claude -p --resume`, in that session's directory.
final class ClaudeBridge: @unchecked Sendable {
    private struct Transcript {
        let url: URL
        var incarnation = UUID()
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var remainder = Data()
        var entries: [[String: Any]] = []
        var projected: [[[String: Any]]]?
    }
    private struct Run {
        let token: String
        let process: Process
        let operation: String
    }
    private struct Summary {
        let size: Int
        let modified: Double
        let customModified: Double
        let title: String
        let cwd: String
    }
    static let modes = ["default", "auto", "acceptEdits", "plan", "bypassPermissions"]
    /// Stable CLI aliases avoid guessing account-specific model IDs. The installed CLI and account
    /// determine availability; unavailable selections return the provider's error.
    static var models: [[String: Any]] {
        [
            [
                "id": "default", "name": L10n.text("provider.default_model"),
                "description": L10n.text("provider.use_claude_code_settings"), "efforts": efforts,
                "defaultEffort": "default",
            ],
            ["id": "opus", "name": "Opus", "description": "", "efforts": efforts, "defaultEffort": "default"],
            ["id": "sonnet", "name": "Sonnet", "description": "", "efforts": efforts, "defaultEffort": "default"],
            ["id": "haiku", "name": "Haiku", "description": "", "efforts": ["default"], "defaultEffort": "default"],
        ]
    }
    private static let efforts = ["default", "low", "medium", "high", "xhigh", "max"]
    private let queue = DispatchQueue(label: "vibepier.claude-bridge")
    private let root: URL
    private static let sharedProcesses = SessionWorkBudget(
        limits: .init(perDevice: 4, total: 8, bytesPerDevice: 8 * 1024 * 1024, bytesTotal: 16 * 1024 * 1024))
    private let processBudget: SessionWorkBudget
    private let processExecutable: URL?
    private let attachments: CodexAttachments?
    private let markdownFiles = SessionMarkdownFiles()
    private let settingsFile: URL
    private var selected: [String: String] = [:]
    private var viewVersions: [String: Int64] = [:]
    private var transcripts: [String: Transcript] = [:]
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var revisions: [String: Int] = [:]
    private var emittedPages: [String: [String: Any]] = [:]
    private var updateIntervals: [String: TimeInterval] = [:]
    private var scheduled = Set<String>()
    private var runs: [String: Run] = [:]
    private var runErrors: [String: [String: Any]] = [:]
    private let operationReceipts = ProviderOperationReceipts()
    private var summaries: [String: Summary] = [:]
    private var settings: [String: [String: String]] = [:]
    private var desktopControls: [String: ClaudeDesktop.Controls] = [:]
    private let permissions = ClaudePermissionTail()
    private var registryWatcher: DispatchSourceFileSystemObject?
    var event: (@Sendable (String, Data) -> Void)?
    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
        processExecutable: URL? = nil, processBudget: SessionWorkBudget? = nil, settingsFile: URL? = nil,
        attachmentRoot: URL? = nil
    ) {
        self.root = root
        self.processExecutable = processExecutable
        self.processBudget = processBudget ?? Self.sharedProcesses
        self.settingsFile = settingsFile ?? Paths.supportDirectory.appendingPathComponent("claude-sessions.json")
        attachments = try? CodexAttachments(
            root: attachmentRoot ?? Paths.supportDirectory.appendingPathComponent("claude-attachments"))
        settings =
            (try? JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: self.settingsFile)))
            ?? [:]
    }
    func stop(_ client: String) { queue.async { self.unsubscribe(client) } }
    func stopAll() { queue.async { for client in Array(self.selected.keys) { self.unsubscribe(client) } } }
    private let requestAdmission = SessionRequestAdmission()

    func perform(_ data: Data, client: String, completion: @escaping @Sendable (Data) -> Void) {
        if let cached = operationReceipts.cachedReply(data, client: client, provider: "claude") {
            completion(cached)
            return
        }
        requestAdmission.submit(on: queue) {
            completion(SessionRequestAdmission.rejection(provider: "claude"))
        } work: { [self] in
            var ticket: ProviderOperationReceipts.Ticket?
            var result: [String: Any]
            do {
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CLIError(L10n.text("core.invalid_request"))
                }
                if ProviderOperationReceipts.mutable(request["op"] as? String ?? "") {
                    switch try self.operationReceipts.begin(request, client: client) {
                    case .fresh(let fresh): ticket = fresh
                    case .cached(var cached):
                        cached["provider"] = "claude"
                        completion((try? JSONSerialization.data(withJSONObject: cached)) ?? Data())
                        return
                    }
                }
                if request["op"] as? String == "new", let creationTicket = ticket {
                    try self.create(request, ticket: creationTicket) { value in
                        var value = self.operationReceipts.finish(creationTicket, result: value)
                        value["provider"] = "claude"
                        completion((try? JSONSerialization.data(withJSONObject: value)) ?? Data())
                    }
                    return
                }
                result = try self.handle(request, client: client, ticket: ticket)
                if result["ok"] == nil { result["ok"] = true }
            } catch let file as SessionFileRequest {
                SessionFileLoader.shared.perform(file, provider: "claude", completion: completion)
                return
            } catch let image as ConversationImageRequest {
                ConversationImageLoader.shared.perform(image, provider: "claude", completion: completion)
                return
            } catch { result = ProviderFailure.reply(error, provider: "claude") }
            if let ticket { result = self.operationReceipts.finish(ticket, result: result) }
            result["provider"] = "claude"
            completion((try? JSONSerialization.data(withJSONObject: result)) ?? Data())
        }
    }
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude",
            home + "/.claude/local/claude",
        ]
        .first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    private func sessionFiles() -> [URL] {
        let projects =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return projects.flatMap {
            (try? FileManager.default.contentsOfDirectory(
                at: $0, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
        }
        .filter { $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
    }
    private func file(_ session: String) throws -> URL {
        guard UUID(uuidString: session) != nil,
            let url = sessionFiles().first(where: { $0.deletingPathExtension().lastPathComponent == session })
        else { throw CLIError(L10n.text("provider.this_claude_code_session_was_not_found")) }
        return url
    }
    private static func parse(_ data: Data) -> [[String: Any]] {
        data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }
    private func summary(_ url: URL) -> Summary? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let size = values.fileSize,
            let modified = values.contentModificationDate?.timeIntervalSince1970
        else { return nil }
        let titleURL = url.deletingPathExtension().appendingPathComponent("custom-title.json")
        let titleModified =
            (try? titleURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?
                .timeIntervalSince1970) ?? 0
        if let cached = summaries[url.path], cached.size == size, cached.modified == modified,
            cached.customModified == titleModified
        {
            return cached
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let custom =
            (try? Data(contentsOf: titleURL)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }?["customTitle"] as? String
        guard let metadata = ClaudeSessionSummary.read(data, customTitle: custom) else { return nil }
        let value = Summary(
            size: size, modified: modified, customModified: titleModified, title: metadata.title, cwd: metadata.cwd)
        summaries[url.path] = value
        return value
    }
    private func sessions(search: String, cwd: String? = nil, count: Int? = nil) -> [(id: String, summary: Summary)] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var files: [(url: URL, modified: Double)] = []
        for url in sessionFiles() {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            files.append((url, values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        files.sort {
            if $0.modified == $1.modified { return $0.url.path > $1.url.path }
            return $0.modified > $1.modified
        }
        var result: [(id: String, summary: Summary)] = []
        for (url, _) in files {
            guard let item = summary(url), cwd == nil || item.cwd == cwd else { continue }
            guard needle.isEmpty || item.title.lowercased().contains(needle) || item.cwd.lowercased().contains(needle)
            else { continue }
            result.append((url.deletingPathExtension().lastPathComponent, item))
            if let count, result.count >= count { break }
        }
        return result
    }
    /// What each session is doing now: `running` while our headless run or a busy live process works on it,
    /// `approval` while the desktop app waits on a permission for it. Idle sessions are absent.
    private func statuses() -> [String: String] {
        var result: [String: String] = [:]
        for session in runs.keys { result[session] = "running" }
        let live = ClaudeDesktop.live(excluding: Set(runs.values.map { $0.process.processIdentifier }))
        guard !live.isEmpty else { return result }
        permissions.update()
        let waiting = Set(permissions.log.pending.map(\.host))
        for (session, owner) in live {
            if owner.desktop, let host = owner.host, waiting.contains(host) {
                result[session] = "approval"
            } else if owner.busy, result[session] == nil {
                result[session] = "running"
            }
        }
        return result
    }
    /// `cwd` limits the list to one project; nil lists every project.
    private func list(search: String, offset: Int, cwd: String?, limit: Int = 20) -> [String: Any] {
        let limit = max(1, min(limit, 20))
        let offset = max(0, min(offset, 100_000))
        let status = statuses()
        let rows: [[String: Any]] = sessions(search: search, cwd: cwd, count: max(0, offset) + limit + 1).map {
            id, item in
            var row: [String: Any] = [
                "id": id, "title": item.title, "project": URL(fileURLWithPath: item.cwd).lastPathComponent,
                "cwd": item.cwd,
                "pinned": false, "updatedAt": Int64(item.modified * 1000),
            ]
            if let value = status[id] { row["status"] = value }
            return row
        }
        let start = max(0, min(offset, rows.count))
        return [
            "threads": Array(rows[start..<min(rows.count, start + limit)]),
            "nextOffset": rows.count > start + limit ? start + limit : -1,
        ]
    }
    /// One row per working directory, most recently active first.
    private func projects(search: String, offset: Int = 0, limit: Int = 100) -> [String: Any] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var latest: [String: Double] = [:]
        var running: [String: Int] = [:]
        let status = statuses()
        for (id, item) in sessions(search: search) {
            if counts[item.cwd] == nil {
                order.append(item.cwd)
                latest[item.cwd] = item.modified
            }
            counts[item.cwd, default: 0] += 1
            if status[id] != nil { running[item.cwd, default: 0] += 1 }
        }
        let start = max(0, min(offset, order.count))
        let limit = max(1, min(limit, 100))
        return [
            "nextOffset": order.count > start + limit ? start + limit : -1,
            "projects": order.dropFirst(start).prefix(limit).map { cwd in
                var row: [String: Any] = [
                    "cwd": cwd, "project": URL(fileURLWithPath: cwd).lastPathComponent, "count": counts[cwd] ?? 0,
                    "updatedAt": Int64((latest[cwd] ?? 0) * 1000),
                ]
                if let count = running[cwd] { row["running"] = count }
                return row
            },
        ]
    }
    /// Starts a session in a known project headlessly with the first message, replying once its transcript exists so the phone can open it.
    /// The first turn runs as `claude -p`; once it ends the session is imported into the desktop app, which runs the later turns.
    private func create(
        _ request: [String: Any], ticket: ProviderOperationReceipts.Ticket,
        reply: @escaping @Sendable ([String: Any]) -> Void
    ) throws {
        guard let operation = request["id"] as? String, UUID(uuidString: operation) != nil else {
            throw CLIError(L10n.text("core.invalid_request"))
        }
        let cwd = request["cwd"] as? String ?? ""
        guard request["text"] == nil || request["text"] is String else {
            throw CLIError(L10n.text("core.invalid_request"))
        }
        let text = (request["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard request["attachments"] == nil || request["attachments"] is [String] else {
            throw CLIError(L10n.text("core.invalid_request"))
        }
        let ids = request["attachments"] as? [String] ?? []
        guard !text.isEmpty || !ids.isEmpty, text.utf8.count <= 32_000 else {
            throw CLIError(L10n.text("session.the_first_message_must_not_be_empty_or_exceed_32_kb"))
        }
        guard sessions(search: "").contains(where: { $0.summary.cwd == cwd }) else {
            throw CLIError(L10n.text("provider.not_a_known_claude_code_project"))
        }
        let configuration = try ClaudeSessionConfiguration.resolve(
            request, current: ["model": "default", "effort": "default", "mode": "acceptEdits"])
        let prompt: ClaudePrompt
        if request["draftId"] != nil || !ids.isEmpty {
            let draft = try SessionCreationDraft(request, project: cwd, provider: "claude")
            guard let attachments else { throw CLIError(L10n.text("session.attachment_storage_is_unavailable")) }
            prompt = try attachments.claudePrompt(text, ids: ids, device: ticket.key.client, thread: draft.scope)
        } else {
            prompt = try ClaudePrompt(text: text)
        }
        let proof = prompt.proof
        let session = UUID().uuidString.lowercased()
        try operationReceipts.observe(ticket, bytes: proof.retainedBytes + cwd.utf8.count + session.utf8.count) {
            [weak self] in
            guard let self, let url = try? self.file(session) else { return nil }
            return ClaudeCreationReceipt.read(url, session: session, cwd: cwd, proof: proof)
        }
        // Save before launching so the first turn and later phone continuations agree.
        // Old phone requests without configuration keep the existing creation defaults.
        if ClaudeSessionConfiguration.keys.contains(where: { request[$0] != nil }) {
            settings[session] = configuration
            do { try saveSettings() } catch {
                settings.removeValue(forKey: session)
                throw CLIError(L10n.text("provider.could_not_save_session_settings"))
            }
        }
        try launch(
            session, prompt: prompt.text, cwd: cwd, operation: operation, client: ticket.key.client, fresh: true,
            streamInput: prompt.streamInput(session: session))
        operationReceipts.arm(ticket)
        @Sendable func poll(_ step: Int) {
            if let url = try? self.file(session),
                let value = ClaudeCreationReceipt.read(url, session: session, cwd: cwd, proof: proof)
            {
                reply(value)
                return
            }
            guard step < 60, self.runs[session] != nil || step < 3 else {
                reply([
                    "ok": false, "unknown": true,
                    "error": self.runErrors[session]?["text"] as? String
                        ?? L10n.text("provider.claude_code_could_not_create_a_new_session"),
                ])
                return
            }
            self.queue.asyncAfter(deadline: .now() + 0.4) { poll(step + 1) }
        }
        poll(0)
    }
    private func handle(_ request: [String: Any], client: String, ticket: ProviderOperationReceipts.Ticket?) throws
        -> [String: Any]
    {
        let op = request["op"] as? String ?? ""
        if ["receiptCheck", "newReceiptCheck", "settingsReceiptCheck", "interruptReceiptCheck"].contains(op) {
            let kind =
                request["originalOperation"] as? String
                ?? [
                    "newReceiptCheck": "new", "settingsReceiptCheck": "settings", "interruptReceiptCheck": "interrupt",
                ][op] ?? "send"
            return operationReceipts.lookup(
                client: client, operation: request["operation"] as? String ?? request["id"] as? String ?? "",
                thread: request["threadId"] as? String ?? "", kind: kind)
        }
        if op == "newOptions" || SessionCreationDraft.attachmentOperations.contains(op) {
            let cwd = request["cwd"] as? String ?? ""
            guard sessions(search: "").contains(where: { $0.summary.cwd == cwd }) else {
                throw CLIError(L10n.text("provider.not_a_known_claude_code_project"))
            }
            guard let attachments else { throw CLIError(L10n.text("session.attachment_storage_is_unavailable")) }
            let draft = try SessionCreationDraft(request, project: cwd, provider: "claude")
            if op == "newOptions" {
                return [
                    "creationVersion": 1, "draftId": draft.id, "models": Self.models,
                    "composer": ["model": "default", "effort": "default", "mode": "default"],
                    "capabilities": ["attachments": true],
                    "permissionModes": Self.modes.map { mode -> [String: Any] in
                        [
                            "id": mode, "name": ClaudeDesktop.modeTitles[mode] ?? mode,
                            "requiresConfirmation": mode == "bypassPermissions",
                        ]
                    },
                ]
            }
            return try draft.attachment(request, storage: attachments, device: client)
        }
        let search = String((request["search"] as? String ?? "").prefix(200))
        if op == "list" || op == "projects" {
            var value =
                op == "list"
                ? list(
                    search: search, offset: request["offset"] as? Int ?? 0, cwd: request["cwd"] as? String,
                    limit: request["limit"] as? Int ?? 20)
                : projects(
                    search: search, offset: request["offset"] as? Int ?? 0, limit: request["limit"] as? Int ?? 100)
            value["capabilities"] = ["markdownFiles": true, "projectFiles": true]
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
        guard let session = request["threadId"] as? String, UUID(uuidString: session) != nil else {
            throw CLIError(L10n.text("session.invalid_session"))
        }
        if op == "attachmentRemove" {
            guard let attachments else { throw CLIError(L10n.text("session.attachment_storage_is_unavailable")) }
            try attachments.remove(request["attachmentId"] as? String ?? "", device: client, thread: session)
            return [:]
        }
        if op == "open" {
            guard viewVersion >= 0, viewVersion >= (viewVersions[client] ?? -1) else {
                throw CLIError(L10n.text("session.the_session_view_changed"))
            }
            viewVersions[client] = viewVersion
            if selected[client] != session {
                unsubscribe(client)
                selected[client] = session
            }
            updateIntervals[client] = min(1.5, max(0.25, Double(request["updatesIntervalMs"] as? Int ?? 250) / 1000))
            if transcripts[session] == nil {
                transcripts[session] = Transcript(url: try file(session))
                watch(session)
            }
            watchRegistry()
            refresh(session)
            var page = makePage(session)
            page["viewVersion"] = viewVersion
            emittedPages[client] = page
            return ConversationReply.conditional(page, known: request["knownVersion"] as? String)
        }
        guard viewVersions[client] == viewVersion, selected[client] == session, let transcript = transcripts[session]
        else { throw CLIError(L10n.text("session.the_session_is_not_ready_reopen_it")) }
        let cwd = transcript.entries.lazy.compactMap { $0["cwd"] as? String }.last ?? "/"
        switch op {
        case "readMarkdownFile":
            throw try markdownFiles.request(
                request, cwd: transcript.entries.lazy.compactMap { $0["cwd"] as? String }.last ?? "", device: client,
                thread: session,
                referencedPaths: SessionMarkdownFiles.referencedPaths(in: projected(session).flatMap { $0 }))
        case "browseFiles":
            throw SessionProjectFiles.browseRequest(
                request["folder"] as? String ?? "",
                cwd: transcript.entries.lazy.compactMap { $0["cwd"] as? String }.last ?? "", thread: session)
        case _ where SessionProjectFiles.operations.contains(op):
            let projectCwd = transcript.entries.lazy.compactMap { $0["cwd"] as? String }.last ?? ""
            if op == "openFile" {
                return try SessionProjectFiles.reply(
                    op, request, cwd: projectCwd, rows: { [] }, reader: markdownFiles, device: client, thread: session)
            }
            let rows = op == "fileChanges" ? projected(session).suffix(2).flatMap { $0 } : []
            throw try SessionProjectFiles.request(
                op, request, cwd: projectCwd, rows: rows, reader: markdownFiles, device: client, thread: session)
        case "sync":
            var page = makePage(session)
            page["viewVersion"] = viewVersions[client]
            emittedPages[client] = page
            return ConversationReply.conditional(page, known: request["knownVersion"] as? String)
        case "history":
            guard let before = request["before"] as? String else {
                throw CLIError(L10n.text("session.update_the_phone_app_before_loading_earlier_messages"))
            }
            guard let window = ConversationReply.older(projected(session), before: before) else {
                throw CLIError(L10n.text("session.the_session_changed_reopen_it"))
            }
            return ["threadId": session, "messages": window.rows, "hasOlder": window.start > 0]
        case "parts":
            let id = request["messageId"] as? String ?? ""
            guard
                var result = ConversationReply.partPage(
                    projected(session).flatMap { $0 }, id: id, offset: request["offset"] as? Int ?? 0,
                    headersOnly: request["headersOnly"] as? Bool ?? false,
                    sequence: request["sequence"] as? Bool ?? false, before: request["before"] as? Int)
            else { throw CLIError(L10n.text("session.the_message_changed_refresh_it")) }
            result["threadId"] = session
            result["messageId"] = id
            return result
        case "message":
            let id = request["messageId"] as? String ?? ""
            let rows = projected(session).flatMap { $0 }
            guard let text = ConversationReply.fullText(rows, id: id) else {
                throw CLIError(L10n.text("session.the_message_changed_refresh_it"))
            }
            let offset = max(0, min(request["offset"] as? Int ?? 0, text.count))
            let part = String(text.dropFirst(offset).prefix(12_000))
            var reply: [String: Any] = [
                "threadId": session, "messageId": id, "text": part,
                "nextOffset": offset + part.count < text.count ? offset + part.count : -1,
            ]
            if offset == 0, request["withPart"] as? Bool == true {
                reply["part"] = ConversationReply.partDetails(rows, id: id)
            }
            return reply
        case "image":
            let id = request["imageId"] as? String ?? ""
            guard let source = ConversationReply.image(projected(session).flatMap { $0 }, id: id) else {
                throw CLIError(L10n.text("session.the_image_changed_refresh_it"))
            }
            throw ConversationImageRequest(
                thread: session, id: id, source: source,
                cwd: transcript.entries.lazy.compactMap { $0["cwd"] as? String }.last ?? "",
                maxPixel: request["size"] as? String == "large" ? 1280 : 480)
        case "composerOptions":
            let owner = owner(session)
            // Reading the menus means switching the desktop app; while locked, keep the last known ones.
            if let owner, owner.desktop, let host = owner.host, !ScreenLock.locked() {
                desktopControls[session] = try ClaudeDesktop.controls(host: host)
            }
            return [
                "threadId": session, "models": models(session), "composer": composer(session, owner: owner),
                "description": owner?.desktop == true
                    ? L10n.text("provider.uses_the_models_currently_available_in_claude_desktop_for_this_session_only")
                    : L10n.text("provider.applies_to_subsequent_claude_code_requests_sent_from_the_phone"),
            ]
        case "contextUsage":
            guard let owner = owner(session), owner.desktop, let host = owner.host else {
                throw CLIError(
                    L10n.text("provider.the_session_is_not_open_in_claude_desktop_so_accurate_context_usage_is_unava"))
            }
            let result = try ClaudeDesktop.contextUsage(host: host)
            desktopControls[session] = result.controls.withModels(desktopControls[session]?.models ?? [])
            return [
                "threadId": session, "summary": result.controls.contextUsage, "detail": result.detail,
                "composer": composer(session, owner: owner),
            ]
        case "approvalDetails":
            guard
                let approval = approvals(session).first(where: {
                    $0["fingerprint"] as? String == request["fingerprint"] as? String
                })
            else { throw CLIError(L10n.text("provider.the_approval_was_resolved_or_changed_refresh_to_continue")) }
            return ["threadId": session, "approval": approval]
        case "appshotApps": return ["apps": CodexAppshot.apps()]
        case "appshot":
            guard let attachments, let bundle = request["bundleID"] as? String,
                let id = request["attachmentId"] as? String
            else { throw CLIError(L10n.text("session.choose_an_application")) }
            let bytes = try CodexAppshot.capture(bundleID: bundle)
            _ = try attachments.start(
                ["attachmentId": id, "name": bundle + ".jpg", "mime": "image/jpeg", "size": bytes.count],
                device: client, thread: session)
            for offset in stride(from: 0, to: bytes.count, by: 128 * 1024) {
                _ = try attachments.chunk(
                    [
                        "attachmentId": id, "offset": offset,
                        "data": bytes.subdata(in: offset..<min(offset + 128 * 1024, bytes.count)).base64EncodedString(),
                    ], device: client, thread: session)
            }
            return try attachments.complete(
                ["attachmentId": id, "sha256": CodexConversation.dataHash(bytes)], device: client, thread: session)
        case "attachmentPreview", "attachmentStart", "attachmentChunk", "attachmentComplete", "attachmentReference":
            guard let attachments else {
                throw CLIError(L10n.text("session.attachment_storage_is_unavailable_check_on_the_mac"))
            }
            switch op {
            case "attachmentPreview":
                return try attachments.preview(
                    request["attachmentId"] as? String ?? "", device: client, thread: session)
            case "attachmentStart": return try attachments.start(request, device: client, thread: session)
            case "attachmentChunk": return try attachments.chunk(request, device: client, thread: session)
            case "attachmentComplete": return try attachments.complete(request, device: client, thread: session)
            default:
                return try attachments.reference(
                    request["path"] as? String ?? "", cwd: cwd, id: request["attachmentId"] as? String ?? "",
                    device: client, thread: session)
            }
        case "settings":
            if let owner = owner(session), owner.desktop, let host = owner.host {
                guard let operation = request["id"] as? String, UUID(uuidString: operation) != nil else {
                    throw CLIError(L10n.text("provider.invalid_settings_request"))
                }
                let model = request["model"] as? String
                let effort = request["effort"] as? String
                let mode = request["mode"] as? String
                guard model != nil || effort != nil || mode != nil else {
                    throw CLIError(L10n.text("provider.no_settings_to_change"))
                }
                if let mode {
                    guard Self.modes.contains(mode) else {
                        throw CLIError(L10n.text("provider.unsupported_permission_mode"))
                    }
                    guard mode != "bypassPermissions" || request["confirmFullAccess"] as? Bool == true else {
                        throw CLIError(L10n.text("provider.bypassing_permissions_requires_explicit_confirmation"))
                    }
                }
                if let model {
                    guard desktopControls[session]?.models.contains(model) == true else {
                        throw CLIError(
                            L10n.text("provider.reopen_the_model_menu_and_select_a_model_available_on_the_desktop"))
                    }
                }
                if let effort {
                    let targetModel = model ?? desktopControls[session]?.model ?? ""
                    guard ClaudeDesktop.efforts(for: targetModel).contains(effort) else {
                        throw CLIError(
                            L10n.text("provider.this_desktop_model_does_not_support_the_selected_reasoning_effort"))
                    }
                }
                let choices = desktopControls[session]?.models ?? []
                try DesktopMutationScope.run { mutation in
                    try ScreenLock.unlocked {
                        if let model {
                            desktopControls[session] = try ClaudeDesktop.selectModel(
                                model, host: host, mutation: mutation
                            ).withModels(choices)
                        }
                        if let effort, effort != "default" {
                            desktopControls[session] = try ClaudeDesktop.selectEffort(
                                effort, host: host, mutation: mutation
                            ).withModels(
                                choices)
                        }
                        if let mode {
                            desktopControls[session] = try ClaudeDesktop.selectMode(
                                mode, host: host, mutation: mutation
                            ).withModels(choices)
                        }
                    }
                }
                schedule(session)
                return ["accepted": true, "threadId": session, "composer": composer(session, owner: owner)]
            }
            let next = try ClaudeSessionConfiguration.resolve(request, current: selection(session))
            let previous = settings[session]
            settings[session] = next
            do { try saveSettings() } catch {
                settings[session] = previous
                throw CLIError(L10n.text("provider.could_not_save_session_settings"))
            }
            schedule(session)
            return ["accepted": true, "threadId": session]
        case "interrupt":
            if runs[session] == nil, let owner = owner(session), owner.desktop, owner.busy, let host = owner.host {
                refresh(session)
                guard let expected = request["expectedTurnId"] as? String,
                    expected == ClaudeSendReceipt.activeTurn(entries: transcripts[session]?.entries ?? [], host: host)
                else { throw CLIError(L10n.text("session.the_running_task_changed_the_new_task_was_not_stopped")) }
                func sameTurn() -> Bool {
                    self.refresh(session)
                    return expected
                        == ClaudeSendReceipt.activeTurn(entries: self.transcripts[session]?.entries ?? [], host: host)
                }
                try ScreenLock.unlocked {
                    try ClaudeDesktop.interrupt(
                        host: host,
                        isCurrent: {
                            sameTurn() && self.owner(session)?.host == host && self.owner(session)?.busy == true
                        },
                        confirmed: { seconds in
                            self.waitFor(seconds) {
                                self.refresh(session)
                                return self.owner(session)?.host == host && self.owner(session)?.busy == false
                                    && ClaudeSendReceipt.stoppedTurn(
                                        entries: self.transcripts[session]?.entries ?? [], host: host,
                                        expected: expected)
                            }
                        })
                }
                schedule(session)
                return ["accepted": true, "threadId": session]
            }
            guard let run = runs[session] else {
                throw CLIError(L10n.text("session.there_is_no_running_task_in_this_session"))
            }
            guard request["expectedTurnId"] as? String == run.token else {
                throw CLIError(L10n.text("session.the_running_task_changed_the_new_task_was_not_stopped"))
            }
            run.process.interrupt()
            queue.asyncAfter(deadline: .now() + 3) { if run.process.isRunning { run.process.terminate() } }
            return ["accepted": true, "threadId": session]
        case "send":
            guard let ticket else { throw CLIError(L10n.text("core.invalid_request")) }
            let text = (request["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let attachmentIDs = request["attachments"] as? [String] ?? []
            guard !text.isEmpty || !attachmentIDs.isEmpty, text.utf8.count <= 32_000,
                let operation = request["id"] as? String, UUID(uuidString: operation) != nil
            else { throw CLIError(L10n.text("session.the_reply_must_not_be_empty_or_exceed_32_kb")) }
            guard runs[session] == nil else {
                throw CLIError(L10n.text("provider.claude_code_is_working_wait_for_it_to_finish_or_stop_it_first"))
            }
            guard let attachments else { throw CLIError(L10n.text("session.attachment_storage_is_unavailable")) }
            let files = try attachments.selected(attachmentIDs, device: client, thread: session)
            let references = (files.images + files.files).compactMap { item -> String? in
                guard let path = item["path"] as? String else { return nil }
                return L10n.text(
                    "session.user_attached_file_0_local_path_on_the_mac_1", item["label"] as? String ?? "", path)
            }
            let prompt = ([text] + references).filter { !$0.isEmpty }.joined(separator: "\n\n")
            if let owner = owner(session) {
                // Resuming headlessly next to a live process forks the session and never shows up there, so type into it instead.
                guard owner.desktop, let host = owner.host else {
                    throw CLIError(
                        L10n.text(
                            "provider.this_session_is_running_in_claude_code_in_a_mac_terminal_continue_there_to_a"))
                }
                return try deliverDesktop(prompt, session: session, host: host, ticket: ticket)
            }
            if ClaudeDesktop.running {
                // Nothing has it open: continue it in the desktop app (importing it first) so it shows up there, not as a headless run.
                return try ScreenLock.unlocked {
                    try deliverDesktop(
                        prompt, session: session, host: ClaudeDesktop.adopt(session), ticket: ticket)
                }
            }
            try launch(session, prompt: prompt, cwd: cwd, operation: operation, client: client)
            return ["accepted": true, "threadId": session]
        case "approve":
            let fingerprint = request["fingerprint"] as? String ?? ""
            let allow = request["allow"] as? Bool
            let option = request["option"] as? String
            guard let operation = request["id"] as? String, UUID(uuidString: operation) != nil,
                allow != nil || !(option ?? "").isEmpty
            else { throw CLIError(L10n.text("provider.invalid_approval_request")) }
            guard let owner = owner(session), owner.desktop, let host = owner.host else {
                throw CLIError(L10n.text("provider.the_session_is_not_open_in_claude_desktop_handle_it_on_the_mac"))
            }
            refresh(session)
            guard let approval = approvals(session).first(where: { $0["fingerprint"] as? String == fingerprint }),
                let requestID = approval["requestId"] as? String
            else {
                throw CLIError(L10n.text("provider.the_approval_was_resolved_or_changed_refresh_to_continue"))
            }
            guard approval["canDecide"] as? Bool == true else {
                throw CLIError(L10n.text("provider.this_request_must_be_handled_on_the_mac"))
            }
            // The desktop shows one card at a time; with several open the visible button may belong to another request.
            guard permissions.log.pending.filter({ $0.host == host }).count == 1 else {
                throw CLIError(L10n.text("provider.multiple_desktop_approvals_are_pending_handle_them_on_the_mac"))
            }
            func stillPending() -> Bool {
                self.refresh(session)
                let matching = self.approvals(session).filter {
                    $0["fingerprint"] as? String == fingerprint && $0["requestId"] as? String == requestID
                }
                return matching.count == 1 && self.permissions.log.pending.filter { $0.host == host }.count == 1
            }
            if let options = approval["options"] as? [String] {
                guard let option, options.contains(option) else {
                    throw CLIError(L10n.text("provider.select_a_valid_option"))
                }
                try ScreenLock.unlocked {
                    try ClaudeDesktop.answerQuestion(option: option, host: host, stillPending: stillPending) {
                        self.permissions.waitAnswered(requestID, decision: "once", seconds: $0)
                    }
                }
            } else {
                guard let allow else { throw CLIError(L10n.text("provider.invalid_approval_request")) }
                try ScreenLock.unlocked {
                    try ClaudeDesktop.answerPermission(
                        allow: allow, plan: approval["plan"] as? Bool == true, host: host, stillPending: stillPending
                    ) { self.permissions.waitAnswered(requestID, decision: allow ? "once" : "deny", seconds: $0) }
                }
            }
            refresh(session)
            schedule(session)
            return ["submitted": true, "threadId": session, "fingerprint": fingerprint]
        default: throw CLIError(L10n.text("session.unsupported_session_operation"))
        }
    }
    private func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    private func deliverDesktop(
        _ prompt: String, session: String, host: String, ticket: ProviderOperationReceipts.Ticket
    ) throws -> [String: Any] {
        var receipt: ClaudeSendReceipt?
        var incarnation: UUID?
        var nativeID: String?
        try ScreenLock.unlocked {
            try ClaudeDesktop.deliver(
                prompt, host: host,
                willSubmit: {
                    self.refresh(session)
                    guard let transcript = self.transcripts[session] else {
                        throw CLIError(L10n.text("session.the_session_is_not_ready_reopen_it"))
                    }
                    let proof = ClaudeSendReceipt(entries: transcript.entries, text: prompt)
                    let original = transcript.incarnation
                    receipt = proof
                    incarnation = original
                    try self.operationReceipts.observe(ticket, bytes: proof.retainedBytes) { [weak self] in
                        guard let self else { return nil }
                        self.refresh(session)
                        guard let current = self.transcripts[session], current.incarnation == original,
                            let id = proof.confirmedMessage(in: current.entries)
                        else { return nil }
                        return [
                            "ok": true, "accepted": true, "threadId": session, "delivery": "desktop",
                            "nativeMessageId": id,
                        ]
                    }
                },
                confirmed: { seconds in
                    self.operationReceipts.arm(ticket)
                    return self.waitFor(seconds) {
                        self.refresh(session)
                        guard let incarnation, self.transcripts[session]?.incarnation == incarnation else {
                            return false
                        }
                        nativeID = receipt?.confirmedMessage(in: self.transcripts[session]?.entries ?? [])
                        return nativeID != nil
                    }
                })
        }
        guard let nativeID else {
            throw UnconfirmedDesktopMutation(reason: L10n.text("provider.claude_send_receipt_missing"))
        }
        runErrors.removeValue(forKey: session)
        schedule(session)
        return ["accepted": true, "threadId": session, "delivery": "desktop", "nativeMessageId": nativeID]
    }
    /// Open desktop permission requests of this session, with full details; empty unless the desktop app owns it.
    private func approvals(_ session: String) -> [[String: Any]] {
        guard let owner = owner(session), owner.desktop, let host = owner.host,
            let entries = transcripts[session]?.entries
        else { return [] }
        permissions.update()
        let cwd = entries.lazy.compactMap { $0["cwd"] as? String }.last ?? ""
        return ClaudePermissions.approvals(entries, requests: permissions.log.pending, host: host, cwd: cwd)
    }
    /// A live Claude Code process other than our own headless runs that has this session open, desktop app first.
    private func owner(_ session: String) -> ClaudeDesktop.Owner? {
        ClaudeDesktop.owners(session, excluding: Set(runs.values.map { $0.process.processIdentifier })).first
    }
    /// `claude-opus-5-5` → `Opus 5.5`, `claude-haiku-4-5-20251001` → `Haiku 4.5`.
    static func modelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first, !family.isEmpty else { return id }
        return
            ([family.prefix(1).uppercased() + family.dropFirst()]
            + (parts.count > 1 ? [parts.dropFirst().joined(separator: ".")] : [])).joined(separator: " ")
    }
    /// The model the session is on: a later `/model` result wins over the model of the latest reply.
    private func currentModel(_ session: String) -> (label: String, alias: String)? {
        let entries = transcripts[session]?.entries ?? []
        let reply = entries.indices.reversed().lazy.compactMap { index -> (Int, String)? in
            guard entries[index]["type"] as? String == "assistant",
                let model = (entries[index]["message"] as? [String: Any])?["model"] as? String,
                model.hasPrefix("claude")
            else { return nil }
            return (index, model)
        }.first
        if let switched = ClaudeTranscript.command("model", in: entries, after: (reply?.0 ?? -1) + 1),
            let label = switched.output.split(separator: "`").dropFirst().first.map(String.init)
        {
            return (label.replacingOccurrences(of: " (default)", with: ""), switched.args.lowercased())
        }
        guard let reply else { return nil }
        let label = Self.modelName(reply.1)
        return (label, label.split(separator: " ").first.map { $0.lowercased() } ?? "")
    }
    private func currentEffort(_ session: String) -> String {
        let args = ClaudeTranscript.command("effort", in: transcripts[session]?.entries ?? [])?.args.lowercased() ?? ""
        return Self.efforts.contains(args) ? args : "default"
    }
    private func composer(_ session: String, owner: ClaudeDesktop.Owner?) -> [String: Any] {
        var value: [String: Any] = selection(session)
        let current = currentModel(session)
        if owner?.desktop == true {
            if let host = owner?.host, let visible = ClaudeDesktop.visibleControls(host: host) {
                desktopControls[session] = visible.withModels(desktopControls[session]?.models ?? [])
            }
            let live = desktopControls[session]
            value["model"] = live?.model ?? current?.label ?? "default"
            value["modelLabel"] = live?.model ?? current?.label ?? L10n.text("provider.desktop_model")
            value["effort"] = live?.effort ?? currentEffort(session)
            value["mode"] = live?.mode ?? value["mode"]
            value["contextUsage"] = live?.contextUsage ?? ""
            value["modeLocked"] = false
        } else if value["model"] as? String == "default", let current {
            value["modelLabel"] = current.label
        }
        return value
    }
    private func models(_ session: String) -> [[String: Any]] {
        if let live = desktopControls[session], owner(session)?.desktop == true {
            return live.models.map {
                ["id": $0, "name": $0, "efforts": ClaudeDesktop.efforts(for: $0), "defaultEffort": "medium"]
            }
        }
        guard let current = currentModel(session)?.label else { return Self.models }
        return Self.models.map { entry in
            var entry = entry
            if entry["id"] as? String == "default" {
                entry["name"] = L10n.text("provider.default_currently_0", current)
            }
            return entry
        }
    }
    private func selection(_ session: String) -> [String: String] {
        var value = settings[session] ?? [:]
        if value["mode"] == nil {
            let recent =
                transcripts[session]?.entries.last(where: { $0["permissionMode"] is String })?["permissionMode"]
                as? String ?? ""
            value["mode"] = Self.modes.contains(recent) ? recent : "acceptEdits"
        }
        return [
            "model": value["model"] ?? "default", "effort": value["effort"] ?? "default",
            "mode": value["mode"] ?? "acceptEdits",
        ]
    }
    private func saveSettings() throws {
        try FileManager.default.createDirectory(
            at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: settingsFile, options: .atomic)
    }
    private func launch(
        _ session: String, prompt: String, cwd: String, operation: String, client: String, fresh: Bool = false,
        streamInput: Data? = nil
    ) throws {
        guard
            case .accepted(let admission) = processBudget.begin(
                device: client, id: operation, bytes: streamInput?.count ?? prompt.utf8.count)
        else { throw CLIError(L10n.text("provider.claude_process_capacity")) }
        let budget = processBudget
        var launched = false
        defer { if !launched { budget.finish(admission) } }
        guard let executable = processExecutable ?? Self.executable() else {
            throw CLIError(L10n.text("provider.the_claude_command_was_not_found_install_claude_code_on_the_mac_first"))
        }
        guard FileManager.default.fileExists(atPath: cwd) else {
            throw CLIError(L10n.text("provider.the_session_directory_no_longer_exists_0", cwd))
        }
        let choice = selection(session)
        var arguments = [
            "-p", fresh ? "--session-id" : "--resume", session, "--output-format", "stream-json", "--verbose",
            "--permission-mode", choice["mode"] ?? "acceptEdits",
        ]
        if let model = choice["model"], model != "default" { arguments += ["--model", model] }
        if let effort = choice["effort"], effort != "default" { arguments += ["--effort", effort] }
        if streamInput != nil { arguments += ["--input-format", "stream-json"] }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CLAUDECODE") || key == "CLAUDE_CODE_ENTRYPOINT" {
            environment.removeValue(forKey: key)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = [
            "/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            environment["PATH"] ?? "",
        ].joined(separator: ":")
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let token = UUID().uuidString
        let collected = ClaudeProcessOutput()
        collected.startReading(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
        process.terminationHandler = { [weak self] finished in
            // A phone disconnect or an early request receipt must not release a still-running child.
            // Capture the budget independently of the bridge so destruction cannot leak the admission.
            defer { budget.finish(admission) }
            let failure = collected.failure(
                status: finished.terminationStatus, interrupted: finished.terminationReason == .uncaughtSignal)
            collected.stopReading(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
            self?.queue.async { [weak self] in
                guard let self, self.runs[session]?.token == token else { return }
                self.runs.removeValue(forKey: session)
                if fresh, failure == nil, ClaudeDesktop.running, self.owner(session) == nil {
                    DispatchQueue.global().async { _ = try? ClaudeDesktop.adopt(session, restoreFocus: true) }
                }
                if let failure {
                    self.runErrors[session] = [
                        "id": "run-error-" + token, "role": "assistant", "text": "⚠️ " + failure,
                        "parts": [
                            ConversationReply.Part(
                                id: "run-error-part-" + token, kind: "notice", title: L10n.text("provider.run_failed"),
                                status: "failed",
                                text: failure, extra: ["groupType": "notice:run-error"]
                            ).value
                        ],
                    ]
                }
                self.refresh(session)
                self.schedule(session)
            }
        }
        do { try process.run() } catch {
            collected.stopReading(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
            throw error
        }
        launched = true
        // The parent must not keep the child's pipe ends open, otherwise EOF cannot complete.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        runs[session] = Run(token: token, process: process, operation: operation)
        if let streamInput {
            ClaudeProcessInput.write(streamInput, to: input.fileHandleForWriting) { succeeded in
                guard !succeeded, process.isRunning else { return }
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
        } else {
            defer { try? input.fileHandleForWriting.close() }
            do {
                try UnconfirmedDesktopMutation.attempting {
                    try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                }
            } catch {
                if process.isRunning { process.terminate() }
                throw error
            }
        }
        runErrors.removeValue(forKey: session)
        schedule(session)
    }
    private func projected(_ session: String) -> [[[String: Any]]] {
        guard let transcript = transcripts[session] else { return [] }
        if let cached = transcript.projected { return cached }
        let rows = ClaudeTranscript.turns(transcript.entries)
        transcripts[session]?.projected = rows
        return rows
    }
    private func makePage(_ session: String) -> [String: Any] {
        let entries = transcripts[session]?.entries ?? []
        var page = ClaudeTranscript.page(entries, projected: projected(session))
        if let failure = runErrors[session] {
            page["messages"] = (page["messages"] as? [[String: Any]] ?? []) + [failure]
        }
        page["threadId"] = session
        page["title"] = ClaudeTranscript.title(entries)
        let owner = owner(session)
        let desktopTurn =
            owner?.desktop == true && owner?.busy == true
            ? owner?.host.flatMap { ClaudeSendReceipt.activeTurn(entries: entries, host: $0) } : nil
        page["status"] = runs[session] != nil || owner?.busy == true ? "active" : "idle"
        page["activeTurnId"] = runs[session]?.token ?? desktopTurn ?? ""
        if let blocker = ClaudeTranscript.blocker(entries) { page["blocker"] = blocker }
        page["composer"] = composer(session, owner: owner)
        page["revision"] = revisions[session] ?? 0
        page["canSend"] = Self.executable() != nil || owner?.desktop == true
        var capabilities = page["capabilities"] as? [String: Any] ?? [:]
        capabilities["markdownFiles"] = true
        capabilities["projectFiles"] = true
        page["capabilities"] = capabilities
        if let owner { page["owner"] = owner.desktop ? "desktop" : "terminal" }
        // Details can be whole files; the phone fetches them when the card is opened.
        page["approvals"] = approvals(session).map { item -> [String: Any] in
            var row = item
            row.removeValue(forKey: "details")
            row["detailsOnDemand"] = true
            return row
        }
        return ConversationReply.versioned(page)
    }
    /// Reads only bytes appended since the previous read; a truncated or replaced file is re-read from the start.
    private func refresh(_ session: String) {
        guard var transcript = transcripts[session] else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: transcript.url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            transcripts[session] = Transcript(url: transcript.url)
            return
        }
        if inode != transcript.inode || size < transcript.offset {
            transcript = Transcript(url: transcript.url)
            transcript.inode = inode
        }
        guard size > transcript.offset, let handle = try? FileHandle(forReadingFrom: transcript.url) else {
            transcripts[session] = transcript
            return
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: transcript.offset)
        let data = transcript.remainder + (handle.readDataToEndOfFile())
        transcript.offset += UInt64(data.count - transcript.remainder.count)
        let complete = data.lastIndex(of: UInt8(ascii: "\n")).map { data[data.startIndex...$0] } ?? Data()
        transcript.remainder = Data(data[(complete.endIndex)...])
        transcript.entries += Self.parse(Data(complete))
        transcript.projected = nil
        transcripts[session] = transcript
        revisions[session] = (revisions[session] ?? 0) + 1
    }
    private func watch(_ session: String) {
        guard let url = transcripts[session]?.url else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                source.cancel()
                self.watchers.removeValue(forKey: session)
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    if self.selected.values.contains(session) {
                        self.watch(session)
                        self.refresh(session)
                        self.schedule(session)
                    }
                }
                return
            }
            self.refresh(session)
            self.schedule(session)
        }
        source.setCancelHandler { close(descriptor) }
        watchers[session]?.cancel()
        watchers[session] = source
        source.resume()
    }
    /// Desktop and terminal processes register and update `~/.claude/sessions/<pid>.json`; refresh open pages on change.
    private func watchRegistry() {
        guard registryWatcher == nil else { return }
        let descriptor = open(ClaudeDesktop.sessionsDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            for session in Set(self.selected.values) { self.schedule(session) }
        }
        source.setCancelHandler { close(descriptor) }
        registryWatcher = source
        source.resume()
    }
    private func unsubscribe(_ client: String) {
        markdownFiles.remove(device: client)
        defer {
            if selected.isEmpty {
                registryWatcher?.cancel()
                registryWatcher = nil
            }
        }
        guard let session = selected.removeValue(forKey: client) else { return }
        emittedPages.removeValue(forKey: client)
        updateIntervals.removeValue(forKey: client)
        // A running turn keeps its transcript so completion still clears state; it never stops the run.
        if !selected.values.contains(session) {
            watchers.removeValue(forKey: session)?.cancel()
            if runs[session] == nil {
                transcripts.removeValue(forKey: session)
                revisions.removeValue(forKey: session)
            }
        }
    }
    /// Coalesces bursts of transcript writes into one page or delta per 250 ms, like the Codex bridge.
    private func schedule(_ session: String) {
        guard scheduled.insert(session).inserted else { return }
        let clients = selected.filter { $0.value == session }.map(\.key)
        let delay =
            clients.contains { emittedPages[$0] == nil } ? 0 : clients.compactMap { updateIntervals[$0] }.min() ?? 0.25
        queue.asyncAfter(deadline: .now() + delay) {
            self.scheduled.remove(session)
            guard self.transcripts[session] != nil else { return }
            self.revisions[session] = (self.revisions[session] ?? 0) + 1
            for (client, selected) in self.selected where selected == session {
                var result = self.makePage(session)
                result["viewVersion"] = self.viewVersions[client]
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
                    result["event"] = "snapshot"
                }
                self.emittedPages[client] = full
                if let data = try? JSONSerialization.data(withJSONObject: result) { self.event?(client, data) }
            }
            // The desktop's busy → idle flip may land after its last transcript write, so recheck while it runs.
            if self.runs[session] == nil, self.owner(session)?.busy == true, self.selected.values.contains(session) {
                self.queue.asyncAfter(deadline: .now() + 3) { self.schedule(session) }
            }
        }
    }
}
