// SPDX-License-Identifier: MIT
//
// Typed, high-level API for the Vibe Key.

import Foundation
import VibeLocalization

public enum VibeKeyError: Error, CustomStringConvertible {
    case unexpectedReply(String, Frame)
    case writeRejected(String, Frame)
    case micOffline

    public var description: String {
        switch self {
        case .unexpectedReply(let what, let f): return L10n.text("hardware.unexpected_reply", what, f.shortHex)
        case .writeRejected(let what, let f): return L10n.text("hardware.write_rejected", what, f.shortHex)
        case .micOffline: return L10n.text("hardware.mic_offline")
        }
    }
}

public struct DongleInfo: Sendable, Codable {
    public var version: VersionInfo?
    public var serialNumber: String?
    public var flashID: String?
    public var micLinked: Bool
}

public struct DeviceInfo: Sendable, Codable {
    public var version: VersionInfo?
    public var hardwareVersion: Int?
    public var serialNumber: String?
    public var flashID: String?
    public var macAddress: String?
    public var battery: BatteryStatus?
}

public struct DeviceSettings: Sendable, Codable {
    public var sleepTimeSeconds: UInt32?
    public var standbyTimeSeconds: UInt32?
    public var standbyStatus: UInt8?
    public var motorStrength: UInt16?
    public var noiseReductionLevel: UInt8?
    public var noiseReductionLow: Int?
    public var noiseReductionHigh: Int?
    public var microphoneEnabled: Bool?
    public var audioButtonSystemMode: UInt8?
    public var hooksMode: UInt8?
    public var lights: IndicatorLights?
}

public struct ButtonBinding: Sendable, Codable {
    public var control: Control
    public var fixedFunction: UInt32?
    public var shortcut: [ShortcutKey]

    public init(control: Control, fixedFunction: UInt32?, shortcut: [ShortcutKey]) {
        self.control = control
        self.fixedFunction = fixedFunction
        self.shortcut = shortcut
    }

    /// The firmware uses the shortcut when one is stored, and the fixed function otherwise.
    public var summary: String {
        if !shortcut.isEmpty { return Hotkey.render(shortcut) }
        if let f = fixedFunction { return "fixed:\(FixedFunction.name(forCode: f))" }
        return "unknown"
    }
}

public final class VibeKey: @unchecked Sendable {
    public let session: VibeSession

    public init(session: VibeSession) {
        self.session = session
    }

    // MARK: Generic helpers

    func read(_ request: Request) async throws -> VibeMessage {
        let frame = try await session.send(request)
        return VibeMessage.parse(frame)
    }

    /// Sends a write. The reply usually echoes the request's operation byte with
    /// the reply flag set (for example 0x02 -> 0x12). Some commands answer with a
    /// bare 0x10. Replies carry no status code, so any matching reply counts as
    /// an acknowledgement. Read the value back to confirm that it persisted.
    func write(_ request: Request) async throws {
        let frame = try await session.send(request)
        if !frame.isReply {
            throw VibeKeyError.writeRejected(request.name, frame)
        }
    }

    // MARK: Dongle

    public func isMicLinked() async throws -> Bool {
        if case .deviceActive(let on) = try await read(DongleRequest.deviceActive) { return on }
        return false
    }

    public func dongleInfo() async throws -> DongleInfo {
        var info = DongleInfo(micLinked: false)
        if case .dongleVersion(let v) = try await read(DongleRequest.version) { info.version = v }
        if case .dongleSerial(let s) = try await read(DongleRequest.serialNumber) { info.serialNumber = s }
        if case .dongleFlashID(let b) = try await read(DongleRequest.flashID) {
            info.flashID = b.allSatisfy { $0 == 0 } ? nil : hexString(b)
        }
        info.micLinked = try await isMicLinked()
        return info
    }

    public func rebootDongle(delayMs: UInt32 = 500) async throws {
        try await write(DongleRequest.reboot(delayMs: delayMs))
    }

    // MARK: Device

    public func requireMic() async throws {
        if !(try await isMicLinked()) { throw VibeKeyError.micOffline }
    }

    public func battery() async throws -> BatteryStatus {
        guard case .battery(let b) = try await read(DeviceRequest.battery) else {
            throw VibeKeyError.unexpectedReply("battery", Frame([]))
        }
        return b
    }

    public func deviceSerialNumber() async throws -> String {
        let frames = try await session.collect(DeviceRequest.serialNumber)
        var chunks: [Int: [UInt8]] = [:]
        for f in frames {
            if case .deviceSerialChunk(let offset, let bytes) = VibeMessage.parse(f) {
                chunks[offset] = bytes
            }
        }
        let joined = chunks.keys.sorted().flatMap { chunks[$0]! }
        return String(decoding: joined.prefix { $0 != 0 }, as: UTF8.self)
    }

