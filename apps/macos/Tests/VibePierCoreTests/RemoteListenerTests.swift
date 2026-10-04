import VibeKit
import XCTest

@testable import VibePierCore

final class RemoteListenerTests: XCTestCase {
    func testRepeatedDeleteIsAtomicButOrdinaryPressStillHolds() throws {
        let step = try XCTUnwrap(RemoteEvent.parse("vibepier1 phone 1 knob-press step backspace"))
        XCTAssertTrue(step.isMomentary)
        XCTAssertFalse(try XCTUnwrap(RemoteEvent.parse("vibepier1 phone 2 confirm down return")).isMomentary)
        XCTAssertFalse(try XCTUnwrap(RemoteEvent.parse("vibepier1 phone 3 confirm up return")).isMomentary)
        var dedup = RemoteDeduplicator()
        XCTAssertTrue(dedup.isNew(step))
        XCTAssertFalse(dedup.isNew(step))
        XCTAssertTrue(dedup.isNew(try XCTUnwrap(RemoteEvent.parse("vibepier1 phone 4 knob-press step backspace"))))
    }
    func testApplicationSubscriptionRepliesWithoutTriggeringKeys() throws {
        let listener = RemoteListener(
            application: { FrontmostApplication(bundleID: "com.example.editor", name: "编辑器 Example") },
            leaseSeconds: 0.5, keyForDevice: SecureTestPhone.root, sessionRemote: { TestSessionRouter() },
            handler: { _ in XCTFail("subscription must not dispatch an action") })
        try listener.start(port: 47901)
        defer { listener.stop() }
        let phone = try SecureUDPTestPhone(port: 47901)
        let device = phone.phone.device
        phone.sendWire(Data("vibepier-watch1 \(device)".utf8))
        XCTAssertNil(phone.receiveWire(milliseconds: 100), "plaintext discovery must not disclose application state")
        try phone.connect()
        try phone.send("vibepier-watch1 \(device)")
        let reply = try phone.receive()
        XCTAssertEqual(reply["type"] as? String, "vibepier-app1")
        XCTAssertEqual(reply["sender"] as? String, device)
        XCTAssertEqual(reply["bundleID"] as? String, "com.example.editor")
        XCTAssertEqual(reply["name"] as? String, "编辑器 Example")
        XCTAssertEqual(reply["shortcutsCount"] as? Int, ApplicationShortcuts.shared.snapshot.entries.count)
        XCTAssertEqual(reply["shortcutsRevision"] as? String, ApplicationShortcuts.shared.snapshot.revision)
        XCTAssertEqual(reply["currentAppRevision"] as? String, CurrentApplicationShortcut.shared.snapshot.revision)
        XCTAssertGreaterThan(try XCTUnwrap(reply["stamp"] as? Int64), 0)
        XCTAssertEqual(listener.connectedAddresses, [], "a request alone does not confirm the return path")
        try phone.send("vibepier-current1 \(device)")
        let cached = CurrentApplicationShortcut.shared.snapshot
        for _ in CurrentApplicationShortcut.shared.frames(sender: device) {
            let frame = try phone.receive()
            XCTAssertEqual(frame["type"] as? String, "vibepier-current1")
            XCTAssertEqual(frame["sender"] as? String, device)
            XCTAssertEqual(frame["revision"] as? String, cached.revision)
            XCTAssertEqual(frame["slot"] as? Int, -1)
            XCTAssertEqual(frame["bundleID"] as? String, cached.entry.bundleID)
        }
        let connected = expectation(forNotification: DriverNotifications.statusChanged, object: listener)
        try phone.send("vibepier-ack1 \(device)")
        wait(for: [connected], timeout: 1)
        XCTAssertEqual(listener.connectedAddresses, ["127.0.0.1"])
        XCTAssertEqual(listener.connectedDeviceIDs, [device])
        let expired = expectation(forNotification: DriverNotifications.statusChanged, object: listener)
        wait(for: [expired], timeout: 1)
        XCTAssertTrue(listener.connectedAddresses.isEmpty)
        XCTAssertTrue(listener.connectedDeviceIDs.isEmpty)
        // Soft presence expiry must allow an authorized watch without waiting for crypto expiry.
        try phone.send("vibepier-watch1 \(device)")
        XCTAssertEqual(try phone.receive()["type"] as? String, "vibepier-app1")
    }

