import XCTest

@testable import VibePierCore

final class RelayClientTests: XCTestCase {
    private let secret = "0123456789abcdef0123456789abcdef"

    func testSettingsValidation() throws {
        let ok = try XCTUnwrap(RelaySettings(url: " wss://example.com/vibepier/relay ", room: "mac-1", secret: secret))
        XCTAssertEqual(ok.url.absoluteString, "wss://example.com/vibepier/relay")
        XCTAssertNil(RelaySettings(url: "https://example.com/vibepier/relay", room: "mac-1", secret: secret))
        XCTAssertNil(RelaySettings(url: "wss://example.com/r", room: "bad room", secret: secret))
        XCTAssertNil(RelaySettings(url: "wss://example.com/r", room: String(repeating: "a", count: 65), secret: secret))
        XCTAssertNil(RelaySettings(url: "wss://example.com/r", room: "mac", secret: "short"))
        XCTAssertNil(RelaySettings(url: "wss://example.com/r", room: "mac", secret: secret + " x"))
        XCTAssertNil(RelaySettings(url: "", room: "mac", secret: secret))
        var config = Config()
        config.relayURL = "ws://127.0.0.1:47801/"
        config.relayRoom = "r"
        config.relaySecret = secret
        XCTAssertEqual(RelaySettings(config)?.room, "r")
    }

    func testDNSRecoveryMustBeExplicitAndUsesEncryptedRelayURL() throws {
        let ordinary = try XCTUnwrap(RelaySettings(url: "wss://relay.example.test/r", room: "room", secret: secret))
        XCTAssertFalse(ordinary.dnsRecovery)
        XCTAssertFalse(ordinary.pairingCode.contains("dns="))
        let recovery = try XCTUnwrap(
            RelaySettings(url: "wss://relay.example.test/r", room: "room", secret: secret, dnsRecovery: true))
        XCTAssertTrue(recovery.pairingCode.hasSuffix(" dns=alidns"))
        XCTAssertNil(RelaySettings(url: "ws://relay.example.test/r", room: "room", secret: secret, dnsRecovery: true))
        XCTAssertNil(RelaySettings(url: "wss://user:password@relay.example.test/r", room: "room", secret: secret))
    }

    func testHelloMatchesServerVector() throws {
        try checkSharedHelloVectors(protocolName: "vibepier-relay1", count: 2)
        XCTAssertEqual(RelaySettings.randomHex(bytes: 16).count, 32)
    }

    func testRoutedHelloAuthenticatesProtocolVersion() throws {
        try checkSharedHelloVectors(protocolName: "vibepier-relay2", count: 1)
    }

    private func checkSharedHelloVectors(protocolName: String, count: Int) throws {
        struct Vector: Decodable {
            let `protocol`: String
            let role: String
            let room: String
            let secret: String
            let timestamp: Int64
            let nonce: String
            let hmac: String
        }
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let data = try Data(contentsOf: repository.appendingPathComponent("protocol/fixtures/relay-hello.json"))
        let vectors = try JSONDecoder().decode([Vector].self, from: data).filter { $0.protocol == protocolName }
        XCTAssertEqual(vectors.count, count)
        for vector in vectors {
            let actual = RelaySettings.hello(
                role: vector.role, room: vector.room, secret: vector.secret, timestamp: vector.timestamp,
                nonce: vector.nonce, version: protocolName == "vibepier-relay2" ? 2 : 1)
            XCTAssertEqual(
                actual,
                "\(vector.protocol) hello \(vector.role) \(vector.room) \(vector.timestamp) \(vector.nonce) \(vector.hmac)"
            )
        }
    }

    func testRoutedPayloadRequiresServerIDAndValidUTF8() {
        let peer = String(repeating: "a", count: 32)
        let line =
            "vibepier-relay2 from \(peer) \(Data("vibepier-watch1 00000000-0000-4000-8000-000000000001".utf8).base64EncodedString())"
        XCTAssertEqual(RelayClient.routedPayload(line)?.peer, peer)
        XCTAssertEqual(
            RelayClient.routedPayload(line)?.data, Data("vibepier-watch1 00000000-0000-4000-8000-000000000001".utf8))
        XCTAssertNil(
            RelayClient.routedPayload(line.replacingOccurrences(of: peer, with: "00000000-0000-4000-8000-000000000001"))
        )
        XCTAssertNil(RelayClient.routedPayload("vibepier-relay2 from \(peer) /w=="))
        XCTAssertNil(RelayClient.routedPayload("vibepier-relay2 from \(peer) invalid"))
    }

