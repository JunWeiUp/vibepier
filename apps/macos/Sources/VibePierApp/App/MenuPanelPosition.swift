import AppKit
import SwiftUI

/// Keep the menu panel a little farther inward than the system's default anchor.
struct MenuPanelPosition: NSViewRepresentable {
    func makeNSView(context: Context) -> PositionView { PositionView() }
    func updateNSView(_ view: PositionView, context: Context) { view.schedulePosition() }

    final class PositionView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var positionPending = false
        private var lastPlacedX: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            lastPlacedX = nil
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification] {
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in self?.schedulePosition() })
            }
            schedulePosition()
        }

        func schedulePosition() {
            guard !positionPending else { return }
            positionPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.positionPending = false
                guard let window = self.window, window.isVisible,
                    let screen = window.screen
                else { return }
                let origin = window.frame.origin
                // Our own move and subsequent SwiftUI updates must not accumulate offsets.
                if let lastPlacedX = self.lastPlacedX, abs(origin.x - lastPlacedX) < 0.5 { return }
                let x = max(screen.visibleFrame.minX + 8, origin.x - 80)
                self.lastPlacedX = x
                window.setFrameOrigin(NSPoint(x: x, y: origin.y))
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
