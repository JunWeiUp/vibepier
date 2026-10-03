import AppKit
import ApplicationServices

/// An accessibility error may arrive after the application handled the action.
/// Select one input method before starting; never turn an uncertain press into a second click.
enum DesktopInput {
    static func perform(
        isCurrent: () -> Bool, supportsPress: Bool, press: () throws -> Void,
        prepareClick: () throws -> (() throws -> Void)?
    ) throws {
        guard isCurrent() else { throw unavailable() }
        if supportsPress {
            try UnconfirmedDesktopMutation.attempting { try press() }
        } else {
            guard let click = try prepareClick(), isCurrent() else { throw unavailable() }
            try click()
        }
    }

    /// Events are prepared before calling this function. Once down is posted, up is mandatory,
    /// even if focus, hit testing, or the caller's identity check changes during the gesture.
    static func pointerSequence(
        isCurrent: () -> Bool, move: () -> Void, down: () -> Void, up: () -> Void, pause: () -> Void
    ) throws {
        guard isCurrent() else { throw unavailable() }
        move()
        pause()
        guard isCurrent() else { throw unavailable() }
        down()
        defer { up() }
        pause()
        guard isCurrent() else { throw UnconfirmedDesktopMutation(reason: String(describing: unavailable())) }
    }

    static func hasPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success
            && (names as? [String] ?? []).contains(kAXPressAction as String)
    }

    static func prepareClick(
        _ element: AXUIElement, application: AXUIElement, isCurrent: @escaping () -> Bool
    ) -> (() throws -> Void)? {
        guard let center = center(element), hit(element, in: application, at: center),
            let source = CGEventSource(stateID: .hidSystemState),
            let move = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left),
            let down = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
            let up = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
        else { return nil }
        for event in [move, down, up] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        return {
            // Do not take over a drag that the user already owns.
            guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else { throw unavailable() }
            let prior = CGEvent(source: nil)?.location
            var moved = false
            defer {
                if moved, let prior, pointerIsAt(CGEvent(source: nil)?.location, center) {
                    CGWarpMouseCursorPosition(prior)
                }
            }
            try pointerSequence(
                isCurrent: {
                    isCurrent() && Self.center(element) == center && hit(element, in: application, at: center)
                        && (!moved || pointerIsAt(CGEvent(source: nil)?.location, center))
                },
                move: {
                    move.post(tap: .cghidEventTap)
                    moved = true
                },
                down: { down.post(tap: .cghidEventTap) },
                up: {
                    // Cleanup must release the button without moving a pointer the user moved meanwhile.
                    up.location = CGEvent(source: nil)?.location ?? center
                    up.post(tap: .cghidEventTap)
                }, pause: { Thread.sleep(forTimeInterval: 0.05) })
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    /// Prepare the release as well as the press before posting either event.
    static func keySequence(isCurrent: () -> Bool, down: () -> Void, up: () -> Void) throws {
        guard isCurrent() else { throw unavailable() }
        down()
        up()
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = [], isCurrent: () -> Bool = { true }) throws {
        guard isCurrent() else { throw unavailable() }
        guard let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { throw unavailable() }
        down.flags = flags
        up.flags = flags
        try keySequence(
            isCurrent: isCurrent, down: { down.post(tap: .cghidEventTap) }, up: { up.post(tap: .cghidEventTap) })
    }

    private static func center(_ element: AXUIElement) -> CGPoint? {
        var origin: CFTypeRef?
        var extent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &origin) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &extent) == .success,
            let origin, let extent, CFGetTypeID(origin) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(origin as! AXValue, .cgPoint, &point),
            AXValueGetValue(extent as! AXValue, .cgSize, &size),
            point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
            size.width > 2, size.height > 2
        else { return nil }
        let center = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
        guard center.x.isFinite, center.y.isFinite, Float(center.x).isFinite, Float(center.y).isFinite else {
            return nil
        }
        return center
    }

    static func pointerIsAt(_ pointer: CGPoint?, _ target: CGPoint) -> Bool {
        guard let pointer else { return false }
        return abs(pointer.x - target.x) <= 1 && abs(pointer.y - target.y) <= 1
    }

    private static func hit(_ element: AXUIElement, in application: AXUIElement, at center: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(center.x), Float(center.y), &hit) == .success else {
            return false
        }
        for _ in 0..<8 {
            guard let node = hit else { return false }
            if CFEqual(node, element) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return false }
            hit = (parent as! AXUIElement)
        }
        return false
    }

    private static func unavailable() -> CLIError { CLIError(L10n.text("provider.desktop_input_changed")) }
}
