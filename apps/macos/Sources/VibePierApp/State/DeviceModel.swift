import Foundation
import SwiftUI
import VibePierCore

// MARK: - JSON models for `vibepier info --json` / `vibepier settings --json`

struct InfoJSON: Codable {
    struct Version: Codable { let version: String }
    struct Battery: Codable {
        let percent: Int
        let charging: Bool
        let millivolts: Int
        let chargeFull: Bool
    }
    struct Device: Codable {
        let battery: Battery
        let serialNumber: String?
        let version: Version?
    }
    struct Dongle: Codable {
        let micLinked: Bool
        let serialNumber: String?
        let version: Version?
    }
    let device: Device?
    let dongle: Dongle?
    let settings: SettingsJSON?
}

/// Served from the daemon's memory; reading it does not query the AU05.
struct DaemonStatusJSON: Decodable {
    struct Bluetooth: Decodable {
        let state: String
        let connectedCount: Int
    }
    struct Relay: Decodable {
        let dnsRecovery: Bool?
        let state: String
        let connectedCount: Int
        let url: String?
        let room: String?
    }
    struct Battery: Decodable {
        let percent: Int
        let charging: Bool
        let millivolts: Int
    }
    let ok: Bool
    let dongleConnected: Bool
    let micLinked: Bool
    let battery: Battery?
    let agentLightsEnabled: Bool?
    let launchAtLogin: Bool?
    let accessibilityTrusted: Bool?
    let heartbeatEnabled: Bool?
    let heartbeatInterval: Double?
    let heartbeatMode: String?
    let connectedPhoneIDs: [String]?
    let remoteConnectedAddresses: [String]?
    let remoteListening: Bool?
    let remotePort: Int?
    let bluetooth: Bluetooth?
    let relay: Relay?
    let applicationShortcuts: [ApplicationShortcut]?
    let applicationLaunchError: String?
    let taskActivity: TaskActivityJSON?
}

struct SettingsJSON: Codable {
    struct Lights: Codable {
        let mode: Int
        let allOnBrightness: Int
    }
    let lights: Lights
    let noiseReductionLevel: Int
    let sleepTimeSeconds: Int
    let standbyTimeSeconds: Int
    let microphoneEnabled: Bool?
}

struct KeyBinding: Identifiable, Equatable {
    let control: String
    var keys: String
    var id: String { control }
}

// MARK: - Observed state

@MainActor
final class DeviceModel: ObservableObject {
    enum LinkState { case noDongle, dongleOnly, linked, unknown }

    @Published var linkState: LinkState = .unknown
    @Published var batteryPercent: Int?
    @Published var millivolts: Int?
    @Published var charging = false
    @Published var chargeFull = false
    @Published var firmware = ""
    @Published var daemonRunning = false
    @Published var launchAtLogin = false
    @Published var accessibilityTrusted = true
    @Published var heartbeatEnabled = true
    @Published var heartbeatInterval: Double = 1
    @Published var heartbeatMode = "on"
    @Published var connectedPhoneIDs: [String] = []
    @Published var remoteConnectedAddresses: [String] = []
    @Published var remoteListening = false
    @Published var remotePort = 47800
    @Published var bluetoothState = L10n.text("mac.not_started")
    @Published var bluetoothConnectedCount = 0
    @Published var relayState = L10n.text("mac.not_configured")
    @Published var relayConnectedCount = 0
    @Published var relayURL = ""
    @Published var relayRoom = ""
    @Published var relayDNSRecovery = false
    @Published var relayError = ""
    @Published var applicationShortcuts: [ApplicationShortcut] = []
    @Published var applicationShortcutError = ""
    @Published var taskActivity = TaskActivityJSON.empty
    @Published var taskActivityError = ""
    @Published var openingTask: TaskSessionKey?
    @Published var clearingUnread = false
    @Published var deviceSettingError = ""
    @Published var settings: SettingsJSON?
    @Published var bindings: [KeyBinding] = []
    @Published var hooksLines: [String] = []
    @Published var agentLightsEnabled = false
    @Published var inputDevices: [AudioManager.InputDevice] = []
    @Published var defaultInputUID: String?
    @Published var lastUpdated: Date?
    @Published var refreshing = false

