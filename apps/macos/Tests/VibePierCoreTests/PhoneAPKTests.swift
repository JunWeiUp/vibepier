import CryptoKit
import XCTest

@testable import VibePierCore

final class PhoneAPKTests: XCTestCase {
    func testSnapshotResumeIsolationIntegrityAndTerminalCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("app.apk")
        let expected = Data((0..<290_000).map { UInt8($0 % 251) })
        try expected.write(to: source)
        let store = PhoneAPK(root: root.appendingPathComponent("snapshots"))
        try store.stage(source, device: "first")
        try Data([1]).write(to: source)  // Changes after staging never alter the published snapshot.
        let offer = try store.reply(["op": "apkOffer"], device: "first")
        let id = try XCTUnwrap(offer["transfer"] as? String)
        XCTAssertEqual(
            offer["sha256"] as? String, SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
        XCTAssertNil(try store.reply(["op": "apkOffer"], device: "other")["transfer"])
        var received = Data()
        while received.count < expected.count {
            let request: [String: Any] = [
                "op": "apkChunk", "transfer": id, "offset": received.count, "limit": 128 * 1024,
            ]
            let chunk = try store.reply(request, device: "first")
            XCTAssertEqual(try store.reply(request, device: "first")["data"] as? String, chunk["data"] as? String)
            XCTAssertLessThan(try JSONSerialization.data(withJSONObject: chunk).count, 300_000)
            received.append(try XCTUnwrap(Data(base64Encoded: chunk["data"] as? String ?? "")))
        }
        XCTAssertEqual(received, expected)
        let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(store.matchingActive(digest, device: "first")?.transfer, id)
        XCTAssertNil(store.matchingActive("different", device: "first"))
        XCTAssertNil(store.matchingActive(digest, device: "other"))
        _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "received"], device: "first")
        XCTAssertEqual(store.status("first")?.received, expected.count)
        XCTAssertEqual(store.status("first")?.phase, .received)
        XCTAssertTrue(store.status("first")?.phase.canCancel == true)
        _ = try store.reply(["op": "apkChunk", "transfer": id, "offset": 0], device: "first")
        // A late download retry cannot regress installation UI.
        XCTAssertEqual(store.status("first")?.phase, .received)
        _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "installing"], device: "first")
        XCTAssertFalse(store.status("first")?.phase.canCancel == true)
        _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "success"], device: "first")
        // Late retry cannot undo success.
        _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "installing"], device: "first")
        XCTAssertEqual(store.status("first")?.state, L10n.text("control.installation_succeeded"))
        XCTAssertEqual(store.status("first")?.phase, .success)
        XCTAssertFalse(store.status("first")?.phase.canCancel == true)
        XCTAssertNil(try store.reply(["op": "apkOffer"], device: "first")["transfer"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("snapshots/\(id).apk").path))
    }
    func testBoundsReplacementAndCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("app.apk")
        try Data([1, 2, 3]).write(to: source)
        let store = PhoneAPK(root: root.appendingPathComponent("snapshots"))
        XCTAssertThrowsError(try store.stage(root, device: "phone"))
        try store.stage(source, device: "phone")
        let id = try XCTUnwrap(store.status("phone")?.transfer)
        for offset in [-1, 3, Int.max] {
            XCTAssertThrowsError(
                try store.reply(["op": "apkChunk", "transfer": id, "offset": offset], device: "phone"))
        }
        XCTAssertThrowsError(try store.reply(["op": "apkChunk", "transfer": "wrong", "offset": 0], device: "phone"))
        XCTAssertThrowsError(try store.stage(source, device: "phone"))
        XCTAssertEqual(store.status("phone")?.transfer, id)  // Active tasks are never silently replaced.
        store.cancel("phone")
        try store.stage(source, device: "phone")
        XCTAssertThrowsError(try store.reply(["op": "apkChunk", "transfer": id, "offset": 0], device: "phone"))
        store.cancel("phone")
        XCTAssertNil(store.status("phone"))
        XCTAssertNil(try store.reply(["op": "apkOffer"], device: "phone")["transfer"])
    }
    func testNegotiatedRelayWindowUsesDurableAcknowledgmentsAndBindsPeer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.apk")
        try Data(repeating: 42, count: 600_000).write(to: source)
        let store = PhoneAPK(root: root.appendingPathComponent("snapshots"))
        try store.stage(source, device: "phone")
        let token = UUID().uuidString
        let offerRequest: [String: Any] = ["op": "apkOffer", "id": token, "downloadVersion": 1]
        for peer in ["ble:fixture", "udp:fixture"] {
            XCTAssertNil(try store.reply(offerRequest, device: "phone", peer: peer)["download"])
        }
        let offer = try store.reply(offerRequest, device: "phone", peer: "relay:first")
        let profile = try XCTUnwrap(offer["download"] as? [String: Any])
        XCTAssertEqual(profile["token"] as? String, token)
        XCTAssertEqual(profile["fragmentChars"] as? Int, 7200)
        var request: [String: Any] = [
            "op": "apkChunk", "transfer": offer["transfer"]!, "offset": 393216,
            "limit": 131072, "downloadToken": token, "durableOffset": 0,
        ]
        _ = try store.reply(request, device: "phone", peer: "relay:first")
        XCTAssertEqual(store.status("phone")?.received, 0)
        request["durableOffset"] = 131072
        _ = try store.reply(request, device: "phone", peer: "relay:first")
        XCTAssertEqual(store.status("phone")?.received, 131072)
        request["durableOffset"] = 0
        _ = try store.reply(request, device: "phone", peer: "relay:first")
        XCTAssertEqual(store.status("phone")?.received, 131072)  // Late request cannot roll progress back.
        XCTAssertThrowsError(try store.reply(request, device: "phone", peer: "relay:replacement"))
        request.removeValue(forKey: "durableOffset")
        XCTAssertThrowsError(try store.reply(request, device: "phone", peer: "relay:first"))
        request["durableOffset"] = 600001
        XCTAssertThrowsError(try store.reply(request, device: "phone", peer: "relay:first"))
        // A new legacy offer explicitly ends fast negotiation, including on transport switch.
        XCTAssertNil(try store.reply(["op": "apkOffer"], device: "phone", peer: "ble:fixture")["download"])
        XCTAssertFalse(store.fastDownload(request, device: "phone", peer: "relay:first"))
        request.removeValue(forKey: "downloadToken")
        _ = try store.reply(request, device: "phone", peer: "ble:fixture")
    }

    func testFastFramesFitBothEncryptionBudgetsAndPreserveCiphertext() throws {
        let device = UUID().uuidString
        let packet = UUID().uuidString
        let request = UUID().uuidString
        let key = Data(repeating: 7, count: 32)
        let clear = try JSONSerialization.data(
            withJSONObject: [
                "id": request, "ok": true,
                "data": Data(repeating: 255, count: 131072).base64EncodedString(),
            ], options: [.withoutEscapingSlashes])
        let cipher = try SessionEnvelope.seal(clear, key: key, device: device, packet: packet, direction: "mac")
        let legacy = SessionEnvelope.frames(cipher, device: device, packet: packet, sender: device)
        let fast = SessionEnvelope.frames(
            cipher, device: device, packet: packet, sender: device, fragmentChars: 7200, requestID: request)
        XCTAssertEqual(legacy.count, 260)
        XCTAssertEqual(fast.count, 33)
        let keys = try SecureControlEnvelope.Keys(root: key)
        var base64 = ""
        for (index, frame) in fast.enumerated() {
            XCTAssertLessThanOrEqual(frame.count, 8192)
            let wrapped = try SecureControlEnvelope.seal(
                frame, device: device, session: UUID().uuidString, sequence: Int64(index + 1), direction: "mac",
                keys: keys)
            XCTAssertLessThanOrEqual(wrapped.count, 16384)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            XCTAssertEqual(object["request"] as? String, request)
            base64 += try XCTUnwrap(object["data"] as? String)
        }
        XCTAssertEqual(Data(base64Encoded: base64), cipher)
        XCTAssertEqual(
            try SessionEnvelope.open(cipher, key: key, device: device, packet: packet, direction: "mac"), clear)
        XCTAssertTrue(
            SessionEnvelope.frames(cipher, device: device, packet: packet, sender: device, fragmentChars: 7200).isEmpty)
    }

}
