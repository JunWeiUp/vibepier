import Foundation

/// Confirms an appended native user message, never an empty composer or a matching old transcript row.
struct ClaudeSendReceipt: Sendable {
    private let seen: Set<String>
    private let anchor: String?
    private let expected: String
    var retainedBytes: Int { expected.utf8.count + seen.reduce(512) { $0 + $1.utf8.count + 32 } }

    init(entries: [[String: Any]], text: String) {
        let ids = entries.compactMap { $0["uuid"] as? String }.filter { !$0.isEmpty }
        seen = Set(ids)
        anchor = ids.last
        expected = Self.normalized(text)
    }

    /// Desktop composers rewrite paragraph breaks, so a multi-line message is compared with whitespace runs collapsed.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func message(_ entry: [String: Any]) -> (id: String, text: String)? {
        guard entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
            entry["isCompactSummary"] as? Bool != true, entry["isSidechain"] as? Bool != true,
            let id = entry["uuid"] as? String, !id.isEmpty,
            let content = (entry["message"] as? [String: Any])?["content"]
        else { return nil }
        let text: String
        if let value = content as? String {
            text = value
        } else if let blocks = content as? [[String: Any]],
            blocks.allSatisfy({ $0["type"] as? String == "text" && $0["text"] is String })
        {
            // Desktop adoption can prepend a `<system-reminder>` block; only the typed text is the receipt.
            text = ClaudeTranscript.humanText(blocks)
        } else {
            return nil
        }
        return (id, normalized(text))
    }

    func confirmedMessage(in entries: [[String: Any]]) -> String? {
        let start: Int
        if let anchor {
            guard let index = entries.lastIndex(where: { $0["uuid"] as? String == anchor }) else { return nil }
            start = index + 1
        } else {
            start = 0
        }
        let matches = entries.dropFirst(start).compactMap(Self.message).filter {
            !seen.contains($0.id) && !expected.isEmpty && $0.text == expected
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    static func activeTurn(entries: [[String: Any]], host: String) -> String? {
        guard let last = entries.reversed().compactMap(message).first else { return nil }
        return "desktop:" + host + ":" + last.id
    }

    /// The native interrupt marker may follow the original user message; another actual prompt cannot.
    /// Callers must additionally observe this host becoming idle.
    static func stoppedTurn(entries: [[String: Any]], host: String, expected: String) -> Bool {
        let messages = entries.compactMap(message)
        guard let index = messages.lastIndex(where: { "desktop:" + host + ":" + $0.id == expected }) else {
            return false
        }
        return messages.dropFirst(index + 1).allSatisfy { $0.text.hasPrefix(ClaudeTranscript.interrupted) }
    }
}

enum ClaudeCreationReceipt {
    /// Read only a bounded native prefix. A title or the mere existence of a file is not a submission receipt.
    static func read(_ url: URL, session: String, cwd: String, text: String) -> [String: Any]? {
        guard let prompt = try? ClaudePrompt(text: text) else { return nil }
        return read(url, session: session, cwd: cwd, proof: prompt.proof)
    }
    static func read(
        _ url: URL, session: String, cwd: String, proof: ClaudePrompt.Proof,
        executionMode: String? = nil, permissionMode: String? = nil
    ) -> [String: Any]? {
        guard let before = try? FileManager.default.attributesOfItem(atPath: url.path),
            before[.type] as? FileAttributeType == .typeRegular,
            let inode = before[.systemFileNumber] as? NSNumber,
            let file = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 8 * 1024 * 1024),
            let after = try? FileManager.default.attributesOfItem(atPath: url.path),
            after[.systemFileNumber] as? NSNumber == inode
        else { return nil }
        // An unterminated JSONL record may still be being written.
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        for line in lines {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
            guard entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
                entry["isCompactSummary"] as? Bool != true, entry["isSidechain"] as? Bool != true
            else { continue }
            guard let id = entry["uuid"] as? String, !id.isEmpty,
                let content = (entry["message"] as? [String: Any])?["content"]
            else { return nil }
            if let blocks = content as? [[String: Any]],
                blocks.contains(where: { $0["type"] as? String == "tool_result" })
            {
                continue
            }
            guard entry["sessionId"] as? String == session, entry["cwd"] as? String == cwd,
                id.utf8.count <= 256, !id.contains("\0"), proof.matches(content)
            else { return nil }
            var result: [String: Any] = [
                "ok": true, "accepted": true, "threadId": session, "cwd": cwd, "nativeMessageId": id,
                // Claude's transcript has no turn UUID. This exact native human record
                // is the verified turn anchor; it remains stable after the CLI exits.
                "turnId": "transcript:" + session + ":" + id, "turnIdentityKind": "nativeMessageAnchor",
            ]
            if let executionMode {
                let actual = entry["permissionMode"] as? String
                guard ClaudeSessionConfiguration.executionMode(permissionMode: actual) == executionMode,
                    actual == permissionMode
                else {
                    // The native first message proves creation; an unreported mode is a warning, not uncertainty.
                    result["executionModeVerified"] = false
                    var warning: [String: Any] = ["field": "executionMode", "requested": executionMode]
                    if let actual { warning["observed"] = actual }
                    result["warnings"] = [warning]
                    return result
                }
                result["executionModeVerified"] = true
                result["effectiveExecutionMode"] = executionMode
                result["composer"] = ["mode": actual!, "executionMode": executionMode]
            }
            return result
        }
        return nil
    }
}
