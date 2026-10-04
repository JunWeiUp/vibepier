import CryptoKit
import Foundation
import XCTest

@testable import VibePierCore

final class PhoneAppVersionsTests: XCTestCase {
    private func metadata(_ code: Any = 5, name: String = "0.1.0-beta.1") -> [String: Any] {
        ["packageName": PhoneAppVersions.packageName, "versionCode": code, "versionName": name]
    }
    func testReportsPersistButDoNotAdvertiseAnUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhoneAppVersions(root: root)
        XCTAssertNil(try store.report(metadata(999), device: "one")["latest"])
        _ = try store.report(metadata(4), device: "two")
        let restored = PhoneAppVersions(root: root)
        XCTAssertEqual(restored.installed("one")?["versionCode"] as? Int, 999)
        XCTAssertEqual(restored.installed("two")?["versionCode"] as? Int, 4)
        restored.revoke("one")
        XCTAssertNil(PhoneAppVersions(root: root).installed("one"))
    }
    func testPublishDigestMonotonicVersionAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let apk = root.appendingPathComponent("synthetic.apk")
        let bytes = Data("Synthetic artifact, never installed".utf8)
        try bytes.write(to: apk)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        func write(_ code: Int, hash: String = digest) throws {
            var value = metadata(code)
            value["sha256"] = hash
            try JSONSerialization.data(withJSONObject: value).write(to: apk.appendingPathExtension("json"))
        }
        let store = PhoneAppVersions(root: root.appendingPathComponent("store"))
        try write(5)
        try store.publish(apk)
        XCTAssertEqual(store.latest?["versionCode"] as? Int, 5)
        XCTAssertEqual(
            try store.requestedUpdate(["packageName": PhoneAppVersions.packageName, "versionCode": 4]).version
                .versionCode, 5)
        for code: Any in [true, 5, 6, 0, "4"] {
            XCTAssertThrowsError(
                try store.requestedUpdate(["packageName": PhoneAppVersions.packageName, "versionCode": code]))
        }
        XCTAssertThrowsError(try store.requestedUpdate(["packageName": "other.package", "versionCode": 4]))
        try store.publish(apk)  // Same artifact is repeatable.
        try write(4)
        XCTAssertThrowsError(try store.publish(apk))
        try write(5, hash: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try store.publish(apk))
        try write(6, hash: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try store.publish(apk))
        XCTAssertEqual(store.latest?["versionCode"] as? Int, 5)
        try write(6)
        try store.publish(apk)
        let restored = PhoneAppVersions(root: root.appendingPathComponent("store"))
        XCTAssertEqual(restored.latest?["versionCode"] as? Int, 6)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.apkURL)), bytes)
        XCTAssertEqual(
            (try restored.report(metadata(7), device: "newer")["latest"] as? [String: Any])?["versionCode"] as? Int, 6)
    }
    func testMalformedVersionReports() throws {
        for code: Any in [true, 0, -1, 2_100_000_001, "5", 1.5] {
            XCTAssertThrowsError(try PhoneAppVersions.Version(metadata(code)))
        }
        XCTAssertNoThrow(try PhoneAppVersions.Version(metadata(1)))
        let wire = try JSONSerialization.data(withJSONObject: metadata(1))
        XCTAssertNoThrow(
            try PhoneAppVersions.Version(try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])))
        XCTAssertThrowsError(try PhoneAppVersions.Version(metadata(name: "bad\nversion")))
    }
    func testPreparedReleaseCannotCommitOverNewerRegistration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let apk = root.appendingPathComponent("fixture.apk")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: apk)
        let store = PhoneAppVersions(root: root.appendingPathComponent("store"))
        func prepare(_ code: Int) throws -> PhoneAppVersions.PreparedRelease {
            var value = metadata(code)
            value["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try JSONSerialization.data(withJSONObject: value).write(to: apk.appendingPathExtension("json"))
            return try PhoneAppVersions.prepare(apk, root: store.root, job: APKPreparationJob())
        }
        let old = try prepare(5)
        let new = try prepare(6)
        try store.adopt(new)
        XCTAssertThrowsError(try store.adopt(old))
        old.apk.discard()
        XCTAssertEqual(store.latest?["versionCode"] as? Int, 6)
    }
}
