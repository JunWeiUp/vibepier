// SPDX-License-Identifier: MIT
//
// Host-side actions for key events. Without a host session, the dongle types
// the stored bindings on its own HID keyboard interface. While a host session
// is open (the daemon sends the heartbeat), the firmware sends key-event
// notices instead, and the host must perform the binding. The daemon replays
// the binding with CGEvent, which is what Ulanzi Studio does through
// `ProfilePresenter::triggerDialAction`.

import AppKit
import ApplicationServices
import Foundation
import VibeKit

enum ActionRunner {
    private static let sequentialQueue = DispatchQueue(label: "io.github.junweiup.vibepier.sequential-actions")
    nonisolated(unsafe) private static var heldVoiceKeys: String?

    static func shutdown() {
        sequentialQueue.sync {
            if let keys = heldVoiceKeys { sendKeys(keys, event: "release", mode: "release", log: { _ in }) }
            heldVoiceKeys = nil
            try? TalkInputRouter.shared.release()
        }
    }

    static func run(_ action: HostAction, pressed: Bool, log: @escaping @Sendable (String) -> Void) {
        if action.sequential == true || action.switchInput == true {
            sequentialQueue.async { execute(action, pressed: pressed, wait: true, log: log) }
        } else {
            execute(action, pressed: pressed, wait: false, log: log)
        }
    }

    /// Used by the talk flow to bracket the completed action with heartbeat control.
    static func runAndWait(
        _ action: HostAction, pressed: Bool,
        shouldRun: @escaping @Sendable () -> Bool,
        log: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            sequentialQueue.async {
                guard shouldRun() else {
                    continuation.resume(returning: false)
                    return
                }
                execute(action, pressed: pressed, wait: true, log: log)
                continuation.resume(returning: true)
            }
        }
    }

    private static func execute(
        _ action: HostAction, pressed: Bool, wait: Bool, log: @escaping @Sendable (String) -> Void
    ) {
        let event = pressed ? "press" : "release"
        let holdingKeys = action.keysMode == "hold"
        // End dictation before returning to the previous microphone.
        if holdingKeys && !pressed {
            sendKeys(action.keys, event: event, mode: "release", log: log)
            if action.switchInput == true { heldVoiceKeys = nil }
        }
        if action.switchInput == true {
            do {
                if pressed { try TalkInputRouter.shared.press() } else { try TalkInputRouter.shared.release() }
            } catch {
                log("audio input switch: \(error)")
                return
            }
        }
        if let cmd = action.run {
            let succeeded = spawn("/bin/sh", ["-c", cmd], event: event, wait: wait, log: log)
            if wait && !succeeded { return }
        }
        if let target = action.open {
            let succeeded = spawn("/usr/bin/open", [target], event: event, wait: wait, log: log)
            if wait && !succeeded { return }
        }
        if let script = action.applescript {
            let succeeded = spawn("/usr/bin/osascript", ["-e", script], event: event, wait: wait, log: log)
            if wait && !succeeded { return }
        }
        if holdingKeys {
            if pressed {
                sendKeys(action.keys, event: event, mode: "press", log: log)
                if action.switchInput == true { heldVoiceKeys = action.keys }
            }
        } else {
            let keysOn = action.keysOn ?? action.trigger
            if keysOn == "both" || keysOn == event {
                sendKeys(action.keys, event: event, mode: "tap", log: log)
            }
        }
    }

    private static func sendKeys(
        _ keys: String?, event: String, mode: String, log: @escaping @Sendable (String) -> Void
    ) {
        guard let keys else { return }
        do {
            let codes = try Hotkey.parseHIDCodes(keys)
            switch mode {
            case "press": try KeySynth.press(codes)
            case "release": try KeySynth.release(codes)
            default: try KeySynth.tap(codes)
            }
        } catch {
            // Invalid key text can contain arbitrary user input; keep it out of persisted logs.
            log("action key synthesis failed on \(event)")
        }
    }

    @discardableResult static func spawn(
        _ path: String, _ args: [String], event: String, wait: Bool,
        log: @escaping @Sendable (String) -> Void
    ) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["VIBEPIER_KEY_EVENT"] = event
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            if wait {
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    log("action command exited with status \(p.terminationStatus): \(path)")
                    return false
                }
            }
            return true
        } catch {
            log("could not run \(path): \(error)")
            return false
        }
    }
}