    func testParsesSTUNMappedAddress() throws {
        let transaction = [UInt8](repeating: 7, count: 12)
        XCTAssertEqual(Array(STUN.request(transaction: transaction).prefix(8)), [0, 1, 0, 0, 0x21, 0x12, 0xA4, 0x42])
        // XOR-MAPPED-ADDRESS 61.138.202.226:47800
        let port = UInt16(47800) ^ 0x2112
        let ip: [UInt8] = zip([61, 138, 202, 226] as [UInt8], [0x21, 0x12, 0xA4, 0x42] as [UInt8]).map { $0 ^ $1 }
        var response: [UInt8] = [0x01, 0x01, 0x00, 0x0C, 0x21, 0x12, 0xA4, 0x42] + transaction
        response += [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, UInt8(port >> 8), UInt8(port & 0xFF)] + ip
        XCTAssertTrue(STUN.isResponse(response))
        XCTAssertEqual(STUN.transaction(response), transaction)
        XCTAssertEqual(STUN.mappedAddress(response), "61.138.202.226:47800")
        XCTAssertFalse(STUN.isResponse(Array("vibepier-watch1 phone".utf8)))
    }

    func testClassifiesLocalSourcesAndParsesCandidates() throws {
        for host in ["192.168.0.2", "10.1.2.3", "172.20.0.1", "127.0.0.1", "fe80::1", "fd00::2"] {
            XCTAssertTrue(UDPEndpoint.isLocal(host), host)
        }
        for host in ["61.138.202.226", "100.64.0.1", "172.32.0.1", "2408:8000::1"] {
            XCTAssertFalse(UDPEndpoint.isLocal(host), host)
        }
        XCTAssertEqual(UDPEndpoint(candidate: "61.138.202.226:47800", fd4: 3, fd6: 4)?.id, "61.138.202.226:47800")
        XCTAssertEqual(UDPEndpoint(candidate: "[2408:8000::1]:5000", fd4: 3, fd6: 4)?.id, "[2408:8000::1]:5000")
        XCTAssertEqual(UDPEndpoint(candidate: "[2408:8000::1]:5000", fd4: 3, fd6: 4)?.fd, 4)
        XCTAssertNil(UDPEndpoint(candidate: "[fe80::1]:5000", fd4: 3, fd6: 4))
        XCTAssertNil(UDPEndpoint(candidate: "example.com:5000", fd4: 3, fd6: 4))
        XCTAssertNil(UDPEndpoint(candidate: "1.2.3.4:0", fd4: 3, fd6: 4))
        XCTAssertNil(UDPEndpoint(candidate: "127.0.0.1:5000", fd4: 3, fd6: 4))
    }

