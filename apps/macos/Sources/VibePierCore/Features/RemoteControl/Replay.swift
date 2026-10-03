// SPDX-License-Identifier: MIT

import ApplicationServices
import Foundation
import VibeKit

/// A firmware binding, translated into host events.
enum Replay {
    case keys([UInt16])
    case media(Int)
    case none(String)

    init(binding: ButtonBinding) {
        if !binding.shortcut.isEmpty {
            self = .keys(Replay.codes(binding.shortcut))
            return
        }
        guard let fn = binding.fixedFunction else {
            self = .none("no binding")
            return
        }
        if fn == binding.control.factoryFixedFunction,
            let codes = try? Hotkey.parseHIDCodes(binding.control.defaultHotkey)
        {
            self = .keys(codes)
        } else if let nx = KeySynth.mediaKeys[fn] {
            self = .media(nx)
        } else {
            self = .none("fixed function \(FixedFunction.name(forCode: fn)) has no host equivalent")
        }
    }

    /// Expands firmware pairs to HID codes. A modifier pair can carry several bits.
    static func codes(_ keys: [ShortcutKey]) -> [UInt16] {
        var out: [UInt16] = []
        for k in keys {
            if k.page == 3 {
                for bit in 0..<8 where k.value & UInt8(1 << bit) != 0 { out.append(0xE0 + UInt16(bit)) }
            } else {
                out.append(k.hidCode)
            }
        }
        return out
    }

    func press() throws {
        switch self {
        case .keys(let c): try KeySynth.press(c)
        case .media(let nx): try KeySynth.mediaKey(nx, down: true)
        case .none: break
        }
    }

    func release() throws {
        switch self {
        case .keys(let c): try KeySynth.release(c)
        case .media(let nx): try KeySynth.mediaKey(nx, down: false)
        case .none: break
        }
    }

    func tap() throws {
        try press()
        try release()
    }

    static func checkAccessibility(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
