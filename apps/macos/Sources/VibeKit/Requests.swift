// SPDX-License-Identifier: MIT
//
// Request builders. Each one reproduces the byte layout of the matching
// `+[MessageHelper ...]` builder in kwdm.dylib. The layouts were recovered by
// emulating the builders and were checked against the live AU05 dongle.

/// How to recognise the reply to a request.
public struct ReplyMatch: Sendable, Equatable {
    public var type: UInt8
    public var group: UInt8
    public var command: UInt8
    /// Optional extra byte check, for commands that carry an index.
    public var byteAt: Int?
    public var byteValue: UInt8?
    /// Expected operation byte of the reply: the request operation with the reply flag set.
    public var operation: UInt8?

    public init(
        type: UInt8, group: UInt8, command: UInt8, byteAt: Int? = nil, byteValue: UInt8? = nil,
        operation: UInt8? = nil
    ) {
        self.type = type
        self.group = group
        self.command = command
        self.byteAt = byteAt
        self.byteValue = byteValue
        self.operation = operation
    }

    public func matches(_ f: Frame) -> Bool {
        guard f.rawType & 0x1F == type, f.group == group, f.command == command, f.isReply else {
            return false
        }
        if let op = operation, f.operation != op {
            // Some writes (hooks mode, for example) are acknowledged with a bare 0x10.
            let isWrite = op != Operation.read | Operation.replyFlag
            if !(isWrite && f.operation == Operation.replyFlag) { return false }
        }
        if let i = byteAt, let v = byteValue, f[i] != v { return false }
        return true
    }
}

/// A protocol request: the plaintext bytes and the reply to wait for.
public struct Request: Sendable, CustomStringConvertible {
    public var name: String
    public var bytes: [UInt8]
    public var reply: ReplyMatch?

    public init(_ name: String, _ bytes: [UInt8], reply: ReplyMatch?) {
        self.name = name
        self.bytes = bytes + [UInt8](repeating: 0, count: max(0, VibeUSB.reportLength - bytes.count))
        self.reply = reply
    }

    public var description: String { "\(name) [\(Frame(bytes).shortHex)]" }

    /// A read or write whose reply echoes type, group, and command.
    static func simple(
        _ name: String, _ type: MessageType, _ group: UInt8, _ command: UInt8,
        _ op: UInt8, _ payload: [UInt8] = [], matchByte: (Int, UInt8)? = nil
    ) -> Request {
        Request(
            name, [type.rawValue, group, command, op] + payload,
            reply: ReplyMatch(
                type: type.rawValue, group: group, command: command,
                byteAt: matchByte?.0, byteValue: matchByte?.1,
                operation: op | Operation.replyFlag))
    }
}

func le16(_ v: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
}

func le32(_ v: UInt32) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
        UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24),
    ]
}

/// Commands handled by the dongle (message type 0x06).
public enum DongleRequest {
    /// `dongleAuthMessage:`. The dongle replies with `code ^ authPrivateKeys[index]`.
    public static func auth(code: UInt32) -> Request {
        .simple("dongle.auth", .dongle, 0x02, 0x05, Operation.read, [UInt8(code & 0x0F)] + le32(code))
    }

    /// `deviceHeartbeatMessage`. The vendor library sends it every second once authenticated.
    public static let heartbeat = Request(
        "dongle.heartbeat", [0x06, 0x01, 0x23, 0x00, 0x01],
        reply: nil)

    public static let version = Request.simple("dongle.version", .dongle, 0x02, 0x03, Operation.read)
    public static let flashID = Request.simple("dongle.flashId", .dongle, 0x02, 0x0B, Operation.read)
    public static let serialNumber = Request.simple("dongle.sn", .dongle, 0x02, 0x81, Operation.read)
    /// Reports whether the microphone is currently linked to the dongle.
    public static let deviceActive = Request.simple("dongle.deviceActive", .dongle, 0x03, 0x0A, Operation.read)
    public static let chargingStatus = Request.simple("dongle.charging", .dongle, 0x08, 0x02, Operation.read)

    /// `setDongleRebootMessage:`. Ulanzi Studio passes 500.
    public static func reboot(delayMs: UInt32 = 500) -> Request {
        .simple("dongle.reboot", .dongle, 0x01, 0x26, Operation.write0, le32(delayMs))
    }
}

/// Indicator LED parameters. The value for LED `n` sits at byte `8 + 5n + field`.
public enum LEDField: Int, CaseIterable, Sendable {
    case workType = 0
    case workTime = 1
    case breatheLevel = 2
    case breatheBrightness = 3
    case alwaysOnBrightness = 4

    /// Bit in byte 4 that selects the field in a write.
    public var mask: UInt8 { UInt8(0x04 << rawValue) }

    public var name: String {
        switch self {
        case .workType: return "type"
        case .workTime: return "time"
        case .breatheLevel: return "breathe-level"
        case .breatheBrightness: return "breathe-brightness"
        case .alwaysOnBrightness: return "brightness"
        }
    }

