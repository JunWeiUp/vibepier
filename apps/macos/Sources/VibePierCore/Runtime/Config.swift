// SPDX-License-Identifier: MIT

import Foundation
import VibeKit

enum Paths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("vibepier", isDirectory: true)
    }

    static var configFile: URL {
        if let override = ProcessInfo.processInfo.environment["VIBEPIER_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory.appendingPathComponent("config.json")
    }

    /// The control socket path. A Unix socket path must fit in 104 bytes, so a
    /// long home directory falls back to the per-user temporary directory.
    static var socket: URL {
        if let override = ProcessInfo.processInfo.environment["VIBEPIER_SOCKET"] {
            return URL(fileURLWithPath: override)
        }
        let preferred = supportDirectory.appendingPathComponent("vibepier.sock")
        if preferred.path.utf8.count < 100 { return preferred }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 {
            let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let tmp = String(decoding: bytes, as: UTF8.self)
            return URL(fileURLWithPath: tmp).appendingPathComponent("vibepier.sock")
        }
        return preferred
    }

    static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/vibepier.log")
    }

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
    }
}

/// A host-side action that the daemon runs when a control fires.
struct HostAction: Codable, Equatable, Sendable {
    /// A shell command, run with /bin/sh -c.
    var run: String?
    /// A URL, file, or application to open with /usr/bin/open.
    var open: String?
    /// A hotkey to synthesise with CGEvent (needs Accessibility permission).
    var keys: String?
    /// AppleScript source to run with /usr/bin/osascript.
    var applescript: String?
    /// "press" (default), "release", or "both".
    var on: String?
    /// Event on which to synthesize keys. Defaults to `on` for compatibility.
    var keysOn: String?
    /// "tap" (default) or "hold" across press and release events.
    var keysMode: String?
    /// Run events in order and wait for the command before sending keys.
    var sequential: Bool?
    /// Switch AU05 in-process before/after a held voice shortcut.
    var switchInput: Bool?

    var trigger: String { on ?? "press" }
}

/// LED work types for LED indices 1...3, keyed by LED index as a string.
typealias LEDPattern = [String: UInt8]

struct Settings: Codable, Equatable {
    /// Auto power-off in seconds. 0 = never.
    var sleepTime: UInt32?
    var standbyTime: UInt32?
    var vibration: Bool?
    var motorStrength: UInt16?
    var denoise: Bool?
    /// 0 = off, 1 = all on, 2 = work mode.
    var lightMode: UInt8?
    /// 0...20 in Ulanzi Studio.
    var brightness: UInt8?
    var hooksMode: Bool?
    var audioButtonSystemMode: UInt8?
    /// LED work time for LEDs 1...3. The firmware turns an LED off when it
    /// expires. 0 turns the LED off almost at once, the factory value is 10,
    /// and 255 keeps it lit. The daemon uses 255 when this is not set.
    var ledWorkTime: UInt8?
}

struct Config: Codable, Equatable {
    /// Firmware bindings per control. Values: a hotkey ("cmd+shift+4"),
    /// "fixed:<name or code>", or "factory".
    var buttons: [String: String]?
    /// Host actions per control, run by the daemon on key events.
    var actions: [String: HostAction]?
    var settings: Settings?
    /// Agent state -> LED work types. Missing states fall back to the Ulanzi Studio table.
    var agentLights: [String: LEDPattern]?
    /// Set to false to leave the LEDs alone when agent hooks fire.
    var agentLightsEnabled: Bool?
    /// "vibepier" (default) for distinct patterns, or "ulanzi" for the Ulanzi Studio table.
    var agentLightsPreset: String?
    /// While the daemon runs, the firmware reports key presses instead of typing
    /// the stored bindings, so the daemon replays them. Set to false to disable.
    var replayBindings: Bool?
    /// Double-press the knob to enter agent mode, where turning steps through
    /// Herdr agents: "herdr" (default), or "off" to fire knob presses at once.
    var agentMode: String?
    /// "auto": heartbeat only during talk; "on" or "off": manual override.
    var heartbeatMode: String?
    /// The terminal app that runs Herdr, for example "iTerm2" or "Ghostty". When it
    /// is not set, the daemon finds the app from the parent processes of Herdr.
    var herdrApp: String?
    /// When to move that terminal to the front: "always" (default) on the
    /// double-press and on each agent switch, "enter" only on the double-press,
    /// or "off".
    var herdrFocusTerminal: String?
    /// Where to move the pointer when the terminal comes to the front, so that the
    /// knob scrolls the terminal: "bottom-right" (default), "bottom-left" or "off".
    var herdrPointer: String?
    /// UDP port for the Android remote (default 47800). 0 turns it off.
    var remotePort: Int?
    /// Ordered Mac-configured application bundle IDs; empty strings leave a slot unassigned.
    var applicationShortcuts: [String]?
    /// Cloud relay for the Android remote, e.g. "wss://example.com/vibepier/relay". Empty turns it off.
    var relayURL: String?
    /// Room shared by this Mac and its phones on the relay.
    var relayRoom: String?
    /// Read only for migration of development configs; ordinary saves refuse plaintext credentials.
    var relaySecret: String?
    /// Explicit opt-in: recover failed Android relay DNS through validated AliDNS HTTPS.
    var relayDNSRecovery: Bool?
    /// New installs start with verified voice behavior and no hardware-setting writes.
    static let defaults = Config(
        actions: ["talk": HostAction(keys: "rcmd", on: "both", keysMode: "hold", sequential: true, switchInput: true)],
        agentLightsEnabled: false,
        agentMode: "off",
        heartbeatMode: "on")
    static let example = defaults

