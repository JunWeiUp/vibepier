import Foundation

/// Queue-confined assembly/replay state for already enrolled phones. Never performs desktop actions.
struct SessionPacketInbox {
    private struct Token: Hashable {
        let device: String
        let packet: String
    }
    private struct Assembly {
        let count: Int
        let created: Double
        let upload: String?
        let fragmentChars: Int
        var recoveryScheduled = false
        var recoveryAttempts = 0
        var chunks: [Int: String] = [:]
    }
    private var partial: [Token: Assembly] = [:]
    private var seen: [Token: Double] = [:]
    private let clock: () -> Double
    private let wallClock: () -> Double
    private let replayPerDevice: Int
    private let replayTotal: Int
    static let plaintextLimit = 300_000

    init(
        clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        wallClock: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
        replayPerDevice: Int = 2048, replayTotal: Int = 8192
    ) {
        self.clock = clock
        self.wallClock = wallClock
        self.replayPerDevice = max(1, replayPerDevice)
        self.replayTotal = max(1, replayTotal)
    }

    // A disconnect/stop must not forget authenticated packets whose timestamps are still valid.
    mutating func discardPartial() { partial.removeAll() }
    mutating func revoke(_ device: String) {
        partial = partial.filter { $0.key.device != device }
    }

    mutating func receive(_ data: Data, sender: String, key: Data, allowsUploads: Bool = false) -> (
        clear: Data, request: [String: Any]
    )? {
        guard data.count <= (allowsUploads ? SecureControlEnvelope.maximumPlaintext : 4096),
            UUID(uuidString: sender) != nil, key.count == 32,
            let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let upload = frame["upload"] as? String
        let fragmentChars: Int
        if upload == nil {
            fragmentChars = 900
        } else if frame["fragmentChars"] != nil {
            guard let span = Self.integer(frame["fragmentChars"], range: 512...7200), [512, 7200].contains(span) else {
                return nil
            }
            fragmentChars = span
        } else {
            fragmentChars = 7200
        }
        let expected: Set<String> = ["type", "sender", "device", "packet", "part", "parts", "data"]
        guard
            upload == nil
                ? Set(frame.keys) == expected
                : allowsUploads && UUID(uuidString: upload!) != nil
                    && (Set(frame.keys) == expected.union(["upload"])
                        || Set(frame.keys) == expected.union(["upload", "fragmentChars"])),
            frame["type"] as? String == "vibepier-session1",
            frame["sender"] as? String == sender, frame["device"] as? String == sender,
            let packet = frame["packet"] as? String, UUID(uuidString: packet) != nil,
            let index = Self.integer(frame["part"], range: 0...(upload == nil ? 511 : fragmentChars == 512 ? 255 : 55)),
            let count = Self.integer(
                frame["parts"], range: 1...(upload == nil ? 512 : fragmentChars == 512 ? 256 : 56)), index < count,
            let body = frame["data"] as? String, !body.isEmpty, body.utf8.count <= fragmentChars,
            index == count - 1 || body.utf8.count == fragmentChars,
            body.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [43, 47, 61].contains($0)
            })
        else { return nil }
        let now = clock()
        partial = partial.filter { now - $0.value.created < 30 }
        seen = seen.filter { now - $0.value < 300 }
        let token = Token(device: sender, packet: packet)
        // Never evict a live replay record to admit another packet. Its authenticated timestamp must expire first.
        guard seen[token] == nil, seen.count < replayTotal,
            seen.keys.filter({ $0.device == sender }).count < replayPerDevice
        else { return nil }
        if partial[token] == nil {
            guard partial.count < 8, partial.keys.filter({ $0.device == sender }).count < 4 else { return nil }
        }
        var assembly =
            partial[token] ?? Assembly(count: count, created: now, upload: upload, fragmentChars: fragmentChars)
        guard assembly.count == count, assembly.upload == upload, assembly.fragmentChars == fragmentChars else {
            return nil
        }
        if let previous = assembly.chunks[index] {
            // Retransmission cannot replace bytes or extend this packet's absolute lifetime.
            guard previous == body else { return nil }
        }
        assembly.chunks[index] = body
        partial[token] = assembly
        guard assembly.chunks.count == count else { return nil }
        partial.removeValue(forKey: token)
        guard let encrypted = Data(base64Encoded: (0..<count).compactMap { assembly.chunks[$0] }.joined()),
            (28...(Self.plaintextLimit + 28)).contains(encrypted.count),
            let clear = try? SessionEnvelope.open(
                encrypted, key: key, device: sender, packet: packet, direction: "phone"),
            clear.count <= Self.plaintextLimit,
            let request = try? JSONSerialization.jsonObject(with: clear) as? [String: Any],
            let id = request["id"] as? String, UUID(uuidString: id) != nil,
            let sentAt = request["sentAt"] as? NSNumber,
            CFGetTypeID(sentAt) != CFBooleanGetTypeID(), sentAt.doubleValue.isFinite,
            abs(wallClock() - sentAt.doubleValue) < 180_000
        else { return nil }
        if let upload {
            guard ["attachmentChunk", "newAttachmentChunk"].contains(request["op"] as? String ?? ""),
                request["attachmentId"] as? String == upload,
                Self.integer(request["uploadVersion"], range: 1...1) == 1
            else { return nil }
        }
        seen[token] = now
        return (clear, request)
    }

    mutating func recoveryPacket(_ data: Data, sender: String) -> String? {
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let packet = frame["packet"] as? String
        else { return nil }
        let token = Token(device: sender, packet: packet)
        guard var assembly = partial[token], assembly.upload != nil, !assembly.recoveryScheduled else { return nil }
        assembly.recoveryScheduled = true
        partial[token] = assembly
        return packet
    }
    mutating func missingUpload(sender: String, packet: String) -> [String: Any]? {
        let token = Token(device: sender, packet: packet)
        guard var assembly = partial[token], let upload = assembly.upload,
            clock() - assembly.created < 30, assembly.recoveryAttempts < 3
        else { return nil }
        assembly.recoveryAttempts += 1
        partial[token] = assembly
        return [
            "event": "uploadMissing", "packet": packet, "attachmentId": upload,
            "missing": (0..<assembly.count).filter { assembly.chunks[$0] == nil },
        ]
    }

    private static func integer(_ value: Any?, range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite,
            number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound),
            Double(number.intValue) == number.doubleValue
        else { return nil }
        return number.intValue
    }
}
