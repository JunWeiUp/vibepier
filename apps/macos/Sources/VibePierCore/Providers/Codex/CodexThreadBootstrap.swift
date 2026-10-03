import Foundation

/// The native thread/start contract creates an empty persistent thread in an existing
/// project. Its returned identity and configuration must be verified before the desktop
/// is asked to open it or submit the first turn. This component never calls turn/start.
enum CodexThreadBootstrap {
    /// Native thread/start reserves an in-memory thread only. Naming saves its project
    /// metadata; archive flushes the native rollout, and unarchive restores visibility.
    /// Only this newly verified empty thread is touched. No model turn runs here.
    static func startPersisted(
        parameters: [String: Any], project: CodexCreationProject, settings: [String: Any],
        title: String, request: (String, [String: Any]) throws -> [String: Any]
    ) throws -> [String: Any] {
        let reply = try request("thread/start", parameters)
        let created = try verified(reply, project: project, settings: settings)
        _ = try request(
            "thread/name/set",
            [
                "threadId": created.id, "name": title.isEmpty ? project.name : String(title.prefix(80)),
            ])
        _ = try request("thread/archive", ["threadId": created.id])
        let restored = try request("thread/unarchive", ["threadId": created.id])
        var metadata = restored
        metadata["cwd"] = (restored["thread"] as? [String: Any])?["cwd"]
        guard try verified(metadata, project: project, settings: [:]) == created else {
            throw CLIError(L10n.text("session.codex_creation_project_unverified"))
        }
        return reply
    }

    struct Created: Equatable, Sendable {
        let id: String
        let cwd: String
        let projectID: String
    }

    static func parameters(project: CodexCreationProject, settings: [String: Any]) throws -> [String: Any] {
        guard UUID(uuidString: project.id) != nil, project.cwd.hasPrefix("/"), !project.cwd.contains("\0"),
            project.cwd.utf8.count <= 4096
        else { throw CLIError(L10n.text("session.codex_creation_project_unverified")) }
        var result: [String: Any] = [
            "cwd": project.cwd, "projectId": project.id, "runtimeWorkspaceRoots": [project.cwd],
            "ephemeral": false, "experimentalRawEvents": false, "allowProviderModelFallback": false,
        ]
        for key in ["model", "approvalPolicy", "approvalsReviewer", "permissions"] {
            if let value = settings[key] as? String { result[key] = value }
        }
        if let effort = settings["effort"] as? String { result["config"] = ["model_reasoning_effort": effort] }
        return result
    }

    static func verified(_ reply: [String: Any], project: CodexCreationProject, settings: [String: Any]) throws
        -> Created
    {
        guard let thread = reply["thread"] as? [String: Any],
            let id = thread["id"] as? String, UUID(uuidString: id) != nil,
            thread["cwd"] as? String == project.cwd, reply["cwd"] as? String == project.cwd,
            thread["projectId"] as? String == project.id,
            SessionProviderReply.boolean(thread["ephemeral"]) == false,
            let turns = thread["turns"] as? [Any], turns.isEmpty,
            !((thread["status"] as? [String: Any])?["type"] as? String == "active")
        else { throw CLIError(L10n.text("session.codex_creation_project_unverified")) }
        for (key, nativeKey) in [
            ("model", "model"), ("effort", "reasoningEffort"), ("approvalPolicy", "approvalPolicy"),
        ] {
            if let expected = settings[key] as? String, reply[nativeKey] as? String != expected {
                throw CLIError(L10n.text("session.codex_creation_settings_unverified"))
            }
        }
        if let profile = settings["permissions"] as? String,
            (reply["activePermissionProfile"] as? [String: Any])?["id"] as? String != profile
        {
            throw CLIError(L10n.text("session.codex_creation_settings_unverified"))
        }
        if let reviewer = settings["approvalsReviewer"] as? String {
            let native = reply["approvalsReviewer"] as? String
            let matches = native == reviewer || (reviewer == "guardian_subagent" && native == "auto_review")
            guard matches else { throw CLIError(L10n.text("session.codex_creation_settings_unverified")) }
        }
        return Created(id: id, cwd: project.cwd, projectID: project.id)
    }
}
