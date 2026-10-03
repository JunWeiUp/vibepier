// SPDX-License-Identifier: MIT
//
// vibepier: an open-source driver and daemon for the Ulanzi Vibe Key (AU05) on macOS.

import Foundation
import VibeKit

let usage = L10n.text("cli.help")

// MARK: Argument helpers

nonisolated(unsafe) var args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) {
        args.remove(at: i)
        return true
    }
    return false
}

func option(_ name: String) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count {
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }
    if let i = args.firstIndex(where: { $0.hasPrefix(name + "=") }) {
        let v = String(args[i].dropFirst(name.count + 1))
        args.remove(at: i)
        return v
    }
    return nil
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("vibepier: \(message)\n".utf8))
    exit(code)
}

func parseBool(_ s: String) throws -> Bool {
    switch s.lowercased() {
    case "on", "true", "yes", "1", "enable", "enabled": return true
    case "off", "false", "no", "0", "disable", "disabled": return false
    default: throw CLIError(L10n.text("cli.expected_boolean", s))
    }
}

func parseUInt<T: FixedWidthInteger & UnsignedInteger>(_ s: String, _: T.Type) throws -> T {
    let v: T? = s.lowercased().hasPrefix("0x") ? T(s.dropFirst(2), radix: 16) : T(s)
    guard let v else { throw CLIError(L10n.text("cli.expected_number", s)) }
    return v
}

func parseDuration(_ s: String) throws -> UInt32 {
    let l = s.lowercased()
    if l == "off" || l == "never" { return 0 }
    for (suffix, multiplier): (String, UInt32) in [("h", 3600), ("m", 60)] {
        if l.hasSuffix(suffix), let value = UInt32(l.dropLast()) {
            let result = value.multipliedReportingOverflow(by: multiplier)
            guard !result.overflow else { throw CLIError(L10n.text("cli.duration_range", s)) }
            return result.partialValue
        }
    }
    if l.hasSuffix("s"), let v = UInt32(l.dropLast()) { return v }
    return try parseUInt(l, UInt32.self)
}

/// Validate before opening hardware; floating-point input must not trap during integer conversion.
func parseDelayNanoseconds(_ value: String, nanosecondsPerUnit: Double, option: String) throws -> UInt64 {
    guard let number = Double(value), number.isFinite, number >= 0,
        nanosecondsPerUnit.isFinite, nanosecondsPerUnit > 0
    else { throw CLIError(L10n.text("cli.invalid_delay", option)) }
    let scaled = number * nanosecondsPerUnit
    // Double(UInt64.max) rounds up to 2^64, so the upper bound must be exclusive.
    guard scaled.isFinite, scaled < Double(UInt64.max) else {
        throw CLIError(L10n.text("cli.invalid_delay", option))
    }
    return UInt64(scaled)
}

func formatDuration(_ s: UInt32?) -> String {
    guard let s else { return "?" }
    if s == 0 { return "never" }
    if s % 3600 == 0 { return "\(s / 3600) h" }
    if s % 60 == 0 { return "\(s / 60) min" }
    return "\(s) s"
}

func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(value), let s = String(data: d, encoding: .utf8) { print(s) }
}

// MARK: Session helpers

let verbose = flag("--verbose") || flag("-v")
let pidOverride = option("--pid").flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }

func openKey() async throws -> VibeKey {
    let transport = HIDTransport(productID: pidOverride ?? VibeUSB.productID)
    let session = VibeSession(transport: transport)
    session.logFrames = verbose
    session.start()
    do {
        try await session.waitUntilReady(timeout: 5)
    } catch {
        throw CLIError(
            transport.isConnected
                ? L10n.text("cli.handshake_failed")
                : L10n.text(
                    "cli.dongle_missing",
                    String(format: "%04X:%04X", VibeUSB.vendorID, pidOverride ?? VibeUSB.productID))
        )
    }
    return VibeKey(session: session)
}

func withKey(requireMic: Bool = true, _ body: (VibeKey) async throws -> Void) async {
    do {
        let key = try await openKey()
        if requireMic { try await key.requireMic() }
        try await body(key)
        key.session.stop()
    } catch {
        fail("\(error)")
    }
}

// MARK: Commands

