import AppKit
import XCTest

@testable import VibePierCore

@MainActor
final class ApplicationShortcutsTests: XCTestCase {
    func testFiveSlotsPersistWithEmptyPositions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ids = ["com.apple.finder", "", "com.apple.Safari", "", "com.apple.Terminal"]
        var config = Config()
        config.applicationShortcuts = ids
        try config.save(url)
        XCTAssertEqual(try Config.load(url).applicationShortcuts, ids)
        XCTAssertEqual(ApplicationShortcuts.normalized(nil), Array(repeating: "", count: 5))
    }

    func testMoreThanFiveSlotsPersistWithoutTruncation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ids = (0..<12).map { "test.application\($0)" }
        var config = Config()
        config.applicationShortcuts = ids
        try config.save(url)
        XCTAssertEqual(ApplicationShortcuts.normalized(try Config.load(url).applicationShortcuts), ids)
        let store = ApplicationShortcuts()
        store.configure(ids)
        XCTAssertEqual(store.snapshot.entries.map(\.slot), Array(0..<12))
        for data in store.frames(sender: "test") {
            let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(frame["count"] as? Int, 12)
            XCTAssertTrue((0..<12).contains(try XCTUnwrap(frame["slot"] as? Int)))
        }
    }

    func testAddingRemovingAndReorderingBeyondFiveSlots() throws {
        let original = (0..<6).map { "test.application\($0)" }
        let added = try ApplicationShortcuts.applying(.add(bundleID: "test.application6"), to: original)
        XCTAssertEqual(added, original + ["test.application6"])
        let moved = try ApplicationShortcuts.applying(.move(index: 6, target: 5), to: added)
        XCTAssertEqual(Array(moved.suffix(2)), ["test.application6", "test.application5"])
        let removed = try ApplicationShortcuts.applying(.remove(index: 1), to: moved)
        XCTAssertEqual(
            removed,
            [
                "test.application0", "test.application2", "test.application3", "test.application4", "test.application6",
                "test.application5",
            ])
        let store = ApplicationShortcuts()
        store.configure(removed)
        XCTAssertEqual(store.snapshot.entries.map(\.slot), Array(0..<6))
        XCTAssertThrowsError(try ApplicationShortcuts.applying(.remove(index: 6), to: removed))
        XCTAssertThrowsError(try ApplicationShortcuts.applying(.move(index: 5, target: 6), to: removed))
        XCTAssertThrowsError(
            try ApplicationShortcuts.applying(.add(bundleID: "/Applications/Example.app"), to: removed))
    }

    func testAddingFillsLegacyEmptyPositionsAndRemovingKeepsMinimumFive() throws {
        let filled = try ApplicationShortcuts.applying(.add(bundleID: "test.application"), to: nil)
        XCTAssertEqual(filled, ["test.application", "", "", "", ""])
        let cleared = try ApplicationShortcuts.applying(.remove(index: 0), to: filled)
        XCTAssertEqual(cleared, Array(repeating: "", count: 5))
        let six = (0..<6).map { "test.application\($0)" }
        XCTAssertEqual(try ApplicationShortcuts.applying(.remove(index: 0), to: six), Array(six.dropFirst()))
        XCTAssertThrowsError(try ApplicationShortcuts.applying(.add(bundleID: ""), to: cleared))
    }

    func testCountOnlyChangeUpdatesRevisionAndShrinkingAdvertisesNewCount() throws {
        let store = ApplicationShortcuts()
        store.configure(nil)
        let first = store.snapshot.revision
        store.configure(Array(repeating: "", count: 6))
        let second = store.snapshot.revision
        XCTAssertNotEqual(first, second)
        store.configure(Array(repeating: "", count: 6))
        XCTAssertEqual(store.snapshot.revision, second)
        store.configure(nil)
        XCTAssertNotEqual(store.snapshot.revision, second)
        let frames = try store.frames(sender: "test").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(frames.count, 5)
        XCTAssertTrue(frames.allSatisfy { $0["count"] as? Int == 5 })
    }

    func testSyncFramesAreBoundedAndRevisionOnlyChangesWithConfiguration() throws {
        let store = ApplicationShortcuts()
        store.configure(["com.apple.finder", "com.apple.Safari", "com.apple.Terminal", "", "missing.app"])
        let first = store.snapshot
        let frames = store.frames(sender: "test")
        XCTAssertGreaterThan(frames.count, 5)
        for data in frames {
            XCTAssertLessThan(data.count, 4096)
            let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertTrue((0..<5).contains(try XCTUnwrap(frame["slot"] as? Int)))
            XCTAssertEqual(frame["revision"] as? String, first.revision)
            XCTAssertEqual(frame["count"] as? Int, 5)
        }
        XCTAssertFalse(first.entries[4].available)
        let iconData = try XCTUnwrap(Data(base64Encoded: first.entries[0].iconPNG))
        let image = try XCTUnwrap(NSBitmapImageRep(data: iconData))
        XCTAssertEqual(image.pixelsWide, 128)
        XCTAssertEqual(image.pixelsHigh, 128)
        let chunks = try frames.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
            .filter { $0["slot"] as? Int == 0 }
            .sorted { ($0["iconPart"] as! Int) < ($1["iconPart"] as! Int) }
        XCTAssertEqual(chunks.compactMap { $0["iconPNG"] as? String }.joined(), first.entries[0].iconPNG)
        store.configure(first.entries.map(\.bundleID))
        XCTAssertEqual(store.snapshot.revision, first.revision)
        store.configure([])
        XCTAssertNotEqual(store.snapshot.revision, first.revision)
    }

    func testPhoneCannotLaunchUnconfiguredOrStaleApplication() async {
        let store = ApplicationShortcuts()
        store.configure(["com.apple.finder"])
        let wrong = await store.activate(slot: 0, bundleID: "com.apple.Terminal")
        let empty = await store.activate(slot: 1, bundleID: "com.apple.Terminal")
        let invalid = await store.activate(slot: 5, bundleID: "com.apple.finder")
        XCTAssertNotNil(wrong)
        XCTAssertNotNil(empty)
        XCTAssertNotNil(invalid)
    }

    func testLaunchBeyondFifthPositionStillChecksConfiguredBundle() async {
        let store = ApplicationShortcuts()
        store.configure((0..<7).map { "missing.application\($0)" })
        let configured = await store.activate(slot: 6, bundleID: "missing.application6")
        XCTAssertEqual(configured, L10n.text("control.application_not_found_0", "missing.application6"))
        let stale = await store.activate(slot: 6, bundleID: "missing.application5")
        XCTAssertEqual(stale, L10n.text("control.the_application_settings_changed_select_the_app_again"))
        let outOfRange = await store.activate(slot: 7, bundleID: "missing.application6")
        XCTAssertEqual(outOfRange, L10n.text("control.the_application_settings_changed_select_the_app_again"))
    }

    func testLaunchProtocolRejectsInvalidSlotsAndDeduplicatesRetries() throws {
        let event = try XCTUnwrap(RemoteEvent.parse("vibepier-launch1 phone 9 2 com.apple.finder"))
        XCTAssertEqual(event.applicationSlot, 2)
        XCTAssertEqual(event.applicationID, "com.apple.finder")
        XCTAssertNil(event.control)
        XCTAssertTrue(event.isMomentary)
        XCTAssertEqual(event.applicationAction, .activate)
        var dedup = RemoteDeduplicator()
        XCTAssertTrue(dedup.isNew(event))
        XCTAssertFalse(dedup.isNew(event))
        XCTAssertEqual(RemoteEvent.parse("vibepier-launch1 phone 9 -1 com.apple.finder")?.applicationSlot, -1)
        XCTAssertNil(RemoteEvent.parse("vibepier-launch1 phone 9 -2 com.apple.finder"))
        XCTAssertEqual(RemoteEvent.parse("vibepier-launch1 phone 9 5 com.apple.finder")?.applicationSlot, 5)
        XCTAssertEqual(RemoteEvent.parse("vibepier-launch1 phone 9 11 com.apple.finder")?.applicationSlot, 11)
        XCTAssertNil(RemoteEvent.parse("vibepier-launch1 phone 9 99999999999999999999 com.apple.finder"))
        XCTAssertNil(RemoteEvent.parse("vibepier-launch1 phone 9 2"))
        XCTAssertNil(RemoteEvent.parse("vibepier-launch1 phone 9 2 com.apple.finder extra"))
    }

    func testExplicitHideProtocolAndApplicationTapDeduplicateAcrossTransports() throws {
        var event = try XCTUnwrap(RemoteEvent.parse("vibepier-launch1 phone 10 -1 com.apple.finder action=hide"))
        XCTAssertEqual(event.applicationSlot, -1)
        XCTAssertEqual(event.applicationAction, .hide)
        XCTAssertNil(RemoteEvent.parse("vibepier-launch1 phone 10 -1 com.apple.finder action=close"))
        XCTAssertNil(RemoteEvent.parse("vibepier-launch1 phone 10 -1 com.apple.finder action=hide extra"))
        var dedup = RemoteDeduplicator()
        XCTAssertTrue(dedup.isNewApplication(event))
        event.sender = "relay:phone"
        XCTAssertFalse(dedup.isNewApplication(event))
        event.sender = "ble:central-uuid:phone"
        XCTAssertFalse(dedup.isNewApplication(event))
        event.seq = 11
        XCTAssertTrue(dedup.isNewApplication(event))
    }

    func testHideRejectsStaleForegroundAndStaleConfiguredSlot() {
        let entries = [
            ApplicationShortcut(slot: 0, bundleID: "test.editor", name: "Editor", iconPNG: "", available: true)
        ]
        XCTAssertNil(
            ApplicationShortcuts.validationError(
                slot: 0, bundleID: "test.editor", action: .hide,
                entries: entries, frontmost: "test.editor", locked: false))
        XCTAssertEqual(
            ApplicationShortcuts.validationError(
                slot: 0, bundleID: "test.editor", action: .hide,
                entries: entries, frontmost: "test.other", locked: false),
            L10n.text("control.the_active_mac_app_changed_select_it_again"))
        XCTAssertEqual(
            ApplicationShortcuts.validationError(
                slot: 0, bundleID: "test.other", action: .hide,
                entries: entries, frontmost: "test.other", locked: false),
            L10n.text("control.the_application_settings_changed_select_the_app_again"))
        XCTAssertEqual(
            ApplicationShortcuts.validationError(
                slot: 0, bundleID: "test.editor", action: .hide,
                entries: entries, frontmost: "test.editor", locked: true),
            L10n.text("control.the_mac_is_locked_unlock_it_before_hiding_the_app"))
    }

    func testCurrentSlotRequiresLiveForegroundForEveryActionWithoutChangingConfiguration() {
        let store = ApplicationShortcuts()
        store.configure(["test.configured"])
        let before = store.snapshot
        for action in [ApplicationShortcutAction.activate, .hide] {
            XCTAssertNil(
                ApplicationShortcuts.validationError(
                    slot: -1, bundleID: "test.unconfigured", action: action,
                    entries: before.entries, frontmost: "test.unconfigured", locked: false))
            XCTAssertEqual(
                ApplicationShortcuts.validationError(
                    slot: -1, bundleID: "test.old", action: action,
                    entries: before.entries, frontmost: "test.new", locked: false),
                L10n.text("control.the_active_mac_app_changed_select_it_again"))
            XCTAssertEqual(
                ApplicationShortcuts.validationError(
                    slot: -1, bundleID: "", action: action,
                    entries: before.entries, frontmost: "", locked: false),
                L10n.text("control.the_application_settings_changed_select_the_app_again"))
        }
        XCTAssertEqual(store.snapshot.entries.map(\.bundleID), before.entries.map(\.bundleID))
        XCTAssertEqual(store.snapshot.revision, before.revision)
    }
}
