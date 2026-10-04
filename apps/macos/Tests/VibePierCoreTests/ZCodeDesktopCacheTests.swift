import Foundation
import XCTest

@testable import VibePierCore

final class ZCodeDesktopCacheTests: XCTestCase {
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