func cmdInfo(json: Bool) async {
    await withKey(requireMic: false) { key in
        let dongle = try await key.dongleInfo()
        var device: DeviceInfo?
        var settings: DeviceSettings?
        if dongle.micLinked {
            device = try await key.deviceInfo()
            settings = try await key.settings()
        }
        if json {
            struct Out: Encodable {
                var dongle: DongleInfo
                var device: DeviceInfo?
                var settings: DeviceSettings?
            }
            printJSON(Out(dongle: dongle, device: device, settings: settings))
            return
        }
        print("Dongle (AU05 USB receiver)")
        print(
            "  firmware   \(dongle.version?.version ?? "?")  (code \(dongle.version?.customCode ?? "?"), built \(dongle.version?.buildStamp ?? "?"))"
        )
        print("  serial     \(dongle.serialNumber ?? "?")")
        if let f = dongle.flashID { print("  flash id   \(f)") }
        print("  mic link   \(dongle.micLinked ? "linked" : "not linked (switch the Vibe Key on)")")
        guard let device else { return }
        print("Vibe Key (microphone)")
        print(
            "  firmware   \(device.version?.version ?? "?")  (code \(device.version?.customCode ?? "?"), built \(device.version?.buildStamp ?? "?"))"
        )
        if let h = device.hardwareVersion { print("  hardware   \(h)") }
        print("  serial     \(device.serialNumber ?? "?")")
        print("  flash id   \(device.flashID ?? "?")")
        if let m = device.macAddress { print("  mac        \(m)") }
        if let b = device.battery {
            print(
                "  battery    \(b.percent)%  \(b.millivolts) mV\(b.charging ? "  charging" : "")\(b.chargeFull ? "  full" : "")"
            )
        }
        if let settings { printSettings(settings) }
    }
}

func printSettings(_ s: DeviceSettings) {
    print("Settings")
    print("  sleep        \(formatDuration(s.sleepTimeSeconds))")
    print("  standby      \(formatDuration(s.standbyTimeSeconds))")
    if let m = s.motorStrength { print("  vibration    \(m == 0 ? "off" : "on") (\(m))") }
    if let l = s.noiseReductionLevel {
        print(
            "  denoise      \(l == 0 ? "off" : "on") (level \(l), low \(s.noiseReductionLow ?? 0), high \(s.noiseReductionHigh ?? 0))"
        )
    }
    if let h = s.hooksMode { print("  hooks mode   \(h == 0 ? "off" : "on")") }
    if let a = s.audioButtonSystemMode { print("  audio button \(a)") }
    if let m = s.microphoneEnabled { print("  mic enable   \(m)") }
    if let l = s.lights {
        let modes = ["off", "all on", "work mode"]
        print(
            "  lights       \(Int(l.mode) < modes.count ? modes[Int(l.mode)] : "\(l.mode)") (all-on brightness \(l.allOnBrightness))"
        )
        for (i, led) in l.leds.enumerated() {
            print(
                "    led \(i)      type \(led.workType)  time \(led.workTime)  breathe \(led.breatheLevel)  breathe-brightness \(led.breatheBrightness)  brightness \(led.alwaysOnBrightness)"
            )
        }
    }
}

func setDeviceSetting(_ rest: [String], key: VibeKey) async throws {
    guard let what = rest.first else { throw CLIError(L10n.text("cli.set_usage")) }
    let values = Array(rest.dropFirst())
    func value(_ i: Int = 0) throws -> String {
        guard i < values.count else { throw CLIError(L10n.text("cli.missing_value", what)) }
        return values[i]
    }
    switch what.lowercased() {
    case "sleep", "sleep-time":
        try await key.setSleepTime(seconds: try parseDuration(value()))
    case "standby-time":
        try await key.setStandbyTime(seconds: try parseDuration(value()))
    case "standby":
        try await key.setStandbyStatus(try parseBool(value()))
    case "vibration", "motor":
        let v = try value()
        if let b = try? parseBool(v), UInt16(v) == nil || v == "0" || v == "1" {
            try await key.setMotorStrength(b ? 255 : 0)
        } else {
            try await key.setMotorStrength(try parseUInt(v, UInt16.self))
        }
    case "denoise", "noise-reduction", "nr":
        try await key.setNoiseReduction(level: try parseBool(value()) ? 1 : 0)
    case "light-mode", "lights":
        let map: [String: UInt8] = ["off": 0, "on": 1, "all-on": 1, "work": 2, "work-mode": 2]
        let m = try map[value().lowercased()] ?? parseUInt(value(), UInt8.self)
        try await key.setLightMode(m)
    case "brightness":
        let v = try parseUInt(value(), UInt8.self)
        guard v <= 20 else { throw CLIError(L10n.text("cli.brightness_range")) }
        try await key.setBrightness(v)
    case "led":
        let led = try parseUInt(value(0), UInt8.self)
        guard led <= 3 else { throw CLIError(L10n.text("cli.led_index_range")) }
        guard let field = LEDField(name: try value(1)) else {
            throw CLIError(L10n.text("cli.led_field", LEDField.allCases.map(\.name).joined(separator: ", ")))
        }
        try await key.setLED(Int(led), field, try parseUInt(value(2), UInt8.self))
    case "hooks-mode", "hooks":
        try await key.setHooksMode(try parseBool(value()))
    case "audio-button-mode":
        try await key.setAudioButtonSystemMode(try parseUInt(value(), UInt8.self))
    case "mic", "microphone":
        try await key.setMicrophoneEnabled(try parseBool(value()))
    default:
        throw CLIError(L10n.text("cli.unknown_setting", what))
    }
}

