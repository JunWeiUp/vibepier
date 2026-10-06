import CryptoKit
import Foundation
import XCTest

@testable import VibePierCore

final class SecureControlChannelTests: XCTestCase {
    private let device = "00000000-0000-4000-8000-000000000001"
    private let root = Data(repeating: 0x31, count: 32)
    private let timestamp: Int64 = 1_700_000_000

    private func server(key: Data? = Data(repeating: 0x31, count: 32)) -> SecureControlServer {
        let id = device
        return SecureControlServer(keyForDevice: { $0 == id ? key : nil }, clock: { 1_700_000_000 })
    }

    private func hello(
        nonce: String = UUID().uuidString, time: Int64? = nil, key: Data? = nil, versions: String = "1",
        capabilities: String = "15"
    ) throws -> Data {
        let keys = try SecureControlEnvelope.Keys(root: key ?? root)
        let fields = [SecureControlEnvelope.hello, device, nonce, String(time ?? timestamp), versions, capabilities]
        return Data(
            (fields + [SecureControlEnvelope.signature(fields, key: keys.handshake)]).joined(separator: " ").utf8)
    }

    private func connect(_ server: SecureControlServer, hello: Data? = nil, peer: String = "udp:phone") throws -> String
    {
        guard case .handshake(let bytes) = server.receive(try hello ?? self.hello(), peer: peer) else {
            XCTFail("authorized hello should receive an authenticated challenge")
            throw SecureControlEnvelope.Failure.invalidFrame
        }
        let fields = String(decoding: bytes, as: UTF8.self).split(separator: " ").map(String.init)
        XCTAssertEqual(fields.count, 7)
        XCTAssertTrue(
            SecureControlEnvelope.verify(
                fields[6], fields: Array(fields.prefix(6)), key: try SecureControlEnvelope.Keys(root: root).handshake))
        return fields[3]
    }

    private func packet(_ session: String, sequence: Int64, text: String = "confirm") throws -> Data {
        try SecureControlEnvelope.seal(
            Data(text.utf8), device: device, session: session, sequence: sequence, direction: "phone",
            keys: SecureControlEnvelope.Keys(root: root))
    }

    private func rejected(_ value: SecureControlServer.Result, file: StaticString = #filePath, line: UInt = #line) {
        guard case .rejected = value else {
            XCTFail("expected rejection", file: file, line: line)
            return
        }
    }

    func testUnknownUnpairedAndPlaintextInputsHaveNoResponse() throws {
        rejected(server(key: nil).receive(try hello(), peer: "udp:phone"))
        let host = server()
        rejected(host.receive(Data("vibepier1 spoof 1 confirm down".utf8), peer: "udp:phone"))
        rejected(host.receive(try hello(key: Data(repeating: 0x32, count: 32)), peer: "udp:phone"))
        rejected(host.receive(try hello(time: timestamp - 121), peer: "udp:phone"))
        rejected(host.receive(try hello(time: timestamp + 121), peer: "udp:phone"))
        XCTAssertNil(host.seal(Data("private app name".utf8), peer: "udp:phone"))
    }

    func testReorderedPacketsAcceptedOnceAndWrongPeerRejected() throws {
        let host = server()
        let session = try connect(host)
        let second = try packet(session, sequence: 2)
        let first = try packet(session, sequence: 1)
        rejected(host.receive(second, peer: "udp:other"))
        for frame in [second, first] {
            guard case .message(let sender, let payload) = host.receive(frame, peer: "udp:phone") else {
                return XCTFail("valid packet rejected")
            }
            XCTAssertEqual(sender, device)
            XCTAssertEqual(String(decoding: payload, as: UTF8.self), "confirm")
            rejected(host.receive(frame, peer: "udp:phone"))
        }
    }