/// Synthesises key and mouse events with CGEvent. It needs the Accessibility
/// permission for the process that posts the events.
enum KeySynth {
    enum SynthError: Error, CustomStringConvertible {
        case notTrusted
        case unmapped(UInt16)

        var description: String {
            switch self {
            case .notTrusted:
                return
                    L10n.text("core.key_permission")
            case .unmapped(let c): return L10n.text("core.unmapped_key", String(format: "%02X", c))
            }
        }
    }

    /// Presses and releases a hotkey.
    static func tap(_ codes: [UInt16]) throws {
        try press(codes)
        try release(codes)
    }

    /// Presses a hotkey and holds it: modifier keys go down first, then the keys.
    /// Mouse clicks go down, and a scroll step happens now.
    static func press(
        _ codes: [UInt16], isTrusted: () -> Bool = { AXIsProcessTrusted() },
        send: (InputEvent) -> Void = { emit($0) }
    ) throws {
        // Resolve the entire shortcut before posting its first modifier/mouse event.
        // A raw unsupported HID code must not strand a partially pressed shortcut.
        let events = try pressEvents(codes)
        guard isTrusted() else { throw SynthError.notTrusted }
        events.forEach(send)
    }

    enum InputEvent: Equatable {
        case key(CGKeyCode, Bool, CGEventFlags)
        case mouse(UInt16, Bool)
        case scroll(Bool)
    }

    private static func emit(_ event: InputEvent) {
        switch event {
        case .key(let code, let down, let flags): post(code, down: down, flags: flags)
        case .mouse(let code, let down): click(code, down: down)
        case .scroll(let up): scroll(up: up)
        }
    }

    private static func pressEvents(_ codes: [UInt16]) throws -> [InputEvent] {
        var events: [InputEvent] = []
        var flags: CGEventFlags = []
        for c in codes {
            if let (mask, key) = modifier(c) {
                flags.insert(mask)
                events.append(.key(key, true, flags))
            }
        }
        for c in codes where modifier(c) == nil {
            switch c {
            case 0x105, 0x106: events.append(.scroll(c == 0x105))
            case 0x100...0x102: events.append(.mouse(c, true))
            default:
                guard let k = hidToMac[c] else { throw SynthError.unmapped(c) }
                events.append(.key(k, true, flags))
            }
        }
        return events
    }

    /// Releases a hotkey pressed with `press`, in reverse order.
    static func release(_ codes: [UInt16]) throws {
        guard AXIsProcessTrusted() else { throw SynthError.notTrusted }
        var flags: CGEventFlags = []
        for c in codes { if let (mask, _) = modifier(c) { flags.insert(mask) } }
        for c in codes.reversed() where modifier(c) == nil {
            switch c {
            case 0x105, 0x106: break
            case 0x100...0x102: click(c, down: false)
            default:
                if let k = hidToMac[c] { post(k, down: false, flags: flags) }
            }
        }
        for c in codes.reversed() {
            if let (mask, key) = modifier(c) {
                flags.remove(mask)
                post(key, down: false, flags: flags)
            }
        }
    }

    /// Modifier HID usage -> (event flag, macOS key code).
    static func modifier(_ code: UInt16) -> (CGEventFlags, CGKeyCode)? {
        switch code {
        case 0xE0: return (.maskControl, 0x3B)
        case 0xE4: return (.maskControl, 0x3E)
        case 0xE1: return (.maskShift, 0x38)
        case 0xE5: return (.maskShift, 0x3C)
        case 0xE2: return (.maskAlternate, 0x3A)
        case 0xE6: return (.maskAlternate, 0x3D)
        case 0xE3: return (.maskCommand, 0x37)
        case 0xE7: return (.maskCommand, 0x36)
        case 0x02: return (.maskSecondaryFn, 0x3F)
        default: return nil
        }
    }