    private var timer: Timer?
    private var statusObserver: NSObjectProtocol?
    private var operation: Task<Void, Never>?
    private var hooksLoaded = false
    private var statusRefreshPending = false
    private let runCommand: ([String]) async -> AppCommands.Result

    init(runCommand: @escaping ([String]) async -> AppCommands.Result = AppCommands.run) {
        self.runCommand = runCommand
        statusObserver = NotificationCenter.default.addObserver(
            forName: DriverNotifications.statusChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshStatus() }
        }
    }

    static let controlOrder = ["talk", "confirm", "cancel", "knob-press", "knob-left", "knob-right"]

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    func startMonitoring() {
        stopMonitoring()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshStatus() }
        }
        timer?.tolerance = 5
        Task { await preparePanel() }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Serialize explicit changes and reads so CLI sessions do not compete.
    private func perform(_ body: @escaping @MainActor (DeviceModel) async -> Void) async {
        let previous = operation
        let next = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.refreshing = true
            defer { self.refreshing = false }
            await body(self)
            // Notifications received during an awaited command must still update a closed menu panel.
            while self.statusRefreshPending { await self.readStatus() }
        }
        operation = next
        await next.value
    }

    /// Every periodic tick stays local, even after a disconnect/reconnect.
    func refreshStatus() async {
        guard !refreshing else {
            statusRefreshPending = true
            return
        }
        await perform { model in await model.readStatus() }
    }

    func preparePanel() async {
        await perform { model in
            await model.readStatus()
            if model.linkState == .linked && model.settings == nil {
                await model.readInfo()
            }
            if model.agentLightsEnabled && !model.hooksLoaded { await model.readHooks() }
        }
    }

    /// The explicit Refresh button may query hardware, including without a daemon.
    func refresh() async {
        await perform { model in
            await model.readStatus()
            await model.readInfo()
            if model.agentLightsEnabled { await model.readHooks() }
        }
    }

    private func readStatus() async {
        statusRefreshPending = false
        let result = await runCommand(["status"])
        if result.success, let data = result.stdout.data(using: .utf8),
            let status = try? JSONDecoder().decode(DaemonStatusJSON.self, from: data), status.ok
        {
            daemonRunning = true
            launchAtLogin = status.launchAtLogin ?? false
            accessibilityTrusted = status.accessibilityTrusted ?? true
            heartbeatEnabled = status.heartbeatEnabled ?? true
            heartbeatInterval = status.heartbeatInterval ?? 1
            heartbeatMode = status.heartbeatMode ?? "on"
            connectedPhoneIDs = Array(Set(status.connectedPhoneIDs ?? [])).sorted()
            remoteConnectedAddresses = status.remoteConnectedAddresses ?? []
            remoteListening = status.remoteListening ?? false
            remotePort = status.remotePort ?? 47800
            bluetoothState = status.bluetooth?.state ?? L10n.text("mac.not_started")
            bluetoothConnectedCount = status.bluetooth?.connectedCount ?? 0
            relayState = status.relay?.state ?? L10n.text("mac.not_configured")
            relayConnectedCount = status.relay?.connectedCount ?? 0
            relayURL = status.relay?.url ?? ""
            relayRoom = status.relay?.room ?? ""
            relayDNSRecovery = status.relay?.dnsRecovery ?? false
            applicationShortcuts = status.applicationShortcuts ?? []
            applicationShortcutError = status.applicationLaunchError ?? ""
            taskActivity = status.taskActivity ?? .empty
            agentLightsEnabled = status.agentLightsEnabled ?? true
            linkState = !status.dongleConnected ? .noDongle : (status.micLinked ? .linked : .dongleOnly)
            batteryPercent = linkState == .linked ? status.battery?.percent : nil
            millivolts = linkState == .linked ? status.battery?.millivolts : nil
            charging = linkState == .linked && (status.battery?.charging ?? false)
            chargeFull = chargeFull && batteryPercent == 100 && charging
        } else {
            daemonRunning = false
            connectedPhoneIDs = []
            remoteConnectedAddresses = []
            remoteListening = false
            bluetoothConnectedCount = 0
            relayConnectedCount = 0
            agentLightsEnabled = false
            linkState = .unknown
            batteryPercent = nil
            millivolts = nil
            charging = false
            chargeFull = false
            taskActivity = .empty
        }
        if linkState != .linked {
            settings = nil
            firmware = ""
            bindings = []
        }
        if !agentLightsEnabled {
            hooksLines = []
            hooksLoaded = false
        }
        refreshAudioDevices()
        lastUpdated = Date()
    }

    private func readInfo() async {
        let info = await runCommand(["info", "--json"])
        if info.success, let data = info.stdout.data(using: .utf8),
            let parsed = try? JSONDecoder().decode(InfoJSON.self, from: data)
        {
            // `info` already contains settings; do not issue a second settings query.
            deviceSettingError = ""
            settings = parsed.settings
            firmware = parsed.dongle?.version?.version ?? parsed.device?.version?.version ?? ""
            if let dongle = parsed.dongle {
                linkState = dongle.micLinked ? .linked : .dongleOnly
            } else {
                linkState = .noDongle
            }
            batteryPercent = parsed.device?.battery.percent
            millivolts = parsed.device?.battery.millivolts
            charging = parsed.device?.battery.charging ?? false
            chargeFull = parsed.device?.battery.chargeFull ?? false
        } else {
            settings = nil
            recordError(info)
            deviceSettingError =
                info.success
                ? L10n.text("mac.could_not_read_device_status_refresh_to_retry")
                : (AppCommands.lastError ?? L10n.text("mac.the_device_did_not_respond"))
        }
        if linkState != .linked { bindings = [] }
        lastUpdated = Date()
    }

    private func readSettings() async {
        let result = await runCommand(["settings", "--json"])
        if result.success, let data = result.stdout.data(using: .utf8) {
            settings = try? JSONDecoder().decode(SettingsJSON.self, from: data)
            deviceSettingError = settings == nil ? L10n.text("mac.could_not_read_device_settings_refresh_to_retry") : ""
        } else {
            settings = nil
            recordError(result)
            deviceSettingError = AppCommands.lastError ?? L10n.text("mac.the_device_did_not_respond")
        }
    }

    func refreshBindings() async {
        await perform { model in await model.readBindings() }
    }

    private func readBindings() async {
        let buttons = await runCommand(["buttons"])
        if buttons.success {
            bindings = Self.controlOrder.compactMap { control in
                guard
                    let line = buttons.stdout
                        .split(separator: "\n")
                        .first(where: { $0.hasPrefix(control) })
                else { return nil }
                // Format: "talk        rcmd   (fixed function ...)" — second column is the binding.
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { return nil }
                return KeyBinding(control: control, keys: String(parts[1]))
            }
        } else {
            bindings = []
            recordError(buttons)
        }
    }

    private func readHooks() async {
        let hooks = await runCommand(["hooks", "status"])
        hooksLines =
            hooks.success
            ? hooks.stdout.split(separator: "\n").map(String.init)
            : []
        hooksLoaded = hooks.success
    }

    func refreshHooks() async {
        await perform { model in await model.readHooks() }
    }

    func refreshAudioDevices() {
        inputDevices = AudioManager.inputDevices()
        defaultInputUID = AudioManager.defaultInputDevice()?.uid
    }

    private func recordError(_ result: AppCommands.Result, operation: String = L10n.text("mac.refresh_device_status")) {
        AppCommands.report(result, operation: operation)
    }

    /// Switch the system default audio input device.
    func switchInput(to device: AudioManager.InputDevice) {
        guard AudioManager.setDefaultInputDevice(uid: device.uid) else { return }
        defaultInputUID = device.uid
    }

    func updateApplicationShortcut(index: Int, bundleID: String) async {
        await changeApplicationShortcut(["application-shortcut-set", String(index), bundleID])
    }
    func moveApplicationShortcut(index: Int, target: Int) async {
        await changeApplicationShortcut(["application-shortcut-move", String(index), String(target)])
    }
    func addApplicationShortcut(bundleID: String) async {
        await changeApplicationShortcut(["application-shortcut-add", bundleID])
    }
    func removeApplicationShortcut(index: Int) async {
        await changeApplicationShortcut(["application-shortcut-remove", String(index)])
    }
    private func changeApplicationShortcut(_ args: [String]) async {
        await perform { model in
            AppCommands.clearError()
            let result = await model.runCommand(args)
            if result.success {
                model.applicationShortcutError = ""
                await model.readStatus()
            } else {
                model.applicationShortcutError = result.stderr
            }
        }
    }

    /// An empty URL turns the relay off; an empty secret keeps the saved one.
    func setRelay(url: String, room: String, secret: String, dnsRecovery: Bool = false) async -> Bool {
        var success = false
        await perform { model in
            AppCommands.clearError()
            let result = await model.runCommand(["relay-config", url, room, secret, dnsRecovery ? "alidns" : "system"])
            success = result.success
            model.relayError = success ? "" : result.stderr
            await model.readStatus()
        }
        return success
    }

    func relayPairingCode() async -> String? {
        let result = await runCommand(["relay-pairing"])
        return result.success ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    // MARK: - Actions forwarded to the CLI

    /// Only this provider/session is opened and acknowledged by the Driver; opening the panel never marks tasks read.
    func openTaskSession(_ session: TaskActivityJSON.Session) async {
        guard openingTask == nil, !clearingUnread else { return }
        openingTask = session.key
        defer { openingTask = nil }
        await perform { model in
            AppCommands.clearError()
            let result = await model.runCommand(["task-open", session.provider, session.id])
            guard result.success else {
                let error = result.stderr.isEmpty ? result.stdout : result.stderr
                model.taskActivityError =
                    error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? L10n.text("mac.could_not_open_the_session") : error
                return
            }
            model.taskActivityError = ""
            await model.readStatus()
        }
    }

    /// Clears VibePier's dots for the tasks on screen; the native apps' own unread state is left untouched.
    func clearUnreadTasks() async {
        let keys = taskActivity.sessions.filter(\.isUnread).map { "\($0.provider):\($0.id)" }
        guard !keys.isEmpty, openingTask == nil, !clearingUnread else { return }
        clearingUnread = true
        defer { clearingUnread = false }
        await perform { model in
            AppCommands.clearError()
            let result = await model.runCommand(["task-clear-unread"] + keys)
            guard result.success else {
                let error = result.stderr.isEmpty ? result.stdout : result.stderr
                model.taskActivityError =
                    error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? L10n.text("mac.could_not_clear_unviewed_tasks") : error
                return
            }
            model.taskActivityError = ""
            await model.readStatus()
        }
    }

    func setHeartbeatEnabled(_ enabled: Bool) async {
        await perform { model in
            AppCommands.clearError()
            let result = await model.runCommand(["heartbeat", enabled ? "on" : "off"])
            guard result.success else {
                model.recordError(result)
                return
            }
            await model.readStatus()
        }
    }

    func setHeartbeatMode(_ mode: String) async {
        await perform { model in
            model.deviceSettingError = ""
            AppCommands.clearError()
            let result = await model.runCommand(["heartbeat-mode", mode])
            guard result.success else {
                model.recordError(result, operation: L10n.text("mac.au05_device_settings"))
                model.deviceSettingError = (AppCommands.lastError ?? L10n.text("mac.the_device_did_not_respond"))
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines)
                return
            }
            await model.readStatus()
        }
    }

    func applySetting(_ arguments: [String]) async {
        await perform { model in
            model.deviceSettingError = ""
            AppCommands.clearError()
            let result = await model.runCommand(arguments)
            guard result.success else {
                model.recordError(result, operation: L10n.text("mac.au05_device_settings"))
                model.deviceSettingError = (AppCommands.lastError ?? L10n.text("mac.the_device_did_not_respond"))
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines)
                return
            }
            if arguments.first == "set" {
                await model.readSettings()
            } else {
                await model.readStatus()
                if model.linkState == .linked && model.settings == nil { await model.readInfo() }
            }
        }
    }

    func setBinding(control: String, keys: String) async -> Bool {
        var success = false
        await perform { model in
            AppCommands.clearError()
            let result = await model.runCommand(["bind", control, keys])
            success = result.success
            if success {
                await model.readBindings()
            } else {
                model.recordError(result, operation: L10n.text("mac.key_bindings"))
            }
        }
        return success
    }

    func resetBindings() async -> Bool {
        var success = false
        await perform { model in
            AppCommands.clearError()
            let result = await model.runCommand(["reset-buttons"])
            success = result.success
            if result.success {
                await model.readBindings()
            } else {
                model.recordError(result, operation: L10n.text("mac.restore_all_firmware_defaults"))
            }
        }
        return success
    }

    var statusIcon: String {
        if !daemonRunning || !accessibilityTrusted { return "exclamationmark.triangle.fill" }
        if linkState == .linked {
            if charging { return "bolt.fill" }
            if let batteryPercent, batteryPercent <= 10 { return "battery.0percent" }
            return connectedRemoteCount > 0 ? "waveform" : "mic.fill"
        }
        if connectedRemoteCount > 0 { return "iphone" }
        if linkState == .dongleOnly { return "antenna.radiowaves.left.and.right" }
        return "waveform.slash"
    }

    var menuIconDescription: String {
        if !daemonRunning { return L10n.text("mac.control_service_is_not_running") }
        var details = [accessibilityTrusted ? statusText : L10n.text("mac.accessibility_permission_required")]
        if linkState == .linked, let batteryPercent, batteryPercent <= 10, !charging {
            details.append(L10n.text("mac.low_battery"))
        }
        details.append(
            connectedRemoteCount > 0
                ? L10n.text("mac.connected_phones_0", connectedRemoteCount) : L10n.text("mac.no_phone_connected"))
        if taskActivity.runningCount > 0 { details.append(L10n.text("mac.running_tasks_0", taskActivity.runningCount)) }
        if taskActivity.unreadCount > 0 {
            details.append(L10n.text("mac.completed_tasks_not_yet_viewed_0", taskActivity.unreadCount))
        }
        return details.joined(separator: " · ")
    }

    var statusText: String {
        switch linkState {
        case .linked:
            let base = "Vibe Key \(batteryPercent.map { "\($0)%" } ?? "?")"
            return charging ? base + " ⚡" : base
        case .dongleOnly: return L10n.text("mac.vibe_key_disconnected")
        case .noDongle: return L10n.text("mac.no_receiver_detected")
        case .unknown: return "…"
        }
    }

    var menuStatusText: String {
        guard connectedRemoteCount > 0 else {
            return remoteListening && linkState != .linked ? L10n.text("mac.no_phone_connected") : statusText
        }
        return linkState == .linked
            ? L10n.text(
                "mac.0_phones_1", statusText,
                connectedRemoteCount)
            : L10n.text("mac.phone_connected")
    }
    var connectedRemoteCount: Int { Set(connectedPhoneIDs).count }
}
