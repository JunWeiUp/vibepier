import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import VibePierCore

final class BinaryMediaFilesTests: XCTestCase {
    func testSnapshotsArePrivateExactBytesWithFullDigest() throws {
        let bytes = Data((0..<2_000_000).map { UInt8($0 % 251) })
        let source = try BinaryMediaFiles.snapshot(bytes)
        defer { source.discard() }
        let fd = Darwin.open(source.file.path, O_RDONLY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        let copy = try BinaryMediaFiles.snapshot(fd: fd, size: bytes.count)
        defer { copy.discard() }
        XCTAssertEqual(try Data(contentsOf: copy.file), bytes)
        XCTAssertEqual(copy.digest, source.digest)
        let attributes = try FileManager.default.attributesOfItem(atPath: copy.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try BinaryMediaFiles.snapshot(fd: fd, size: bytes.count + 1))
    }

    func testHelperMediaOfferContainsNoImageBodyAndCancellationRemovesSnapshot() throws {
        guard let executable = ProcessInfo.processInfo.environment["VIBEPIER_BINARY_HELPER_TEST_EXECUTABLE"] else {
            throw XCTSkip("Explicit isolated file helper opt-in required")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = BinaryFileTransfers(
            executable: URL(fileURLWithPath: executable), stagingRoot: root,
            authorized: { $0 == "synthetic-phone" })
        files.configure(nil)
        let snapshot = try BinaryMediaFiles.snapshot(Data(repeating: 7, count: 128_000))
        let profile = try BinaryMediaFiles.offer(
            snapshot, device: "synthetic-phone", thread: "synthetic-thread",
            mime: "image/jpeg", files: files)
        XCTAssertEqual(profile["kind"] as? String, "media")
        XCTAssertEqual(profile["encoding"] as? String, "raw")
        XCTAssertEqual(profile["sha256"] as? String, snapshot.digest)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: profile).count, 4096)
        let ticket = try XCTUnwrap(profile["id"] as? String)
        files.cancelTicket(device: "other-phone", ticket: ticket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.file.path))
        files.cancelTicket(device: "synthetic-phone", ticket: ticket)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.file.path))
    }
}
