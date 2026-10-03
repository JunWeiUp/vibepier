// SPDX-License-Identifier: MIT
//
// Hotkey parsing and the firmware shortcut encoding.
//
// Ulanzi Studio converts a hotkey to a list of 16-bit HID codes
// (`KeyCodeConverter::parseToHid`): keyboard usages (page 0x07), modifier
// usages 0xE0...0xE7, 0x02 for Fn, and 0x100...0x106 for mouse actions. The
// vendor library (`setDeviceButtonShortcutFunction2`) then maps each code to a
// firmware (page, value) pair:
//
//     0xE0...0xE7   -> page 3, value = 1 << (code - 0xE0)   (modifier bit mask)
//     0x100...0x106 -> page 7, value = code & 0xFF          (mouse)
//     0x02          -> page 0x13, value 2                    (Fn / Globe)
//     anything else -> page 2, value = code                  (keyboard usage)
//
// At most four codes fit in one button.

import Foundation
import VibeLocalization

/// One (page, value) pair in a firmware shortcut.
public struct ShortcutKey: Equatable, Sendable, Codable, CustomStringConvertible {
    public var page: UInt8
    public var value: UInt8
    public var sign: Bool

    public init(page: UInt8, value: UInt8, sign: Bool = false) {
        self.page = page
        self.value = value
        self.sign = sign
    }

    /// Encodes one host HID code the way `setDeviceButtonShortcutFunction2` does.
    public init(hidCode code: UInt16) {
        switch code {
        case 0xE0...0xE7:
            self.init(page: 3, value: UInt8(1 << (code - 0xE0)))
        case 0x100...0x106:
            self.init(page: 7, value: UInt8(code & 0xFF))
        case 0x02:
            self.init(page: 0x13, value: 2)
        default:
            self.init(page: 2, value: UInt8(truncatingIfNeeded: code))
        }
    }

    /// The host HID code that this pair represents.
    public var hidCode: UInt16 {
        switch page {
        case 3:
            for bit in 0..<8 where value == UInt8(1 << bit) { return 0xE0 + UInt16(bit) }
            return 0xE0
        case 7: return 0x100 | UInt16(value)
        case 0x13: return 0x02
        default: return UInt16(value)
        }
    }

    public var description: String {
        Hotkey.name(forHIDCode: hidCode) ?? String(format: "page%02x:%02x", page, value)
    }
}

public enum HotkeyError: Error, CustomStringConvertible {
    case unknownKey(String)
    case tooManyKeys(Int)
    case empty

    public var description: String {
        switch self {
        case .unknownKey(let k): return L10n.text("hardware.unknown_key", k)
        case .tooManyKeys(let n): return L10n.text("hardware.too_many_keys", n)
        case .empty: return L10n.text("hardware.empty_hotkey")
        }
    }
}

public enum Hotkey {
    /// Parses a hotkey such as `cmd+shift+4`, `fn`, `wheel-up`, or `ctrl+alt+delete`
    /// into firmware shortcut pairs. Modifiers come first, as in Ulanzi Studio.
    public static func parse(_ text: String) throws -> [ShortcutKey] {
        let codes = try parseHIDCodes(text)
        return codes.map { ShortcutKey(hidCode: $0) }
    }

