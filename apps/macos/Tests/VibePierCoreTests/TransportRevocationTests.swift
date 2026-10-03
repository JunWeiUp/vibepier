import Foundation
import XCTest

@testable import VibePierCore

final class TransportRevocationTests: XCTestCase {
    private final class Observed: @unchecked Sendable, SessionRemoteRouting {
        private let lock = NSLock()
        private var events: [RemoteEvent] = []
        private var disconnectedPeers: [String] = []
        private var releases = 0
        private var releaseCallback: (@Sendable () -> Void)?
        var onRelease: (@Sendable () -> Void)? {
            get { lock.withLock { releaseCallback } }
            set { lock.withLock { releaseCallback = newValue } }
        }
        func event(_ value: RemoteEvent) {
            lock.withLock { events.append(value) }
            if value.event == "up", value.sender == SecureTestPhone.primary { onRelease?() }
        }
        func releaseAudio() { lock.withLock { releases += 1 } }
        var audioReleases: Int { lock.withLock { releases } }
        var ups: [String] { lock.withLock { events.filter { $0.event == "up" }.map(\.sender) } }
        var all: [RemoteEvent] { lock.withLock { events } }
        var disconnectedCount: Int { lock.withLock { disconnectedPeers.count } }
        func disconnected(_ peer: String) { lock.withLock { disconnectedPeers.append(peer) } }
        func touch(_ peer: String) {}
        func receive(_ data: Data, peer: String, sender: String, send: @escaping @Sendable ([Data]) -> Void) {}
        func requestPair(_ data: Data, peer: String) {}
        func pairResult(_ peer: String) -> Data { Data() }
    }

    private func trust() throws -> DeviceTrustStore {
        let store = DeviceTrustStore(read: { nil }, write: { _ in })
        for device in [SecureTestPhone.primary, SecureTestPhone.secondary] {
            try store.authorize(id: device, name: "Fixture phone", key: XCTUnwrap(SecureTestPhone.root(for: device)))
        }
        return store
    }

    func testUDPRevocationReleasesOnlyThatPhonesKeysAudioAndRoutingBeforeLeaseExpiry() throws {
        let store = try trust()
        let observed = Observed()
        let mic = PhoneMicrophone(
            prepare: { _ in }, cleanup: {}, press: { _ in }, release: { _ in observed.releaseAudio() },
            foreground: { "fixture.editor" })
        let listener = RemoteListener(
            application: { FrontmostApplication(bundleID: "fixture.editor", name: "Fixture") }, leaseSeconds: 30,
            microphone: { mic }, keyForDevice: { store.key(for: $0) }, sessionRemote: { observed },
            handler: { observed.event($0) })
        try listener.start(port: 47910)
        defer {
            listener.stop()
            mic.stop()
        }
        let first = try SecureUDPTestPhone(port: 47910)
        let second = try SecureUDPTestPhone(port: 47910, device: SecureTestPhone.secondary)
        for phone in [first, second] {
            try phone.connect()
            try phone.send("vibepier-watch1 \(phone.phone.device)")
            _ = try phone.receive()
            try phone.send("vibepier-ack1 \(phone.phone.device)")
        }
        while first.receiveWire(milliseconds: 20) != nil {}
        try first.send("vibepier1 \(first.phone.device) 1 talk down rcmd")
        try second.send("vibepier1 \(second.phone.device) 1 confirm down return")
        let begin: [String: Any] = [
            "type": "vibepier-mic1", "sender": first.phone.device, "action": "begin",
            "session": String(repeating: "a", count: 32), "button": "talk", "app": "fixture.editor", "rate": 16000,
            "keys": "cmd+ctrl",
        ]
        try first.send(String(decoding: JSONSerialization.data(withJSONObject: begin), as: UTF8.self))
        XCTAssertEqual(try first.receive()["ready"] as? Bool, true)
        XCTAssertTrue(mic.active)
        let released = expectation(description: "revocation releases held key without waiting 30-second lease")
        observed.onRelease = { released.fulfill() }
        try store.revoke(first.phone.device)
        wait(for: [released], timeout: 1)
        _ = listener.connectedAddresses
        XCTAssertFalse(mic.active)
        XCTAssertEqual(observed.audioReleases, 1)
        XCTAssertEqual(observed.ups, [first.phone.device])
        XCTAssertEqual(observed.disconnectedCount, 1)
        try first.send("vibepier-watch1 \(first.phone.device)")
        XCTAssertNil(first.receiveWire(milliseconds: 100))
        first.sendWire(first.phone.hello())
        XCTAssertNil(first.receiveWire(milliseconds: 100))
        try second.send("vibepier-watch1 \(second.phone.device)")
        XCTAssertEqual(try second.receive()["sender"] as? String, second.phone.device)
        XCTAssertEqual(observed.ups, [first.phone.device], "The other phone's held key must remain owned")
        observed.onRelease = nil
    }

    func testRelayRevocationAndKeyRotationRetireOnlyAffectedPhone() throws {
        for rotate in [false, true] {
            let store = try trust()
            let observed = Observed()
            let settings = try XCTUnwrap(
                RelaySettings(url: "ws://127.0.0.1:1/", room: "fixture", secret: String(repeating: "c", count: 32)))
            let relay = AuthenticatedRelay(
                settings: settings, application: { FrontmostApplication(bundleID: "fixture.editor", name: "Fixture") },
                leaseSeconds: 30,
                keyForDevice: { store.key(for: $0) }, sessionRemote: { observed }, handler: { observed.event($0) })
            relay.start()
            defer { relay.stop() }
            for (device, peer) in [(SecureTestPhone.primary, "first"), (SecureTestPhone.secondary, "second")] {
                try relay.dispatch("vibepier-watch1 \(device)", peer: peer)
                try relay.dispatch("vibepier-ack1 \(device)", peer: peer)
            }
            try relay.dispatch("vibepier1 \(SecureTestPhone.primary) 1 talk down rcmd", peer: "first")
            try relay.dispatch("vibepier1 \(SecureTestPhone.secondary) 1 confirm down return", peer: "second")
            XCTAssertEqual(relay.status["connectedCount"] as? Int, 2)
            let released = expectation(description: "trust change releases first phone")
            observed.onRelease = { released.fulfill() }
            if rotate {
                try store.authorize(
                    id: SecureTestPhone.primary, name: "Re-enrolled", key: Data(repeating: 0x41, count: 32))
            } else {
                try store.revoke(SecureTestPhone.primary)
            }
            wait(for: [released], timeout: 1)
            XCTAssertEqual(relay.status["connectedCount"] as? Int, 1)
            XCTAssertEqual(observed.ups, [SecureTestPhone.primary])
            XCTAssertEqual(observed.disconnectedCount, 1)
            let before = observed.all.count
            try relay.dispatch("vibepier1 \(SecureTestPhone.primary) 2 confirm down", peer: "first")
            XCTAssertEqual(observed.all.count, before)
            try relay.dispatch("vibepier1 \(SecureTestPhone.secondary) 2 confirm up", peer: "second")
            XCTAssertEqual(observed.ups, [SecureTestPhone.primary, SecureTestPhone.secondary])
            observed.onRelease = nil
        }
    }
}
