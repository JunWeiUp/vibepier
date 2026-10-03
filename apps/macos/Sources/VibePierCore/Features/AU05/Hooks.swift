// SPDX-License-Identifier: MIT
//
// AI-agent hook integration, modelled on Ulanzi Studio's ustudio-cli
// (installers/install.js and hooks/device-hook.js). Each agent calls
// `vibepier hook --agent <id> --event <name>`. The hook maps the event to a
// state and forwards only the state, the session ID and the agent ID to the
// daemon. Prompts, transcripts and tool inputs never leave the hook.

import Foundation

struct AgentDescriptor {
    enum Format { case nested, flat, copilot }

    var id: String
    var label: String
    var configPath: (URL) -> URL
    var events: [String]
    var format: Format
    var timeout: ((String) -> Int)?
    var codexFeatureFile: ((URL) -> URL)?
}

enum Agents {
    static var all: [AgentDescriptor] {
        [
            AgentDescriptor(
                id: "claude-code", label: "Claude Code",
                configPath: { $0.appendingPathComponent(".claude/settings.json") },
                events: [
                    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                    "PostToolUseFailure", "Stop", "StopFailure", "SubagentStart",
                    "SubagentStop", "Notification", "PermissionRequest", "PreCompact", "SessionEnd",
                ],
                format: .nested),
            AgentDescriptor(
                id: "codex", label: "Codex CLI",
                configPath: { $0.appendingPathComponent(".codex/hooks.json") },
                events: [
                    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop",
                    "PermissionRequest",
                ],
                format: .nested,
                timeout: { $0 == "PermissionRequest" ? 600 : 30 },
                codexFeatureFile: { $0.appendingPathComponent(".codex/config.toml") }),
            AgentDescriptor(
                id: "gemini-cli", label: "Gemini CLI",
                configPath: { $0.appendingPathComponent(".gemini/settings.json") },
                events: [
                    "SessionStart", "SessionEnd", "BeforeAgent", "BeforeTool", "AfterTool",
                    "AfterAgent", "Notification", "PreCompress",
                ],
                format: .nested),
            AgentDescriptor(
                id: "cursor-agent", label: "Cursor Agent",
                configPath: { $0.appendingPathComponent(".cursor/hooks.json") },
                events: [
                    "sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse", "postToolUse",
                    "postToolUseFailure", "subagentStart", "subagentStop", "preCompact",
                    "afterAgentThought", "stop",
                ],
                format: .flat),
            AgentDescriptor(
                id: "copilot-cli", label: "Copilot CLI",
                configPath: { $0.appendingPathComponent(".copilot/hooks/hooks.json") },
                events: [
                    "userPromptSubmit", "preToolUse", "postToolUse", "postToolUseFailure",
                    "agentStop", "agentStopFailure", "subagentStart", "subagentStop",
                ],
                format: .copilot),
        ]
    }

    static func find(_ id: String) -> AgentDescriptor? { all.first { $0.id == id } }
}

enum HookInstaller {
    /// Substring that identifies entries written by vibepier.
    static let marker = " hook --agent "

