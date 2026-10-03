import Foundation

/// Read the same local catalog as Codex; only supported, visible models are selectable.
struct CodexComposer {
    let catalogURL: URL
    init(
        catalogURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".codex/models_cache.json")
    ) { self.catalogURL = catalogURL }
    func models() throws -> [[String: Any]] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any],
            let rows = value["models"] as? [[String: Any]]
        else {
            throw CLIError(L10n.text("session.the_mac_model_list_is_unavailable_open_the_model_menu_in_codex_and_r"))
        }
        return rows.filter { $0["visibility"] as? String == "list" }.compactMap { item in
            guard let id = item["slug"] as? String else { return nil }
            let efforts = (item["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap {
                $0["effort"] as? String
            }
            return [
                "id": id, "name": item["display_name"] as? String ?? id,
                "description": item["description"] as? String ?? "", "efforts": efforts,
                "defaultEffort": item["default_reasoning_level"] as? String ?? "medium",
            ]
        }
    }
    static func selection(_ state: [String: Any]) -> [String: Any] {
        let settings = state["latestThreadSettings"] as? [String: Any] ?? [:]
        let permissions = state["currentPermissions"] as? [String: Any] ?? settings
        let profile =
            settings["permissions"] as? String ?? (settings["activePermissionProfile"] as? [String: Any])?["id"]
            as? String ?? (permissions["activePermissionProfile"] as? [String: Any])?["id"] as? String ?? ""
        let reviewer = settings["approvalsReviewer"] as? String ?? permissions["approvalsReviewer"] as? String ?? "user"
        let mode =
            profile == ":danger-full-access"
            ? "full-access"
            : ["guardian_subagent", "auto_review"].contains(reviewer)
                ? "guardian-approvals" : profile == ":workspace" ? "auto" : "custom"
        return [
            "model": settings["model"] as? String ?? state["latestModel"] as? String ?? "",
            "effort": settings["effort"] as? String ?? state["latestReasoningEffort"] as? String ?? "medium",
            "mode": mode,
        ]
    }
    func settings(_ request: [String: Any], state: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        if let model = request["model"] as? String {
            guard let entry = try models().first(where: { $0["id"] as? String == model }) else {
                throw CLIError(L10n.text("session.this_model_is_not_in_the_mac_s_available_model_list"))
            }
            let effort = request["effort"] as? String ?? entry["defaultEffort"] as? String ?? "medium"
            guard (entry["efforts"] as? [String] ?? []).contains(effort) else {
                throw CLIError(L10n.text("session.this_model_does_not_support_the_selected_reasoning_effort"))
            }
            result["model"] = model
            result["effort"] = effort
        }
        if let mode = request["mode"] as? String {
            switch mode {
            case "auto":
                result.merge(["permissions": ":workspace", "approvalPolicy": "on-request", "approvalsReviewer": "user"])
                { _, new in new }
            case "guardian-approvals":
                result.merge([
                    "permissions": ":workspace", "approvalPolicy": "on-request",
                    "approvalsReviewer": "guardian_subagent",
                ]) { _, new in new }
            case "full-access":
                guard SessionProviderReply.boolean(request["confirmFullAccess"]) == true else {
                    throw CLIError(L10n.text("session.full_access_requires_explicit_confirmation"))
                }
                result.merge([
                    "permissions": ":danger-full-access", "approvalPolicy": "never", "approvalsReviewer": "user",
                ]) { _, new in new }
            default: throw CLIError(L10n.text("session.unsupported_approval_mode"))
            }
        }
        guard !result.isEmpty else { throw CLIError(L10n.text("session.no_session_settings_to_update")) }
        return result
    }
}
