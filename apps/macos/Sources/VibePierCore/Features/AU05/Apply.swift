// SPDX-License-Identifier: MIT

import Foundation
import VibeKit

/// Pushes configuration to the device. Shared by the daemon and `vibepier apply`.
/// It reads the current state first and writes only the values that differ,
/// so that repeated links do not rewrite the device flash.
enum Apply {
    static func settings(_ s: Settings?, to key: VibeKey, log: @Sendable (String) -> Void) async throws {
        guard let s else { return }
        let cur = try await key.settings()
        if let v = s.sleepTime, cur.sleepTimeSeconds != v {
            try await key.setSleepTime(seconds: v)
            log("sleep time \(v) s")
        }
        if let v = s.standbyTime, cur.standbyTimeSeconds != v {
            try await key.setStandbyTime(seconds: v)
            log("standby time \(v) s")
        }
        let motor: UInt16? = s.motorStrength ?? s.vibration.map { $0 ? 255 : 0 }
        if let v = motor, cur.motorStrength != v {
            try await key.setMotorStrength(v)
            log("motor strength \(v)")
        }
        if let v = s.denoise, (cur.noiseReductionLevel ?? 0 > 0) != v {
            try await key.setNoiseReduction(level: v ? 1 : 0)
            log("denoise \(v ? "on" : "off")")
        }
        if let v = s.lightMode, cur.lights?.mode != v {
            try await key.setLightMode(v)
            log("light mode \(v)")
        }
        if let v = s.brightness {
            let lights = try await key.indicatorLights()
            let current = lights.mode == 2 ? lights.leds[3].alwaysOnBrightness : lights.allOnBrightness
            if current != v {
                try await key.setBrightness(v)
                log("brightness \(v)")
            }
        }
        if let v = s.hooksMode, (cur.hooksMode ?? 0 != 0) != v {
            try await key.setHooksMode(v)
            log("hooks mode \(v ? "on" : "off")")
        }
        if let v = s.audioButtonSystemMode, cur.audioButtonSystemMode != v {
            try await key.setAudioButtonSystemMode(v)
            log("audio button mode \(v)")
        }
    }

    /// Sets the work time of the visible LEDs (1...3) when it differs from the device.
    static func ledWorkTime(_ value: UInt8, to key: VibeKey, log: @Sendable (String) -> Void) async throws {
        let lights = try await key.indicatorLights()
        for led in 1...3 where led < lights.leds.count && lights.leds[led].workTime != value {
            try await key.setLED(led, .workTime, value)
            log("led \(led) work time \(value)")
        }
    }

    static func buttons(_ b: [String: String]?, to key: VibeKey, log: @Sendable (String) -> Void) async throws {
        guard let b else { return }
        for (name, value) in b.sorted(by: { $0.key < $1.key }) {
            guard let control = Control(name: name) else {
                log("config: unknown control '\(name)'")
                continue
            }
            if try await binding(value, control: control, key: key) {
                log("\(control.name) -> \(value)")
            }
        }
    }

    enum Target: Equatable {
        case shortcut([ShortcutKey])
        case fixed(UInt32)
    }

    static func target(_ value: String, control: Control) throws -> Target {
        let v = value.trimmingCharacters(in: .whitespaces)
        let lower = v.lowercased()
        if lower == "factory" || lower == "default" {
            return .fixed(control.factoryFixedFunction)
        }
        if lower.hasPrefix("fixed:") || lower.hasPrefix("media:") {
            let name = String(v.split(separator: ":", maxSplits: 1)[1])
            guard let code = FixedFunction.code(forName: name) else { throw HotkeyError.unknownKey(name) }
            return .fixed(code)
        }
        return .shortcut(try Hotkey.parse(v))
    }

    /// Writes one binding if it differs from the device. Returns true when it wrote.
    @discardableResult
    static func binding(_ value: String, control: Control, key: VibeKey, force: Bool = false) async throws -> Bool {
        let want = try target(value, control: control)
        let cur = try await key.binding(control)
        switch want {
        case .shortcut(let keys):
            if !force, cur.shortcut == keys { return false }
            try await key.bind(control, keys: keys)
        case .fixed(let code):
            if !force, cur.shortcut.isEmpty, cur.fixedFunction == code { return false }
            try await key.bindFixed(control, function: code)
        }
        return true
    }
}