    static func load(_ url: URL = Paths.configFile) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaults }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    func save(_ url: URL = Paths.configFile) throws {
        guard relaySecret == nil else {
            throw CLIError(L10n.text("core.migrate_the_relay_secret_to_keychain_before_saving_it_cannot_be_writ"))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Agent states used by the Ulanzi Studio hook scripts (hooks/mappings.js).
enum AgentState: String, CaseIterable {
    case idle, thinking, working, error, attention, notification, sweeping, sleeping
}

/// LED work types, confirmed by eye on an AU05: 0 = off, 1 = solid, 2 = breathing.
/// LED 1 sits on the confirm key, LED 2 on the cancel key, and LED 3 on the knob.
/// LED 0 is not visible.
enum LEDType {
    static let off: UInt8 = 0
    static let solid: UInt8 = 1
    static let breathing: UInt8 = 2
}

/// Ulanzi Studio's `LedIndicator::getConfigForState` table (v3.3.9). Every
/// state maps to LED 1 = 0, LED 2 = 0, LED 3 = 1, so the LEDs never change.
let vendorAgentLights: [String: LEDPattern] = Dictionary(
    uniqueKeysWithValues:
        AgentState.allCases.map { ($0.rawValue, ["1": 0, "2": 0, "3": 1]) })

/// The vibepier default: the knob shows activity, and the confirm and cancel keys
/// light up when the agent needs an answer from you.
let defaultAgentLights: [String: LEDPattern] = [
    // Ready: knob solid.
    "idle": ["1": LEDType.off, "2": LEDType.off, "3": LEDType.solid],
    // Busy: knob breathing.
    "thinking": ["1": LEDType.off, "2": LEDType.off, "3": LEDType.breathing],
    "working": ["1": LEDType.off, "2": LEDType.off, "3": LEDType.breathing],
    "sweeping": ["1": LEDType.off, "2": LEDType.off, "3": LEDType.breathing],
    // Permission request: confirm and cancel breathing. Answer with either key.
    "notification": ["1": LEDType.breathing, "2": LEDType.breathing, "3": LEDType.solid],
    // Finished and waiting for your next prompt: confirm solid.
    "attention": ["1": LEDType.solid, "2": LEDType.off, "3": LEDType.solid],
    // Failure: cancel solid.
    "error": ["1": LEDType.off, "2": LEDType.solid, "3": LEDType.solid],
    // Session ended: all off.
    "sleeping": ["1": LEDType.off, "2": LEDType.off, "3": LEDType.off],
]

/// Maps an agent hook event to a state, as in Ulanzi Studio hooks/mappings.js.
enum AgentEventMap {
    static let maps: [String: [String: String]] = [
        "claude-code": [
            "SessionStart": "idle", "UserPromptSubmit": "thinking", "PreToolUse": "working",
            "PostToolUse": "working", "PostToolUseFailure": "error", "Stop": "attention",
            "StopFailure": "error", "SubagentStart": "working", "SubagentStop": "working",
            // Claude Code sends Notification both for permission prompts and when it
            // waits for input. PermissionRequest covers the prompts, so Notification
            // shows the finished pattern. Ulanzi Studio maps it to "notification".
            "Notification": "attention", "PermissionRequest": "notification", "PreCompact": "sweeping",
            "SessionEnd": "sleeping",
        ],
        "codex": [
            "SessionStart": "idle", "UserPromptSubmit": "thinking", "PreToolUse": "working",
            "PostToolUse": "working", "Stop": "attention", "PermissionRequest": "notification",
        ],
        "gemini-cli": [
            "SessionStart": "idle", "SessionEnd": "sleeping", "BeforeAgent": "thinking",
            "BeforeTool": "working", "AfterTool": "working", "AfterAgent": "idle",
            "Notification": "notification", "PreCompress": "sweeping",
        ],
        "cursor-agent": [
            "sessionStart": "idle", "sessionEnd": "sleeping", "beforeSubmitPrompt": "thinking",
            "userPromptSubmit": "thinking", "preToolUse": "working", "postToolUse": "working",
            "postToolUseFailure": "error", "stop": "attention", "stopFailure": "error",
            "notification": "notification", "subagentStart": "working", "subagentStop": "working",
            "preCompact": "sweeping", "afterAgentThought": "thinking",
        ],
        "copilot-cli": [
            "userPromptSubmit": "thinking", "preToolUse": "working", "postToolUse": "working",
            "postToolUseFailure": "error", "agentStop": "attention", "agentStopFailure": "error",
            "subagentStart": "working", "subagentStop": "working",
        ],
    ]

    static func state(agent: String, event: String) -> String? {
        maps[agent]?[event]
    }

    /// The stdout that each agent expects from a hook (hooks/mappings.js `stdoutForHook`).
    static func stdout(agent: String, event: String) -> String {
        if agent == "gemini-cli", event == "BeforeTool" || event == "AfterTool" {
            return #"{"decision":"allow"}"#
        }
        return "{}"
    }
}