    public init?(name: String) {
        guard let f = LEDField.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = f
    }
}

/// Commands relayed to the microphone (message type 0x01).
public enum DeviceRequest {
    public static let battery = Request.simple("device.battery", .device, 0x01, 0x02, Operation.read)
    public static let version = Request.simple("device.version", .device, 0x04, 0x04, Operation.read)
    public static let hardwareVersion = Request.simple("device.hwVersion", .device, 0x01, 0x41, Operation.read)
    public static let flashID = Request.simple("device.flashId", .device, 0x04, 0x0B, Operation.read)
    /// The serial number arrives in two chunks (offset 0 and offset 1).
    public static let serialNumber = Request.simple("device.sn", .device, 0x01, 0x0B, Operation.read)
    public static let uuid = Request.simple("device.uuid", .device, 0x01, 0x0A, Operation.read)
    public static let macAddress = Request.simple("device.mac", .device, 0x01, 0xFA, Operation.read)

    public static let standbyStatus = Request.simple("device.standby", .device, 0x01, 0x0D, Operation.read)
    public static func setStandbyStatus(_ on: Bool) -> Request {
        .simple("device.setStandby", .device, 0x01, 0x0D, Operation.write0, [on ? 1 : 0])
    }

    public static let standbyTime = Request.simple("device.standbyTime", .device, 0x01, 0x2C, Operation.read)
    public static func setStandbyTime(seconds: UInt32) -> Request {
        .simple("device.setStandbyTime", .device, 0x01, 0x2C, Operation.write2, le32(seconds))
    }

    /// Auto power-off time in seconds. Ulanzi Studio offers 3600, 7200, 10800, 14400, and 0 (never).
    public static let sleepTime = Request.simple("device.sleepTime", .device, 0x01, 0x42, Operation.read)
    public static func setSleepTime(seconds: UInt32) -> Request {
        .simple("device.setSleepTime", .device, 0x01, 0x42, Operation.write2, le32(seconds))
    }

    public static let microphoneEnable = Request.simple("device.micEnable", .device, 0x01, 0x2A, Operation.read)
    public static func setMicrophoneEnable(_ on: Bool) -> Request {
        .simple("device.setMicEnable", .device, 0x01, 0x2A, Operation.write0, [on ? 1 : 0])
    }

    /// Noise reduction. Ulanzi Studio writes level 0 (off) or 1 (on) with
    /// lowParam 1600 and highParam 1000.
    public static let noiseReduction = Request.simple("device.nr", .device, 0x01, 0x90, Operation.read)
    public static func setNoiseReduction(level: UInt8, low: UInt16 = 1600, high: UInt16 = 1000) -> Request {
        .simple("device.setNr", .device, 0x01, 0x90, Operation.write4, [level] + le16(Int(low)) + le16(Int(high)))
    }

    /// Haptic motor strength. Ulanzi Studio writes 255 (on) or 0 (off).
    public static let motorStrength = Request.simple("device.motor", .device, 0x06, 0x40, Operation.read)
    public static func setMotorStrength(_ value: UInt16) -> Request {
        .simple("device.setMotor", .device, 0x06, 0x40, Operation.write4, le16(Int(value)))
    }

    public static let audioButtonSystemMode = Request.simple(
        "device.audioButtonMode", .device, 0x06, 0x51, Operation.read)
    public static func setAudioButtonSystemMode(_ mode: UInt8) -> Request {
        .simple("device.setAudioButtonMode", .device, 0x06, 0x51, Operation.write4, [mode])
    }

    /// AI-agent hooks mode. Ulanzi Studio enables it when its agent hooks are installed.
    public static let hooksMode = Request.simple("device.hooksMode", .device, 0x0B, 0x89, Operation.read)
    public static func setHooksMode(_ on: Bool) -> Request {
        .simple("device.setHooksMode", .device, 0x0B, 0x89, Operation.write4, [on ? 1 : 0])
    }

    public static let supportMicrophone = Request.simple("device.supportMic", .device, 0x06, 0x37, Operation.read)
    public static let supportButtonFunction = Request.simple(
        "device.supportButtonFunc", .device, 0x06, 0x38, Operation.read)
    public static let supportLEDEffect = Request.simple("device.supportLedEffect", .device, 0x06, 0x39, Operation.read)

    // MARK: Indicator LEDs

    public static let indicatorLights = Request.simple("device.leds", .device, 0x0B, 0x88, Operation.read)

    /// Light mode: 0 = off, 1 = all on, 2 = per-LED work mode (Ulanzi Studio radio buttons).
    public static func setIndicatorLightMode(_ mode: UInt8) -> Request {
        .simple("device.setLedMode", .device, 0x0B, 0x88, Operation.write4, [0x01, 0x00, mode])
    }

    /// Brightness used by light mode 1. Ulanzi Studio uses a 0...20 slider.
    public static func setIndicatorLightAllOnBrightness(_ level: UInt8) -> Request {
        .simple("device.setLedAllOnBrightness", .device, 0x0B, 0x88, Operation.write4, [0x02, 0x00, 0x00, level])
    }

