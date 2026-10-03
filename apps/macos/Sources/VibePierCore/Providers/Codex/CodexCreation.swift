import Foundation

struct CodexCreationProject: Equatable, Sendable {
    let id: String
    let name: String
    let cwd: String

    static func labelIdentity(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct CodexCreationSnapshot: Sendable {
    let cwd: String
    let since: Int64
    let existingIDs: Set<String>
}

struct CodexCreationReceipt: Equatable, Sendable {
    let threadID: String
    let title: String
    let cwd: String
    let messageID: String
    let turnID: String

    var reply: [String: Any] {
        [
            "ok": true, "threadId": threadID, "title": title, "cwd": cwd,
            "nativeMessageId": messageID, "nativeTurnId": turnID,
        ]
    }

    /// Current desktop rollouts identify actual human input by content_item_kinds.
    /// Context injected as role=user is not the first submitted user message.
    static func firstUser(in data: Data, threadID: String, cwd: String, text: String) -> (
        message: String, turn: String
    )? {
        var metadataSeen = false
        var firstTurn: String?
        for raw in data.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
            guard !raw.isEmpty,
                let row = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                let kind = row["type"] as? String, let payload = row["payload"] as? [String: Any]
            else { return nil }
            if !metadataSeen {
                guard kind == "session_meta", payload["id"] as? String == threadID,
                    payload["cwd"] as? String == cwd, payload["source"] as? String == "vscode",
                    ["Codex Desktop", "codex_desktop"].contains(payload["originator"] as? String ?? "")
                else { return nil }
                metadataSeen = true
                continue
            }
            if kind == "session_meta" { return nil }
            if kind == "event_msg", payload["type"] as? String == "task_started" {
                guard firstTurn == nil, let turn = payload["turn_id"] as? String, UUID(uuidString: turn) != nil else {
                    return nil
                }
                firstTurn = turn
            }
            guard kind == "response_item", payload["type"] as? String == "message",
                payload["role"] as? String == "user"
            else { continue }
            let metadata: [String: Any]?
            if let encoded = payload["internal_chat_message_metadata_passthrough"] as? String {
                metadata = (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? [String: Any]
            } else {
                metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any]
            }
            guard let metadata, let kinds = metadata["content_item_kinds"] as? [String], !kinds.isEmpty else {
                return nil
            }
            if kinds.allSatisfy({ !$0.hasPrefix("user.") }) { continue }
            guard kinds == ["user.text"], let contents = payload["content"] as? [[String: Any]], contents.count == 1,
                contents[0]["type"] as? String == "input_text", let body = contents[0]["text"] as? String,
                // The desktop app appends one LF to a plain submitted message; do not use substring matching.
                body == text || body == text + "\n",
                let id = payload["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
                let turn = metadata["turn_id"] as? String, turn == firstTurn
            else { return nil }
            return (id, turn)
        }
        return nil
    }

    static func read(rollout: String, threadID: String, cwd: String, text: String) -> (message: String, turn: String)? {
        let url = URL(fileURLWithPath: rollout).resolvingSymlinksInPath()
        guard let before = try? FileManager.default.attributesOfItem(atPath: url.path),
            before[.type] as? FileAttributeType == .typeRegular,
            let inode = before[.systemFileNumber] as? NSNumber,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        // A new rollout may contain a large context. Never read an unbounded transcript to find its first message.
        guard let prefix = try? handle.read(upToCount: 8 << 20),
            let after = try? FileManager.default.attributesOfItem(atPath: url.path),
            after[.systemFileNumber] as? NSNumber == inode
        else { return nil }
        return firstUser(in: prefix, threadID: threadID, cwd: cwd, text: text)
    }
}

enum CodexCreationFlow {
    static func url(project: CodexCreationProject, text: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "path", value: project.cwd), URLQueryItem(name: "projectId", value: project.id),
            URLQueryItem(name: "mode", value: "codex"), URLQueryItem(name: "prompt", value: text),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw CLIError(L10n.text("session.could_not_open_codex")) }
        return url
    }

    /// Opening only prefills. Prepare may wait for the exact composer; once invoked, submit is never repeated.
    static func run(
        open: () throws -> Void, prepare: () throws -> (() throws -> Void)?,
        receipt: () throws -> CodexCreationReceipt?, wait: () -> Void,
        attempts: Int = 50, timeout: TimeInterval = 20,
        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws -> CodexCreationReceipt {
        try DesktopMutationScope.run { mutation in
            let deadline = clock() + timeout
            try mutation.attempt(open)
            var submitted = false
            for _ in 0..<attempts {
                guard clock() < deadline else { break }
                if !submitted, let action = try prepare() {
                    guard clock() < deadline else { break }
                    submitted = true
                    try mutation.attempt(action)
                }
                if submitted, let result = try receipt() { return result }
                wait()
            }
            throw CLIError(L10n.text("session.codex_creation_unconfirmed"))
        }
    }
}
