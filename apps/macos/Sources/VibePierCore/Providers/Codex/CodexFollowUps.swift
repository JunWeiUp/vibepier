import Foundation

/// The desktop's durable local queue. Writes go through its owner IPC, never through the JSON file.
final class CodexFollowUps {
    private var signature = ""
    private var cachedQueues: [String: Any] = [:]
    let file: URL
    init(
        file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".codex/.codex-global-state.json")
    ) { self.file = file }
    func messages(_ thread: String) throws -> [[String: Any]] {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let current =
            "\(attributes[.systemFileNumber] ?? "")|\(attributes[.size] ?? "")|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if current != signature {
            guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                throw CLIError(L10n.text("session.could_not_read_the_desktop_send_queue"))
            }
            let value = root["queued-follow-ups"] ?? [String: Any]()
            guard let queues = value as? [String: Any] else {
                throw CLIError(L10n.text("session.the_desktop_send_queue_format_changed"))
            }
            cachedQueues = queues
            signature = current
        }
        let queues = cachedQueues
        guard let rows = queues[thread] else { return [] }
        guard let messages = rows as? [[String: Any]],
            messages.allSatisfy({ $0["id"] is String && $0["context"] is [String: Any] })
        else { throw CLIError(L10n.text("session.the_desktop_send_queue_format_changed")) }
        return messages
    }
    static func message(id: String, text: String, cwd: String, files: [[String: Any]], images: [[String: Any]])
        -> [String: Any]
    {
        var context: [String: Any] = ["prompt": text, "workspaceRoots": [cwd], "isAutoContextOn": false]
        for key in [
            "addedFiles", "attachmentOrder", "imageCommentDrafts", "appshotContexts", "pastedTextAttachments",
            "uploadedFileAttachments", "mcpAppModelContextAttachments", "selectedTextAttachments",
            "responseTextAnnotations", "commentAttachments",
        ] { context[key] = [Any]() }
        context["fileAttachments"] = files
        context["imageAttachments"] = images.map { image in
            var image = image
            if let path = image["fsPath"] as? String {
                image["src"] = URL(fileURLWithPath: path).absoluteString
                image["localPath"] = path
            }
            return image
        }
        return [
            "id": id, "text": text, "cwd": cwd, "createdAt": Date().timeIntervalSince1970 * 1000, "context": context,
        ]
    }
    /// Let the desktop coordinator acquire its send lock, prepare attachments and reconcile uncertain delivery.
    static func steer(_ message: [String: Any]) throws -> [String: Any] {
        let submission = message["submission"] as? [String: Any] ?? [:]
        guard !["pending", "sending", "outcome-unknown"].contains(submission["status"] as? String ?? "") else {
            throw CLIError(L10n.text("session.this_message_is_being_sent_or_its_result_is_unconfirmed_check_again_"))
        }
        var result = message
        result.removeValue(forKey: "pausedReason")
        result["submission"] = ["hostId": "local", "status": "pending", "queueModeOverride": "send-now"]
        result["submissionIntent"] = "send-now"
        return result
    }
    static func project(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.map { row in
            let context = row["context"] as? [String: Any] ?? [:]
            let status = (row["submission"] as? [String: Any])?["status"] as? String ?? "queued"
            let files =
                (context["fileAttachments"] as? [[String: Any]] ?? [])
                + (context["imageAttachments"] as? [[String: Any]] ?? [])
            return [
                "id": row["id"] ?? "",
                "text": String((row["text"] as? String ?? context["prompt"] as? String ?? "").prefix(4000)),
                "attachments": files.map {
                    $0["label"] as? String ?? $0["name"] as? String ?? $0["path"] as? String
                        ?? L10n.text("session.attachment")
                },
                "status": status, "pausedReason": row["pausedReason"] ?? "",
                "canSteer": !["pending", "sending", "outcome-unknown"].contains(status),
                "canDelete": !["pending", "sending"].contains(status),
            ]
        }
    }
}
