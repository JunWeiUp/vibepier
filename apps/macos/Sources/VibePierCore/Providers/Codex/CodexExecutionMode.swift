import AppKit
import Foundation

/// The inspected desktop uses the native collaboration preset, including its built-in instructions.
/// A settings ACK is not evidence of the selected preset; only an owner-bound snapshot is.
enum CodexExecutionMode {
    static func supports(build: String?) -> Bool {
        build.map { ["12553", "12947"].contains($0) } ?? false
    }

    static func catalog(_ response: [String: Any], build: String?) throws -> [[String: Any]] {
        guard supports(build: build), let masks = response["data"] as? [[String: Any]], masks.count <= 32 else {
            throw CLIError(L10n.text("session.the_current_codex_interface_is_incompatible"))
        }
        var result: [[String: Any]] = []
        for id in ["default", "plan"] {
            let matches = masks.filter { $0["mode"] as? String == id }
            guard matches.count == 1, let name = matches[0]["name"] as? String, !name.isEmpty else {
                throw CLIError(L10n.text("session.the_current_codex_interface_is_incompatible"))
            }
            result.append(["id": id, "name": name])
        }
        return result
    }

    static func nativeCatalog() throws -> [[String: Any]] {
        let url =
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first?
            .bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        guard let url, let bundle = Bundle(url: url),
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, supports(build: build)
        else { throw CLIError(L10n.text("session.the_current_codex_interface_is_incompatible")) }
        let executable = url.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CLIError(L10n.text("usage.codex_missing"))
        }
        let rpc = try CodexStdioRPC(executable: executable, purpose: .catalog)
        defer { rpc.close() }
        return try catalog(rpc.request("collaborationMode/list", params: [:]), build: build)
    }

    static func selected(_ state: [String: Any]) -> String? {
        let settings = state["latestThreadSettings"] as? [String: Any]
        let preset =
            settings?["collaborationMode"] as? [String: Any]
            ?? state["latestCollaborationMode"] as? [String: Any]
        return selectedPreset(preset)
    }

    private static func selectedPreset(_ preset: [String: Any]?) -> String? {
        guard let preset, let mode = preset["mode"] as? String, ["default", "plan"].contains(mode),
            let options = preset["settings"] as? [String: Any], let model = options["model"] as? String,
            !model.isEmpty
        else { return nil }
        return mode
    }

    static func turnSelection(_ state: [String: Any], turnID: String) -> String? {
        let matches = CodexConversation.turns(state).filter {
            ($0["turnId"] as? String ?? $0["id"] as? String) == turnID
        }
        guard matches.count == 1, let params = matches[0]["params"] as? [String: Any] else { return nil }
        return selectedPreset(params["collaborationMode"] as? [String: Any])
    }

    static func messageTurn(_ state: [String: Any], messageID: String) -> String? {
        let matches = CodexConversation.turns(state).filter { turn in
            (turn["items"] as? [[String: Any]] ?? []).contains {
                $0["type"] as? String == "userMessage"
                    && ($0["clientId"] as? String ?? $0["clientUserMessageId"] as? String) == messageID
            }
        }
        guard matches.count == 1 else { return nil }
        return matches[0]["turnId"] as? String ?? matches[0]["id"] as? String
    }

    static func preset(mode: String, model: String, effort: String, catalog: [[String: Any]]) throws -> [String: Any] {
        guard ["default", "plan"].contains(mode), !model.isEmpty,
            catalog.filter({ $0["id"] as? String == mode }).count == 1
        else { throw CLIError(L10n.text("session.the_current_codex_interface_is_incompatible")) }
        return [
            "mode": mode,
            "settings": ["model": model, "reasoning_effort": effort, "developer_instructions": NSNull()],
        ]
    }

    static func verifiedComposer(_ state: [String: Any], request: [String: Any]) throws -> [String: Any] {
        let actual = CodexConversation.composer(state)
        let keys = ["model", "effort", "mode", "executionMode"].filter { request[$0] != nil }
        guard !keys.isEmpty, keys.allSatisfy({ request[$0] as? String == actual[$0] as? String }) else {
            throw UnconfirmedDesktopMutation(
                reason: L10n.text("session.codex_did_not_apply_this_setting_refresh_and_retry"))
        }
        return actual
    }
}
