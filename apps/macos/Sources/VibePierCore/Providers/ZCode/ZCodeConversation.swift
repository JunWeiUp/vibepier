import Foundation

/// ZCode stores tool input, result and final status in the same native part.
/// This projection retains those IDs and the desktop's original part order.
enum ZCodeConversation {
    static func userText(_ parts: [[String: Any]]) -> String {
        parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
    }
    static func imageSource(_ value: [String: Any]) -> String? {
        guard (value["mime"] as? String ?? "").hasPrefix("image/") else { return nil }
        if (value["imageDeferred"] as? NSNumber)?.boolValue == true || value["imageDeferred"] as? Bool == true {
            return "zcode-part:" + (value["id"] as? String ?? "")
        }
        let source = value["source"] as? [String: Any] ?? [:]
        let metadata = value["metadata"] as? [String: Any] ?? [:]
        for candidate in [source["path"], metadata["originalUrl"], value["url"]].compactMap({ $0 as? String }) {
            if candidate.hasPrefix("data:image/") { return candidate }
            if let url = URL(string: candidate), url.isFileURL { return url.path }
            if candidate.hasPrefix("/") { return candidate }
        }
        return nil
    }
    static func status(_ value: String) -> String {
        switch value {
        case "running", "pending": return "running"
        case "completed": return "completed"
        case "error", "failed": return "failed"
        case "cancelled", "canceled", "declined": return "declined"
        default: return ""
        }
    }
    static func imageSources(_ native: [String: Any]) -> [String] {
        if native["type"] as? String == "file" { return imageSource(native).map { [$0] } ?? [] }
        if native["type"] as? String == "text" {
            return ConversationReply.localImageReferences(native["text"] as? String ?? "")
        }
        let count = (native["nativeImageCount"] as? NSNumber)?.intValue ?? 0
        if count > 0 { return (0..<min(count, 12)).map { "zcode-part:" + (native["id"] as? String ?? "") + ":\($0)" } }
        let state = native["state"] as? [String: Any] ?? [:]
        let metadata = state["metadata"] as? [String: Any] ?? [:]
        let display = metadata["display"] as? [String: Any] ?? [:]
        let images = display["images"] as? [[String: Any]] ?? []
        let media = display["media"] as? [[String: Any]] ?? []
        return (images + media).compactMap { item -> String? in
            let mime = item["mimeType"] as? String ?? ""
            guard mime.hasPrefix("image/"), let data = item["base64"] as? String ?? item["data"] as? String else {
                return nil
            }
            return data.hasPrefix("data:image/") ? data : "data:\(mime);base64," + data
        }
    }
    static func part(_ native: [String: Any]) -> ConversationReply.Part {
        let id = native["id"] as? String ?? ""
        let type = native["type"] as? String ?? ""
        var part = ConversationReply.Part(id: id, kind: "tool")
        switch type {
        case "text":
            part.kind = "text"
            part.text = native["text"] as? String ?? ""
            let images = imageSources(native)
            if !images.isEmpty { part.extra[ConversationReply.imageKey] = images }
        case "reasoning":
            part.kind = "thinking"
            part.title = L10n.text("session.thinking")
            part.text = native["text"] as? String ?? ""
            part.status = (native["time"] as? [String: Any])?["end"] is NSNumber ? "completed" : "running"
            part.extra["groupType"] = "thinking"
        case "tool":
            let state = native["state"] as? [String: Any] ?? [:]
            let input = state["input"] as? [String: Any] ?? [:]
            let name = native["tool"] as? String ?? ""
            part = ClaudeTranscript.toolPart(["id": id, "name": name, "input": input], cwd: nil)
            part.status = status(state["status"] as? String ?? "")
            let output = state["output"] as? String ?? ""
            let error = state["error"] as? String ?? ""
            if part.kind == "command" {
                part.text = output.isEmpty ? error : output
            } else if !output.isEmpty {
                part.text += (part.text.isEmpty ? "" : "\n\n") + output
            }
            if !error.isEmpty, part.kind != "command" { part.text += L10n.text("session.error_2") + error }
            if name == "TodoWrite" {
                part.kind = "tool"
                part.title = L10n.text("provider.update_to_do_list")
                part.extra["groupType"] = "plan"
                part.extra["toolName"] = name
            }
            let display = (state["metadata"] as? [String: Any])?["display"] as? [String: Any] ?? [:]
            if display["kind"] as? String == "file_diff" {
                part.kind = "file"
                part.title =
                    display["filePath"] as? String ?? input["file_path"] as? String ?? L10n.text("provider.edit_file")
                part.extra["groupType"] = "file-edit"
                if let hunks = display["structuredPatch"] as? [[String: Any]] {
                    part.text = hunks.map { hunk in
                        let oldStart = (hunk["oldStart"] as? NSNumber)?.intValue ?? 0
                        let oldLines = (hunk["oldLines"] as? NSNumber)?.intValue ?? 0
                        let newStart = (hunk["newStart"] as? NSNumber)?.intValue ?? 0
                        let newLines = (hunk["newLines"] as? NSNumber)?.intValue ?? 0
                        return "@@ -\(oldStart),\(oldLines) +\(newStart),\(newLines) @@\n"
                            + (hunk["lines"] as? [String] ?? []).joined(separator: "\n")
                    }.joined(separator: "\n")
                }
                part.extra["added"] = display["additions"] ?? 0
                part.extra["removed"] = display["deletions"] ?? 0
            }
            if let time = state["time"] as? [String: Any], let start = time["start"] as? NSNumber,
                let end = time["end"] as? NSNumber
            {
                part.extra["durationMs"] = max(0, end.int64Value - start.int64Value)
            }
            let images = imageSources(native)
            if !images.isEmpty { part.extra[ConversationReply.imageKey] = images }
        case "file":
            part.title = native["filename"] as? String ?? L10n.text("session.attachment")
            part.extra["groupType"] =
                (native["mime"] as? String ?? "").hasPrefix("image/") ? "image-view" : "attachment"
            if let source = imageSource(native) { part.extra[ConversationReply.imageKey] = [source] }
        case "compaction":
            part.kind = "notice"
            part.title = L10n.text("session.context_compacted")
            part.status = status(native["timelineStatus"] as? String ?? "")
            part.extra["groupType"] = "notice:context-compaction"
        case "timeline":
            part.kind = "notice"
            part.status = status(native["status"] as? String ?? "")
            let kind = native["timelineType"] as? String ?? ""
            part.title =
                kind == "model_change" ? L10n.text("provider.model_changed") : L10n.text("provider.session_update")
            if !kind.isEmpty { part.extra["groupType"] = "notice:" + kind.replacingOccurrences(of: "_", with: "-") }
            let model = native["toModelSelection"] as? [String: Any] ?? native["toModel"] as? [String: Any] ?? [:]
            part.text = model["label"] as? String ?? model["modelID"] as? String ?? model["modelId"] as? String ?? ""
        default:
            part.kind = "notice"
            part.title = L10n.text("provider.session_update")
        }
        return part
    }

