import Foundation

/// Shared validation for a new first turn and later headless turns. Native desktop
/// model menus use their own provider choices and are validated by ClaudeDesktop.
enum ClaudeSessionConfiguration {
    static let keys = ["model", "effort", "mode", "executionMode"]
    static var executionModes: [[String: Any]] {
        [
            ["id": "default", "name": ClaudeDesktop.modeTitles["default"] ?? "Manual", "permissionMode": "default"],
            ["id": "plan", "name": ClaudeDesktop.modeTitles["plan"] ?? "Plan", "permissionMode": "plan"],
        ]
    }

    /// Claude's native Plan is a permission mode. An explicit exit uses Manual unless
    /// the caller also selected a non-Plan permission mode; it never restores full access.
    static func permissionMode(_ request: [String: Any]) throws -> String? {
        guard keys.allSatisfy({ request[$0] == nil || request[$0] is String }) else {
            throw CLIError(L10n.text("core.invalid_request"))
        }
        let mode = request["mode"] as? String
        guard let execution = request["executionMode"] as? String else { return mode }
        switch execution {
        case "plan":
            guard mode == nil || mode == "plan" else { throw CLIError(L10n.text("core.invalid_request")) }
            return "plan"
        case "default":
            guard mode != "plan" else { throw CLIError(L10n.text("core.invalid_request")) }
            return mode ?? "default"
        default: throw CLIError(L10n.text("core.invalid_request"))
        }
    }

    static func executionMode(permissionMode: String?) -> String? {
        guard let permissionMode, ClaudeBridge.modes.contains(permissionMode) else { return nil }
        return permissionMode == "plan" ? "plan" : "default"
    }

    static func resolve(
        _ request: [String: Any], current: [String: String],
        models: [[String: Any]] = [ClaudeModelCatalog.defaultEntry]
    ) throws -> [String: String] {
        guard keys.allSatisfy({ request[$0] == nil || request[$0] is String }) else {
            throw CLIError(L10n.text("core.invalid_request"))
        }
        var result = current
        let model = request["model"] as? String ?? current["model"] ?? "default"
        guard
            let entry = models.first(where: {
                $0["id"] as? String == model || ($0["aliases"] as? [String] ?? []).contains(model)
            })
        else {
            throw CLIError(L10n.text("provider.this_model_is_not_supported"))
        }
        let effort = request["effort"] as? String ?? (request["model"] == nil ? current["effort"] : nil) ?? "default"
        guard (entry["efforts"] as? [String] ?? []).contains(effort) else {
            throw CLIError(L10n.text("session.this_model_does_not_support_the_selected_reasoning_effort"))
        }
        let mode = try permissionMode(request) ?? current["mode"] ?? "acceptEdits"
        guard ClaudeBridge.modes.contains(mode) else {
            throw CLIError(L10n.text("provider.unsupported_permission_mode"))
        }
        if request["mode"] != nil, mode == "bypassPermissions",
            SessionProviderReply.boolean(request["confirmFullAccess"]) != true
        {
            throw CLIError(L10n.text("provider.bypassing_permissions_requires_explicit_confirmation"))
        }
        result["model"] = entry["id"] as? String
        result["effort"] = effort
        result["mode"] = mode
        result["executionMode"] = executionMode(permissionMode: mode)
        return result
    }
}
