import Foundation
import XCTest

@testable import VibePierCore

final class ZCodeDesktopCacheTests: XCTestCase {
    func testPendingCreationKeepsVerifiedNativeModeBoundToOriginalDeviceAndOperation() throws {
        let cache = ZCodeDesktop.Cache()
        let key = ZCodeDesktop.receiptKey(client: "phone-a", session: "", operation: "creation")
        var receipt: [String: Any] = [
            "unknown": true, "accepted": false,
            "executionModeVerified": true, "effectiveExecutionMode": "plan",
        ]
        try cache.record(key, receipt, text: "first message", creationCwd: "/fixture")
        receipt["sessionId"] = "new-native-session"
        try cache.record(key, receipt, text: "first message", creationCwd: "/fixture")
        XCTAssertEqual(cache.receipt(key)?["executionModeVerified"] as? Bool, true)
        XCTAssertEqual(cache.receipt(key)?["effectiveExecutionMode"] as? String, "plan")
        XCTAssertEqual(cache.pendingSubmission(key)?.creationCwd, "/fixture")
        XCTAssertNil(cache.receipt(ZCodeDesktop.receiptKey(client: "phone-b", session: "", operation: "creation")))
        XCTAssertNil(cache.receipt(ZCodeDesktop.receiptKey(client: "phone-a", session: "", operation: "another")))
    }
    private func owner(
        session: String = "sess_00000000-0000-4000-8000-000000000001", pid: Int32 = 77,
        launched: TimeInterval = 100, window: Int = 1
    ) -> ZCodeDesktop.OwnerScope<Int> {
        .init(session: session, pid: pid, launched: Date(timeIntervalSince1970: launched), window: window)
    }

    func testOwnerProofExistsOnlyAfterVerifiedBindingAndIsStableAcrossContentReads() throws {
        let proof = ZCodeDesktop.VerifiedOwner<Int>()
        XCTAssertNil(proof.current(owner()))
        let epoch = try XCTUnwrap(proof.bind(owner()))
        XCTAssertNotNil(UUID(uuidString: epoch))
        XCTAssertEqual(proof.current(owner()), epoch)
        XCTAssertEqual(proof.bind(owner()), epoch)
        proof.invalidate()
        XCTAssertNil(proof.current(owner()))
        XCTAssertNotEqual(proof.bind(owner()), epoch)
    }

    func testProcessReuseAndWindowReplacementInvalidateOldOwnerWithoutRestoringIt() throws {
        for changed in [owner(pid: 78), owner(launched: 101), owner(window: 2)] {
            let proof = ZCodeDesktop.VerifiedOwner<Int>()
            let original = try XCTUnwrap(proof.bind(owner()))
            XCTAssertNil(proof.current(changed))
            XCTAssertNil(proof.current(owner()))
            XCTAssertNotEqual(proof.bind(changed), original)
        }
    }

    func testAnotherHistoryReadCannotBorrowOrEraseTheVisibleSessionsOwnerProof() throws {
        let proof = ZCodeDesktop.VerifiedOwner<Int>()
        let original = try XCTUnwrap(proof.bind(owner()))
        let other = owner(session: "sess_00000000-0000-4000-8000-000000000002")
        XCTAssertNil(proof.current(other))
        XCTAssertEqual(proof.current(owner()), original)
        XCTAssertNotEqual(proof.bind(other), original)
        XCTAssertNil(proof.current(owner()))
    }

    func testInvalidNativeIdentityOrProcessStartCannotCreateOwnerEvidence() {
        for invalid in [owner(session: "history-id"), owner(pid: 0), owner(launched: .nan), owner(launched: 0)] {
            let proof = ZCodeDesktop.VerifiedOwner<Int>()
            XCTAssertNil(proof.bind(invalid))
            XCTAssertNil(proof.current(invalid))
        }
    }

    func testPendingReceiptsRemainIndependentUntilNativeAcceptance() throws {
        let cache = ZCodeDesktop.Cache()
        try cache.record(
            "phone-a:thread:operation", ["accepted": false, "unknown": true], before: "anchor", text: "first")
        try cache.record("phone-b:thread:operation", ["accepted": false, "unknown": true], text: "second")
        XCTAssertEqual(cache.pendingSubmission("phone-a:thread:operation")?.before, "anchor")
        XCTAssertEqual(cache.pendingSubmission("phone-b:thread:operation")?.text, "second")
        try cache.record("phone-a:thread:operation", ["accepted": true])
        XCTAssertNil(cache.receipt("phone-a:thread:operation"))
        XCTAssertNil(cache.pendingSubmission("phone-a:thread:operation"))
        XCTAssertNotNil(cache.receipt("phone-b:thread:operation"))
    }

    func testFullReceiptCacheRefusesNewMarkersWithoutDroppingUncertainOnes() throws {
        let cache = ZCodeDesktop.Cache()
        for index in 0..<128 { try cache.record("operation-\(index)", ["unknown": true], text: "pending-\(index)") }
        XCTAssertThrowsError(try cache.record("overflow", ["unknown": true], text: "overflow"))
        XCTAssertEqual(cache.pendingSubmission("operation-0")?.text, "pending-0")
        XCTAssertNotNil(cache.receipt("operation-127"))
        try cache.record("operation-0", ["unknown": true], text: "rechecked")
        XCTAssertEqual(cache.pendingSubmission("operation-0")?.text, "rechecked")
    }

    func testSettingsReaderRetainsOnlyNativeViewAndProviderIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: [
            "enabledBuiltinAgentCliProviders": ["glm"], "lastWorkspaceSession": "fixture",
            "lastActiveTabIndex": 2, "relaySecret": "synthetic-private", "unknown": "discarded",
        ]).write(to: path)
        let cache = ZCodeDesktop.Cache()
        let settings = cache.desktopSettings(at: path)
        XCTAssertEqual(
            Set(settings.keys), Set(["enabledBuiltinAgentCliProviders", "lastWorkspaceSession", "lastActiveTabIndex"]))
        XCTAssertEqual(settings["enabledBuiltinAgentCliProviders"] as? [String], ["glm"])
        XCTAssertTrue(cache.desktopSettings(at: directory.appendingPathComponent("missing.json")).isEmpty)
    }
}
