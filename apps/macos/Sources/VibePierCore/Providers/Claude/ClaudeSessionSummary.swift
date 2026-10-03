import Foundation

/// Listing sessions needs their first prompt and title records, not decoding every tool result.
enum ClaudeSessionSummary {
    static func read(_ data: Data, customTitle: String? = nil) -> (title: String, cwd: String)? {
        guard let user = record(data, type: "user", last: false, accept: { ClaudeTranscript.userText($0) != nil })
        else { return nil }
        var title = String((ClaudeTranscript.userText(user) ?? "Claude Code").prefix(80))
        if let generated = record(data, type: "ai-title", last: true)?["aiTitle"] as? String { title = generated }
        if let named = record(data, type: "custom-title", last: true)?["customTitle"] as? String, !named.isEmpty {
            title = named
        }
        if let customTitle, !customTitle.isEmpty { title = customTitle }
        var cwd = user["cwd"] as? String ?? ""
        if cwd.isEmpty {
            cwd =
                data.prefix(64 * 1024).split(separator: 10).lazy.compactMap {
                    (try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["cwd"] as? String
                }.first ?? ""
        }
        return (title, cwd)
    }
    private static func record(_ data: Data, type: String, last: Bool, accept: ([String: Any]) -> Bool = { _ in true })
        -> [String: Any]?
    {
        let needles = ["\"type\":\"\(type)\"", "\"type\": \"\(type)\"", "\"type\" : \"\(type)\""].map { Data($0.utf8) }
        let newline = Data([10])
        var bounds = data.startIndex..<data.endIndex
        while !bounds.isEmpty {
            let matches = needles.compactMap {
                data.range(of: $0, options: last ? .backwards : [], in: bounds)?.lowerBound
            }
            guard let hit = last ? matches.max() : matches.min() else { return nil }
            let start =
                data.range(of: newline, options: .backwards, in: data.startIndex..<hit).map { $0.upperBound }
                ?? data.startIndex
            let end = data.range(of: newline, in: hit..<data.endIndex)?.lowerBound ?? data.endIndex
            if let value = try? JSONSerialization.jsonObject(with: data.subdata(in: start..<end)) as? [String: Any],
                value["type"] as? String == type, accept(value)
            {
                return value
            }
            if last { bounds = data.startIndex..<start } else { bounds = min(end + 1, data.endIndex)..<data.endIndex }
        }
        return nil
    }
}
