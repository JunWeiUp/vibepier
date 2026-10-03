import Foundation

/// The Claude desktop app answers tool permissions in its own UI; its main log is the only outside record of which
/// requests are open. Each request also leaves a `tool_use` without a `tool_result` in the session transcript,
/// which supplies the details and keeps a lost log line from showing a stale prompt.
struct ClaudePermissionLog {
    struct Request: Equatable {
        let id: String
        let tool: String
        let host: String
    }
    private(set) var pending: [Request] = []
    private(set) var answers: [String: String] = [:]
    private var answerOrder: [String] = []

    private mutating func answer(_ id: String, decision: String) {
        guard pending.contains(where: { $0.id == id }), ["once", "deny"].contains(decision) else { return }
        answers[id] = decision
        answerOrder.append(id)
        if answerOrder.count > 128 { answers.removeValue(forKey: answerOrder.removeFirst()) }
    }

    mutating func consume(_ text: Substring) {
        for line in text.split(separator: "\n") { consume(line: line) }
    }
    mutating func consume(line: Substring) {
        if let start = line.range(of: "Emitted tool permission request ") {
            // `<id> for <tool> in session <host>`
            let parts = line[start.upperBound...].split(separator: " ")
            guard parts.count >= 6, parts[1] == "for", parts[3] == "in", parts[4] == "session",
                parts[5].hasPrefix("local_")
            else { return }
            let request = Request(id: String(parts[0]), tool: String(parts[2]), host: String(parts[5]))
            pending.removeAll { $0.id == request.id }
            answers.removeValue(forKey: request.id)
            answerOrder.removeAll { $0 == request.id }
            pending.append(request)
            if pending.count > 64 { pending.removeFirst(pending.count - 64) }
        } else if let start = line.range(of: "Received permission response for ") {
            let id = line[start.upperBound...].prefix { $0 != ":" && $0 != " " }
            let suffix = line[start.upperBound...].dropFirst(id.count)
            let decision = suffix.drop(while: { $0 == ":" || $0 == " " }).prefix { $0 != " " && $0 != "," }
            answer(String(id), decision: String(decision))
            pending.removeAll { $0.id == id }
        } else if let start = line.range(of: "respondToToolPermission: requestId=") {
            let id = line[start.upperBound...].prefix { $0 != "," && $0 != " " }
            if let decisionStart = line.range(of: ", decision=") {
                let decision = line[decisionStart.upperBound...].prefix { $0 != "," && $0 != " " }
                answer(String(id), decision: String(decision))
            }
            pending.removeAll { $0.id == id }
        } else if let start = line.range(of: "Permission request "), line.contains(" aborted") {
            let id = line[start.upperBound...].prefix { $0 != " " }
            pending.removeAll { $0.id == id }
        }
    }
}

/// Follows the desktop main log by byte offset; only appended bytes are read, so checking it on every page is cheap.
final class ClaudePermissionTail {
    static var defaultFiles: [URL] {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return [logs.appendingPathComponent("Claude-3p/main.log"), logs.appendingPathComponent("Claude/main.log")]
    }
    private let files: [URL]
    private var url: URL?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var remainder = Data()
    private(set) var log = ClaudePermissionLog()
    init(files: [URL] = ClaudePermissionTail.defaultFiles) { self.files = files }

    /// The log most recently written; requests still open were emitted within the last stretch of it.
    func update() {
        let candidates = files.compactMap { file -> (URL, UInt64, UInt64, Date)? in
            guard let values = try? FileManager.default.attributesOfItem(atPath: file.path),
                let size = (values[.size] as? NSNumber)?.uint64Value,
                let node = (values[.systemFileNumber] as? NSNumber)?.uint64Value,
                let modified = values[.modificationDate] as? Date
            else { return nil }
            return (file, size, node, modified)
        }
        guard let (file, size, node, _) = candidates.max(by: { $0.3 < $1.3 }) else { return }
        if file != url || node != inode || size < offset {
            url = file
            inode = node
            remainder = Data()
            log = ClaudePermissionLog()
            offset = size > 1_048_576 ? size - 1_048_576 : 0
            if offset > 0 { skipPartialLine = true }
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var data = remainder + handle.readDataToEndOfFile()
        offset += UInt64(data.count - remainder.count)
        if skipPartialLine, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = Data(data[data.index(after: newline)...])
            skipPartialLine = false
        }
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else {
            remainder = data
            return
        }
        remainder = Data(data[data.index(after: end)...])
        log.consume(Substring(String(decoding: data[data.startIndex...end], as: UTF8.self)))
    }
    private var skipPartialLine = false

    /// Waits for the desktop to log an answer to `id`.
    func waitAnswered(_ id: String, decision: String, seconds: Double) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            update()
            if log.answers[id] == decision { return true }
            if ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.15) }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
}

