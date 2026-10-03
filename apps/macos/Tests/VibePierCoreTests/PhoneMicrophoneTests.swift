import XCTest

@testable import VibePierCore

final class PhoneMicrophoneTests: XCTestCase {
    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var pressed = 0
        var released = 0
        func press() { lock.withLock { pressed += 1 } }
        func release() { lock.withLock { released += 1 } }
    }
    private func request(_ action: String, token: String = String(repeating: "a", count: 32)) throws -> String {
        let value: [String: Any] = [
            "type": "vibepier-mic1", "sender": "phone", "action": action,
            "session": token, "button": "talk", "app": "org.test", "rate": 16000, "keys": "cmd+ctrl",
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    func testDuplicateBeginAndLatePacketsCannotRestartRecording() throws {
        let counts = Counts()
        let mic = PhoneMicrophone(
            prepare: { _ in }, press: { _ in counts.press() }, release: { _ in counts.release() },
            foreground: { "org.test" })
        defer { mic.stop() }
        let begin = try request("begin")
        _ = mic.receive(begin, peer: "peer", sender: "phone")
        _ = mic.receive(begin, peer: "peer", sender: "phone")
        XCTAssertTrue(mic.active)
        XCTAssertEqual(counts.pressed, 1)
        _ = mic.receive(try request("end"), peer: "peer", sender: "phone")
        _ = mic.receive(begin, peer: "peer", sender: "phone")
        XCTAssertFalse(mic.active)
        XCTAssertEqual(counts.pressed, 1)
        XCTAssertEqual(counts.released, 1)
    }
    func testEarlyReleaseAndWrongPeerAreIsolated() throws {
        let mic = PhoneMicrophone(prepare: { _ in }, press: { _ in }, release: { _ in }, foreground: { "org.test" })
        defer { mic.stop() }
        _ = mic.receive(try request("end"), peer: "peer", sender: "phone")
        _ = mic.receive(try request("begin"), peer: "peer", sender: "phone")
        XCTAssertFalse(mic.active)
        _ = mic.receive(try request("begin", token: String(repeating: "b", count: 32)), peer: "peer", sender: "phone")
        XCTAssertTrue(mic.active)
        _ = mic.receive(try request("end", token: String(repeating: "b", count: 32)), peer: "stranger", sender: "phone")
        XCTAssertTrue(mic.active)
    }
    func testRequestsWithoutPhoneTalkButtonCannotSwitchInput() throws {
        let counts = Counts()
        let mic = PhoneMicrophone(
            prepare: { _ in counts.press() }, press: { _ in }, release: { _ in }, foreground: { "org.test" })
        var json = try JSONSerialization.jsonObject(with: Data(request("begin").utf8)) as! [String: Any]
        json.removeValue(forKey: "button")
        _ = mic.receive(
            String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self), peer: "peer",
            sender: "phone")
        json["button"] = "confirm"
        _ = mic.receive(
            String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self), peer: "peer",
            sender: "phone")
        XCTAssertFalse(mic.active)
        XCTAssertEqual(counts.pressed, 0)
    }
    func testBusyAndPreparationFailureNeverPressKeys() throws {
        let counts = Counts()
        let mic = PhoneMicrophone(
            prepare: { _ in throw CLIError("missing driver") }, press: { _ in counts.press() },
            release: { _ in counts.release() }, foreground: { "org.test" })
        let busy = try XCTUnwrap(mic.receive(try request("begin"), peer: "peer", sender: "phone", canBegin: false))
        let json = try JSONSerialization.jsonObject(with: busy) as! [String: Any]
        XCTAssertEqual(json["ready"] as? Bool, false)
        _ = mic.receive(try request("begin"), peer: "peer", sender: "phone")
        XCTAssertFalse(mic.active)
        XCTAssertEqual(counts.pressed, 0)
    }
    func testWatchdogReleasesWithoutPhoneEnd() throws {
        let counts = Counts()
        let mic = PhoneMicrophone(
            prepare: { _ in }, press: { _ in counts.press() }, release: { _ in counts.release() },
            foreground: { "org.test" })
        _ = mic.receive(try request("begin"), peer: "peer", sender: "phone")
        let expectation = expectation(description: "watchdog")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.2) {
            XCTAssertFalse(mic.active)
            XCTAssertEqual(counts.lock.withLock { counts.released }, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3)
    }
    func testDecoderBoundsAndIndependentFrames() throws {
        var zero = Data(repeating: 0, count: 84)
        XCTAssertEqual(PhoneAudioCodec.decode(zero, samples: 160), [Float](repeating: 0, count: 160))
        zero[2] = 89
        XCTAssertNil(PhoneAudioCodec.decode(zero, samples: 160))
        XCTAssertNil(PhoneAudioCodec.decode(Data(), samples: 320))
        XCTAssertNil(PhoneAudioCodec.decode(Data(repeating: 0, count: 84), samples: 320))
        let saturated = Data([255, 127, 88, 0] + [UInt8](repeating: 119, count: 80))
        XCTAssertTrue(PhoneAudioCodec.decode(saturated, samples: 160)!.allSatisfy { abs($0) <= 1 })
    }
    func testSixtyMillisecondPacketNegotiationAndLegacyFallback() throws {
        for duration in [20, 60, 40] {
            let mic = PhoneMicrophone(prepare: { _ in }, press: { _ in }, release: { _ in }, foreground: { "org.test" })
            defer { mic.stop() }
            var json = try JSONSerialization.jsonObject(with: Data(request("begin").utf8)) as! [String: Any]
            if duration != 20 { json["packetMs"] = duration }
            let reply = try XCTUnwrap(
                mic.receive(
                    String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self), peer: "peer",
                    sender: "phone"))
            let ack = try JSONSerialization.jsonObject(with: reply) as! [String: Any]
            XCTAssertEqual(ack["ready"] as? Bool, duration != 40)
            if duration != 40 { XCTAssertEqual(ack["packetMs"] as? Int, duration) }
        }
        for count in [480, 960] {
            let packet = Data([232, 3, 0, 0] + [UInt8](repeating: 0, count: count / 2))
            XCTAssertEqual(
                PhoneAudioCodec.decode(packet, samples: count), [Float](repeating: 1000 / 32768, count: count))
            XCTAssertNil(PhoneAudioCodec.decode(packet.dropLast(), samples: count))
        }
    }
}
