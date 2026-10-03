// SPDX-License-Identifier: MIT
//
// Parser for replies and notices. Field offsets were recovered by feeding
// crafted frames to `-[MessageHandler parseMessage:length:]` in kwdm.dylib and
// logging the delegate calls it made. Live AU05 captures confirm them.

import Foundation

public struct VersionInfo: Equatable, Sendable, Codable {
    /// Three-byte customer code, for example "410000".
    public var customCode: String
    /// Firmware version, for example "4.4.0".
    public var version: String
    /// Build stamp bytes (BCD year, month, day, hour, minute on units seen so far).
    public var buildStamp: String
    public var raw: [UInt8]

    init(frame f: Frame) {
        let p = f.slice(4, 15)
        func b(_ i: Int) -> UInt8 { i < p.count ? p[i] : 0 }
        customCode = String(format: "%02X%02X%02X", b(0), b(1), b(2))
        if b(14) != 0 {
            version = "\(b(6)).\(b(7)).\(b(8)).\(b(14))"
        } else {
            version = "\(b(6)).\(b(7)).\(b(8))"
        }
        buildStamp = String(format: "20%02x-%02x-%02x %02x:%02x", b(9), b(10), b(11), b(12), b(13))
        raw = p
    }
}

public struct BatteryStatus: Equatable, Sendable, Codable {
    public var percent: Int
    public var millivolts: Int
    public var charging: Bool
    public var chargeFull: Bool
    /// 0 = normal. Higher values mean lower battery.
    public var lowBatteryLevel: Int
    public var powerOff: Bool
}

public struct LEDState: Equatable, Sendable, Codable {
    public var workType: UInt8
    public var workTime: UInt8
    public var breatheLevel: UInt8
    public var breatheBrightness: UInt8
    public var alwaysOnBrightness: UInt8

    public func value(_ field: LEDField) -> UInt8 {
        switch field {
        case .workType: return workType
        case .workTime: return workTime
        case .breatheLevel: return breatheLevel
        case .breatheBrightness: return breatheBrightness
        case .alwaysOnBrightness: return alwaysOnBrightness
        }
    }
}

public struct IndicatorLights: Equatable, Sendable, Codable {
    /// 0 = off, 1 = all on, 2 = work mode.
    public var mode: UInt8
    public var allOnBrightness: UInt8
    public var leds: [LEDState]
}

public struct KeyEvent: Equatable, Sendable, Codable {
    public var index: UInt8
    public var status: UInt8
    public var physicalIndex: UInt8

    /// The control, resolved the way the vendor library does for the AU05: its
    /// device-table entry sets `isSwitchKeyIndex`, so the physical index is reported.
    public var control: Control? { Control(rawValue: Int(physicalIndex)) }
}

public enum UpgradeEvent: Equatable, Sendable {
    case connected
    case receivePackageNum(mask: UInt32, checksum: UInt32)
    case programComplete(result: UInt8, mask: UInt8, index: UInt16)
    case checkAllSum(UInt32)
    case result(UInt8)
    case other(Frame)
}

/// A parsed message from the dongle.
public enum VibeMessage: Sendable, Equatable {
    // Dongle replies.
    case authReply(keyIndex: Int, code: UInt32)
    case dongleVersion(VersionInfo)
    case dongleFlashID([UInt8])
    case dongleSerial(String)
    case deviceActive(Bool)
    case dongleCharging(UInt8)
    case dongleReboot(ok: Bool)
    case heartbeat