    func testTwoPhonesReceiveSeparateRepliesAndDisconnectIndependently() throws {
        let settings = try XCTUnwrap(RelaySettings(url: "ws://127.0.0.1:1/", room: "r", secret: secret))
        let events = Events()
        let frames = RelayFrames()
        let client = AuthenticatedRelay(
            settings: settings,
            application: { FrontmostApplication(bundleID: "a", name: "A") },
            transport: { frames.append($0, $1) }, handler: { events.append($0) }
        )
        let a = String(repeating: "a", count: 32)
        let b = String(repeating: "b", count: 32)
        try client.dispatch("vibepier-watch1 00000000-0000-4000-8000-000000000001", peer: a)
        try client.dispatch("vibepier-watch1 00000000-0000-4000-8000-000000000002", peer: b)
        try client.dispatch("vibepier-ack1 00000000-0000-4000-8000-000000000001", peer: a)
        try client.dispatch("vibepier-ack1 00000000-0000-4000-8000-000000000002", peer: b)
        XCTAssertEqual(client.status["connectedCount"] as? Int, 2)
        XCTAssertEqual(frames.all.map { $0.0 }, [a, b])
        for (peer, data) in frames.all {
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(
                json["sender"] as? String,
                peer == a ? "00000000-0000-4000-8000-000000000001" : "00000000-0000-4000-8000-000000000002")
            XCTAssertEqual(json["shortcutsCount"] as? Int, ApplicationShortcuts.shared.snapshot.entries.count)
            XCTAssertEqual(json["shortcutsRevision"] as? String, ApplicationShortcuts.shared.snapshot.revision)
            XCTAssertEqual(json["currentAppRevision"] as? String, CurrentApplicationShortcut.shared.snapshot.revision)
        }
        try client.dispatch("vibepier1 00000000-0000-4000-8000-000000000001 1 talk down rcmd", peer: a)
        try client.dispatch("vibepier1 00000000-0000-4000-8000-000000000002 1 talk down rcmd", peer: b)
        try client.dispatch("vibepier1 00000000-0000-4000-8000-000000000002 2 confirm down", peer: a)
        client.handle("vibepier-relay2 peer down \(b)", 0)
        XCTAssertEqual(client.status["connectedCount"] as? Int, 1)
        XCTAssertEqual(
            events.all.map { "\($0.sender) \($0.event)" },
            [
                "00000000-0000-4000-8000-000000000001 down", "00000000-0000-4000-8000-000000000002 down",
                "00000000-0000-4000-8000-000000000002 up",
            ])
        try client.dispatch("vibepier1 00000000-0000-4000-8000-000000000001 2 talk up rcmd", peer: a)
        XCTAssertEqual(events.all.last?.sender, "00000000-0000-4000-8000-000000000001")
        client.stop()
    }

