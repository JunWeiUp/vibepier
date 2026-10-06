import Foundation

/// The phone selects a decision, never supplies a rule. Only the current native request can propose one.
enum CodexApprovalDecision {
    static func similarRule(_ source: [String: Any]) -> [String]? {
        guard source["method"] as? String == "item/commandExecution/requestApproval",
            let params = source["params"] as? [String: Any],
            params["networkApprovalContext"] == nil || params["networkApprovalContext"] is NSNull,
            let rule = params["proposedExecpolicyAmendment"] as? [String], (1...64).contains(rule.count),
            rule.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 4096
                    && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            }),
            rule.reduce(0, { $0 + $1.utf8.count }) <= 8192
        else { return nil }
        if let raw = params["availableDecisions"], !(raw is NSNull) {
            guard let choices = raw as? [Any],
                choices.contains(where: {
                    guard let choice = $0 as? [String: Any] else { return false }
                    return NSDictionary(dictionary: choice).isEqual(to: nativeSimilar(rule))
                })
            else { return nil }
        }
        return rule
    }

    static func nativeSimilar(_ rule: [String]) -> [String: Any] {
        ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": rule]]
    }

    static func description(_ rule: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: rule, options: [.withoutEscapingSlashes])) ?? Data()
        return L10n.text("session.allow_similar_command_rule", String(decoding: data, as: UTF8.self))
    }

    static func decision(_ request: [String: Any], source: [String: Any], projected: [String: Any]) throws -> Any {
        if request["decision"] as? String == "allowSimilar" {
            guard projected["canDecide"] as? Bool == true,
                (projected["allowedDecisions"] as? [String] ?? []).contains("allowSimilar"),
                request["fingerprint"] as? String == projected["fingerprint"] as? String,
                let requestedID = request["nativeRequestId"] as? NSObject,
                let nativeID = source["id"] as? NSObject, requestedID == nativeID,
                let rule = similarRule(source)
            else { throw CLIError(L10n.text("session.the_approval_expired_or_must_be_handled_on_the_mac_refresh_it")) }
            return nativeSimilar(rule)
        }
        guard request["decision"] == nil, let allow = request["allow"] as? Bool else {
            throw CLIError(L10n.text("session.choose_allow_once_or_deny"))
        }
        return allow ? "accept" : "decline"
    }
}