    // Device (mic) replies.
    case deviceVersion(VersionInfo)
    case hardwareVersion(UInt8)
    case deviceFlashID([UInt8])
    case deviceSerialChunk(offset: Int, bytes: [UInt8])
    case uuidChunk(offset: Int, bytes: [UInt8])
    case macAddress([UInt8])
    case battery(BatteryStatus)
    case standbyStatus(UInt8)
    case standbyTime(UInt32)
    case sleepTime(UInt32)
    case microphoneEnable(Bool)
    case noiseReduction(level: UInt8, low: Int, high: Int)
    case motorStrength(UInt16)
    case audioButtonSystemMode(UInt8)
    case hooksMode(UInt8)
    case indicatorLights(IndicatorLights)
    case buttonFixedFunction(index: Int, macroConfig: UInt8, function: UInt32)
    case buttonShortcut(index: Int, keys: [ShortcutKey])
    case supportFlag(command: UInt8, value: UInt8)
    case deviceReboot(ok: Bool)

    // Notices.
    case keyEvent(KeyEvent)
    case linkActive(Bool)
    case batteryNotice(BatteryStatus)
    case chargingNotice(Bool)
    case standbyNotice(UInt8)
    case powerOn
    case noiseReductionNotice(level: UInt8, low: Int, high: Int)

    // Firmware upgrade.
    case upgrade(target: UInt8, UpgradeEvent)

    /// A reply that the parser does not decode (for example a write acknowledgement).
    case reply(Frame)
    case unknown(Frame)

    public static func parse(_ f: Frame) -> VibeMessage {
        switch f.rawType & 0x1F {
        case MessageType.dongle.rawValue: return parseDongle(f)
        case MessageType.device.rawValue: return parseDevice(f)
        case MessageType.notice.rawValue: return parseNotice(f)
        case MessageType.dongleUpgrade.rawValue, MessageType.deviceUpgrade.rawValue, MessageType.uploadImage.rawValue:
            return .upgrade(target: f.rawType & 0x1F, parseUpgrade(f))
        default: return .unknown(f)
        }
    }

    static func parseDongle(_ f: Frame) -> VibeMessage {
        if f.group == 0x01, f.command == 0x23 { return .heartbeat }
        guard f.isReply else { return .unknown(f) }
        switch (f.group, f.command) {
        case (0x01, 0x26): return .dongleReboot(ok: true)
        case (0x02, 0x03): return .dongleVersion(VersionInfo(frame: f))
        case (0x02, 0x05):
            let index = Int(f[4])
            guard index < authPrivateKeys.count else { return .unknown(f) }
            return .authReply(keyIndex: index, code: f.u32(5) ^ authPrivateKeys[index])
        case (0x02, 0x0B): return .dongleFlashID(f.slice(4, 16))
        case (0x02, 0x81):
            let length = min(Int(f[4]), 30)
            return .dongleSerial(ascii(f.slice(8, length)))
        case (0x03, 0x0A): return .deviceActive(f[4] != 0)
        case (0x08, 0x02): return .dongleCharging(f[4])
        default: return .reply(f)
        }
    }

