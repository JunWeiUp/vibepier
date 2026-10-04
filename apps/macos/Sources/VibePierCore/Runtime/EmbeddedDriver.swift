import Foundation
import VibeKit

public enum DriverNotifications {
    public static let statusChanged = Notification.Name("io.github.junweiup.vibepier.statusChanged")
}

public struct DriverResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var success: Bool { exitCode == 0 }
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Shared by the menu and HID callbacks, with a single transport/session.
public final class EmbeddedDriver: @unchecked Sendable {
    public static let shared = EmbeddedDriver()
    private let lock = NSLock()
    private var daemon: Daemon?
    public init() {}

    public func start() throws {
        try lock.withLock {
            guard daemon == nil else { return }
            let driver = Daemon(config: try Config.load(), verbose: false, enableBluetooth: true)
            try driver.start()
            daemon = driver
        }
    }

    public func stop() {
        let driver = lock.withLock {
            let d = daemon
            daemon = nil
            return d
        }
        driver?.stop()
    }

    public func run(_ args: [String]) async -> DriverResult {
        do {
            let result = try await execute(args)
            return DriverResult(exitCode: 0, stdout: result, stderr: "")
        } catch {
            return DriverResult(exitCode: 1, stdout: "", stderr: String(describing: error))
        }
    }

