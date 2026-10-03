import XCTest

@testable import VibePierCore

final class CurrentApplicationShortcutTests: XCTestCase {
    func testUnknownApplicationHasStableEmptyFrame() throws {
        let store = CurrentApplicationShortcut()
        let first = store.snapshot
        XCTAssertEqual(first.entry.slot, -1)
        XCTAssertEqual(first.entry.bundleID, "")
        XCTAssertEqual(first.entry.name, L10n.text("control.unknown_application"))
        XCTAssertFalse(first.entry.available)
        let frames = store.frames(sender: "phone")
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0]) as? [String: Any])
        XCTAssertEqual(frame["type"] as? String, "vibepier-current1")
        XCTAssertEqual(frame["sender"] as? String, "phone")
        XCTAssertEqual(frame["revision"] as? String, first.revision)
        XCTAssertEqual(frame["slot"] as? Int, -1)
        XCTAssertEqual(frame["iconPNG"] as? String, "")
        XCTAssertEqual(frame["iconPart"] as? Int, 0)
        XCTAssertEqual(frame["iconParts"] as? Int, 1)
        XCTAssertEqual(frame["available"] as? Bool, false)
        XCTAssertEqual(store.snapshot.revision, first.revision)
    }

    func testCacheRevisionChangesOnlyForApplicationIdentityOrName() {
        let store = CurrentApplicationShortcut()
        let initial = store.snapshot.revision
        store.update(
            entry: ApplicationShortcut(
                slot: 2, bundleID: "example.editor", name: "Editor", iconPNG: "first", available: true))
        let first = store.snapshot
        XCTAssertNotEqual(initial, first.revision)
        XCTAssertEqual(first.entry.slot, -1)
        store.update(
            entry: ApplicationShortcut(
                slot: 7, bundleID: "example.editor", name: "Editor", iconPNG: "second", available: false))
        XCTAssertEqual(store.snapshot.revision, first.revision)
        XCTAssertEqual(store.snapshot.entry.iconPNG, "first")
        XCTAssertTrue(store.snapshot.entry.available)
        store.update(
            entry: ApplicationShortcut(
                slot: 0, bundleID: "example.editor", name: "Editor 2", iconPNG: "third", available: true))
        let renamed = store.snapshot
        XCTAssertNotEqual(renamed.revision, first.revision)
        XCTAssertEqual(renamed.entry.iconPNG, "third")
        store.update(
            entry: ApplicationShortcut(
                slot: 0, bundleID: "example.other", name: "Editor 2", iconPNG: "fourth", available: true))
        XCTAssertNotEqual(store.snapshot.revision, renamed.revision)
    }

    func testCurrentApplicationCanBeUnconfiguredAndDoesNotAlterConfiguredSlots() {
        let configured = ApplicationShortcuts.shared.snapshot
        let store = CurrentApplicationShortcut()
        store.update(
            entry: ApplicationShortcut(
                slot: -1, bundleID: "example.unconfigured", name: "临时应用", iconPNG: "", available: true))
        XCTAssertEqual(store.snapshot.entry.bundleID, "example.unconfigured")
        XCTAssertTrue(store.snapshot.entry.available)
        XCTAssertEqual(ApplicationShortcuts.shared.snapshot.revision, configured.revision)
        XCTAssertEqual(ApplicationShortcuts.shared.snapshot.entries.map(\.bundleID), configured.entries.map(\.bundleID))
    }

    func testLargeIconIsReassembledFromBoundedFramesWithOneRevision() throws {
        let store = CurrentApplicationShortcut()
        let icon = Data((0..<12000).map { UInt8($0 % 251) }).base64EncodedString()
        store.update(
            entry: ApplicationShortcut(
                slot: 10, bundleID: "example.editor", name: "编辑器", iconPNG: icon, available: true))
        let first = store.snapshot
        let frames = store.frames(sender: "phone")
        XCTAssertEqual(frames.count, (icon.utf8.count + 899) / 900)
        let parsed = try frames.map { data in
            XCTAssertLessThan(data.count, 4096)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        for (part, frame) in parsed.enumerated() {
            XCTAssertEqual(frame["slot"] as? Int, -1)
            XCTAssertEqual(frame["revision"] as? String, first.revision)
            XCTAssertEqual(frame["iconPart"] as? Int, part)
            XCTAssertEqual(frame["iconParts"] as? Int, frames.count)
            XCTAssertEqual(frame["bundleID"] as? String, "example.editor")
            XCTAssertEqual(frame["name"] as? String, "编辑器")
            XCTAssertEqual(frame["available"] as? Bool, true)
            XCTAssertLessThanOrEqual((frame["iconPNG"] as? String)?.utf8.count ?? 0, 900)
        }
        XCTAssertEqual(parsed.compactMap { $0["iconPNG"] as? String }.joined(), icon)
        XCTAssertEqual(store.snapshot.revision, first.revision)
        XCTAssertEqual(store.frames(sender: "phone"), frames)
    }
}
