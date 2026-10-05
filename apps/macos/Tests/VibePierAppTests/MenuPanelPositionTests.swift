import AppKit
import XCTest

@testable import VibePierApp

@MainActor
final class MenuPanelPositionTests: XCTestCase {
    private let screenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)

    func testHeightChangesKeepTheInitialTopEdge() {
        var anchor = MenuPanelAnchor()
        let initial = NSRect(x: 1200, y: 600, width: 340, height: 320)
        let firstOrigin = anchor.origin(for: initial, on: screenFrame)
        XCTAssertEqual(firstOrigin, NSPoint(x: 1120, y: 600))

        // Model a resize that leaves the bottom origin unchanged.
        let grown = NSRect(origin: firstOrigin, size: NSSize(width: 340, height: 480))
        let grownOrigin = anchor.origin(for: grown, on: screenFrame)
        XCTAssertEqual(grownOrigin.y + grown.height, initial.maxY)

        let shrunk = NSRect(origin: grownOrigin, size: NSSize(width: 340, height: 240))
        let shrunkOrigin = anchor.origin(for: shrunk, on: screenFrame)
        XCTAssertEqual(shrunkOrigin.y + shrunk.height, initial.maxY)
        XCTAssertEqual(shrunkOrigin.x, firstOrigin.x)
    }

    func testSystemRecenteringAndOwnMoveDoNotAccumulateOffsets() {
        var anchor = MenuPanelAnchor()
        let initial = NSRect(x: 1200, y: 600, width: 340, height: 320)
        let expectedOrigin = anchor.origin(for: initial, on: screenFrame)

        for height: CGFloat in [480, 240, 420, 320] {
            // MenuBarExtra may recenter both axes after its fitting size changes.
            var frame = NSRect(x: 1218, y: 500, width: 340, height: height)
            for _ in 0..<6 {
                frame.origin = anchor.origin(for: frame, on: screenFrame)
                XCTAssertEqual(frame.minX, expectedOrigin.x)
                XCTAssertEqual(frame.maxY, initial.maxY)
            }
        }
    }

    func testResetUsesTheNextOpeningSystemPosition() {
        var anchor = MenuPanelAnchor()
        _ = anchor.origin(for: NSRect(x: 1200, y: 600, width: 340, height: 320), on: screenFrame)
        anchor.reset()

        let reopened = NSRect(x: 900, y: 500, width: 340, height: 280)
        XCTAssertEqual(anchor.origin(for: reopened, on: screenFrame), NSPoint(x: 820, y: 500))
    }

    func testScreenChangeUsesTheNewScreenSystemPosition() {
        var anchor = MenuPanelAnchor()
        _ = anchor.origin(for: NSRect(x: 1200, y: 600, width: 340, height: 320), on: screenFrame)

        let otherScreen = NSRect(x: -1920, y: 0, width: 1920, height: 1200)
        let moved = NSRect(x: -700, y: 800, width: 340, height: 320)
        let newOrigin = anchor.origin(for: moved, on: otherScreen)
        XCTAssertEqual(newOrigin, NSPoint(x: -780, y: 800))

        let resized = NSRect(origin: newOrigin, size: NSSize(width: 340, height: 480))
        XCTAssertEqual(anchor.origin(for: resized, on: otherScreen).y + resized.height, moved.maxY)
    }

    func testInwardOffsetPreservesTheScreenMargin() {
        var anchor = MenuPanelAnchor()
        let frame = NSRect(x: 40, y: 600, width: 340, height: 320)
        XCTAssertEqual(anchor.origin(for: frame, on: screenFrame).x, screenFrame.minX + 8)
    }

    func testResizeNotificationRestoresTopWithoutShowingAWindow() async throws {
        let fixture = try makeFixture()
        defer { dispose(fixture.window) }
        let original = fixture.window.frame
        await drainPositionCallbacks()

        let positionedX = fixture.window.frame.minX
        let initialMoves = fixture.window.originChangeCount
        fixture.window.setFrame(
            NSRect(x: positionedX, y: original.minY, width: original.width, height: original.height + 120),
            display: false)
        await drainPositionCallbacks()

        XCTAssertEqual(fixture.window.frame.maxY, original.maxY, accuracy: 0.5)
        XCTAssertGreaterThan(fixture.window.originChangeCount, initialMoves)

        fixture.window.setFrame(
            NSRect(x: positionedX, y: fixture.window.frame.minY, width: original.width, height: 180),
            display: false)
        await drainPositionCallbacks()
        XCTAssertEqual(fixture.window.frame.maxY, original.maxY, accuracy: 0.5)
        XCTAssertEqual(fixture.window.frame.minX, positionedX, accuracy: 0.5)

        let settledMoves = fixture.window.originChangeCount
        for _ in 0..<5 {
            NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: fixture.window)
            await drainPositionCallbacks()
        }
        XCTAssertEqual(fixture.window.originChangeCount, settledMoves)
    }

    func testVisibilityKVOResetsAnchorEvenWhenHideAndShowShareAQueueTurn() async throws {
        let fixture = try makeFixture()
        defer { dispose(fixture.window) }
        await drainPositionCallbacks()
        let oldTop = fixture.window.frame.maxY

        // The real window remains hidden. Only its test visibility getter changes;
        // this exercises the production KVO observer without orderFront or activation.
        fixture.window.setFixtureVisible(false)
        let reopened = NSRect(
            x: fixture.screen.visibleFrame.minX + 460,
            y: oldTop - 400, width: 340, height: 260)
        fixture.window.setFrame(reopened, display: false)
        fixture.window.setFixtureVisible(true)
        await drainPositionCallbacks()

        XCTAssertEqual(fixture.window.frame.maxY, reopened.maxY, accuracy: 0.5)
        XCTAssertEqual(fixture.window.frame.minX, reopened.minX - 80, accuracy: 0.5)
    }

    private func makeFixture() throws -> (window: HiddenPanelWindow, screen: NSScreen) {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("A screen is required to provide the production visibleFrame; no window is shown.")
        }
        let frame = NSRect(
            x: screen.visibleFrame.minX + 600,
            y: screen.visibleFrame.maxY - 360, width: 340, height: 320)
        let window = HiddenPanelWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.fixtureScreen = screen
        window.setFixtureVisible(true)
        window.contentView = MenuPanelPosition.PositionView()
        return (window, screen)
    }

    private func dispose(_ window: HiddenPanelWindow) {
        window.setFixtureVisible(false)
        window.contentView = nil
        window.close()
    }

    private func drainPositionCallbacks() async {
        // One callback can enqueue didMove correction; also drain its no-op pass.
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// Never orders itself onscreen. Visibility is injected only for the position bridge.
@MainActor
private final class HiddenPanelWindow: NSWindow {
    private var fixtureVisible = false
    var fixtureScreen: NSScreen?
    private(set) var originChangeCount = 0

    override var isVisible: Bool { fixtureVisible }
    override var screen: NSScreen? { fixtureScreen }

    func setFixtureVisible(_ visible: Bool) {
        guard visible != fixtureVisible else { return }
        willChangeValue(forKey: "visible")
        fixtureVisible = visible
        didChangeValue(forKey: "visible")
    }

    override func setFrameOrigin(_ point: NSPoint) {
        originChangeCount += 1
        super.setFrameOrigin(point)
    }
}