func cmdSet(_ rest: [String]) async {
    await withKey { key in
        try await setDeviceSetting(rest, key: key)
        print("ok")
    }
}

func cmdButtons(json: Bool) async {
    await withKey { key in
        let bindings = try await key.bindings()
        if json {
            printJSON(bindings)
            return
        }
        for b in bindings {
            let name = b.control.name.padding(toLength: 11, withPad: " ", startingAt: 0)
            var line = "\(name) \(b.summary)"
            if !b.shortcut.isEmpty, let f = b.fixedFunction {
                line += "   (fixed function \(FixedFunction.name(forCode: f)) is overridden)"
            }
            print(line)
        }
    }
}

func cmdBind(_ rest: [String]) async {
    guard rest.count >= 2, let control = Control(name: rest[0]) else {
        fail(L10n.text("cli.bind_usage"))
    }
    let binding = rest.dropFirst().joined(separator: " ")
    do {
        _ = try Apply.target(binding, control: control)
    } catch {
        fail("\(error)")
    }
    await withKey { key in
        try await Apply.binding(binding, control: control, key: key, force: true)
        let b = try await key.binding(control)
        print("\(control.name) -> \(b.summary)")
        _ = ControlSocket.request(["cmd": "refresh-bindings"], timeout: 3)
    }
}

func cmdResetButtons() async {
    await withKey { key in
        for c in Control.allCases {
            try await key.resetBinding(c)
            print("\(c.name) -> \(c.defaultHotkey) (factory)")
        }
        _ = ControlSocket.request(["cmd": "refresh-bindings"], timeout: 3)
    }
}

func cmdKeys() {
    print(L10n.text("cli.key_names"))
    for (code, names) in Hotkey.allNames {
        print(String(format: "  0x%03X  ", code) + names.joined(separator: ", "))
    }
    print(L10n.text("cli.fixed_functions"))
    for f in FixedFunction.named {
        print(String(format: "  0x%02X   ", f.code) + f.name)
    }
}

func cmdMonitor() async {
    do {
        let key = try await openKey()
        let session = key.session
        print(L10n.text("cli.monitoring"))
        session.addListener { event in
            switch event {
            case .message(let m, let f):
                switch m {
                case .keyEvent(let e):
                    let name = e.control?.name ?? "index \(e.physicalIndex)"
                    print("key      \(name)  status \(e.status)  (index \(e.index), physical \(e.physicalIndex))")
                case .batteryNotice(let b):
                    print("battery  \(b.percent)%  \(b.millivolts) mV\(b.charging ? "  charging" : "")")
                case .linkActive(let on): print("link     mic \(on ? "linked" : "unlinked")")
                case .powerOn: print("power    mic powered on")
                case .standbyNotice(let s): print("standby  \(s)")
                case .chargingNotice(let c): print("charging \(c)")
                case .noiseReductionNotice(let l, _, _): print("denoise  level \(l)")
                case .heartbeat, .authReply: break
                case .unknown: print("notice   \(f.shortHex)")
                default: if verbose { print("reply    \(f.shortHex)") }
                }
            case .disconnected: print("dongle disconnected")
            case .connected: print("dongle connected")
            case .authenticated: print("dongle authenticated")
            }
        }
        while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
    } catch {
        fail("\(error)")
    }
}

