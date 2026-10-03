import XCTest

@testable import VibePierCore

final class ApplicationCatalogTests: XCTestCase {
    func testStaleSelectionCannotOverwriteConcurrentMacChanges() throws {
        let original = ApplicationShortcuts.normalized(nil)
        let revision = ApplicationCatalog.revision(original)
        let installed: Set<String> = ["test.app.one", "test.app.two"]
        let first = try ApplicationCatalog.setting(
            index: 0, bundleID: "test.app.one", revision: revision, ids: original, installed: installed)
        XCTAssertEqual(first[0], "test.app.one")
        XCTAssertThrowsError(
            try ApplicationCatalog.setting(
                index: 0, bundleID: "test.app.two", revision: revision, ids: first, installed: installed))
        // The same transmitted request may repeat, including after a lost reply or runtime restart.
        XCTAssertEqual(
            try ApplicationCatalog.setting(
                index: 0, bundleID: "test.app.one", revision: revision, ids: first, installed: installed), first)
    }
    func testOnlyInstalledAppsAndBoundedSlotsCanBeSelected() throws {
        let original = ApplicationShortcuts.normalized(nil)
        let revision = ApplicationCatalog.revision(original)
        for index in [-1, 6, 64, Int.max] {
            XCTAssertThrowsError(
                try ApplicationCatalog.setting(
                    index: index, bundleID: "test.app", revision: revision, ids: original, installed: ["test.app"]))
        }
        XCTAssertThrowsError(
            try ApplicationCatalog.setting(
                index: 0, bundleID: "unknown.app", revision: revision, ids: original, installed: []))
        let added = try ApplicationCatalog.setting(
            index: 5, bundleID: "test.app", revision: revision, ids: original, installed: ["test.app"])
        XCTAssertEqual(added.count, 6)
        let cleared = try ApplicationCatalog.setting(
            index: 5, bundleID: "", revision: ApplicationCatalog.revision(added), ids: added, installed: [])
        XCTAssertEqual(cleared.count, 6)
        XCTAssertEqual(cleared[5], "")
    }
    func testCatalogRepliesKeepEmptySlotsAndContainNoPaths() throws {
        let reply = ApplicationCatalog.reply(
            ids: ["test.app", "missing.app"], installed: [.init(bundleID: "test.app", name: "Example")])
        let slots = try XCTUnwrap(reply["shortcuts"] as? [[String: Any]])
        XCTAssertEqual(slots.count, 5)
        XCTAssertEqual(slots[0]["name"] as? String, "Example")
        XCTAssertEqual(slots[1]["name"] as? String, "missing.app")
        XCTAssertEqual(slots[2]["bundleID"] as? String, "")
        XCTAssertEqual((reply["applications"] as? [[String: Any]])?.first?.keys.sorted(), ["bundleID", "name"])
    }
}