    func testTamperedLargeSequenceCannotAdvanceReplayWindow() throws {
        let host = server()
        let session = try connect(host)
        let valid = try packet(session, sequence: 1)
        let altered = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: " 1 ", with: " 9000 ")
        rejected(host.receive(Data(altered.utf8), peer: "udp:phone"))
        guard case .message = host.receive(valid, peer: "udp:phone") else {
            return XCTFail("tampering poisoned replay state")
        }
    }

    func testHandshakeRetryDoesNotResetReplayProtection() throws {
        let host = server()
        let request = try hello()
        let session = try connect(host, hello: request)
        let frame = try packet(session, sequence: 1)
        guard case .message = host.receive(frame, peer: "udp:phone") else { return XCTFail("valid frame rejected") }
        XCTAssertEqual(try connect(host, hello: request), session)
        rejected(host.receive(frame, peer: "udp:phone"))
        rejected(host.receive(request, peer: "udp:different"))
    }

    func testNewHostSessionInvalidatesRecordedCommandsAfterRestart() throws {
        let request = try hello()
        let first = server()
        let next = server()
        let old = try connect(first, hello: request)
        let frame = try packet(old, sequence: 1)
        let fresh = try connect(next, hello: request)
        XCTAssertNotEqual(old, fresh)
        rejected(next.receive(frame, peer: "udp:phone"))
        guard case .message = next.receive(try packet(fresh, sequence: 1), peer: "udp:phone") else {
            return XCTFail("new authenticated session rejected")
        }
    }

    func testDirectionsAndSessionMetadataAreAuthenticated() throws {
        let host = server()
        let session = try connect(host)
        let response = try XCTUnwrap(host.seal(Data("reply".utf8), peer: "udp:phone"))
        rejected(host.receive(response, peer: "udp:phone"))
        let fields = String(decoding: response, as: UTF8.self).split(separator: " ").map(String.init)
        XCTAssertEqual(
            try SecureControlEnvelope.open(fields, direction: "mac", keys: SecureControlEnvelope.Keys(root: root)),
            Data("reply".utf8))
        host.revoke(device)
        XCTAssertNil(host.seal(Data("private".utf8), peer: "udp:phone"))
        rejected(host.receive(try packet(session, sequence: 1), peer: "udp:phone"))
    }

    func testReplayWindowRemainsBoundedAndRejectsOldPackets() {
        var window = ControlReplayWindow()
        XCTAssertFalse(window.accept(0))
        XCTAssertTrue(window.accept(2048))
        XCTAssertFalse(window.accept(1024))
        XCTAssertTrue(window.accept(1025))
        XCTAssertFalse(window.accept(1025))
    }

    func testNegotiationSelectsOnlySupportedVersionAndCapabilitiesAndAuthenticatesThem() throws {
        let host = server()
        let offer = try hello(versions: "1,2", capabilities: "31")
        let tampered = String(decoding: offer, as: UTF8.self).replacingOccurrences(of: " 31 ", with: " 7 ")
        rejected(host.receive(Data(tampered.utf8), peer: "udp:phone"))
        guard case .handshake(let response) = host.receive(offer, peer: "udp:phone") else {
            return XCTFail("handshake")
        }
        let fields = String(decoding: response, as: UTF8.self).split(separator: " ").map(String.init)
        XCTAssertEqual(fields[0], SecureControlEnvelope.ready)
        XCTAssertEqual(fields[4], "1")
        XCTAssertEqual(fields[5], "15")
        XCTAssertTrue(
            SecureControlEnvelope.verify(
                fields[6], fields: Array(fields.prefix(6)), key: try SecureControlEnvelope.Keys(root: root).handshake))
        XCTAssertEqual(DirectAdmissions.sender(in: String(decoding: offer, as: UTF8.self)), device)
    }

    func testAuthenticatedIncompatibilityDoesNotCreateASessionAndBindsRetryToOriginalOffer() throws {
        for (versions, capabilities, reason) in [("2", "15", "version"), ("1", "1", "capabilities")] {
            let host = server()
            let nonce = UUID().uuidString
            let offer = try hello(nonce: nonce, versions: versions, capabilities: capabilities)
            guard case .handshake(let response) = host.receive(offer, peer: "udp:phone") else {
                return XCTFail("signed refusal")
            }
            let fields = String(decoding: response, as: UTF8.self).split(separator: " ").map(String.init)
            XCTAssertEqual(fields[0], SecureControlEnvelope.incompatible)
            XCTAssertEqual(fields[3], reason)
            XCTAssertTrue(
                SecureControlEnvelope.verify(
                    fields[6], fields: Array(fields.prefix(6)),
                    key: try SecureControlEnvelope.Keys(root: root).handshake))
            XCTAssertNil(host.device(for: "udp:phone"))
            XCTAssertNil(host.seal(Data("private".utf8), peer: "udp:phone"))
            guard case .handshake(let retry) = host.receive(offer, peer: "udp:phone") else {
                return XCTFail("same refusal")
            }
            XCTAssertEqual(retry, response)
            rejected(host.receive(try hello(nonce: nonce), peer: "udp:phone"))
            _ = try connect(host)
        }
    }

    func testLegacyAndMalformedNegotiationNeverDowngradeOrResetAnActiveSession() throws {
        let host = server()
        let current = try connect(host)
        let keys = try SecureControlEnvelope.Keys(root: root)
        let legacy = ["vibepier-secure-hello1", device, UUID().uuidString, String(timestamp)]
        rejected(
            host.receive(
                Data(
                    (legacy + [SecureControlEnvelope.signature(legacy, key: keys.handshake)]).joined(separator: " ")
                        .utf8), peer: "udp:phone"))
        for versions in ["", "01", "1,1", "2,1", "0", "256", "1,2,3,4,5,6,7,8,9"] {
            rejected(host.receive(try hello(versions: versions), peer: "udp:phone"))
        }
        for capabilities in ["", "015", "-1", "65536", "2147483648"] {
            rejected(host.receive(try hello(capabilities: capabilities), peer: "udp:phone"))
        }
        XCTAssertEqual(host.sessionIdentifier(for: "udp:phone"), current)
    }

    func testOptionalAudioCapabilityIsEnforcedWithoutMisclassifyingSessionContent() throws {
        let id = device
        let key = root
        let host = SecureControlServer(
            keyForDevice: { $0 == id ? key : nil }, clock: { 1_700_000_000 }, capabilities: ControlProtocol.required)
        let session = try connect(host)
        for text in ["vibepier-audio1 \(device) stream 1 packet", "{\"type\":\"vibepier-mic1\"}"] {
            rejected(host.receive(try packet(session, sequence: 9000, text: text), peer: "udp:phone"))
        }
        XCTAssertNil(host.seal(Data("{\"type\":\"vibepier-mic-state1\"}".utf8), peer: "udp:phone"))
        let text = "{\"type\":\"vibepier-session1\",\"text\":\"vibepier-mic1\"}"
        guard case .message = host.receive(try packet(session, sequence: 1, text: text), peer: "udp:phone") else {
            return XCTFail("Ordinary session content must not be treated as an audio control")
        }
    }

    func testOnePhoneCannotExhaustOtherPhonesHandshakeCapacity() throws {
        let primary = device
        let primaryKey = root
        let secondary = "00000000-0000-4000-8000-000000000004"
        let secondaryKey = Data(repeating: 0x32, count: 32)
        let host = SecureControlServer(
            keyForDevice: { $0 == primary ? primaryKey : $0 == secondary ? secondaryKey : nil },
            clock: { 1_700_000_000 })
        for index in 0..<4 { _ = try connect(host, peer: "peer-\(index)") }
        rejected(host.receive(try hello(), peer: "peer-4"))
        var latest = Data()
        for _ in 4..<64 {
            latest = try hello()
            _ = try connect(host, hello: latest, peer: "peer-0")
        }
        rejected(host.receive(try hello(), peer: "peer-0"))
        // A retry of the most recent offer still returns the existing challenge after the per-device quota fills.
        _ = try connect(host, hello: latest, peer: "peer-0")
        let fields = [SecureControlEnvelope.hello, secondary, UUID().uuidString, String(timestamp), "1", "15"]
        let other = Data(
            (fields + [
                SecureControlEnvelope.signature(
                    fields, key: try SecureControlEnvelope.Keys(root: secondaryKey).handshake)
            ]).joined(separator: " ").utf8)
        guard case .handshake = host.receive(other, peer: "other-phone") else {
            return XCTFail("Another authorized phone was crowded out")
        }
        XCTAssertEqual(host.device(for: "other-phone"), secondary)
    }

    func testRetiredBulkFrameIsRejectedWithoutAdvancingReplayWindow() throws {
        XCTAssertEqual(ControlProtocol.all, 15)
        let host = server()
        let session = try connect(host)
        let keys = try SecureControlEnvelope.Keys(root: root)
        let payload = try JSONSerialization.data(withJSONObject: [
            "type": "vibepier-session1", "sender": device, "device": device,
            "packet": UUID().uuidString, "part": 0, "parts": 1,
            "upload": UUID().uuidString, "data": "c2VhbGVk",
        ])
        // Even a correctly authenticated retired wrapper must not enter the current channel.
        let material = HMAC<SHA256>.authenticationCode(
            for: Data(["vibepier-bulk-key-v1", "phone", device, session].joined(separator: "|").utf8),
            using: keys.handshake)
        let fields = ["vibepier-bulk1", device, session, "9000", payload.base64EncodedString()]
        let tag = SecureControlEnvelope.signature(
            ["vibepier-bulk-frame-v1", "phone"] + fields, key: SymmetricKey(data: material))
        let retired = (fields + [tag]).joined(separator: " ")
        XCTAssertNil(DirectAdmissions.sender(in: retired))
        rejected(host.receive(Data(retired.utf8), peer: "udp:phone"))
        let text = #"{"type":"vibepier-session1","data":"synthetic"}"#
        let current = try packet(session, sequence: 1, text: text)
        guard case .message(_, let opened) = host.receive(current, peer: "udp:phone") else {
            return XCTFail("Retired frame must not poison ordinary encrypted RPC")
        }
        XCTAssertEqual(opened, Data(text.utf8))
        rejected(host.receive(current, peer: "udp:phone"))
    }

    func testRelaySelectsRequiredCapabilitiesOnly() throws {
        let id = device
        let key = root
        let host = SecureControlServer(
            keyForDevice: { $0 == id ? key : nil },
            clock: { 1_700_000_000 }, capabilities: ControlProtocol.required)
        guard case .handshake(let bytes) = host.receive(try hello(), peer: "relay:phone") else {
            return XCTFail("Current relay handshake failed")
        }
        let fields = String(decoding: bytes, as: UTF8.self).split(separator: " ").map(String.init)
        XCTAssertEqual(fields[5], "7")
        guard case .message = host.receive(try packet(fields[3], sequence: 1), peer: "relay:phone") else {
            return XCTFail("Current relay encrypted RPC failed")
        }
    }

    func testIndependentSharedCryptographyVectors() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let text = try String(
            contentsOf: repository.appendingPathComponent("protocol/fixtures/control-v1.properties"), encoding: .utf8)
        let fixture = Dictionary(
            uniqueKeysWithValues: text.split(separator: "\n").compactMap { line -> (String, String)? in
                guard !line.hasPrefix("#") else { return nil }
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            })
        let keys = try SecureControlEnvelope.Keys(root: root)
        for (purpose, key) in [("handshake", keys.handshake), ("phone", keys.phone), ("mac", keys.mac)] {
            let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
            XCTAssertEqual(hex, fixture[purpose + "KeyHex"])
        }
        for direction in ["phone", "mac"] {
            let frame = try XCTUnwrap(fixture[direction + "Frame"]).split(separator: " ").map(String.init)
            let opened = try SecureControlEnvelope.open(frame, direction: direction, keys: keys)
            XCTAssertEqual(String(decoding: opened, as: UTF8.self), fixture[direction + "Payload"])
        }
        let hello = try XCTUnwrap(fixture["hello"]).split(separator: " ").map(String.init)
        XCTAssertTrue(SecureControlEnvelope.verify(hello[6], fields: Array(hello.prefix(6)), key: keys.handshake))
        let ready = try XCTUnwrap(fixture["ready"]).split(separator: " ").map(String.init)
        XCTAssertTrue(SecureControlEnvelope.verify(ready[6], fields: Array(ready.prefix(6)), key: keys.handshake))
    }
}