    /// Parses a hotkey into the HID code list that Ulanzi Studio would produce.
    public static func parseHIDCodes(_ text: String) throws -> [UInt16] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw HotkeyError.empty }
        // "+" separates keys, but a lone "+" or a trailing "++" means the plus key.
        var parts: [String] = []
        var current = ""
        var previous: Character?
        for ch in trimmed {
            if ch == "+" && !current.isEmpty && previous != "+" {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        if !current.isEmpty { parts.append(current) }

        var modifiers: [UInt16] = []
        var keys: [UInt16] = []
        for raw in parts {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard let code = code(forName: name) else { throw HotkeyError.unknownKey(raw) }
            if (0xE0...0xE7).contains(code) {
                if !modifiers.contains(code) { modifiers.append(code) }
            } else {
                keys.append(code)
            }
        }
        let all = modifiers + keys
        guard !all.isEmpty else { throw HotkeyError.empty }
        guard all.count <= 4 else { throw HotkeyError.tooManyKeys(all.count) }
        return all
    }

    /// The Ulanzi Studio string form sent to `setDeviceButtonShortcutFunction2`:
    /// two-digit upper-case hex codes joined with `|`, or one four-digit code for a mouse action.
    public static func vendorContentString(_ codes: [UInt16]) -> String {
        if codes.count == 1, codes[0] >= 0x100 {
            return String(format: "%04X", codes[0])
        }
        return codes.map { String(format: "%02X", $0) }.joined(separator: "|")
    }

    public static func code(forName name: String) -> UInt16? {
        if let c = aliases[name] { return c }
        if name.count == 1, let c = singleCharacter[name] { return c }
        if name.hasPrefix("0x"), let v = UInt16(name.dropFirst(2), radix: 16) { return v }
        return nil
    }

    public static func name(forHIDCode code: UInt16) -> String? {
        canonicalNames[code]
    }

    /// All accepted key names, grouped for `vibepier keys`.
    public static var allNames: [(code: UInt16, names: [String])] {
        var byCode: [UInt16: [String]] = [:]
        for (n, c) in aliases { byCode[c, default: []].append(n) }
        for (n, c) in singleCharacter { byCode[c, default: []].append(n) }
        return byCode.keys.sorted().map { c in
            let canonical = canonicalNames[c]
            var names = byCode[c]!.sorted()
            if let canonical, let i = names.firstIndex(of: canonical) {
                names.remove(at: i)
                names.insert(canonical, at: 0)
            }
            return (c, names)
        }
    }

    // MARK: Tables

    static let singleCharacter: [String: UInt16] = {
        var m: [String: UInt16] = [:]
        for (i, ch) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[String(ch)] = 0x04 + UInt16(i) }
        for (i, ch) in "1234567890".enumerated() { m[String(ch)] = 0x1E + UInt16(i) }
        let punct: [(String, UInt16)] = [
            ("-", 0x2D), ("=", 0x2E), ("[", 0x2F), ("]", 0x30), ("\\", 0x31),
            (";", 0x33), ("'", 0x34), ("`", 0x35), (",", 0x36), (".", 0x37), ("/", 0x38),
            ("+", 0x2E),
        ]
        for (k, v) in punct { m[k] = v }
        return m
    }()

    /// Name -> HID code. Canonical names come first in `canonicalNames`.
    static let aliases: [String: UInt16] = {
        var m: [String: UInt16] = [
            // Modifiers (left side unless stated).
            "ctrl": 0xE0, "control": 0xE0, "lctrl": 0xE0, "⌃": 0xE0,
            "shift": 0xE1, "lshift": 0xE1, "⇧": 0xE1,
            "alt": 0xE2, "option": 0xE2, "opt": 0xE2, "lalt": 0xE2, "⌥": 0xE2,
            "cmd": 0xE3, "command": 0xE3, "gui": 0xE3, "meta": 0xE3, "super": 0xE3, "win": 0xE3, "lcmd": 0xE3,
            "⌘": 0xE3,
            "rctrl": 0xE4, "rcontrol": 0xE4,
            "rshift": 0xE5,
            "ralt": 0xE6, "roption": 0xE6, "ropt": 0xE6,
            "rcmd": 0xE7, "rcommand": 0xE7,
            // Fn / Globe. The firmware sends it on page 0x13.
            "fn": 0x02, "globe": 0x02,
            // Editing and navigation.
            "return": 0x28, "enter": 0x28, "↩": 0x28,
            "escape": 0x29, "esc": 0x29, "⎋": 0x29,
            "backspace": 0x2A, "delete": 0x2A, "⌫": 0x2A,
            "tab": 0x2B, "⇥": 0x2B,
            "space": 0x2C, "spacebar": 0x2C,
            "minus": 0x2D, "equal": 0x2E, "equals": 0x2E, "plus": 0x2E,
            "leftbracket": 0x2F, "rightbracket": 0x30, "backslash": 0x31,
            "semicolon": 0x33, "quote": 0x34, "apostrophe": 0x34, "grave": 0x35, "backtick": 0x35,
            "comma": 0x36, "period": 0x37, "dot": 0x37, "slash": 0x38,
            "capslock": 0x39, "caps": 0x39,
            "printscreen": 0x46, "scrolllock": 0x47, "pause": 0x48,
            "insert": 0x49, "home": 0x4A, "pageup": 0x4B, "pgup": 0x4B,
            "forwarddelete": 0x4C, "del": 0x4C, "⌦": 0x4C,
            "end": 0x4D, "pagedown": 0x4E, "pgdn": 0x4E,
            "right": 0x4F, "rightarrow": 0x4F, "→": 0x4F,
            "left": 0x50, "leftarrow": 0x50, "←": 0x50,
            "down": 0x51, "downarrow": 0x51, "↓": 0x51,
            "up": 0x52, "uparrow": 0x52, "↑": 0x52,
            "numlock": 0x53, "clear": 0x53,
            "kp/": 0x54, "kp*": 0x55, "kp-": 0x56, "kp+": 0x57, "kpenter": 0x58,
            "kp1": 0x59, "kp2": 0x5A, "kp3": 0x5B, "kp4": 0x5C, "kp5": 0x5D,
            "kp6": 0x5E, "kp7": 0x5F, "kp8": 0x60, "kp9": 0x61, "kp0": 0x62, "kp.": 0x63,
            "application": 0x65, "menu": 0x65, "power": 0x66, "kp=": 0x67,
            "help": 0x75, "mute": 0x7F, "volumeup": 0x80, "volumedown": 0x81,
            // Mouse actions (Ulanzi Studio native codes 0x1001...0x1005).
            "left-click": 0x100, "leftclick": 0x100, "click": 0x100, "mouse1": 0x100,
            "right-click": 0x101, "rightclick": 0x101, "mouse2": 0x101,
            "middle-click": 0x102, "middleclick": 0x102, "mouse3": 0x102,
            "wheel-up": 0x105, "wheelup": 0x105, "scroll-up": 0x105, "scrollup": 0x105,
            "wheel-down": 0x106, "wheeldown": 0x106, "scroll-down": 0x106, "scrolldown": 0x106,
        ]
        for i in 1...12 { m["f\(i)"] = 0x3A + UInt16(i - 1) }
        for i in 13...24 { m["f\(i)"] = 0x68 + UInt16(i - 13) }
        return m
    }()

    static let canonicalNames: [UInt16: String] = {
        var m: [UInt16: String] = [
            0xE0: "ctrl", 0xE1: "shift", 0xE2: "alt", 0xE3: "cmd",
            0xE4: "rctrl", 0xE5: "rshift", 0xE6: "ralt", 0xE7: "rcmd",
            0x02: "fn", 0x28: "return", 0x29: "escape", 0x2A: "backspace", 0x2B: "tab",
            0x2C: "space", 0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\",
            0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/",
            0x39: "capslock", 0x46: "printscreen", 0x47: "scrolllock", 0x48: "pause",
            0x49: "insert", 0x4A: "home", 0x4B: "pageup", 0x4C: "forwarddelete", 0x4D: "end",
            0x4E: "pagedown", 0x4F: "right", 0x50: "left", 0x51: "down", 0x52: "up",
            0x53: "numlock", 0x54: "kp/", 0x55: "kp*", 0x56: "kp-", 0x57: "kp+", 0x58: "kpenter",
            0x59: "kp1", 0x5A: "kp2", 0x5B: "kp3", 0x5C: "kp4", 0x5D: "kp5",
            0x5E: "kp6", 0x5F: "kp7", 0x60: "kp8", 0x61: "kp9", 0x62: "kp0", 0x63: "kp.",
            0x65: "menu", 0x66: "power", 0x67: "kp=", 0x75: "help",
            0x7F: "mute", 0x80: "volumeup", 0x81: "volumedown",
            0x100: "left-click", 0x101: "right-click", 0x102: "middle-click",
            0x105: "wheel-up", 0x106: "wheel-down",
        ]
        for (i, ch) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[0x04 + UInt16(i)] = String(ch) }
        for (i, ch) in "1234567890".enumerated() { m[0x1E + UInt16(i)] = String(ch) }
        for i in 1...12 { m[0x3A + UInt16(i - 1)] = "f\(i)" }
        for i in 13...24 { m[0x68 + UInt16(i - 13)] = "f\(i)" }
        return m
    }()

    /// Renders firmware pairs as a hotkey string, for example `cmd+shift+4`.
    public static func render(_ keys: [ShortcutKey]) -> String {
        var parts: [String] = []
        for k in keys {
            if k.page == 3 {
                // A modifier pair can carry several bits.
                for bit in 0..<8 where k.value & UInt8(1 << bit) != 0 {
                    parts.append(canonicalNames[0xE0 + UInt16(bit)] ?? "mod\(bit)")
                }
            } else {
                parts.append(k.description)
            }
        }
        return parts.joined(separator: "+")
    }
}

/// Firmware fixed functions (`setDeviceButtonFixedFunction`).
///
/// Ulanzi Studio uses these for media keys (`MediaKeyConverter`), and the
/// AU05 ships with 0x6E...0x73 as factory defaults.
public enum FixedFunction {
    public static let named: [(name: String, code: UInt32)] = [
        ("play-pause", 7), ("next-track", 8), ("previous-track", 9),
        ("mute", 11), ("volume-up", 12), ("volume-down", 13),
        ("factory-knob-press", 0x6E), ("factory-talk", 0x6F), ("factory-confirm", 0x70),
        ("factory-cancel", 0x71), ("factory-knob-right", 0x72), ("factory-knob-left", 0x73),
    ]

    public static func code(forName name: String) -> UInt32? {
        let n = name.lowercased()
        if let hit = named.first(where: { $0.name == n }) { return hit.code }
        if n.hasPrefix("0x"), let v = UInt32(n.dropFirst(2), radix: 16) { return v }
        return UInt32(n)
    }

    public static func name(forCode code: UInt32) -> String {
        named.first(where: { $0.code == code })?.name ?? String(format: "0x%02X", code)
    }
}
