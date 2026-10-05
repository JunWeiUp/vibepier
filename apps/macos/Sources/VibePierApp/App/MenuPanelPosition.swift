import AppKit
import SwiftUI

/// Preserve the top edge while live content changes the panel's height.
struct MenuPanelAnchor {
    private var topLeft: NSPoint?
    private var screenFrame: NSRect?

    mutating func reset() {
        topLeft = nil
        screenFrame = nil
    }

    mutating func origin(for frame: NSRect, on screenFrame: NSRect) -> NSPoint {
        if topLeft == nil || self.screenFrame != screenFrame {
            // Apply the inward offset once per presentation, never once per resize.
            topLeft = NSPoint(x: max(screenFrame.minX + 8, frame.minX - 80), y: frame.maxY)
            self.screenFrame = screenFrame
        }
        let anchor = topLeft!
        return NSPoint(x: anchor.x, y: anchor.y - frame.height)
    }
}

/// Keep the menu panel a little farther inward than the system's default anchor.
struct MenuPanelPosition: NSViewRepresentable {
    func makeNSView(context: Context) -> PositionView { PositionView() }
    func updateNSView(_ view: PositionView, context: Context) { view.schedulePosition() }

    final class PositionView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var visibilityObservation: NSKeyValueObservation?
        private var positionPending = false
        private var anchor = MenuPanelAnchor()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            visibilityObservation = nil
            anchor.reset()
            guard let window else { return }
            for name in [
                NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification,
                NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
            ] {
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in self?.schedulePosition() })
            }
            visibilityObservation = window.observe(\.isVisible, options: [.initial, .new]) { [weak self] window, _ in
                // MenuBarExtra reuses its window. A later opening must get a fresh
                // system anchor, including after moving the menu item or display.
                if !window.isVisible { self?.anchor.reset() }
                self?.schedulePosition()
            }
            schedulePosition()
        }

        func schedulePosition() {
            guard !positionPending else { return }
            positionPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.positionPending = false
                self.positionNow()
            }
        }

        func positionNow() {
            guard let window else { return }
            guard window.isVisible else {
                anchor.reset()
                return
            }
            guard let screen = window.screen else { return }
            let origin = anchor.origin(for: window.frame, on: screen.visibleFrame)
            // Our own move may send didMove again. Compare both axes so a resize
            // with unchanged X still restores the original top edge.
            guard abs(window.frame.minX - origin.x) >= 0.5 || abs(window.frame.minY - origin.y) >= 0.5 else { return }
            window.setFrameOrigin(origin)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
