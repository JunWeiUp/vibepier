import Foundation
import XCTest

@testable import VibePierCore

final class SessionPacketInboxTests: XCTestCase {
    private let first = "00000000-0000-4000-8000-000000000001"
    private let second = "00000000-0000-4000-8000-000000000002"
    private let key = Data(repeating: 0x31, count: 32)
    private let wall = 1_700_000_000_000.0
    private func frames(
        device: String? = nil, text: String = "fixture", sentAt: Any? = nil, direction: String = "phone",
        packet: String = UUID().uuidString
    ) throws -> [Data] {
        let device = device ?? first
        let clear = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "op": "fixture", "text": text, "sentAt": sentAt ?? wall,
        ])
        let sealed = try SessionEnvelope.seal(clear, key: key, device: device, packet: packet, direction: direction)
        return SessionEnvelope.frames(sealed, device: device, packet: packet, sender: device)
    }
    private func change(_ data: Data, _ key: String, _ value: Any) throws -> Data {
        var frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        frame[key] = value
        return try JSONSerialization.data(withJSONObject: frame)
    }
    private func inbox(perDevice: Int = 2048, total: Int = 8192) -> SessionPacketInbox {
        let wall = wall
        return SessionPacketInbox(clock: { 0 }, wallClock: { wall }, replayPerDevice: perDevice, replayTotal: total)
    }

    func testEncryptedOutOfOrderAndIdenticalDuplicateThenReplay() throws {
        var inbox = inbox()
        let text = String(repeating: "完整消息 C++\n", count: 400)
        let parts = try frames(text: text)
        for part in parts.dropFirst().reversed() {
            XCTAssertNil(inbox.receive(part, sender: first, key: key))
            XCTAssertNil(inbox.receive(part, sender: first, key: key))
        }
        XCTAssertEqual(inbox.receive(parts[0], sender: first, key: key)?.request["text"] as? String, text)
        for part in parts { XCTAssertNil(inbox.receive(part, sender: first, key: key)) }
    }

    func testConflictingDuplicateCannotOverwriteAuthenticChunk() throws {
        var inbox = inbox()
        let parts = try frames(text: String(repeating: "x", count: 800))
        XCTAssertEqual(parts.count, 2)
        XCTAssertNil(inbox.receive(parts[0], sender: first, key: key))
        let conflict = try change(parts[0], "data", String(repeating: "A", count: 900))
        XCTAssertNil(inbox.receive(conflict, sender: first, key: key))
        XCTAssertNotNil(inbox.receive(parts[1], sender: first, key: key))
    }

    func testDuplicateDoesNotExtendAbsoluteAssemblyLifetime() throws {
        var clock = 0.0
        let wall = wall
        var inbox = SessionPacketInbox(clock: { clock }, wallClock: { wall })
        let parts = try frames(text: String(repeating: "x", count: 800))
        XCTAssertEqual(parts.count, 2)
        XCTAssertNil(inbox.receive(parts[0], sender: first, key: key))
        clock = 29
        XCTAssertNil(inbox.receive(parts[0], sender: first, key: key))
        clock = 31
        XCTAssertNil(inbox.receive(parts[1], sender: first, key: key))
        // A fresh whole retransmission may still complete; no original partial bytes survived expiry.
        XCTAssertNotNil(inbox.receive(parts[0], sender: first, key: key))
    }

    func testOnePhoneCannotConsumeOtherPhonesAssemblySlots() throws {
        var inbox = inbox()
        var pending: [[Data]] = []
        for _ in 0..<5 {
            let parts = try frames(text: String(repeating: "x", count: 800))
            pending.append(parts)
            XCTAssertNil(inbox.receive(parts[0], sender: first, key: key))
        }
        XCTAssertNil(inbox.receive(pending[4][1], sender: first, key: key))
        XCTAssertNotNil(inbox.receive(try frames(device: second)[0], sender: second, key: key))
        XCTAssertNotNil(inbox.receive(pending[0][1], sender: first, key: key))
    }

    func testGlobalAssemblyCapacityRecoversAfterOnePacketCompletes() throws {
        var inbox = inbox()
        var firstPacket: [Data] = []
        for device in [first, second] {
            for i in 0..<4 {
                let parts = try frames(device: device, text: String(repeating: "x", count: 800))
                if device == first && i == 0 { firstPacket = parts }
                XCTAssertNil(inbox.receive(parts[0], sender: device, key: key))
            }
        }
        let third = "00000000-0000-4000-8000-000000000003"
        let blocked = try frames(device: third)[0]
        XCTAssertNil(inbox.receive(blocked, sender: third, key: key))
        XCTAssertNotNil(inbox.receive(firstPacket[1], sender: first, key: key))
        XCTAssertNotNil(inbox.receive(blocked, sender: third, key: key))
    }

    func testReplayCapacityRejectsNewPacketsWithoutForgettingPriorPackets() throws {
        var clock = 0.0
        let wall = wall
        var inbox = SessionPacketInbox(clock: { clock }, wallClock: { wall }, replayPerDevice: 2, replayTotal: 3)
        let original = try frames()[0]
        XCTAssertNotNil(inbox.receive(original, sender: first, key: key))
        XCTAssertNotNil(inbox.receive(try frames()[0], sender: first, key: key))
        XCTAssertNil(inbox.receive(try frames()[0], sender: first, key: key))
        XCTAssertNil(inbox.receive(original, sender: first, key: key))
        XCTAssertNotNil(inbox.receive(try frames(device: second)[0], sender: second, key: key))
        XCTAssertNil(inbox.receive(try frames(device: second)[0], sender: second, key: key))
        clock = 301
        XCTAssertNotNil(inbox.receive(try frames()[0], sender: first, key: key))
    }

    func testStrictFrameTypesAndScopeFailBeforeConsumingCapacity() throws {
        var inbox = inbox(perDevice: 1, total: 1)
        let valid = try frames()[0]
        for (field, value) in [
            ("part", true), ("part", 0.5), ("part", -1), ("parts", false), ("parts", 513),
            ("packet", "invalid"), ("device", second), ("sender", second), ("extra", "unknown"),
            ("data", " "), ("data", ""), ("data", String(repeating: "A", count: 901)),
        ] as [(String, Any)] {
            XCTAssertNil(inbox.receive(try change(valid, field, value), sender: first, key: key), field)
        }
        XCTAssertNil(inbox.receive(Data(repeating: 120, count: 4097), sender: first, key: key))
        XCTAssertNil(inbox.receive(valid, sender: second, key: key))
        XCTAssertNil(inbox.receive(valid, sender: first, key: Data(repeating: 0x32, count: 32)))
        XCTAssertNotNil(inbox.receive(valid, sender: first, key: key))
    }

    func testAuthenticatedRequestStillRequiresTimestampDirectionAndPlaintextBound() throws {
        var inbox = inbox(perDevice: 1, total: 1)
        for sentAt in [true, "1700000000000", wall - 180_001, wall + 180_001] as [Any] {
            for part in try frames(sentAt: sentAt) { XCTAssertNil(inbox.receive(part, sender: first, key: key)) }
        }
        for part in try frames(direction: "mac") { XCTAssertNil(inbox.receive(part, sender: first, key: key)) }
        for part in try frames(text: String(repeating: "x", count: SessionPacketInbox.plaintextLimit)) {
            XCTAssertNil(inbox.receive(part, sender: first, key: key))
        }
        XCTAssertNotNil(inbox.receive(try frames()[0], sender: first, key: key))
    }

    func testRevocationClearsOnlyTargetAssemblyAndRetainsReplayState() throws {
        var inbox = inbox(perDevice: 1, total: 2)
        let firstParts = try frames(text: String(repeating: "x", count: 800))
        let secondParts = try frames(device: second, text: String(repeating: "x", count: 800))
        XCTAssertNil(inbox.receive(firstParts[0], sender: first, key: key))
        XCTAssertNil(inbox.receive(secondParts[0], sender: second, key: key))
        inbox.revoke(first)
        XCTAssertNil(inbox.receive(firstParts[1], sender: first, key: key))
        XCTAssertNotNil(inbox.receive(secondParts[1], sender: second, key: key))
        let firstComplete = try frames()[0]
        XCTAssertNotNil(inbox.receive(firstComplete, sender: first, key: key))
        inbox.revoke(first)
        XCTAssertNil(inbox.receive(firstComplete, sender: first, key: key))
        XCTAssertNil(inbox.receive(try frames(device: second)[0], sender: second, key: key))
        inbox.discardPartial()
        XCTAssertNil(inbox.receive(secondParts[1], sender: second, key: key))
    }
}
