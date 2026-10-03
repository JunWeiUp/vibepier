// SPDX-License-Identifier: MIT

import Foundation

/// Encoding and decoding of the 64-byte vendor HID reports.
public enum FrameCodec {
    /// Builds the output report that carries `message`.
    ///
    /// The vendor library pads the message to 64 bytes, TEA-encrypts all eight
    /// blocks, and then copies only the first 63 encrypted bytes after the
    /// report ID. The firmware therefore never sees the last byte, and the last
    /// block cannot be decrypted. Every command fits in the first 56 bytes, so
    /// this quirk is harmless. It is reproduced here byte for byte.
    public static func outputReport(for message: [UInt8]) -> [UInt8] {
        var plain = Array(message.prefix(VibeUSB.reportLength))
        if plain.count < VibeUSB.reportLength {
            plain += [UInt8](repeating: 0, count: VibeUSB.reportLength - plain.count)
        }
        let cipher = TEA.encrypt(plain)
        return [VibeUSB.reportID] + cipher.prefix(VibeUSB.reportLength - 1)
    }

    /// Decodes an input report into the plaintext message.
    ///
    /// `report` is the buffer delivered by IOKit. If it starts with the report
    /// ID, the ID is stripped first. Only complete 8-byte blocks are decrypted
    /// (7 blocks for a 63-byte payload), which matches the vendor library. The
    /// trailing partial block cannot be decrypted, so it is dropped.
    public static func decodeInputReport(_ report: [UInt8]) -> [UInt8] {
        var payload = report
        if payload.first == VibeUSB.reportID {
            payload.removeFirst()
        }
        let decrypted = TEA.decrypt(payload)
        return Array(decrypted.prefix(decrypted.count / 8 * 8))
    }
}

/// A plaintext protocol message.
public struct Frame: Equatable, Sendable, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        if self.bytes.count < 8 {
            self.bytes += [UInt8](repeating: 0, count: 8 - self.bytes.count)
        }
    }

    public subscript(_ i: Int) -> UInt8 {
        i < bytes.count ? bytes[i] : 0
    }

    public var rawType: UInt8 { self[0] }
    public var type: MessageType? { MessageType(rawValue: self[0] & 0x1F) }
    /// Bit 7 of byte 0 is set on replies relayed from the microphone.
    public var fromMic: Bool { self[0] & 0x80 != 0 }
    public var group: UInt8 { self[1] & 0x0F }
    public var command: UInt8 { self[2] }
    public var operation: UInt8 { self[3] }
    public var isReply: Bool { operation & Operation.replyFlag != 0 }
    /// Bit 0 of a reply's operation byte. Read replies (0x11) have it set, and
    /// the vendor library passes it to its handlers to tell replies to a read
    /// from other traffic. Write replies echo the write operation (0x10, 0x12, 0x14).
    public var isReadReply: Bool { operation & Operation.successFlag != 0 }

    public func u16(_ i: Int) -> UInt16 {
        UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    public func u32(_ i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    public func slice(_ start: Int, _ length: Int) -> [UInt8] {
        guard start < bytes.count else { return [] }
        return Array(bytes[start..<min(bytes.count, start + length)])
    }

    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// The hex dump without trailing zero bytes.
    public var shortHex: String {
        var end = bytes.count
        while end > 4 && bytes[end - 1] == 0 { end -= 1 }
        return bytes[0..<end].map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    public var description: String { shortHex }
}