enum ClaudePermissions {
    struct ToolUse {
        let id: String
        let name: String
        let input: [String: Any]
    }
    struct Question {
        let text: String
        let options: [String]
    }
    /// A single-select `AskUserQuestion` call the phone can answer by picking one option; anything else (several
    /// questions, multi-select, malformed or duplicate options) stays Mac-only.
    static func question(_ use: ToolUse) -> Question? {
        guard use.name == "AskUserQuestion", let questions = use.input["questions"] as? [[String: Any]],
            questions.count == 1,
            let question = questions.first, question["multiSelect"] as? Bool != true,
            let text = (question["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty,
            let optionsRaw = question["options"] as? [[String: Any]], (1...8).contains(optionsRaw.count)
        else { return nil }
        let labels = optionsRaw.compactMap { ($0["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard labels.count == optionsRaw.count, Set(labels).count == labels.count else { return nil }
        return Question(text: text, options: labels)
    }
    /// Tool calls of the main conversation that have no result yet, oldest first.
    static func unresolved(_ entries: [[String: Any]]) -> [ToolUse] {
        var uses: [ToolUse] = []
        var results = Set<String>()
        for entry in entries where entry["isSidechain"] as? Bool != true {
            guard let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String,
                    let name = block["name"] as? String
                {
                    uses.append(ToolUse(id: id, name: name, input: block["input"] as? [String: Any] ?? [:]))
                } else if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                    results.insert(id)
                }
            }
        }
        return uses.filter { !results.contains($0.id) }
    }
    /// Pairs each open request of this desktop session with its pending tool call, in order, by tool name.
    static func approvals(
        _ entries: [[String: Any]], requests: [ClaudePermissionLog.Request], host: String, cwd: String
    ) -> [[String: Any]] {
        var open = unresolved(entries)
        return requests.filter { $0.host == host }.compactMap { request in
            guard let index = open.firstIndex(where: { $0.name == request.tool }) else { return nil }
            let use = open.remove(at: index)
            let input = (try? JSONSerialization.data(withJSONObject: use.input, options: [.sortedKeys])) ?? Data()
            let details = Self.details(use, cwd: cwd)
            let question = Self.question(use)
            // A question with options the phone can pick from is decidable; any other question needs the Mac.
            let decidable = question != nil || (use.name != "AskUserQuestion" && details.count <= 60_000)
            let plan = use.name == "ExitPlanMode"
            var row: [String: Any] = [
                "id": request.id,
                "fingerprint": CodexConversation.dataHash(Data((request.id + "|" + use.id + "|").utf8) + input),
                "title": title(use.name), "details": String(details.prefix(60_000)), "canDecide": decidable,
                "requestId": request.id, "toolUseId": use.id, "plan": plan,
                "allowLabel": plan ? L10n.text("provider.approve_plan") : L10n.text("provider.allow_once"),
                "denyLabel": plan ? L10n.text("provider.reject_plan") : L10n.text("control.deny"),
            ]
            if let question {
                row["question"] = question.text
                row["options"] = question.options
            }
            return row
        }
    }
    static func title(_ tool: String) -> String {
        switch tool {
        case "Bash": return L10n.text("session.run_command")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return L10n.text("session.edit_files")
        case "Read": return L10n.text("provider.read_file")
        case "WebFetch", "WebSearch": return L10n.text("provider.access_network")
        case "AskUserQuestion": return L10n.text("provider.answer_question")
        case "ExitPlanMode": return L10n.text("provider.confirm_plan")
        default:
            if tool.hasPrefix("mcp__") {
                return L10n.text("provider.use_tool") + (tool.split(separator: "_").last.map(String.init) ?? tool)
            }
            return L10n.text("provider.use") + tool
        }
    }
    static func details(_ use: ToolUse, cwd: String) -> String {
        var lines = [L10n.text("provider.tool") + use.name, L10n.text("provider.working_directory") + cwd]
        let input = use.input
        switch use.name {
        case "Bash":
            lines.append(L10n.text("provider.command") + (input["command"] as? String ?? ""))
            if let description = input["description"] as? String, !description.isEmpty {
                lines.append(L10n.text("provider.description") + description)
            }
        case "Edit":
            lines.append(L10n.text("provider.file") + (input["file_path"] as? String ?? ""))
            lines.append(L10n.text("provider.before") + (input["old_string"] as? String ?? ""))
            lines.append(L10n.text("provider.after") + (input["new_string"] as? String ?? ""))
            if input["replace_all"] as? Bool == true { lines.append(L10n.text("provider.scope_all_matches")) }
        case "Write":
            lines.append(L10n.text("provider.file") + (input["file_path"] as? String ?? ""))
            lines.append(L10n.text("provider.content") + (input["content"] as? String ?? ""))
        case "ExitPlanMode":
            lines.append(L10n.text("provider.plan") + (input["plan"] as? String ?? ""))
            lines.append(
                L10n.text("provider.approve_matches_desktop_accept_and_keeps_the_current_permission_mode_reject_"))
            return lines.joined(separator: "\n\n")
        case "AskUserQuestion":
            if let question = Self.question(use) {
                lines.append(L10n.text("provider.question") + question.text)
                lines.append(L10n.text("provider.options") + question.options.map { "- " + $0 }.joined(separator: "\n"))
                return lines.joined(separator: "\n\n")
            }
        default:
            let data =
                (try? JSONSerialization.data(
                    withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            lines.append(L10n.text("session.arguments") + String(decoding: data, as: UTF8.self))
        }
        lines.append(L10n.text("provider.applies_once_like_desktop_allow_once_no_lasting_permission_is_saved"))
        return lines.joined(separator: "\n\n")
    }
}
