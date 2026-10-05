import Foundation

/// Parses owner-only runtime setup without starting a process or reading provider credentials.
enum AgentRuntimeCommand {
    static func payload(_ arguments: [String]) throws -> [String: Any] {
        let invalid = CLIError(L10n.text("agent.cli_usage"))
        if arguments == ["status"] { return ["cmd": "agent-runtime", "request": ["action": "status"]] }
        guard arguments.count >= 2, ["codex", "claude-mods"].contains(arguments[0]),
            ["enable", "disable", "bind"].contains(arguments[1])
        else { throw invalid }
        let adapter = arguments[0]
        let action = arguments[1]
        var values: [String: String] = [:]
        guard (arguments.count - 2) % 2 == 0 else { throw invalid }
        for index in stride(from: 2, to: arguments.count, by: 2) {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), values[flag] == nil, !arguments[index + 1].isEmpty else { throw invalid }
            values[flag] = arguments[index + 1]
        }
        let expected: Set<String>
        if action == "disable" {
            expected = []
        } else if action == "enable", adapter == "codex" {
            expected = ["--executable", "--workspace"]
        } else if action == "enable" {
            expected = ["--reviewed-version"]
        } else if adapter == "claude-mods" {
            expected = ["--session", "--workspace", "--runtime-version", "--contract-digest"]
        } else {
            throw invalid
        }
        guard Set(values.keys) == expected else { throw invalid }
        for field in ["--executable", "--workspace"] where values[field] != nil {
            guard values[field]!.hasPrefix("/") else { throw invalid }
        }
        var request: [String: String] = ["action": action, "adapter": adapter]
        let fields = [
            "--executable": "executable", "--workspace": "workspace", "--reviewed-version": "reviewedVersion",
            "--session": "session", "--runtime-version": "runtimeVersion", "--contract-digest": "contractDigest",
        ]
        for (flag, value) in values { request[fields[flag]!] = value }
        return ["cmd": "agent-runtime", "request": request]
    }
}
