// SPDX-License-Identifier: MIT
//
// Wire-level constants for the Ulanzi Vibe Key (AU05).
//
// The Vibe Key is a wireless push-to-talk microphone ("device", "mic", "TX")
// paired with a USB dongle ("dongle", "RX"). The dongle enumerates as a
// composite USB device with a USB Audio Class microphone, a standard HID
// keyboard/mouse/consumer interface, and a vendor HID interface on usage page
// 0xFFFC. All configuration traffic goes over the vendor interface as
// TEA-encrypted 64-byte reports with report ID 0x55.
//
// Every message starts with a 4-byte header:
//
//     byte 0  message type (low 5 bits). Bit 7 is set on replies relayed from the mic.
//     byte 1  command group (low 4 bits for dongle/device messages)
//     byte 2  command
//     byte 3  operation: 0x01 = read, 0x00 / 0x02 / 0x04 = write,
//             bit 4 (0x10) = reply, bit 0 of a reply = success
//
// Notices (type 0x0B) use a different layout: byte 1 is the notice ID and the
// payload starts at byte 2. Firmware-upgrade messages (types 0x15, 0x1E, 0x1F)
// use byte 1 as the step and byte 2 onward as the payload.

public enum VibeUSB {
    public static let vendorID = 0xFFF1
    /// AU05 dongle. Confirmed on hardware.
    public static let productID = 0x00DD
    /// Vendor-defined usage page of the configuration interface.
    public static let usagePage = 0xFFFC
    public static let usage = 0x0001
    public static let reportID: UInt8 = 0x55
    public static let reportLength = 64

    /// Other VID/PID/usage-page triples that the vendor library treats as
    /// Ulanzi devices on the same protocol. Only 0xFFF1:0x00DD is confirmed to be
    /// the Vibe Key. The others are listed so that `--pid` can target them.
    public static let knownUlanziDevices: [(vid: Int, pid: Int, usagePage: Int)] = [
        (0xFFF1, 0x0082, 0xFFFC),
        (0xFFF1, 0x00DE, 0xFFFE),
        (0xFFF1, 0x00DD, 0xFFFC),
        (0xFFF1, 0x00D2, 0xFFFE),
    ]
}

/// Message type, byte 0 of every frame (low 5 bits).
public enum MessageType: UInt8, Sendable {
    /// Commands to and replies from the microphone, relayed by the dongle.
    case device = 0x01
    /// Commands to and replies from the dongle itself.
    case dongle = 0x06
    /// Unsolicited notifications (key presses, battery, link state).
    case notice = 0x0B
    case bleShortAudio = 0x0C
    case bleLongAudio = 0x0D
    case usbAudio = 0x0E
    case uploadImage = 0x15
    case dongleUpgrade = 0x1E
    case deviceUpgrade = 0x1F
}

/// Operation byte (byte 3) values.
public enum Operation {
    public static let read: UInt8 = 0x01
    public static let write0: UInt8 = 0x00
    public static let write2: UInt8 = 0x02
    public static let write4: UInt8 = 0x04
    public static let replyFlag: UInt8 = 0x10
    public static let successFlag: UInt8 = 0x01
}

/// Private key table used to validate the dongle's auth reply
/// (`private_key` in kwdm.dylib at vmaddr 0x2df5c). The dongle answers the
/// host's random code XOR one of these entries and reports the index it used.
public let authPrivateKeys: [UInt32] = [
    0x2014_1107, 0xC138_BF6D, 0xA8AB_23C7, 0x7316_5329,
    0x3062_9139, 0xD9F4_E04C, 0xEC8C_35BF, 0x6410_1856,
    0x4720_1988, 0x9821_1053, 0xF0D4_ECA9, 0x8299_1136,
    0x0915_3583, 0x1614_1925, 0xBF8A_7CED, 0x5455_7049,
]

/// The six inputs on the Vibe Key and their firmware button indices.
///
/// The indices come from `DeviceControlRegistry::registerVibeKey()` in the
/// Ulanzi Studio binary: descriptor field 0 is the index that the app passes to
/// `setDeviceButtonShortcutFunction2`.
public enum Control: Int, CaseIterable, Sendable, Codable {
    case talk = 0
    case confirm = 1
    case cancel = 2
    case knobPress = 3
    case knobRight = 4
    case knobLeft = 5

    public var name: String {
        switch self {
        case .talk: return "talk"
        case .confirm: return "confirm"
        case .cancel: return "cancel"
        case .knobPress: return "knob-press"
        case .knobRight: return "knob-right"
        case .knobLeft: return "knob-left"
        }
    }

    public init?(name: String) {
        let n = name.lowercased().replacingOccurrences(of: "_", with: "-")
        switch n {
        case "talk", "voice", "ptt", "0": self = .talk
        case "confirm", "enter", "ok", "1": self = .confirm
        case "cancel", "esc", "2": self = .cancel
        case "knob-press", "knob", "press", "3": self = .knobPress
        case "knob-right", "right", "cw", "4": self = .knobRight
        case "knob-left", "left", "ccw", "5": self = .knobLeft
        default: return nil
        }
    }

    /// Factory fixed-function code read back from a stock AU05 (firmware 4.4.0).
    public var factoryFixedFunction: UInt32 {
        switch self {
        case .talk: return 0x6F
        case .confirm: return 0x70
        case .cancel: return 0x71
        case .knobPress: return 0x6E
        case .knobRight: return 0x72
        case .knobLeft: return 0x73
        }
    }

    /// The Ulanzi Studio default binding for this control (AU05 default profile).
    public var defaultHotkey: String {
        switch self {
        case .talk: return "fn"
        case .confirm: return "return"
        case .cancel: return "escape"
        case .knobPress: return "backspace"
        case .knobRight: return "wheel-down"
        case .knobLeft: return "wheel-up"
        }
    }
}