func cmdRaw() async {
    let wait: UInt64
    do {
        wait = try parseDelayNanoseconds(option("--wait") ?? "500", nanosecondsPerUnit: 1_000_000, option: "--wait")
    } catch { fail(String(describing: error)) }
    let hex = args.joined().replacingOccurrences(of: " ", with: "")
    var bytes: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        guard let b = UInt8(hex[i..<j], radix: 16) else { fail(L10n.text("cli.invalid_hex", hex[i..<j])) }
        bytes.append(b)
        i = j
    }
    await withKey(requireMic: false) { key in
        key.session.addListener { event in
            if case .message(let m, let f) = event {
                if case .heartbeat = m { return }
                print("<< \(f.shortHex)   \(m)")
            }
        }
        try key.session.sendNow(bytes)
        print(">> \(Frame(bytes).shortHex)")
        try await Task.sleep(nanoseconds: wait)
    }
}

func cmdFirmware(_ rest: [String]) async {
    let sub = rest.first ?? "check"
    switch sub {
    case "check":
        await withKey(requireMic: false) { key in
            let dongle = try await key.dongleInfo()
            guard let sn = dongle.serialNumber else { throw CLIError(L10n.text("cli.serial_unreadable")) }
            var targets: [(FirmwareTarget, String)] = []
            if let v = dongle.version?.version { targets.append((.dongle, v)) }
            if dongle.micLinked, let v = try await key.deviceInfo().version?.version { targets.append((.device, v)) }
            for (t, v) in targets {
                let info = try await FirmwareAPI.check(serial: sn, target: t, currentVersion: v)
                print(
                    "\(t.rawValue): installed \(v), update \(info.needUpdate ? "available: \(info.version ?? "?")" : "not needed")"
                )
                if let url = info.downloadURL { print("  download: \(url.absoluteString)") }
                if let n = info.notes, !n.isEmpty { print("  notes: \(n)") }
                if verbose { print("  raw: \(info.raw)") }
            }
        }
    case "update":
        guard let targetName = option("--target"), let target = FirmwareTarget(rawValue: targetName) else {
            fail(L10n.text("cli.firmware_update_usage"))
        }
        guard let file = option("--file") else { fail(L10n.text("cli.missing_image")) }
        let image: FirmwareImage
        do {
            image = try FirmwareImage(data: try Data(contentsOf: URL(fileURLWithPath: file)), target: target)
        } catch {
            fail("\(error)")
        }
        print(
            "image: \(image.payload.count) bytes, \(image.frames.count) frames, target byte \(image.targetByte), code \(hexString(image.customCode))"
        )
        guard flag("--yes") else {
            fail(
                L10n.text("cli.firmware_confirmation", target.rawValue), code: 2)
        }
        await withKey(requireMic: target == .device) { key in
            let updater = FirmwareUpdater(session: key.session)
            updater.onProgress = { fraction, text in
                print(String(format: "  %3.0f%%  %@", fraction * 100, text))
            }
            try await updater.run(image: image, target: target)
            print(L10n.text("cli.update_finished", target.rawValue))
            if target == .device {
                try? await key.rebootDevice()
            } else {
                try? await key.rebootDongle()
            }
        }
    default:
        fail(L10n.text("cli.firmware_usage"))
    }
}

func cmdHooks(_ rest: [String]) {
    let sub = rest.first ?? "status"
    let agentFilter = option("--agent")
    let configOverride = option("--config").map { URL(fileURLWithPath: $0) }
    let dryRun = flag("--dry-run")
    let home = FileManager.default.homeDirectoryForCurrentUser
    var agents = Agents.all
    if let a = agentFilter {
        guard let d = Agents.find(a) else {
            fail(L10n.text("cli.unknown_agent", a, Agents.all.map(\.id).joined(separator: ", ")))
        }
        agents = [d]
    }
    if configOverride != nil, agents.count != 1 { fail(L10n.text("cli.config_needs_agent")) }
    do {
        switch sub {
        case "install":
            let bin = HookInstaller.executablePath()
            for a in agents {
                let r = try HookInstaller.install(
                    a, home: home, binary: bin, configOverride: configOverride, dryRun: dryRun)
                if let s = r.skipped {
                    print(L10n.text("cli.hook_skipped", a.id, s))
                } else {
                    print(
                        L10n.text(
                            "cli.hook_installed", a.id, r.path, r.added, r.current,
                            dryRun ? L10n.text("cli.dry_run") : ""))
                }
            }
            print(
                L10n.text("cli.enable_hooks")
            )
        case "uninstall":
            for a in agents {
                let r = try HookInstaller.uninstall(a, home: home, configOverride: configOverride, dryRun: dryRun)
                if let s = r.skipped {
                    print(L10n.text("cli.hook_skipped", a.id, s))
                } else {
                    print(
                        L10n.text("cli.hook_removed", a.id, r.path, r.removed, dryRun ? L10n.text("cli.dry_run") : ""))
                }
            }
        case "status":
            for a in agents {
                let s = HookInstaller.status(a, home: home)
                print(
                    "\(a.id.padding(toLength: 13, withPad: " ", startingAt: 0)) \(s.installed)/\(s.total) events  \(s.path)"
                )
            }
        default:
            fail(L10n.text("cli.hooks_usage"))
        }
    } catch {
        fail("\(error)")
    }
}

