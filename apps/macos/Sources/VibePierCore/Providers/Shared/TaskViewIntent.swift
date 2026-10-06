import Foundation

/// An explicit phone open clears only the matching page after it is actually available.
/// Background sync, a pending desktop open, and delayed pages from another view do not count.
struct TaskViewIntent: Equatable, Sendable {
    let provider: String
    let id: String
    let version: Int64
    var completion: String?

    init?(_ request: [String: Any]) {
        guard request["op"] as? String == "open", let id = request["threadId"] as? String, !id.isEmpty,
            let version = (request["viewVersion"] as? NSNumber)?.int64Value, version >= 0
        else { return nil }
        let supplied = request["provider"] as? String ?? "codex"
        let provider = supplied.isEmpty ? "codex" : supplied
        guard ["codex", "claude"].contains(provider) else { return nil }
        self.provider = provider
        self.id = id
        self.version = version
        self.completion = nil
    }

    func isReady(_ page: [String: Any], provider: String) -> Bool {
        guard self.provider == provider, page["threadId"] as? String == id,
            (page["viewVersion"] as? NSNumber)?.int64Value == version,
            page["error"] == nil, page["opening"] as? Bool != true,
            page["ok"] as? Bool != false,
            page["event"] == nil || page["event"] as? String == "snapshot"
        else { return false }
        return page["messages"] is [[String: Any]] || page["unchanged"] as? Bool == true
    }
}
