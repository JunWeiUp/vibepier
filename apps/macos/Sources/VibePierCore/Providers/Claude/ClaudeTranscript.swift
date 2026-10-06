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
            text = humanText(blocks)
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
    /// The person's typed text. Claude Desktop prepends a separate `<system-reminder>` block to the first message it
    /// sends after adopting a CLI session; that injected block is context, not something the person wrote.
    static func humanText(_ blocks: [[String: Any]]) -> String {
        blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
            return injectedReminder(text) ? nil : text
        }.joined(separator: "\n")
    }
    static func injectedReminder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<system-reminder>") && trimmed.hasSuffix("</system-reminder>")
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
