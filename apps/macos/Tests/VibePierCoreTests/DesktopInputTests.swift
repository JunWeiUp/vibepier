import AppKit
import XCTest

@testable import VibePierCore

final class DesktopInputTests: XCTestCase {
    func testPreparedKeyNeverPressesAfterFocusLossAndAlwaysReleasesAnActualPress() throws {
        var events: [String] = []
        var focused = false
        XCTAssertThrowsError(
            try DesktopInput.keySequence(
                isCurrent: { focused }, down: { events.append("down") }, up: { events.append("up") }))
        XCTAssertTrue(events.isEmpty)
        focused = true
        try DesktopInput.keySequence(
            isCurrent: { focused },
            down: {
                events.append("down")
                focused = false
            }, up: { events.append("up") })
        XCTAssertEqual(events, ["down", "up"])
    }
    func testAmbiguousAccessibilityFailureNeverFallsBackToClick() {
        var presses = 0
        var preparations = 0
        XCTAssertThrowsError(
            try DesktopInput.perform(
                isCurrent: { true }, supportsPress: true,
                press: {
                    presses += 1
                    throw CLIError("The application may already have handled this press")
                },
                prepareClick: {
                    preparations += 1
                    return { XCTFail("Never repeat a possibly executed press") }
                })
        ) { XCTAssertTrue($0 is UnconfirmedDesktopMutation) }
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(preparations, 0)
    }

    func testUnavailableClickOrChangedIdentityCannotPress() throws {
        var current = true
        var clicks = 0
        for available in [false, true] {
            current = true
            XCTAssertThrowsError(
                try DesktopInput.perform(
                    isCurrent: { current }, supportsPress: false,
                    press: {
                        XCTFail("No advertised press")
                    },
                    prepareClick: {
                        if !available { return nil }
                        current = false
                        return { clicks += 1 }
                    })
            ) { XCTAssertFalse($0 is UnconfirmedDesktopMutation) }
        }
        XCTAssertEqual(clicks, 0)
        try DesktopInput.perform(
            isCurrent: { true }, supportsPress: false, press: { XCTFail() },
            prepareClick: {
                { clicks += 1 }
            })
        XCTAssertEqual(clicks, 1)
    }

    func testPointerLosingFocusBeforeDownCannotClick() {
        var current = true
        var events: [String] = []
        XCTAssertThrowsError(
            try DesktopInput.pointerSequence(
                isCurrent: { current }, move: { events.append("move") },
                down: { events.append("down") }, up: { events.append("up") }, pause: { current = false })
        ) {
            XCTAssertFalse($0 is UnconfirmedDesktopMutation)
        }
        XCTAssertEqual(events, ["move"])
    }

    func testPointerAlwaysReleasesOnceWhenFocusChangesAfterDown() {
        var current = true
        var events: [String] = []
        XCTAssertThrowsError(
            try DesktopInput.pointerSequence(
                isCurrent: { current }, move: { events.append("move") },
                down: {
                    events.append("down")
                    current = false
                }, up: { events.append("up") }, pause: {})
        ) {
            XCTAssertTrue($0 is UnconfirmedDesktopMutation)
        }
        XCTAssertEqual(events, ["move", "down", "up"])
    }

    func testPointerStableGestureAndFailedInitialPreflight() throws {
        var events: [String] = []
        for current in [false, true] {
            let action = {
                try DesktopInput.pointerSequence(
                    isCurrent: { current }, move: { events.append("move") },
                    down: { events.append("down") }, up: { events.append("up") }, pause: {})
            }
            if current {
                try action()
            } else {
                XCTAssertThrowsError(try action())
                XCTAssertTrue(events.isEmpty)
            }
        }
        XCTAssertEqual(events, ["move", "down", "up"])
    }

    func testCursorCleanupAcceptsPixelRoundingButNotUserMovement() {
        let center = CGPoint(x: 400.5, y: 120.5)
        XCTAssertTrue(DesktopInput.pointerIsAt(CGPoint(x: 400, y: 121), center))
        XCTAssertFalse(DesktopInput.pointerIsAt(CGPoint(x: 405, y: 121), center))
        XCTAssertFalse(DesktopInput.pointerIsAt(nil, center))
        XCTAssertFalse(DesktopInput.pointerIsAt(CGPoint(x: CGFloat.nan, y: 121), center))
    }
}

final class DesktopClipboardTests: XCTestCase {
    private func withBoard(_ body: (NSPasteboard) throws -> Void) throws {
        let board = NSPasteboard(name: .init("io.github.junweiup.vibepier.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        try body(board)
    }

    private func copy(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        XCTAssertTrue(board.setString(text, forType: .string))
    }

    func testRestoresEveryOriginalClipboardTypeAndDoesNotRestoreTwice() throws {
        try withBoard { board in
            let item = NSPasteboardItem()
            let custom = NSPasteboard.PasteboardType("io.github.junweiup.vibepier.test.data")
            item.setString("original", forType: .string)
            item.setData(Data([0, 1, 255]), forType: custom)
            board.clearContents()
            XCTAssertTrue(board.writeObjects([item]))
            let clipboard = try DesktopClipboard(board)
            try clipboard.write("temporary")
            XCTAssertTrue(clipboard.isCurrent)
            clipboard.restore()
            XCTAssertEqual(board.string(forType: .string), "original")
            XCTAssertEqual(board.data(forType: custom), Data([0, 1, 255]))
            copy("user's next copy", to: board)
            clipboard.restore()
            XCTAssertEqual(board.string(forType: .string), "user's next copy")
        }
    }

    func testUserCopyDuringOperationIsPreservedEvenWithIdenticalText() throws {
        try withBoard { board in
            for replacement in ["new user text", "temporary"] {
                copy("original", to: board)
                let clipboard = try DesktopClipboard(board)
                try clipboard.write("temporary")
                copy(replacement, to: board)
                XCTAssertFalse(clipboard.isCurrent)
                clipboard.restore()
                XCTAssertEqual(board.string(forType: .string), replacement)
            }
        }
    }

    func testChangedClipboardBeforePublishAndOversizedSnapshotAreUntouched() throws {
        try withBoard { board in
            copy("first", to: board)
            let clipboard = try DesktopClipboard(board)
            copy("second", to: board)
            XCTAssertThrowsError(try clipboard.write("temporary"))
            XCTAssertEqual(board.string(forType: .string), "second")
            XCTAssertThrowsError(try DesktopClipboard(board, byteLimit: 2))
            XCTAssertEqual(board.string(forType: .string), "second")
        }
    }

    func testNativeCopyCleanupUsesExactObservedVersionAndPreservesLaterCopy() throws {
        try withBoard { board in
            for userCopiesLater in [false, true] {
                copy("original", to: board)
                let clipboard = try DesktopClipboard(board)
                try clipboard.write("")
                XCTAssertFalse(clipboard.adoptNativeCopy("", version: board.changeCount))
                copy("native-session", to: board)
                XCTAssertTrue(clipboard.adoptNativeCopy("native-session", version: board.changeCount))
                if userCopiesLater { copy("native-session", to: board) }
                clipboard.restore()
                XCTAssertEqual(board.string(forType: .string), userCopiesLater ? "native-session" : "original")
            }
        }
    }
}