func cmdConfig(_ rest: [String]) {
    switch rest.first ?? "show" {
    case "path":
        print(Paths.configFile.path)
    case "init":
        if FileManager.default.fileExists(atPath: Paths.configFile.path), !flag("--force") {
            fail(L10n.text("cli.config_exists", Paths.configFile.path))
        }
        do {
            try Config.example.save()
            print(L10n.text("cli.config_written", Paths.configFile.path))
        } catch {
            fail("\(error)")
        }
    case "show":
        do {
            let c = try Config.load()
            printJSON(c)
        } catch {
            fail(L10n.text("cli.config_unreadable", Paths.configFile.path, error))
        }
    default:
        fail(L10n.text("cli.config_usage"))
    }
}

/// Visual and haptic tests. Each one restores the original values afterwards.
func cmdTest(_ rest: [String]) async {
    let pause: UInt64
    do {
        pause = try parseDelayNanoseconds(
            option("--seconds") ?? "3", nanosecondsPerUnit: 1_000_000_000, option: "--seconds")
    } catch { fail(String(describing: error)) }
    switch rest.first ?? "" {
    case "leds":
        await withKey { key in
            let original = try await key.indicatorLights()
            print(L10n.text("cli.test_lights", original.mode))
            if original.mode != 2 { try await key.setLightMode(2) }
            for led in 0..<original.leds.count {
                for type in UInt8(0)...2 {
                    try await key.setLED(led, .workType, type)
                    print(L10n.text("cli.test_led", led, type))
                    try await Task.sleep(nanoseconds: pause)
                }
                try await key.setLED(led, .workType, original.leds[led].workType)
            }
            if original.mode != 2 { try await key.setLightMode(original.mode) }
            print(L10n.text("cli.restored"))
        }
    case "vibration":
        await withKey { key in
            let original = try await key.settings().motorStrength ?? 0
            print(L10n.text("cli.test_motor"))
            try await key.setMotorStrength(255)
            try await Task.sleep(nanoseconds: pause)
            print(L10n.text("cli.test_pulse"))
            _ = try await key.session.send(
                Request("device.motorPulse", [0x01, 0x07, 0x33, 0x02, 0xF4, 0x01, 0x00, 0x00, 0xFF], reply: nil))
            try await Task.sleep(nanoseconds: pause)
            try await key.setMotorStrength(original)
            print(L10n.text("cli.motor_restored", original))
        }
    default:
        fail(L10n.text("cli.test_usage"))
    }
}

// MARK: Dispatch