    static func parseDevice(_ f: Frame) -> VibeMessage {
        guard f.isReply else { return .unknown(f) }
        switch (f.group, f.command) {
        case (0x01, 0x02):
            let flags = f[11]
            return .battery(
                BatteryStatus(
                    percent: Int(f.u16(6)), millivolts: Int(f.u16(4)),
                    charging: f[10] != 0, chargeFull: flags & 0x08 != 0,
                    lowBatteryLevel: Int(flags & 0x03), powerOff: flags & 0x04 != 0))
        case (0x01, 0x0A): return .uuidChunk(offset: Int(f[5]), bytes: f.slice(6, min(Int(f[4]), 58)))
        case (0x01, 0x0B): return .deviceSerialChunk(offset: Int(f[5]), bytes: f.slice(6, min(Int(f[4]), 58)))
        case (0x01, 0x0C): return .deviceReboot(ok: true)
        case (0x01, 0x0D): return f.operation == 0x11 ? .standbyStatus(f[4]) : .reply(f)
        case (0x01, 0x2A): return f.operation == 0x11 ? .microphoneEnable(f[4] != 0) : .reply(f)
        case (0x01, 0x2C): return f.operation == 0x11 ? .standbyTime(f.u32(4)) : .reply(f)
        case (0x01, 0x41): return .hardwareVersion(f[4])
        case (0x01, 0x42): return f.operation == 0x11 ? .sleepTime(f.u32(4)) : .reply(f)
        case (0x01, 0x90):
            return f.operation == 0x11
                ? .noiseReduction(level: f[4], low: Int(f.u16(5)), high: Int(f.u16(7)))
                : .reply(f)
        case (0x01, 0xFA): return .macAddress(f.slice(4, 6))
        case (0x04, 0x04): return .deviceVersion(VersionInfo(frame: f))
        case (0x04, 0x0B): return .deviceFlashID(f.slice(4, 16))
        case (0x06, 0x10):
            return .buttonFixedFunction(index: Int(f[5]), macroConfig: f[4], function: f.u32(6))
        case (0x06, 0x37), (0x06, 0x38), (0x06, 0x39):
            return .supportFlag(command: f.command, value: f[4])
        case (0x06, 0x40): return f.operation == 0x11 ? .motorStrength(f.u16(4)) : .reply(f)
        case (0x06, 0x50):
            let count = min(Int(f[6]), 28)
            var keys: [ShortcutKey] = []
            for i in 0..<count {
                let pageByte = f[7 + 2 * i]
                keys.append(ShortcutKey(page: pageByte & 0x7F, value: f[8 + 2 * i], sign: pageByte & 0x80 != 0))
            }
            return .buttonShortcut(index: Int(f[4]), keys: keys)
        case (0x06, 0x51): return f.operation == 0x11 ? .audioButtonSystemMode(f[4]) : .reply(f)
        case (0x0B, 0x88):
            guard f.operation == 0x11 else { return .reply(f) }
            var leds: [LEDState] = []
            for i in 0..<4 {
                let o = 8 + 5 * i
                leds.append(
                    LEDState(
                        workType: f[o], workTime: f[o + 1], breatheLevel: f[o + 2],
                        breatheBrightness: f[o + 3], alwaysOnBrightness: f[o + 4]))
            }
            return .indicatorLights(IndicatorLights(mode: f[6], allOnBrightness: f[7], leds: leds))
        case (0x0B, 0x89): return f.operation == 0x11 ? .hooksMode(f[4]) : .reply(f)
        default: return .reply(f)
        }
    }

    static func parseNotice(_ f: Frame) -> VibeMessage {
        switch f[1] {
        case 0x0B: return .linkActive(f[2] & 1 != 0)
        case 0x0D: return .standbyNotice(f[2])
        case 0x10: return .keyEvent(KeyEvent(index: f[2], status: f[3], physicalIndex: f[4]))
        case 0x6F: return .chargingNotice(f[4] & 0x08 != 0)
        case 0x7B:
            let flags = f[4]
            return .batteryNotice(
                BatteryStatus(
                    percent: Int(f[5]), millivolts: Int(f.u16(2)),
                    charging: flags & 0x08 != 0, chargeFull: flags & 0x10 != 0,
                    lowBatteryLevel: Int(flags & 0x03), powerOff: flags & 0x04 != 0))
        case 0x83:
            return .noiseReductionNotice(
                level: f[2], low: Int(Int16(bitPattern: f.u16(3))),
                high: Int(Int16(bitPattern: f.u16(5))))
        case 0xF0: return .powerOn
        default: return .unknown(f)
        }
    }

    static func parseUpgrade(_ f: Frame) -> UpgradeEvent {
        switch f[1] {
        case 0x01: return .connected
        case 0x03: return .receivePackageNum(mask: f.u32(2), checksum: f.u32(6))
        case 0x05: return .programComplete(result: f[2], mask: f[3], index: f.u16(4))
        case 0x06: return .checkAllSum(f.u32(2))
        case 0x08: return .result(f[2])
        default: return .other(f)
        }
    }

    static func ascii(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

public func hexString(_ bytes: [UInt8], separator: String = "") -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
}
