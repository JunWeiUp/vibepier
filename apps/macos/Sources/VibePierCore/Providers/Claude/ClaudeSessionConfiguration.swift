import Foundation

/// Shared validation for a new first turn and later headless turns. Native desktop
/// model menus use their own provider choices and are validated by ClaudeDesktop.
enum ClaudeSessionConfiguration {
    static let keys = ["model", "effort", "mode"]

    static func resolve(_ request: [String: Any], current: [String: String]) throws -> [String: String] {
        guard keys.allSatisfy({ request[$0] == nil || request[$0] is String }) else {
            throw CLIError(L10n.text("core.invalid_request"))
        }
        var result = current
        let model = request["model"] as? String ?? current["model"] ?? "default"
        guard let entry = ClaudeBridge.models.first(where: { $0["id"] as? String == model }) else {
            throw CLIError(L10n.text("provider.this_model_is_not_supported"))
        }
        let effort = request["effort"] as? String ?? (request["model"] == nil ? current["effort"] : nil) ?? "default"
        guard (entry["efforts"] as? [String] ?? []).contains(effort) else {
            throw CLIError(L10n.text("session.this_model_does_not_support_the_selected_reasoning_effort"))
        }
        let mode = request["mode"] as? String ?? current["mode"] ?? "acceptEdits"
        guard ClaudeBridge.modes.contains(mode) else {
            throw CLIError(L10n.text("provider.unsupported_permission_mode"))
        }
        if request["mode"] != nil, mode == "bypassPermissions",
            SessionProviderReply.boolean(request["confirmFullAccess"]) != true
        {
            throw CLIError(L10n.text("provider.bypassing_permissions_requires_explicit_confirmation"))
        }
        result["model"] = model
        result["effort"] = effort
        result["mode"] = mode
        return result
    }
}
