import Foundation

/// Shapes verified in the packaged desktop coordinator. A successful envelope alone is not a mutation receipt.
enum CodexNativeReceipt {
    static func validate(_ result: [String: Any], method: String, params: [String: Any]) throws {
        let valid: Bool
        switch method {
        case "thread-follower-load-complete-history":
            valid = AgentSessionProfile.integer(result["revision"]).map { $0 >= 0 } == true
        case "thread-follower-start-turn":
            let turn = (result["result"] as? [String: Any])?["turn"] as? [String: Any]
            valid = !(turn?["id"] as? String ?? "").isEmpty
        case "thread-follower-interrupt-turn":
            valid =
                SessionProviderReply.boolean(result["ok"]) == true
                && !(params["expectedTurnId"] as? String ?? "").isEmpty
                && result["interruptedTurnId"] as? String == params["expectedTurnId"] as? String
        case "thread-follower-update-thread-settings":
            // An explicit false is a verified conditional rejection, not an unknown outcome.
            valid = SessionProviderReply.boolean(result["applied"]) != nil
        case "thread-follower-remove-queued-message":
            if result["removed"] is NSNull {
                valid = true
            } else {
                let removed = result["removed"] as? [String: Any]
                let message = removed?["message"] as? [String: Any]
                valid =
                    !(params["messageId"] as? String ?? "").isEmpty
                    && message?["id"] as? String == params["messageId"] as? String
            }
        case "thread-follower-set-queued-follow-ups-state", "thread-follower-command-approval-decision",
            "thread-follower-file-approval-decision", "thread-follower-permissions-request-approval-response",
            "thread-follower-submit-user-input", "thread-follower-submit-mcp-server-elicitation-response":
            valid = SessionProviderReply.boolean(result["ok"]) == true
        default: return
        }
        guard valid else { throw CLIError(L10n.text("core.invalid_receipt")) }
    }
}