    func testCurrentIconIsRequestedByWatchingSenderAndHideActionReachesHandler() throws {
        let settings = try XCTUnwrap(RelaySettings(url: "ws://127.0.0.1:1/", room: "r", secret: secret))
        let frames = RelayFrames()
        let events = Events()
        let client = AuthenticatedRelay(
            settings: settings, transport: { frames.append($0, $1) }, handler: { events.append($0) })
        let peer = String(repeating: "a", count: 32)
        try client.dispatch("vibepier-current1 00000000-0000-4000-8000-000000000001", peer: peer)
        XCTAssertTrue(frames.all.isEmpty)
        try client.dispatch("vibepier-watch1 00000000-0000-4000-8000-000000000001", peer: peer)
        XCTAssertEqual(frames.all.count, 1)
        try client.dispatch("vibepier-current1 00000000-0000-4000-8000-000000000003", peer: peer)
        XCTAssertEqual(frames.all.count, 1)
        let expected = CurrentApplicationShortcut.shared.frames(sender: "00000000-0000-4000-8000-000000000001")
        try client.dispatch("vibepier-current1 00000000-0000-4000-8000-000000000001", peer: peer)
        XCTAssertEqual(frames.all.count, expected.count + 1)
        for (route, data) in frames.all.dropFirst() {
            XCTAssertEqual(route, peer)
            let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(frame["type"] as? String, "vibepier-current1")
            XCTAssertEqual(frame["sender"] as? String, "00000000-0000-4000-8000-000000000001")
            XCTAssertEqual(frame["revision"] as? String, CurrentApplicationShortcut.shared.snapshot.revision)
        }
        try client.dispatch("vibepier-watch1 00000000-0000-4000-8000-000000000001", peer: peer)
        XCTAssertEqual(frames.all.count, expected.count + 2, "renewing state does not resend icon frames")
        try client.dispatch(
            "vibepier-launch1 00000000-0000-4000-8000-000000000001 2 -1 test.editor action=hide", peer: peer)
        try client.dispatch(
            "vibepier-launch1 00000000-0000-4000-8000-000000000001 2 -1 test.editor action=hide", peer: peer)
        XCTAssertEqual(events.all.count, 1)
        XCTAssertEqual(events.all.first?.applicationAction, .hide)
        XCTAssertEqual(events.all.first?.applicationSlot, -1)
        client.stop()
    }

    func testPendingReplyCannotReachReconnectedDevice() throws {
        let settings = try XCTUnwrap(RelaySettings(url: "ws://127.0.0.1:1/", room: "r", secret: secret))
        let frames = RelayFrames()
        let answers = PendingRelayAnswers()
        let client = AuthenticatedRelay(settings: settings, transport: { frames.append($0, $1) }, handler: { _ in })
        client.directOffer = { _, _, _, answer in answers.append(answer) }
        let a = String(repeating: "a", count: 32)
        let b = String(repeating: "b", count: 32)
        let offer =
            #"{"type":"vibepier-direct-offer1","sender":"00000000-0000-4000-8000-000000000001","token":"abcd","candidates":[]}"#
        try client.dispatch("vibepier-watch1 00000000-0000-4000-8000-000000000001", peer: a)
        try client.dispatch(offer, peer: a)
        try client.dispatch("vibepier-watch1 00000000-0000-4000-8000-000000000001", peer: b)
        try client.dispatch("vibepier-ack1 00000000-0000-4000-8000-000000000001", peer: b)
        answers.all[0](["1.2.3.4:5"])
        _ = client.status  // Drain the asynchronous response.
        XCTAssertEqual(frames.all.count, 2, "stale response is dropped, never rerouted to the new socket")
        try client.dispatch(offer, peer: b)
        answers.all[1](["2.3.4.5:6"])
        _ = client.status
        XCTAssertEqual(frames.all.count, 3)
        XCTAssertEqual(frames.all.last?.0, b)
        XCTAssertEqual(client.status["connectedCount"] as? Int, 1)
        client.stop()
    }

    func testLeaseExpiryReleasesOnlyExpiredPhone() throws {
        let settings = try XCTUnwrap(RelaySettings(url: "ws://127.0.0.1:1/", room: "r", secret: secret))
        let released = expectation(description: "first 00000000-0000-4000-8000-000000000001 lease expired")
        let client = AuthenticatedRelay(settings: settings, leaseSeconds: 0.4) {
            if $0.sender == "00000000-0000-4000-8000-000000000001", $0.event == "up" { released.fulfill() }
        }
        try client.dispatch("vibepier-watch1 00000000-0000-4000-8000-000000000001", peer: "a")
        try client.dispatch("vibepier-ack1 00000000-0000-4000-8000-000000000001", peer: "a")
        try client.dispatch("vibepier1 00000000-0000-4000-8000-000000000001 1 talk down", peer: "a")
        Thread.sleep(forTimeInterval: 0.25)
        try client.dispatch("vibepier-watch1 00000000-0000-4000-8000-000000000002", peer: "b")
        try client.dispatch("vibepier-ack1 00000000-0000-4000-8000-000000000002", peer: "b")
        wait(for: [released], timeout: 1)
        XCTAssertEqual(client.status["connectedCount"] as? Int, 1)
        client.stop()
    }