    /// Sets one per-LED work-mode field (`setDeviceIndicatorLightWorkMode*`).
    public static func setIndicatorLight(led: Int, field: LEDField, value: UInt8) -> Request {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = MessageType.device.rawValue
        b[1] = 0x0B
        b[2] = 0x88
        b[3] = Operation.write4
        b[4] = field.mask
        b[5] = UInt8(truncatingIfNeeded: led)
        let offset = 8 + 5 * led + field.rawValue
        if offset < 64 { b[offset] = value }
        return Request(
            "device.setLed\(led).\(field.name)", b,
            reply: ReplyMatch(
                type: 0x01, group: 0x0B, command: 0x88,
                operation: Operation.write4 | Operation.replyFlag))
    }

    // MARK: Buttons

    /// `getDeviceButtonFuncMessage:`. Reply byte 5 echoes the index.
    public static func buttonFixedFunction(_ index: Int) -> Request {
        .simple(
            "device.buttonFunc\(index)", .device, 0x06, 0x10, Operation.read,
            [0x00, UInt8(index)], matchByte: (5, UInt8(index)))
    }

    /// `setDeviceButtonFuncMessage:funcIndex:`, used for media keys and firmware defaults.
    public static func setButtonFixedFunction(_ index: Int, function: UInt32) -> Request {
        .simple(
            "device.setButtonFunc\(index)", .device, 0x06, 0x10, Operation.write4,
            [0x00, UInt8(index)] + le32(function), matchByte: (5, UInt8(index)))
    }

    /// `getDeviceButtonShortcutFunctionMessage:`. Reply byte 4 echoes the index.
    public static func buttonShortcut(_ index: Int) -> Request {
        .simple(
            "device.shortcut\(index)", .device, 0x06, 0x50, Operation.read,
            [UInt8(index)], matchByte: (4, UInt8(index)))
    }

    /// `setDeviceButtonShortcutFunctionMessage:num:pages:values:signs:`.
    ///
    /// Layout: `01 06 50 04 [index] 01 [count] {[page | sign << 7] [value]} x count`.
    public static func setButtonShortcut(_ index: Int, keys: [ShortcutKey]) -> Request {
        var payload: [UInt8] = [UInt8(index), 0x01, UInt8(keys.count)]
        for k in keys {
            payload.append((k.page & 0x7F) | (k.sign ? 0x80 : 0))
            payload.append(k.value)
        }
        return .simple(
            "device.setShortcut\(index)", .device, 0x06, 0x50, Operation.write4, payload,
            matchByte: (4, UInt8(index)))
    }

    /// `setDeviceRebootMessage:`. Ulanzi Studio passes 500.
    public static func reboot(delayMs: UInt32 = 500) -> Request {
        .simple("device.reboot", .device, 0x01, 0x0C, Operation.write0, le32(delayMs))
    }
}

/// Firmware-upgrade messages. `base` is 0x1E for the dongle and 0x1F for the mic.
public enum UpgradeRequest {
    /// Step 1: announce the image. `fileLength` is the payload length from the
    /// image header, and `customCode` is the 3-byte code from header bytes 5...7.
    public static func connect(target: UInt8, fileLength: UInt32, customCode: [UInt8]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = target
        b[1] = 0x01
        writeLE32(&b, 8, fileLength)
        for (i, c) in customCode.prefix(3).enumerated() { b[12 + i] = c }
        return b
    }

    /// Step 2: one data package of the current frame (at most 59 bytes; the vendor uses 32).
    public static func data(target: UInt8, packageIndex: Int, chunk: [UInt8]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = target
        b[1] = 0x02
        writeLE16(&b, 2, UInt16(truncatingIfNeeded: packageIndex))
        b[4] = UInt8(truncatingIfNeeded: chunk.count)
        for (i, c) in chunk.prefix(59).enumerated() { b[5 + i] = c }
        return b
    }

    /// Step 3: ask which packages arrived. `checksum` is the byte sum of the frame.
    public static func receivePackageNum(target: UInt8, checksum: UInt32) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = target
        b[1] = 0x03
        writeLE32(&b, 6, checksum)
        return b
    }

    /// Step 4: commit the current frame to flash.
    public static func enableProgram(target: UInt8, frameIndex: Int, packageCount: Int, enable: Bool = true) -> [UInt8]
    {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = target
        b[1] = 0x04
        writeLE16(&b, 2, UInt16(truncatingIfNeeded: frameIndex))
        b[4] = UInt8(truncatingIfNeeded: packageCount)
        b[5] = enable ? 1 : 0
        return b
    }

    /// Step 5: ask for the whole-image checksum.
    public static func checkAllSum(target: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = target
        b[1] = 0x06
        return b
    }

    /// Step 6: report whether the whole-image checksum matched.
    public static func allPageCompleteResult(target: UInt8, matched: Bool) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = target
        b[1] = 0x07
        b[2] = matched ? 1 : 0
        return b
    }
}
