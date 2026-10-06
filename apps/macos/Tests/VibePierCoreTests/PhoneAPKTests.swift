import CryptoKit
import XCTest

@testable import VibePierCore

final class PhoneAPKTests: XCTestCase {
    /// File-channel boundary fixture: immutable raw bytes and device-bound tickets; no production trust/network.
    private final class BinaryFixture {
        struct Ticket {
            let device: String
            let transfer: String
            let file: URL
            let offset: Int
            let request: String
            let profile: [String: Any]
        }
        var available = true
        var tickets: [String: Ticket] = [:]
        var files: PhoneAPK.Files {
            .init(
                available: { self.available },
                offer: { device, transfer, file, size, offset, request in
                    guard self.available else { return nil }
                    if let old = self.tickets.values.first(where: {
                        $0.device == device && $0.transfer == transfer && $0.offset == offset && $0.request == request
                    }) {
                        return old.profile
                    }
                    self.cancel(device, transfer)
                    let id =
                        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                        + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                    let profile: [String: Any] = [
                        "version": 1, "encoding": "raw", "kind": "apk", "id": id, "size": size, "offset": offset,
                    ]
                    self.tickets[id] = Ticket(
                        device: device, transfer: transfer, file: file, offset: offset, request: request,
                        profile: profile)
                    return profile
                },
                owns: { device, transfer, id in
                    self.tickets[id]?.device == device && self.tickets[id]?.transfer == transfer
                }, cancel: { self.cancel($0, $1) })
        }
        func cancel(_ device: String, _ transfer: String) {
            tickets = tickets.filter { $0.value.device != device || $0.value.transfer != transfer }
        }
        func body(_ id: String, device: String) throws -> Data {
            guard let ticket = tickets[id] else { throw PhoneTestError.denied }
            guard ticket.device == device else { throw PhoneTestError.denied }
            return try Data(contentsOf: ticket.file).dropFirst(ticket.offset)
        }
    }
    private enum PhoneTestError: Error { case denied }
    private func fixture(_ test: (URL, PhoneAPK, BinaryFixture, Data) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("app.apk")
        let expected = Data((0..<290_000).map { UInt8($0 % 251) })
        try expected.write(to: source)
        let binary = BinaryFixture()
        let store = PhoneAPK(root: root.appendingPathComponent("snapshots"), files: binary.files)
        try store.stage(source, device: "phone")
        try test(root, store, binary, expected)
    }
    private func ticket(_ store: PhoneAPK, transfer: String, offset: Int, request: String = "request") throws -> String
    {
        let reply = try store.reply(
            ["op": "apkBinary", "transfer": transfer, "offset": offset, "id": request], device: "phone")
        let profile = try XCTUnwrap(reply["binary"] as? [String: Any])
        XCTAssertEqual(profile["encoding"] as? String, "raw")
        XCTAssertEqual(profile["offset"] as? Int, offset)
        return try XCTUnwrap(profile["id"] as? String)
    }
    func testBinarySnapshotResumeIsolationIntegrityAndTerminalCleanup() throws {
        try fixture { root, store, binary, expected in
            try Data([1]).write(to: root.appendingPathComponent("app.apk"))
            let offer = try store.reply(["op": "apkOffer"], device: "phone")
            let id = try XCTUnwrap(offer["transfer"] as? String)
            let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(offer["binaryVersion"] as? Int, 1)
            XCTAssertNil(offer["download"])
            XCTAssertEqual(offer["sha256"] as? String, digest)
            XCTAssertNil(try store.reply(["op": "apkOffer"], device: "other")["transfer"])
            let initial = try ticket(store, transfer: id, offset: 0)
            XCTAssertEqual(try ticket(store, transfer: id, offset: 0), initial)
            XCTAssertThrowsError(try binary.body(initial, device: "other"))
            let all = try binary.body(initial, device: "phone")
            XCTAssertEqual(all, expected)
            let durable = 128 * 1024
            _ = try store.reply(
                ["op": "apkProgress", "transfer": id, "binaryTicket": initial, "durableOffset": durable],
                device: "phone")
            let resumed = try ticket(store, transfer: id, offset: durable, request: "resume")
            XCTAssertNotEqual(initial, resumed)
            XCTAssertThrowsError(try binary.body(initial, device: "phone"))
            XCTAssertEqual(Data(all.prefix(durable)) + (try binary.body(resumed, device: "phone")), expected)
            XCTAssertEqual(store.matchingActive(digest, device: "phone")?.transfer, id)
            XCTAssertNil(store.matchingActive("wrong", device: "phone"))
            XCTAssertNil(store.matchingActive(digest, device: "other"))
            _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "received"], device: "phone")
            XCTAssertEqual(store.status("phone")?.received, expected.count)
            XCTAssertTrue(binary.tickets.isEmpty)
            _ = try ticket(store, transfer: id, offset: 0, request: "late")
            XCTAssertEqual(store.status("phone")?.phase, .received)
            XCTAssertTrue(store.status("phone")?.phase.canCancel == true)
            _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "installing"], device: "phone")
            XCTAssertFalse(store.status("phone")?.phase.canCancel == true)
            _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "success"], device: "phone")
            _ = try store.reply(["op": "apkStatus", "transfer": id, "state": "installing"], device: "phone")
            XCTAssertEqual(store.status("phone")?.phase, .success)
            XCTAssertFalse(store.status("phone")?.phase.canCancel == true)
            XCTAssertTrue(binary.tickets.isEmpty)
            XCTAssertNil(try store.reply(["op": "apkOffer"], device: "phone")["transfer"])
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("snapshots/\(id).apk").path))
        }
    }
    func testBinaryBoundsReplacementCancellationAndNoTextFallback() throws {
        try fixture { root, store, binary, expected in
            let id = try XCTUnwrap(store.status("phone")?.transfer)
            XCTAssertThrowsError(try store.stage(root, device: "phone"))
            for offset in [-1, expected.count, Int.max] {
                XCTAssertNil(
                    try store.reply(["op": "apkBinary", "transfer": id, "offset": offset], device: "phone")["binary"])
            }
            XCTAssertThrowsError(
                try store.reply(["op": "apkBinary", "transfer": "wrong", "offset": 0], device: "phone"))
            XCTAssertThrowsError(try store.stage(root.appendingPathComponent("app.apk"), device: "phone"))
            XCTAssertEqual(store.status("phone")?.transfer, id)
            XCTAssertThrowsError(try store.reply(["op": "apkChunk", "transfer": id, "offset": 0], device: "phone"))
            binary.available = false
            XCTAssertNil(try store.reply(["op": "apkOffer"], device: "phone")["binaryVersion"])
            let unavailable = try store.reply(["op": "apkBinary", "transfer": id, "offset": 0], device: "phone")
            XCTAssertEqual(unavailable["binaryUnavailable"] as? Bool, true)
            XCTAssertNil(unavailable["data"])
            store.cancel("phone")
            XCTAssertNil(store.status("phone"))
            XCTAssertTrue(binary.tickets.isEmpty)
            try store.stage(root.appendingPathComponent("app.apk"), device: "phone")
            XCTAssertThrowsError(try store.reply(["op": "apkBinary", "transfer": id, "offset": 0], device: "phone"))
            store.cancel("phone")
            XCTAssertThrowsError(try store.reply(["op": "apkChunk"], device: "phone"))
        }
    }
    func testBinaryProgressRequiresOwnedTicketAndNeverRollsBackDurableOffset() throws {
        try fixture { _, store, _, expected in
            let id = try XCTUnwrap(store.status("phone")?.transfer)
            let capability = try ticket(store, transfer: id, offset: 0)
            XCTAssertEqual(store.status("phone")?.received, 0)
            for value in [131072, 0, 65536] {
                _ = try store.reply(
                    ["op": "apkProgress", "transfer": id, "binaryTicket": capability, "durableOffset": value],
                    device: "phone")
                XCTAssertEqual(store.status("phone")?.received, 131072)
            }
            for offset in [-1, expected.count + 1] {
                XCTAssertThrowsError(
                    try store.reply(
                        ["op": "apkProgress", "transfer": id, "binaryTicket": capability, "durableOffset": offset],
                        device: "phone"))
            }
            XCTAssertThrowsError(
                try store.reply(
                    ["op": "apkProgress", "transfer": id, "binaryTicket": "wrong", "durableOffset": 0], device: "phone")
            )
        }
    }
    func testBinaryCapabilityMetadataRetainsAuthenticatedSessionEnvelope() throws {
        let device = UUID().uuidString
        let packet = UUID().uuidString
        let key = Data(repeating: 7, count: 32)
        let clear = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "ok": true,
            "binary": ["version": 1, "kind": "apk", "encoding": "raw", "id": String(repeating: "a", count: 64)],
        ])
        let cipher = try SessionEnvelope.seal(clear, key: key, device: device, packet: packet, direction: "mac")
        let frames = SessionEnvelope.frames(cipher, device: device, packet: packet, sender: device)
        XCTAssertFalse(frames.isEmpty)
        var encoded = ""
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.count, 4096)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            XCTAssertNil(object["request"])
            encoded += try XCTUnwrap(object["data"] as? String)
        }
        XCTAssertEqual(Data(base64Encoded: encoded), cipher)
        XCTAssertEqual(
            try SessionEnvelope.open(cipher, key: key, device: device, packet: packet, direction: "mac"), clear)
        XCTAssertThrowsError(
            try SessionEnvelope.open(cipher, key: key, device: "other", packet: packet, direction: "mac"))
    }
}
