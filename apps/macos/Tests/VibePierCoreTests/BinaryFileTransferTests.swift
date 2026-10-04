import CryptoKit
import Foundation
import Security
import XCTest

@testable import VibePierCore

/// Explicit, isolated helper interoperability: no provider, desktop, user trust store or installer.
final class BinaryFileTransferTests: XCTestCase {
    private final class PinnedSession: NSObject, URLSessionDelegate, @unchecked Sendable {
        let pin: String
        init(pin: String) { self.pin = pin }
        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let trust = challenge.protectionSpace.serverTrust,
                let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
                SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map({ String(format: "%02x", $0) }).joined()
                    == pin
            else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
    func testHelperAttachmentCommitAndCapabilityIsolation() async throws {
        guard let path = ProcessInfo.processInfo.environment["VIBEPIER_BINARY_HELPER_TEST_EXECUTABLE"] else {
            throw XCTSkip("Explicit isolated file helper opt-in required")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = BinaryFileTransfers(
            executable: URL(fileURLWithPath: path), stagingRoot: root.appendingPathComponent("staging"),
            authorized: { $0 == "phone-a" })
        helper.configure(nil)
        XCTAssertNil(helper.uploadOffer(device: "phone-b", scope: "scope", id: UUID().uuidString, size: 1))
        let store = try CodexAttachments(root: root.appendingPathComponent("attachments"), files: helper)
        let id = UUID().uuidString
        let data = Data((0..<(4 * 1024 * 1024)).map { UInt8($0 % 251) })
        let offer = try store.start(
            [
                "attachmentId": id, "size": data.count, "name": "synthetic.dat", "mime": "application/octet-stream",
                "uploadVersion": 1, "uploadFragmentChars": 512, "binaryVersion": 1,
            ], device: "phone-a", thread: "scope")
        let profile = try XCTUnwrap(offer["binary"] as? [String: Any])
        let ticket = try XCTUnwrap(profile["id"] as? String)
        let body = data
        let url = try XCTUnwrap(URL(string: "https://127.0.0.1:\(profile["port"]!)/files/\(ticket)"))
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(profile["writeToken"]!)", forHTTPHeaderField: "Authorization")
        let delegate = PinnedSession(pin: try XCTUnwrap(profile["pin"] as? String))
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.upload(for: request, from: body)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(
            try store.complete(
                ["attachmentId": id, "binaryTicket": ticket, "sha256": hash], device: "phone-b", thread: "scope"))
        XCTAssertThrowsError(
            try store.complete(
                ["attachmentId": id, "binaryTicket": ticket, "sha256": String(repeating: "0", count: 64)],
                device: "phone-a", thread: "scope"))
        let complete = try store.complete(
            ["attachmentId": id, "binaryTicket": ticket, "sha256": hash], device: "phone-a", thread: "scope")
        XCTAssertEqual(complete["complete"] as? Bool, true)
        let apkFile = root.appendingPathComponent("snapshot.apk")
        try data.write(to: apkFile)
        let first = try XCTUnwrap(
            helper.apkOffer(
                device: "phone-a", transfer: "transfer", file: apkFile, size: data.count, offset: 0,
                requestID: "request-a"))
        let repeated = try XCTUnwrap(
            helper.apkOffer(
                device: "phone-a", transfer: "transfer", file: apkFile, size: data.count, offset: 0,
                requestID: "request-a"))
        XCTAssertEqual(first["id"] as? String, repeated["id"] as? String)
        let next = try XCTUnwrap(
            helper.apkOffer(
                device: "phone-a", transfer: "transfer", file: apkFile, size: data.count, offset: 1024,
                requestID: "request-b"))
        XCTAssertNotEqual(first["id"] as? String, next["id"] as? String)
        helper.cancelTicket(device: "phone-b", ticket: next["id"] as! String)
        XCTAssertTrue(helper.ownsAPKTicket(device: "phone-a", transfer: "transfer", ticket: next["id"] as! String))
        helper.cancelTicket(device: "phone-a", ticket: next["id"] as! String)
        XCTAssertFalse(helper.ownsAPKTicket(device: "phone-a", transfer: "transfer", ticket: next["id"] as! String))
        XCTAssertThrowsError(
            try helper.claimUpload(device: "phone-a", scope: "scope", id: id, ticket: ticket, size: data.count))
    }
}
