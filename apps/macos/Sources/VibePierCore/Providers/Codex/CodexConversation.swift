import CryptoKit
import Foundation

/// The desktop's snapshot is private and versioned; only the conversation — messages and the steps of each reply — leaves this adapter.
enum CodexConversation {
    static func turns(_ state: [String: Any]) -> [[String: Any]] {
        if let history = (state["turnHistory"] as? [String: Any])?["history"] as? [String: Any],
            let entities = history["entitiesByKey"] as? [String: Any],
            let islands = history["islands"] as? [[String: Any]]
        {
            var seen = Set<String>()
            return islands.flatMap { $0["entries"] as? [[String: Any]] ?? [] }.compactMap {
                guard let key = $0["value"] as? String, seen.insert(key).inserted else { return nil }
                return entities[key] as? [String: Any]
            }
        }
        return state["turns"] as? [[String: Any]] ?? []
    }
    /// Desktop form replies and page context are transport wrappers, not user-facing chat text.
    static func displayText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = "<send_user_message_question_reply>"
        let end = "</send_user_message_question_reply>"
        if text.hasPrefix(start), text.hasSuffix(end) {
            let payload = String(text.dropFirst(start.count).dropLast(end.count)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            if let data = payload.data(using: .utf8),
                let answers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            {
                let lines = answers.compactMap { item -> String? in
                    guard let answer = item["answer"] as? String else { return nil }
                    let question = item["question"] as? String ?? ""
                    return question.isEmpty
                        ? answer
                        : question.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(
                            separator: "\n") + "\n\n" + answer
                }
                if lines.count == answers.count { return lines.joined(separator: "\n\n") }
            }
        }
        let contextStart = "<external_codex_apps_open_page>"
        let contextEnd = "</external_codex_apps_open_page>"
        if text.hasPrefix(contextStart), let endRange = text.range(of: contextEnd) {
            let payload = String(text[text.index(text.startIndex, offsetBy: contextStart.count)..<endRange.lowerBound])
            if let bytes = payload.data(using: .utf8), (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any]
            {
                text = String(text[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
    /// The person's messages and, after each, one reply holding every step of the turn in desktop order.
    static func messages(_ turn: [String: Any]) -> [[String: Any]] {
        var builder = ConversationReply.Builder()
        let turnID = turn["turnId"] as? String ?? turn["id"] as? String ?? ""
        for (index, item) in (turn["items"] as? [[String: Any]] ?? []).enumerated() {
            let type = item["type"] as? String ?? ""
            let id = item["id"] as? String ?? "\(turnID)-\(index)"
            if type == "userMessage" || type == "steeringUserMessage" {
                let content = item["content"] as? [[String: Any]] ?? item["input"] as? [[String: Any]] ?? []
                let text = displayText(
                    item["text"] as? String ?? content.compactMap { $0["text"] as? String }.joined(separator: "\n"))
                let images = ConversationReply.imageContentSources(content)
                guard !text.isEmpty || !images.isEmpty else { continue }
                var extra: [String: Any] = [
                    "clientId": item["clientId"] as? String ?? item["clientUserMessageId"] as? String ?? ""
                ]
                if !images.isEmpty { extra[ConversationReply.imageKey] = images }
                builder.user(id, text: text, extra: extra)
            } else if let part = part(item, id: id) {
                builder.add(part)
            }
        }
        if let error = (turn["error"] as? [String: Any])?["message"] as? String, !error.isEmpty {
            builder.add(
                .init(
                    id: turnID + "-error", kind: "notice", title: L10n.text("session.error"), status: "failed",
                    text: error))
        }
        return builder.finish(status: turn["status"] as? String == "inProgress" ? "running" : "")
    }
    static func status(_ item: [String: Any]) -> String {
        switch item["status"] as? String ?? "" {
        case "inProgress", "pending": return "running"
        case "completed":
            return (item["exitCode"] as? NSNumber).map { $0.intValue == 0 ? "completed" : "failed" }
                ?? (item["success"] as? Bool == false ? "failed" : "completed")
        case "failed": return "failed"
        case "declined": return "declined"
        default: return ""
        }
    }
    /// One non-message item as a reply step; unknown or empty items are left out rather than guessed at.
    static func part(_ item: [String: Any], id: String) -> ConversationReply.Part? {
        let type = item["type"] as? String ?? ""
        var part = ConversationReply.Part(id: id, kind: "tool", status: status(item))
        if let duration = item["durationMs"] as? NSNumber { part.extra["durationMs"] = duration.intValue }
        switch type {
        case "agentMessage":
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            part.kind = "text"
            part.text = text
            part.status = ""
        case "reasoning":
            func texts(_ value: Any?) -> [String] {
                (value as? String).map { [$0] }
                    ?? (value as? [Any] ?? []).compactMap {
                        $0 as? String ?? ($0 as? [String: Any])?["text"] as? String
                    }
            }
            let summary = texts(item["summary"])
            let content = texts(item["content"])
            let text = (summary.isEmpty ? content : summary).joined(separator: "\n\n").trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            part.kind = "thinking"
            part.title = L10n.text("session.thinking")
            part.text = text
        case "plan":
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            part.kind = "plan"
            part.title = L10n.text("session.plan")
            part.text = text
        case "commandExecution":
            let command = item["command"] as? String ?? (item["command"] as? [String])?.joined(separator: " ") ?? ""
            part.kind = "command"
            part.title = command
            part.text = item["aggregatedOutput"] as? String ?? ""
            if let code = item["exitCode"] as? NSNumber { part.extra["exitCode"] = code.intValue }
            if let cwd = item["cwd"] as? String { part.extra["cwd"] = cwd }
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            guard !changes.isEmpty else { return nil }
            var added = 0
            var removed = 0
            let files: [[String: Any]] = changes.map { change in
                let diff = change["diff"] as? String ?? ""
                let counts = ConversationReply.lineCounts(diff)
                added += counts.added
                removed += counts.removed
                let kind =
                    change["kind"] as? String ?? (change["kind"] as? [String: Any])?["type"] as? String ?? "update"
                return [
                    "path": change["path"] as? String ?? "", "kind": kind, "added": counts.added,
                    "removed": counts.removed,
                ]
            }
            part.kind = "file"
            part.title =
                files.count == 1 ? files[0]["path"] as? String ?? "" : L10n.text("session.files_0", files.count)
            part.text = zip(changes, files).map { change, file in
                "*** \(file["kind"] as? String ?? "update") \(file["path"] as? String ?? "")\n"
                    + (change["diff"] as? String ?? "")
            }.joined(separator: "\n\n")
            part.extra["files"] = files
            part.extra["added"] = added
            part.extra["removed"] = removed
        case "mcpToolCall":
            part.title = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: " · ")
            var body = L10n.text("session.arguments") + ConversationReply.json(item["arguments"] ?? [:])
            if let error = (item["error"] as? [String: Any])?["message"] as? String {
                body += L10n.text("session.error_2") + error
            } else if let result = item["result"] as? [String: Any] {
                let content = result["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let images = ConversationReply.imageContentSources(content)
                if !images.isEmpty { part.extra[ConversationReply.imageKey] = images }
                body +=
                    L10n.text("session.result")
                    + (text.isEmpty
                        ? images.isEmpty ? ConversationReply.json(result) : L10n.text("session.images_0", images.count)
                        : text)
            }
            part.text = body
        case "dynamicToolCall":
            part.title = item["tool"] as? String ?? L10n.text("session.tool")
            part.text = L10n.text("session.arguments") + ConversationReply.json(item["arguments"] ?? [:])
        case "functionCallOutput":
            part.title = [item["namespace"] as? String, item["name"] as? String].compactMap { $0 }.joined(
                separator: " · ")
            if let content = item["output"] as? [[String: Any]] {
                let images = ConversationReply.imageContentSources(content)
                if !images.isEmpty { part.extra[ConversationReply.imageKey] = images }
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                part.text =
                    text.isEmpty
                    ? images.isEmpty ? ConversationReply.json(content) : L10n.text("session.images_0", images.count)
                    : text
            } else {
                part.text = item["output"] as? String ?? ConversationReply.json(item["output"] ?? "")
            }
        case "collabAgentToolCall":
            part.title = L10n.text("session.subagent") + (item["tool"] as? String ?? "")
            part.text = item["prompt"] as? String ?? ""
        case "webSearch":
            part.title = L10n.text("session.search_the_web")
            part.text = item["query"] as? String ?? ConversationReply.json(item["action"] ?? "")
        case "imageView":
            part.title = L10n.text("session.view_image")
            part.text = item["path"] as? String ?? ""
            if let path = item["path"] as? String { part.extra[ConversationReply.imageKey] = [path] }
        case "imageGeneration":
            part.title = L10n.text("session.generate_image")
            part.text = [item["revisedPrompt"] as? String, item["savedPath"] as? String].compactMap { $0 }.joined(
                separator: "\n\n")
            if let path = item["savedPath"] as? String ?? item["src"] as? String, !path.isEmpty {
                part.extra[ConversationReply.imageKey] = [path]
            } else if let result = item["result"] as? String, !result.isEmpty {
                part.extra[ConversationReply.imageKey] = ["data:image/png;base64," + result]
            }
        case "contextCompaction":
            part.kind = "notice"
            part.title = L10n.text("session.context_compacted")
        case "enteredReviewMode", "exitedReviewMode":
            part.kind = "notice"
            part.title =
                type == "enteredReviewMode"
                ? L10n.text("session.code_review_started") : L10n.text("session.code_review_finished")
            part.text = item["review"] as? String ?? ""
        default:
            return nil
        }
        let grouping: [String: Any]
        switch type {
        case "reasoning": grouping = ["groupType": "thinking"]
        case "commandExecution": grouping = ["groupType": "command"]
        case "fileChange": grouping = ["groupType": "file-edit"]
        case "mcpToolCall":
            grouping = ConversationReply.toolGrouping(
                item["tool"] as? String ?? "", namespace: item["server"] as? String ?? "")
        case "dynamicToolCall":
            let name = item["tool"] as? String ?? ""
            grouping =
                name == "request_user_input"
                ? ["groupType": "approval", "toolName": name]
                : ConversationReply.toolGrouping(name, namespace: item["namespace"] as? String ?? "")
        case "functionCallOutput":
            let name = item["name"] as? String ?? ""
            grouping =
                name == "request_user_input"
                ? ["groupType": "approval", "toolName": name]
                : ConversationReply.toolGrouping(name, namespace: item["namespace"] as? String ?? "")
        case "collabAgentToolCall":
            grouping = ConversationReply.toolGrouping(item["tool"] as? String ?? "", namespace: "collab")
        case "webSearch": grouping = ["groupType": "web-search", "toolName": "WebSearch"]
        case "imageView": grouping = ["groupType": "image-view"]
        case "imageGeneration": grouping = ["groupType": "image-generation"]
        case "contextCompaction": grouping = ["groupType": "notice:context-compaction"]
        case "enteredReviewMode": grouping = ["groupType": "notice:review-start"]
        case "exitedReviewMode": grouping = ["groupType": "notice:review-end"]
        default: grouping = [:]
        }
        part.extra.merge(grouping) { _, new in new }
        return part
    }
    static func dataHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func fingerprint(_ request: [String: Any]) -> String {
        let bytes = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func approvals(_ state: [String: Any]) -> [[String: Any]] {
        let requests = state["requests"] as? [[String: Any]] ?? []
        let items = turns(state).flatMap { $0["items"] as? [[String: Any]] ?? [] }
        return requests.compactMap { request in
            if let question = CodexQuestions.native(request) { return question }
            guard let method = request["method"] as? String, let params = request["params"] as? [String: Any],
                let id = request["id"]
            else { return nil }
            let supported = [
                "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                "item/permissions/requestApproval",
            ].contains(method)
            var details = params
            if let itemID = params["itemId"] as? String,
                let item = items.first(where: { $0["id"] as? String == itemID })
            {
                details["itemDetails"] = item
            }
            let data =
                (try? JSONSerialization.data(
                    withJSONObject: details, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            let tooLarge = data.count > 60_000
            let title: String
            switch method {
            case "item/commandExecution/requestApproval": title = L10n.text("session.run_command")
            case "item/fileChange/requestApproval": title = L10n.text("session.edit_files")
            case "item/permissions/requestApproval": title = L10n.text("session.request_permission")
            default: title = L10n.text("session.handle_this_on_the_mac")
            }
            // Unknown payloads must not gain an Allow button merely because their method is familiar.
            let item = details["itemDetails"] as? [String: Any] ?? [:]
            let command = (params["command"] as? String ?? item["command"] as? String ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines)
            let changes = item["changes"] as? [[String: Any]] ?? []
            let completeChanges =
                !changes.isEmpty
                && changes.allSatisfy {
                    !($0["path"] as? String ?? "").isEmpty && $0["diff"] is String && $0["kind"] != nil
                }
            let hasDetails =
                method == "item/commandExecution/requestApproval"
                ? !command.isEmpty
                : method == "item/fileChange/requestApproval"
                    ? completeChanges
                    : params["permissions"] is [String: Any]
            return [
                "id": id, "fingerprint": fingerprint(["request": request, "details": details]), "title": title,
                "method": method,
                "details": tooLarge
                    ? L10n.text("session.the_request_is_too_long_read_the_complete_content_and_handle_it_on_t")
                    : String(decoding: data, as: UTF8.self),
                "canDecide": supported && hasDetails && !tooLarge,
            ]
        } + CodexQuestions.asynchronous(state)
    }
    /// Match the desktop calculation: latest request total, capped at the reported model window.
    /// Lifetime totals include all earlier turns and must never be used as context occupancy.
    static func contextUsage(_ state: [String: Any]) -> [String: Any]? {
        guard let usage = state["latestTokenUsageInfo"] as? [String: Any],
            let last = usage["last"] as? [String: Any],
            let window = (usage["modelContextWindow"] as? NSNumber)?.int64Value, window > 0,
            let tokens = (last["totalTokens"] as? NSNumber)?.int64Value, tokens >= 0
        else { return nil }
        let used = min(tokens, window)
        let remaining = window - used
        let percent = Double(used) / Double(window) * 100
        func count(_ key: String) -> String {
            (last[key] as? NSNumber).map { String($0.int64Value) } ?? L10n.text("session.not_provided")
        }
        let summary = "\(used) / \(window)（\(String(format: "%.1f", percent))%）"
        let detail =
            L10n.text(
                "session.remaining_0_tokens_latest_request_input_1_cached_2_output_3_reasonin", remaining,
                count("inputTokens"), count("cachedInputTokens"), count("outputTokens"), count("reasoningOutputTokens"))
        return [
            "summary": summary, "detail": detail, "usedTokens": used, "contextWindow": window,
            "remainingTokens": remaining, "percent": percent,
        ]
    }
    static func composer(_ state: [String: Any]) -> [String: Any] {
        var selection = CodexComposer.selection(state)
        selection["contextUsage"] = contextUsage(state)?["summary"] ?? ""
        return selection
    }
    static func page(_ state: [String: Any]) -> [String: Any] {
        let all = turns(state)
        let count = ConversationReply.recentTurns
        // Only the newest turns; the phone asks for earlier ones as the user scrolls up.
        let rows = ConversationReply.preview(all.suffix(count).flatMap(messages))
        return [
            "threadId": state["id"] as? String ?? "", "title": state["title"] as? String ?? "Codex",
            "messages": rows,
            "approvals": approvals(state).map { item in
                var summary = item
                summary.removeValue(forKey: "details")
                summary.removeValue(forKey: "questions")
                summary["detailsOnDemand"] = true
                return summary
            },
            "status": (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String ?? "idle",
            "hasOlder": all.count > count || !CodexHistoryReadback.complete(state),
            "loadedTurns": count,
            "activeTurnId": turns(state).last(where: { $0["status"] as? String == "inProgress" })?["turnId"] as? String
                ?? "", "composer": composer(state),
        ]
    }
    static func patch(_ root: Any, path: ArraySlice<Any>, operation: String, value: Any?) throws -> Any {
        guard let key = path.first else {
            guard operation != "remove", let value else {
                throw CLIError(L10n.text("session.the_session_update_format_is_incompatible"))
            }
            return value
        }
        let rest = path.dropFirst()
        if var object = root as? [String: Any], let name = key as? String {
            if rest.isEmpty {
                if operation == "remove" {
                    object.removeValue(forKey: name)
                } else if let value {
                    object[name] = value
                } else {
                    throw CLIError(L10n.text("session.invalid_session_patch"))
                }
            } else {
                guard let child = object[name] else {
                    throw CLIError(L10n.text("session.the_session_patch_is_outdated"))
                }
                object[name] = try patch(child, path: rest, operation: operation, value: value)
            }
            return object
        }
        if var array = root as? [Any], let index = (key as? NSNumber)?.intValue ?? (key as? String).flatMap(Int.init) {
            guard index >= 0, index <= array.count else {
                throw CLIError(L10n.text("session.the_session_patch_is_out_of_bounds"))
            }
            if rest.isEmpty && operation == "add", let value {
                array.insert(value, at: index)
            } else {
                guard index < array.count else { throw CLIError(L10n.text("session.the_session_patch_is_outdated")) }
                if rest.isEmpty && operation == "remove" {
                    array.remove(at: index)
                } else {
                    array[index] = try patch(array[index], path: rest, operation: operation, value: value)
                }
            }
            return array
        }
        throw CLIError(L10n.text("session.unsupported_session_update_format"))
    }
}