    private func execute(_ args: [String]) async throws -> String {
        guard let driver = lock.withLock({ daemon }) else {
            throw CLIError(L10n.text("core.the_built_in_control_service_is_not_running"))
        }
        let key = driver.key
        switch args.first {
        case "status", "reload":
            let result = await driver.handle(["cmd": args[0]])
            guard result["ok"] as? Bool == true else {
                throw CLIError(result["error"] as? String ?? L10n.text("core.invalid_receipt"))
            }
            return try jsonObject(result)
        case "task-open":
            guard args.count == 3 else { throw CLIError(L10n.text("core.missing_task_provider_or_session_id")) }
            let result = await driver.handle(["cmd": "task-open", "provider": args[1], "id": args[2]])
            guard result["ok"] as? Bool == true else {
                throw CLIError(result["error"] as? String ?? L10n.text("core.could_not_open_the_task_session"))
            }
            return try jsonObject(result)
        case "task-clear-unread":
            guard args.count > 1 else { throw CLIError(L10n.text("core.missing_unviewed_tasks")) }
            let result = await driver.handle(["cmd": "task-clear-unread", "keys": Array(args.dropFirst())])
            guard result["ok"] as? Bool == true else {
                throw CLIError(result["error"] as? String ?? L10n.text("core.could_not_clear_unviewed_tasks"))
            }
            return try jsonObject(result)
        case "application-shortcut-set", "application-shortcut-move":
            guard args.count == 3, let index = Int(args[1]) else {
                throw CLIError(L10n.text("core.missing_application_slot"))
            }
            var request: [String: Any] = ["cmd": args[0], "index": index]
            if args[0] == "application-shortcut-move" {
                guard let target = Int(args[2]) else { throw CLIError(L10n.text("core.invalid_destination_slot")) }
                request["target"] = target
            } else {
                request["bundleID"] = args[2]
            }
            let result = await driver.handle(request)
            guard result["ok"] as? Bool == true else {
                throw CLIError(result["error"] as? String ?? L10n.text("core.could_not_save_application_settings"))
            }
            return try jsonObject(result)
        case "application-shortcut-add", "application-shortcut-remove":
            guard args.count == 2 else { throw CLIError(L10n.text("core.missing_application_settings")) }
            var request: [String: Any] = ["cmd": args[0]]
            if args[0] == "application-shortcut-add" {
                request["bundleID"] = args[1]
            } else {
                guard let index = Int(args[1]) else { throw CLIError(L10n.text("core.invalid_application_slot")) }
                request["index"] = index
            }
            let result = await driver.handle(request)
            guard result["ok"] as? Bool == true else {
                throw CLIError(result["error"] as? String ?? L10n.text("core.could_not_save_application_settings"))
            }
            return try jsonObject(result)
        case "heartbeat":
            guard args.count == 2 else { throw CLIError(L10n.text("core.missing_heartbeat_enabled_state")) }
            return try jsonObject(await driver.handle(["cmd": "heartbeat", "enabled": try parseBool(args[1])]))
        case "relay-config":
            // relay-config <url> <room> [secret]; an empty url turns the relay off.
            guard (2...5).contains(args.count) else {
                throw CLIError(L10n.text("core.usage_relay_config_url_room_secret"))
            }
            let result = await driver.handle([
                "cmd": "relay-config", "url": args[1],
                "room": args.count > 2 ? args[2] : "", "secret": args.count > 3 ? args[3] : "",
                "dnsRecovery": args.count > 4 ? args[4] : "system",
            ])
            guard result["ok"] as? Bool == true else {
                throw CLIError(result["error"] as? String ?? L10n.text("core.could_not_save_cloud_relay_settings"))
            }
            return try jsonObject(result)
        case "relay-pairing":
            let result = await driver.handle(["cmd": "relay-pairing"])
            guard result["ok"] as? Bool == true, let code = result["code"] as? String else {
                throw CLIError(result["error"] as? String ?? L10n.text("core.cloud_relay_is_not_configured"))
            }
            return code
        case "heartbeat-mode":
            guard args.count == 2 else { throw CLIError(L10n.text("core.missing_heartbeat_mode")) }
            let result = await driver.handle(["cmd": "heartbeat-mode", "mode": args[1], "persist": true])
            guard result["ok"] as? Bool == true else {
                throw CLIError(result["error"] as? String ?? L10n.text("core.could_not_change_heartbeat_mode"))
            }
            return try jsonObject(result)
        case "service":
            try Service.configureAppLogin(enabled: args.dropFirst().first == "install")
            return "ok"
        case "hooks":
            let home = FileManager.default.homeDirectoryForCurrentUser
            let command = args.dropFirst().first ?? "status"
            var lines: [String] = []
            for agent in Agents.all {
                switch command {
                case "install":
                    _ = try HookInstaller.install(
                        agent, home: home, binary: home.appendingPathComponent(".local/bin/vibepier").path,
                        configOverride: nil, dryRun: false)
                case "uninstall":
                    _ = try HookInstaller.uninstall(agent, home: home, configOverride: nil, dryRun: false)
                default:
                    let status = HookInstaller.status(agent, home: home)
                    lines.append("\(agent.id) \(status.installed)/\(status.total) events")
                }
            }
            return lines.joined(separator: "\n")
        case "keys":
            return Hotkey.allNames.map { $0.1.joined(separator: ", ") }.joined(separator: "\n")
                + "\n" + FixedFunction.named.map { "fixed:\($0.name)" }.joined(separator: "\n")
        default: break
        }
        guard driver.session.isConnected else { throw CLIError(L10n.text("mac.no_receiver_detected")) }
        try await driver.session.waitUntilReady()
        switch args.first {
        case "info":
            return try await panelInfo(key)
        case "settings": return try json(try await key.settings())
        case "set":
            try await key.requireMic()
            try await setDeviceSetting(Array(args.dropFirst()), key: key)
            return "ok"
        case "buttons":
            try await key.requireMic()
            return try await key.bindings().map {
                "\($0.control.name.padding(toLength: 11, withPad: " ", startingAt: 0)) \($0.summary)"
            }.joined(separator: "\n")
        case "bind":
            guard args.count >= 3, let control = Control(name: args[1]) else {
                throw CLIError(L10n.text("core.invalid_key"))
            }
            try await key.requireMic()
            try await Apply.binding(args.dropFirst(2).joined(separator: " "), control: control, key: key, force: true)
            await driver.refreshBindings()
            return "ok"
        case "reset-buttons":
            try await key.requireMic()
            for control in Control.allCases { try await key.resetBinding(control) }
            await driver.refreshBindings()
            return "ok"
        default: throw CLIError(L10n.text("core.unsupported_panel_action"))
        }
    }

    private struct PanelInfo: Encodable {
        struct Dongle: Encodable {
            let micLinked: Bool
            let version: VersionInfo?
        }
        struct Device: Encodable { let battery: BatteryStatus }
        let dongle: Dongle
        let device: Device?
        let settings: DeviceSettings?
    }

    /// Only fields actually shown in the menu: no serial/flash/MAC collection.
    private func panelInfo(_ key: VibeKey) async throws -> String {
        let linked = try await key.isMicLinked()
        var version: VersionInfo?
        if case .dongleVersion(let value) = VibeMessage.parse(try await key.session.send(DongleRequest.version)) {
            version = value
        }
        let battery = linked ? try await key.battery() : nil
        let settings = linked ? try await key.settings() : nil
        return try json(
            PanelInfo(
                dongle: .init(micLinked: linked, version: version),
                device: battery.map { .init(battery: $0) }, settings: settings))
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private func jsonObject(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