    static func user(_ turn: ZCodeSessionStore.Turn) -> [String: Any] {
        let images = turn.userParts.flatMap(imageSources)
        var row: [String: Any] = ["id": turn.userID, "role": "user", "text": userText(turn.userParts)]
        if !images.isEmpty { row[ConversationReply.imageKey] = images }
        let metadata = ((turn.latest["user"] as? [String: Any])?["metadata"] as? [String: Any]) ?? [:]
        row["clientId"] = metadata["inputClientId"] as? String ?? ""
        row = ConversationReply.preview([row]).first ?? row
        if turn.userParts.contains(where: { (($0["nativeTextLength"] as? NSNumber)?.intValue ?? 0) > 12_000 }) {
            row["hasMore"] = true
            row["nextOffset"] = (row["text"] as? String ?? "").count
        }
        return row
    }
    static func sequence(_ natives: [[String: Any]], offset: Int) -> [[String: Any]] {
        let row: [String: Any] = [
            "id": "sequence", "role": "assistant", "text": "", "parts": natives.map { part($0).value },
        ]
        let projected = ConversationReply.preview([row]).first?["sequence"] as? [[String: Any]] ?? []
        return zip(projected, natives).enumerated().map { index, pair in
            var value = pair.0
            value["index"] = offset + index
            let length = (pair.1["nativeTextLength"] as? NSNumber)?.intValue ?? (pair.1["text"] as? String ?? "").count
            let count = (value["text"] as? String ?? "").count
            if ConversationReply.prose.contains(value["kind"] as? String ?? ""), length > 12_000 {
                value["hasMore"] = true
                value["nextOffset"] = count
            }
            value["bodyVersion"] =
                value["status"] as? String == "running"
                    && !ConversationReply.prose.contains(value["kind"] as? String ?? "")
                ? "running:" + (value["id"] as? String ?? "")
                : (pair.1["nativeVersion"] as? String ?? "") + ":\(length)"
            return value
        }
    }
    static func reply(_ turn: ZCodeSessionStore.Turn) -> [String: Any]? {
        guard turn.partCount > 0 else { return nil }
        let start = max(0, turn.partCount - turn.parts.count)
        return [
            "id": "reply-" + turn.userID, "role": "assistant", "text": "", "partsDeferred": true,
            "partCount": turn.partCount, "sequenceStart": start, "sequence": sequence(turn.parts, offset: start),
            "status": (turn.latest["time"] as? [String: Any])?["completed"] == nil
                && turn.latest["role"] as? String == "assistant" ? "running" : "",
        ]
    }
    static func rows(_ turns: [ZCodeSessionStore.Turn]) -> [[String: Any]] {
        turns.flatMap { turn in [user(turn)] + (reply(turn).map { [$0] } ?? []) }
    }
    static func composer(_ summary: [String: Any], latest: [String: Any]) -> [String: Any] {
        let selection = summary["selection"] as? [String: Any] ?? [:]
        let user = latest["user"] as? [String: Any] ?? [:]
        let native = user["modelSelection"] as? [String: Any] ?? [:]
        let options = native["options"] as? [String: Any] ?? [:]
        return [
            "model": selection["model"] as? String ?? latest["modelId"] as? String ?? native["modelId"] as? String
                ?? "",
            "effort": selection["thoughtLevel"] as? String ?? options["reasoningLevel"] as? String ?? "",
            "mode": selection["mode"] as? String ?? latest["mode"] as? String ?? "", "contextUsage": "",
        ]
    }
}
