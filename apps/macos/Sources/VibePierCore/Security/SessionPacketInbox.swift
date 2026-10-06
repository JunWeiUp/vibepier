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

    mutating func receive(_ data: Data, sender: String, key: Data) -> (
        clear: Data, request: [String: Any]
    )? {
        guard data.count <= 4096,
            UUID(uuidString: sender) != nil, key.count == 32,
            let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let expected: Set<String> = ["type", "sender", "device", "packet", "part", "parts", "data"]
        guard Set(frame.keys) == expected,
            frame["type"] as? String == "vibepier-session1",
            frame["sender"] as? String == sender, frame["device"] as? String == sender,
            let packet = frame["packet"] as? String, UUID(uuidString: packet) != nil,
            let index = Self.integer(frame["part"], range: 0...511),
            let count = Self.integer(
                frame["parts"], range: 1...512), index < count,
            let body = frame["data"] as? String, !body.isEmpty, body.utf8.count <= 900,
            index == count - 1 || body.utf8.count == 900,
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
        var assembly = partial[token] ?? Assembly(count: count, created: now)
        guard assembly.count == count else { return nil }
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
        seen[token] = now
        return (clear, request)
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