    func testDirectOfferAdmitsOnlyMatchingToken() throws {
        let listener = RemoteListener { _ in }
        try listener.start(port: 47902)
        defer { listener.stop() }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let token = String(repeating: "ab", count: 16)
        let answered = expectation(description: "answer")
        // Loopback candidates are never punched; the phone's own punch still gets through.
        listener.acceptDirect(
            sender: "phone", token: token, candidates: ["127.0.0.1:\(UInt16(bigEndian: local.sin_port))"]
        ) { mine in
            XCTAssertFalse(mine.contains { $0.hasPrefix("127.") })
            answered.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        var buffer = [UInt8](repeating: 0, count: 512)
        var count = 0
        var mac = sockaddr_in()
        mac.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        mac.sin_family = sa_family_t(AF_INET)
        mac.sin_port = UInt16(47902).bigEndian
        mac.sin_addr.s_addr = inet_addr("127.0.0.1")
        for line in ["vibepier-punch1 phone wrong", "vibepier-punch1 phone \(token)"] {
            let bytes = Array(line.utf8)
            _ = withUnsafePointer(to: &mac) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        count = recv(fd, &buffer, buffer.count, 0)
        XCTAssertEqual(
            String(decoding: buffer.prefix(max(0, count)), as: UTF8.self), "vibepier-punch-ok1 phone \(token)")
        wait(for: [answered], timeout: 3)
    }

    func testParsesRemoteDatagrams() {
        XCTAssertEqual(
            RemoteEvent.parse("vibepier1 a1b2 7 talk down\n"),
            RemoteEvent(sender: "a1b2", seq: 7, control: .talk, event: "down"))
        XCTAssertEqual(RemoteEvent.parse("vibepier1 x 1 knob-left step")?.control, .knobLeft)
        XCTAssertNil(RemoteEvent.parse("vibepier1 x 1 talk hold"))
        XCTAssertNil(RemoteEvent.parse("vibepier2 x 1 talk down"))
        XCTAssertNil(RemoteEvent.parse("vibepier1 x -1 talk down"))
        XCTAssertNil(RemoteEvent.parse("hello"))
        XCTAssertEqual(RemoteEvent.parse("vibepier1 x 2 confirm down cmd+return")?.keys, "cmd+return")
        XCTAssertNil(RemoteEvent.parse("vibepier1 x 2 confirm down")?.keys)
        XCTAssertNil(RemoteEvent.parse("vibepier1 x 2 confirm down cmd return"))
        XCTAssertEqual(
            RemoteEvent.parse("vibepier1 x 2 confirm down cmd+return app=com.example.Editor")?.applicationID,
            "com.example.Editor")
        XCTAssertNil(RemoteEvent.parse("vibepier1 x 2 confirm down cmd+return app="))
    }

    func testDropsRepeatsOfTheSameEvent() {
        var dedup = RemoteDeduplicator()
        let e = RemoteEvent(sender: "a", seq: 1, control: .talk, event: "down")
        XCTAssertTrue(dedup.isNew(e))
        XCTAssertFalse(dedup.isNew(e))
        XCTAssertTrue(dedup.isNew(RemoteEvent(sender: "b", seq: 1, control: .talk, event: "down")))
        for i in 2...70 { _ = dedup.isNew(RemoteEvent(sender: "a", seq: UInt64(i), control: .talk, event: "up")) }
        XCTAssertTrue(dedup.isNew(e), "old entries are forgotten")
    }

    func testReceivesOnlyAuthenticatedUDPDatagramsAndRejectsReplay() throws {
        let got = expectation(description: "one authenticated event")
        got.assertForOverFulfill = true
        let listener = RemoteListener(
            keyForDevice: SecureTestPhone.root, sessionRemote: { TestSessionRouter() },
            handler: { e in
                XCTAssertEqual(e.sender, SecureTestPhone.primary)
                XCTAssertEqual(e.control, .knobRight)
                got.fulfill()
            })
        try listener.start(port: 47899)
        defer { listener.stop() }
        let phone = try SecureUDPTestPhone(port: 47899)
        let device = phone.phone.device
        phone.sendWire(Data("vibepier1 \(device) 1 confirm down".utf8))
        try phone.connect()
        try phone.send("vibepier1 \(device) 2 confirm down")  // No watch yet.
        try phone.send("vibepier-watch1 \(device)")
        _ = try phone.receive()
        try phone.send("vibepier1 \(SecureTestPhone.secondary) 3 confirm down")  // Spoofed inner sender.
        let wire = try phone.phone.seal("vibepier1 \(device) 4 knob-right step")
        let foreignPeer = try SecureUDPTestPhone(port: 47899)
        foreignPeer.sendWire(wire)
        for _ in 0..<3 { phone.sendWire(wire) }
        wait(for: [got], timeout: 2)
        // Drain queued copies before teardown so an erroneous duplicate would fulfill again.
        try phone.send("vibepier-watch1 \(device)")
        _ = try phone.receive()
    }
}