    static func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }

    static func scroll(up: Bool) {
        let delta: Int32 = up ? 3 : -3
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    static func click(_ code: UInt16, down: Bool) {
        let location = CGEvent(source: nil)?.location ?? .zero
        let (type, button): (CGEventType, CGMouseButton) = {
            switch code {
            case 0x101: return (down ? .rightMouseDown : .rightMouseUp, .right)
            case 0x102: return (down ? .otherMouseDown : .otherMouseUp, .center)
            default: return (down ? .leftMouseDown : .leftMouseUp, .left)
            }
        }()
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    /// Posts a media key (NX_KEYTYPE_*) as a system-defined event.
    static func mediaKey(_ nxKey: Int, down: Bool) throws {
        guard AXIsProcessTrusted() else { throw SynthError.notTrusted }
        let state = down ? 0xA : 0xB
        let data1 = (nxKey << 16) | (state << 8)
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }

    /// Fixed function code (`MediaKeyConverter`) -> NX_KEYTYPE value.
    static let mediaKeys: [UInt32: Int] = [7: 16, 8: 17, 9: 18, 11: 7, 12: 0, 13: 1]

    /// HID keyboard usage -> macOS virtual key code (ANSI layout).
    static let hidToMac: [UInt16: CGKeyCode] = [
        0x04: 0x00, 0x05: 0x0B, 0x06: 0x08, 0x07: 0x02, 0x08: 0x0E, 0x09: 0x03, 0x0A: 0x05, 0x0B: 0x04,
        0x0C: 0x22, 0x0D: 0x26, 0x0E: 0x28, 0x0F: 0x25, 0x10: 0x2E, 0x11: 0x2D, 0x12: 0x1F, 0x13: 0x23,
        0x14: 0x0C, 0x15: 0x0F, 0x16: 0x01, 0x17: 0x11, 0x18: 0x20, 0x19: 0x09, 0x1A: 0x0D, 0x1B: 0x07,
        0x1C: 0x10, 0x1D: 0x06,
        0x1E: 0x12, 0x1F: 0x13, 0x20: 0x14, 0x21: 0x15, 0x22: 0x17, 0x23: 0x16, 0x24: 0x1A, 0x25: 0x1C,
        0x26: 0x19, 0x27: 0x1D,
        0x28: 0x24, 0x29: 0x35, 0x2A: 0x33, 0x2B: 0x30, 0x2C: 0x31, 0x2D: 0x1B, 0x2E: 0x18, 0x2F: 0x21,
        0x30: 0x1E, 0x31: 0x2A, 0x33: 0x29, 0x34: 0x27, 0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C,
        0x39: 0x39,
        0x3A: 0x7A, 0x3B: 0x78, 0x3C: 0x63, 0x3D: 0x76, 0x3E: 0x60, 0x3F: 0x61, 0x40: 0x62, 0x41: 0x64,
        0x42: 0x65, 0x43: 0x6D, 0x44: 0x67, 0x45: 0x6F,
        0x49: 0x72, 0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77, 0x4E: 0x79,
        0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E,
        0x53: 0x47, 0x54: 0x4B, 0x55: 0x43, 0x56: 0x4E, 0x57: 0x45, 0x58: 0x4C,
        0x59: 0x53, 0x5A: 0x54, 0x5B: 0x55, 0x5C: 0x56, 0x5D: 0x57, 0x5E: 0x58, 0x5F: 0x59, 0x60: 0x5B,
        0x61: 0x5C, 0x62: 0x52, 0x63: 0x41, 0x67: 0x51,
        0x68: 0x69, 0x69: 0x6B, 0x6A: 0x71, 0x6B: 0x6A, 0x6C: 0x40, 0x6D: 0x4F, 0x6E: 0x50, 0x6F: 0x5A,
        0x75: 0x72, 0x7F: 0x4A, 0x80: 0x48, 0x81: 0x49,
    ]
}