    static func executablePath() -> String {
        if let override = ProcessInfo.processInfo.environment["VIBEPIER_BIN"] { return override }
        let arg0 = CommandLine.arguments[0]
        let url =
            arg0.hasPrefix("/")
            ? URL(fileURLWithPath: arg0)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(arg0)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func command(agent: String, event: String, binary: String) -> String {
        "\(shellQuote(binary)) hook --agent \(agent) --event \(event)"
    }

    static func shellQuote(_ s: String) -> String {
        if s.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    struct Result {
        var agent: String
        var path: String
        var skipped: String?
        var added = 0
        var removed = 0
        var current = 0
    }

    static func install(
        _ agent: AgentDescriptor, home: URL, binary: String, configOverride: URL?,
        dryRun: Bool
    ) throws -> Result {
        let path = configOverride ?? agent.configPath(home)
        var r = Result(agent: agent.id, path: path.path)
        if configOverride == nil, !FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path) {
            r.skipped = L10n.text("cli.hook_missing_directory")
            return r
        }
        var root = try readJSON(path)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in agent.events {
            var entries = hooks[event] as? [Any] ?? []
            let before = entries.count
            entries.removeAll(where: isOurs)
            let removedOld = before - entries.count
            let cmd = command(agent: agent.id, event: event, binary: binary)
            entries.append(entry(agent, event: event, command: cmd))
            if removedOld == 1 {
                r.current += 1
            } else {
                r.added += 1
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        if !dryRun {
            try writeJSON(root, to: path)
            // With --config, keep the feature file next to the override so that
            // a test run never edits the real ~/.codex/config.toml.
            if let feature = configOverride.map({ $0.deletingLastPathComponent().appendingPathComponent("config.toml") }
            )
                ?? agent.codexFeatureFile?(home), agent.codexFeatureFile != nil
            {
                try enableCodexHooks(feature)
            }
        }
        return r
    }

    static func uninstall(_ agent: AgentDescriptor, home: URL, configOverride: URL?, dryRun: Bool) throws -> Result {
        let path = configOverride ?? agent.configPath(home)
        var r = Result(agent: agent.id, path: path.path)
        guard FileManager.default.fileExists(atPath: path.path) else {
            r.skipped = L10n.text("cli.hook_missing_config")
            return r
        }
        var root = try readJSON(path)
        guard var hooks = root["hooks"] as? [String: Any] else { return r }
        for (event, value) in hooks {
            guard var entries = value as? [Any] else { continue }
            let before = entries.count
            entries.removeAll(where: isOurs)
            r.removed += before - entries.count
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        root["hooks"] = hooks
        if !dryRun, r.removed > 0 { try writeJSON(root, to: path) }
        return r
    }

    static func status(_ agent: AgentDescriptor, home: URL) -> (installed: Int, total: Int, path: String) {
        let path = agent.configPath(home)
        guard let root = try? readJSON(path), let hooks = root["hooks"] as? [String: Any] else {
            return (0, agent.events.count, path.path)
        }
        let n = agent.events.filter { e in (hooks[e] as? [Any])?.contains(where: isOurs) == true }.count
        return (n, agent.events.count, path.path)
    }

    static func entry(_ agent: AgentDescriptor, event: String, command: String) -> [String: Any] {
        switch agent.format {
        case .nested:
            var inner: [String: Any] = ["type": "command", "command": command]
            if let t = agent.timeout?(event) { inner["timeout"] = t }
            return ["matcher": "*", "hooks": [inner]]
        case .flat:
            return ["type": "command", "command": command]
        case .copilot:
            return ["type": "command", "bash": command, "command": command]
        }
    }

    static func isOurs(_ entry: Any) -> Bool {
        guard let dict = entry as? [String: Any] else { return false }
        for key in ["command", "bash"] {
            if let c = dict[key] as? String, c.contains(marker), c.contains("vibepier") { return true }
        }
        if let inner = dict["hooks"] as? [Any] { return inner.contains(where: isOurs) }
        return false
    }

    static func readJSON(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "vibepier", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.text("cli.hook_invalid_config", url.path)])
        }
        return obj
    }

    static func writeJSON(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("vibepier-backup")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: url, to: backup)
        }
        var data = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    /// Sets `[features] hooks = true` in ~/.codex/config.toml, as ustudio-cli does.
    static func enableCodexHooks(_ url: URL) throws {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            var end = lines.count
            for i in (start + 1)..<lines.count where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                end = i
                break
            }
            if let i = (start + 1..<end).first(where: {
                lines[$0].trimmingCharacters(in: .whitespaces).range(of: #"^hooks\s*="#, options: .regularExpression)
                    != nil
            }) {
                if lines[i].contains("true") { return }
                lines[i] = "hooks = true"
            } else {
                lines.insert("hooks = true", at: start + 1)
            }
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append(contentsOf: ["[features]", "hooks = true"])
        }
        text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// `vibepier hook`: called by the agent for every hook event.
enum HookCommand {
    static func run(agent: String, eventArg: String?) -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let payload = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]) ?? [:]
        let event =
            (payload["hook_event_name"] as? String) ?? (payload["event"] as? String)
            ?? (payload["eventName"] as? String) ?? (payload["hookEventName"] as? String) ?? eventArg ?? ""
        var state = AgentEventMap.state(agent: agent, event: event)
        if agent == "gemini-cli", event == "AfterTool",
            let response = payload["tool_response"] as? [String: Any], response["error"] != nil
        {
            state = "error"
        }
        if let state {
            let session =
                ["session_id", "sessionId", "conversation_id", "thread_id", "turn_id"]
                .compactMap { payload[$0] as? String }.first { !$0.isEmpty } ?? "default"
            _ = ControlSocket.request([
                "cmd": "agent-state", "agent": agent, "state": state,
                "session": session, "event": event,
            ])
        }
        print(AgentEventMap.stdout(agent: agent, event: event))
        return 0
    }
}
