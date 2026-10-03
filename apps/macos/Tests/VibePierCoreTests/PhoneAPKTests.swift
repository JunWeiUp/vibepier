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
        _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "received"], device: "first")
        XCTAssertEqual(store.status("first")?.received, expected.count)
        _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "success"], device: "first")
        // Late retry cannot undo success.
        _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "installing"], device: "first")
        XCTAssertEqual(store.status("first")?.state, L10n.text("control.installation_succeeded"))
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
        try store.stage(source, device: "phone")
        XCTAssertThrowsError(try store.reply(["op": "apkChunk", "transfer": id, "offset": 0], device: "phone"))
        store.cancel("phone")
        XCTAssertNil(store.status("phone"))
        XCTAssertNil(try store.reply(["op": "apkOffer"], device: "phone")["transfer"])
    }
}