public func runVibePierCLI() async {
    _ = verbose
    _ = pidOverride
    let command = args.isEmpty ? "help" : args.removeFirst()
    switch command {
    case "help", "--help", "-h":
        print(usage)
    case "version", "--version":
        print("vibepier 0.1.0-beta.1")
    case "info":
        await cmdInfo(json: flag("--json"))
    case "battery":
        await withKey { key in
            let b = try await key.battery()
            print("\(b.percent)%  \(b.millivolts) mV\(b.charging ? "  charging" : "")\(b.chargeFull ? "  full" : "")")
        }
    case "settings":
        let json = flag("--json")
        await withKey { key in
            let s = try await key.settings()
            if json { printJSON(s) } else { printSettings(s) }
        }
    case "set":
        await cmdSet(args)
    case "buttons":
        await cmdButtons(json: flag("--json"))
    case "bind":
        await cmdBind(args)
    case "reset-buttons":
        await cmdResetButtons()
    case "keys":
        cmdKeys()
    case "monitor":
        await cmdMonitor()
    case "raw":
        await cmdRaw()
    case "reboot":
        let target = args.first ?? ""
        await withKey(requireMic: target == "device") { key in
            switch target {
            case "device", "mic": try await key.rebootDevice()
            case "dongle": try await key.rebootDongle()
            default: throw CLIError(L10n.text("cli.reboot_usage"))
            }
            print("ok")
        }
    case "firmware":
        await cmdFirmware(args)
    case "test":
        await cmdTest(args)
    case "config":
        cmdConfig(args)
    case "apply":
        do {
            let cfg = try Config.load()
            await withKey { key in
                try await Apply.settings(cfg.settings, to: key) { print($0) }
                try await Apply.buttons(cfg.buttons, to: key) { print($0) }
                print(L10n.text("cli.configuration_applied"))
                _ = ControlSocket.request(["cmd": "refresh-bindings"], timeout: 3)
            }
        } catch {
            fail(L10n.text("cli.config_unreadable", Paths.configFile.path, error))
        }
    case "daemon":
        do {
            let cfg = try Config.load()
            try await Daemon(config: cfg, verbose: verbose).run()
        } catch {
            fail("\(error)")
        }
    case "preferences":
        do { try PreferencesCommand.run(args) { ControlSocket.request($0, timeout: 15) } } catch {
            fail(String(describing: error))
        }
    case "relay":
        do {
            let payload = try RelayCommand.payload(args)
            guard let reply = ControlSocket.request(payload, timeout: 15) else {
                fail(L10n.text("cli.start_app"))
            }
            guard reply["ok"] as? Bool == true else { fail(reply["error"] as? String ?? L10n.text("cli.relay_failed")) }
            let result: [String: Any] =
                payload["cmd"] == "status" ? (reply["relay"] as? [String: Any] ?? [:]) : ["ok": true]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch { fail(String(describing: error)) }
    case "android-update":
        guard args.count == 1 else { fail(L10n.text("updates.cli_usage")) }
        guard
            let reply = ControlSocket.request(
                [
                    "cmd": "android-update-publish", "path": URL(fileURLWithPath: args[0]).standardizedFileURL.path,
                ], timeout: 30)
        else { fail(L10n.text("cli.start_app")) }
        guard reply["ok"] as? Bool == true else {
            fail(reply["error"] as? String ?? L10n.text("updates.invalid_metadata"))
        }
        if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    case "phone-install":
        let list = flag("--list")
        let status = flag("--status")
        let cancel = flag("--cancel")
        guard (list ? 1 : 0) + (status ? 1 : 0) + (cancel ? 1 : 0) <= 1 else {
            fail(L10n.text("core.choose_one_operation"))
        }
        var payload: [String: Any] = [
            "cmd": list
                ? "phone-apk-list" : status ? "phone-apk-status" : cancel ? "phone-apk-cancel" : "phone-apk-stage"
        ]
        if list {
            guard args.isEmpty else { fail(L10n.text("core.usage_phone_install_list")) }
        } else if status || cancel {
            guard args.count <= 1 else { fail(L10n.text("core.usage_phone_install_status_cancel_device")) }
            if let device = args.first { payload["device"] = device }
        } else {
            guard (1...2).contains(args.count) else { fail(L10n.text("core.usage_phone_install_apk_device")) }
            payload["path"] = URL(fileURLWithPath: args[0]).standardizedFileURL.path
            if args.count == 2 { payload["device"] = args[1] }
        }
        guard let reply = ControlSocket.request(payload, timeout: 30) else {
            fail(L10n.text("core.vibepier_is_not_running_or_apk_preparation_timed_out"))
        }
        if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            print(text)
        }
        if reply["ok"] as? Bool != true { fail(reply["error"] as? String ?? L10n.text("core.transfer_failed")) }
    case "status", "reload":
        guard let reply = ControlSocket.request(["cmd": command], timeout: 2) else {
            fail(L10n.text("cli.daemon_unavailable", Paths.socket.path))
        }
        if let d = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]),
            let s = String(data: d, encoding: .utf8)
        {
            print(s)
        }
    case "service":
        switch args.first ?? "status" {
        case "install":
            do {
                try Service.install(binary: HookInstaller.executablePath())
                print(L10n.text("cli.service_installed", Service.plistURL.path, Paths.logFile.path))
            } catch {
                fail("\(error)")
            }
        case "uninstall":
            do {
                try Service.uninstall()
                print(L10n.text("cli.service_removed", Service.label))
            } catch {
                fail("\(error)")
            }
        default:
            print(
                Service.isLoaded()
                    ? L10n.text("cli.service_loaded", Service.plistURL.path) : L10n.text("cli.service_not_loaded"))
        }
    case "hooks":
        cmdHooks(args)
    case "hook":
        let agent = option("--agent") ?? "unknown"
        let event = option("--event")
        exit(HookCommand.run(agent: agent, eventArg: event))
    default:
        fail(L10n.text("cli.unknown_command", command))
    }

}