    func testPairingCode() throws {
        let settings = try XCTUnwrap(
            RelaySettings(url: "wss://example.com/vibepier/relay", room: "mac-1", secret: secret))
        XCTAssertEqual(settings.pairingCode, "vibepierrelay1 wss://example.com/vibepier/relay mac-1 \(secret)")
    }

    func testDispatchRequiresWatchAndReleasesHeldKeysWhenStopped() throws {
        let settings = try XCTUnwrap(RelaySettings(url: "ws://127.0.0.1:1/", room: "r", secret: secret))
        let events = Events()
        let client = AuthenticatedRelay(
            settings: settings, application: { FrontmostApplication(bundleID: "a", name: "A") },
            handler: {
                events.append($0)
            })
        try client.dispatch("vibepier1 00000000-0000-4000-8000-000000000001 1 confirm down")
        XCTAssertTrue(events.all.isEmpty, "events before vibepier-watch1 are ignored")

        try client.dispatch("vibepier-watch1 00000000-0000-4000-8000-000000000001")
        try client.dispatch("vibepier-ack1 00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(client.status["connectedCount"] as? Int, 1)
        try client.dispatch("vibepier1 00000000-0000-4000-8000-000000000001 2 talk down rcmd")
        try client.dispatch("vibepier1 00000000-0000-4000-8000-000000000001 2 talk down rcmd")
        try client.dispatch("vibepier1 00000000-0000-4000-8000-000000000003 3 confirm down")
        XCTAssertEqual(events.all.map(\.seq), [2])
        XCTAssertEqual(events.all.first?.sender, "00000000-0000-4000-8000-000000000001")

        client.stop()
        XCTAssertEqual(events.all.map(\.event), ["down", "up"], "stop releases the held talk key")
        XCTAssertEqual(client.status["connectedCount"] as? Int, 0)
    }

    func testDirectOfferReachesListenerOnlyFromWatchingPhone() throws {
        let settings = try XCTUnwrap(RelaySettings(url: "ws://127.0.0.1:1/", room: "r", secret: secret))
        let client = AuthenticatedRelay(settings: settings) { _ in }
        let offers = Offers()
        client.directOffer = { sender, token, candidates, _ in
            offers.append("\(sender) \(token) \(candidates.joined(separator: ","))")
        }
        let offer =
            #"{"type":"vibepier-direct-offer1","sender":"00000000-0000-4000-8000-000000000001","token":"abcd","candidates":["1.2.3.4:5"]}"#
        try client.dispatch(offer)
        XCTAssertTrue(offers.all.isEmpty, "no offer before vibepier-watch1")
        try client.dispatch("vibepier-watch1 00000000-0000-4000-8000-000000000001")
        try client.dispatch(offer)
        try client.dispatch(
            offer.replacingOccurrences(
                of: "\"00000000-0000-4000-8000-000000000001\"", with: "\"00000000-0000-4000-8000-000000000003\""))
        XCTAssertEqual(offers.all, ["00000000-0000-4000-8000-000000000001 abcd 1.2.3.4:5"])
        client.stop()
    }
}

private final class Offers: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ e: String) {
        lock.lock()
        items.append(e)
        lock.unlock()
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RemoteEvent] = []
    func append(_ e: RemoteEvent) {
        lock.lock()
        items.append(e)
        lock.unlock()
    }
    var all: [RemoteEvent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private final class RelayFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, Data)] = []
    func append(_ peer: String, _ data: Data) {
        lock.lock()
        items.append((peer, data))
        lock.unlock()
    }
    var all: [(String, Data)] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private final class PendingRelayAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [@Sendable ([String]) -> Void] = []
    func append(_ answer: @escaping @Sendable ([String]) -> Void) {
        lock.lock()
        items.append(answer)
        lock.unlock()
    }
    var all: [@Sendable ([String]) -> Void] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