    public func deviceInfo() async throws -> DeviceInfo {
        var info = DeviceInfo()
        if case .deviceVersion(let v) = try await read(DeviceRequest.version) { info.version = v }
        if case .hardwareVersion(let h) = try await read(DeviceRequest.hardwareVersion) {
            info.hardwareVersion = Int(h)
        }
        info.serialNumber = try await deviceSerialNumber()
        if case .deviceFlashID(let b) = try await read(DeviceRequest.flashID) { info.flashID = hexString(b) }
        if case .macAddress(let m) = try await read(DeviceRequest.macAddress), !m.allSatisfy({ $0 == 0 }) {
            info.macAddress = m.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        info.battery = try await battery()
        return info
    }

    public func settings() async throws -> DeviceSettings {
        var s = DeviceSettings()
        if case .sleepTime(let v) = try await read(DeviceRequest.sleepTime) { s.sleepTimeSeconds = v }
        if case .standbyTime(let v) = try await read(DeviceRequest.standbyTime) { s.standbyTimeSeconds = v }
        if case .standbyStatus(let v) = try await read(DeviceRequest.standbyStatus) { s.standbyStatus = v }
        if case .motorStrength(let v) = try await read(DeviceRequest.motorStrength) { s.motorStrength = v }
        if case .noiseReduction(let l, let lo, let hi) = try await read(DeviceRequest.noiseReduction) {
            s.noiseReductionLevel = l
            s.noiseReductionLow = lo
            s.noiseReductionHigh = hi
        }
        if case .microphoneEnable(let v) = try await read(DeviceRequest.microphoneEnable) { s.microphoneEnabled = v }
        if case .audioButtonSystemMode(let v) = try await read(DeviceRequest.audioButtonSystemMode) {
            s.audioButtonSystemMode = v
        }
        if case .hooksMode(let v) = try await read(DeviceRequest.hooksMode) { s.hooksMode = v }
        s.lights = try await indicatorLights()
        return s
    }

    public func indicatorLights() async throws -> IndicatorLights {
        guard case .indicatorLights(let l) = try await read(DeviceRequest.indicatorLights) else {
            throw VibeKeyError.unexpectedReply("indicator lights", Frame([]))
        }
        return l
    }

    public func setSleepTime(seconds: UInt32) async throws {
        try await write(DeviceRequest.setSleepTime(seconds: seconds))
    }
    public func setStandbyTime(seconds: UInt32) async throws {
        try await write(DeviceRequest.setStandbyTime(seconds: seconds))
    }
    public func setStandbyStatus(_ on: Bool) async throws { try await write(DeviceRequest.setStandbyStatus(on)) }
    public func setMotorStrength(_ v: UInt16) async throws { try await write(DeviceRequest.setMotorStrength(v)) }
    public func setNoiseReduction(level: UInt8, low: UInt16 = 1600, high: UInt16 = 1000) async throws {
        try await write(DeviceRequest.setNoiseReduction(level: level, low: low, high: high))
    }
    public func setMicrophoneEnabled(_ on: Bool) async throws { try await write(DeviceRequest.setMicrophoneEnable(on)) }
    public func setAudioButtonSystemMode(_ m: UInt8) async throws {
        try await write(DeviceRequest.setAudioButtonSystemMode(m))
    }
    public func setHooksMode(_ on: Bool) async throws { try await write(DeviceRequest.setHooksMode(on)) }
    public func setLightMode(_ m: UInt8) async throws { try await write(DeviceRequest.setIndicatorLightMode(m)) }
    public func setAllOnBrightness(_ v: UInt8) async throws {
        try await write(DeviceRequest.setIndicatorLightAllOnBrightness(v))
    }
    public func setLED(_ led: Int, _ field: LEDField, _ value: UInt8) async throws {
        try await write(DeviceRequest.setIndicatorLight(led: led, field: field, value: value))
    }

    /// Mirrors `SettingDialog::onLightBrightnessChanged`: in mode 1 it sets the
    /// all-on brightness, and in mode 2 it sets LED 3 always-on brightness and
    /// the breathe brightness of LEDs 0...2.
    public func setBrightness(_ level: UInt8) async throws {
        let lights = try await indicatorLights()
        switch lights.mode {
        case 1:
            try await setAllOnBrightness(level)
        case 2:
            try await setLED(3, .alwaysOnBrightness, level)
            for led in 0...2 { try await setLED(led, .breatheBrightness, level) }
        default:
            try await setAllOnBrightness(level)
        }
    }

    public func rebootDevice(delayMs: UInt32 = 500) async throws {
        try await write(DeviceRequest.reboot(delayMs: delayMs))
    }

    // MARK: Buttons

    public func binding(_ control: Control) async throws -> ButtonBinding {
        var b = ButtonBinding(control: control, fixedFunction: nil, shortcut: [])
        if case .buttonFixedFunction(_, _, let fn) = try await read(DeviceRequest.buttonFixedFunction(control.rawValue))
        {
            b.fixedFunction = fn
        }
        if case .buttonShortcut(_, let keys) = try await read(DeviceRequest.buttonShortcut(control.rawValue)) {
            b.shortcut = keys
        }
        return b
    }

    public func bindings() async throws -> [ButtonBinding] {
        var out: [ButtonBinding] = []
        for c in Control.allCases { out.append(try await binding(c)) }
        return out
    }

    /// Stores a shortcut in the firmware, like `onSetButtonFunction` does for AU05.
    public func bind(_ control: Control, keys: [ShortcutKey]) async throws {
        try await write(DeviceRequest.setButtonShortcut(control.rawValue, keys: keys))
    }

    public func bind(_ control: Control, hotkey: String) async throws {
        try await bind(control, keys: try Hotkey.parse(hotkey))
    }

    /// Stores a fixed function (media key or factory default) and clears the shortcut.
    public func bindFixed(_ control: Control, function: UInt32) async throws {
        try await write(DeviceRequest.setButtonShortcut(control.rawValue, keys: []))
        try await write(DeviceRequest.setButtonFixedFunction(control.rawValue, function: function))
    }

    /// Restores the factory fixed function and clears any stored shortcut.
    public func resetBinding(_ control: Control) async throws {
        try await bindFixed(control, function: control.factoryFixedFunction)
    }
}
