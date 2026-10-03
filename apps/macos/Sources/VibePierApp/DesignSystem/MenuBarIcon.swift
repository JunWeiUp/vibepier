import AppKit

/// The VibePier mark on a stable 18pt template canvas. Critical device states retain familiar system cues.
@MainActor
enum MenuBarIcon {
    static func image(symbol: String) -> NSImage {
        if ["exclamationmark.triangle.fill", "bolt.fill", "battery.0percent"].contains(symbol) {
            return systemImage(symbol: symbol)
        }
        let connected = ["waveform", "mic.fill", "iphone"].contains(symbol)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            // Brand vector coordinates: fit only the mark's optical bounds, not the app icon's outer square.
            let scale = min(bounds.width, bounds.height) / 18 * 16 / 640
            let transform = AffineTransform(
                m11: scale, m12: 0, m21: 0, m22: -scale,
                tX: bounds.midX - 508 * scale, tY: bounds.midY + 486.5 * scale)
            (transform as NSAffineTransform).concat()
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let v = NSBezierPath()
            v.move(to: NSPoint(x: 280, y: 310))
            v.line(to: NSPoint(x: 454, y: 626))
            v.curve(
                to: NSPoint(x: 509, y: 626),
                controlPoint1: NSPoint(x: 471.333333, y: 658),
                controlPoint2: NSPoint(x: 489.666667, y: 658))
            v.line(to: NSPoint(x: 650, y: 358))
            v.lineWidth = 96
            v.lineCapStyle = .round
            v.lineJoinStyle = .round
            v.stroke()
            let pier = NSBezierPath()
            pier.move(to: NSPoint(x: 288, y: 752))
            pier.line(to: NSPoint(x: 736, y: 752))
            pier.lineWidth = 96
            pier.lineCapStyle = .round
            pier.stroke()
            let signal = NSBezierPath(ovalIn: NSRect(x: 661, y: 173, width: 114, height: 114))
            if connected {
                signal.fill()
            } else {
                signal.lineWidth = 40
                signal.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func systemImage(symbol: String) -> NSImage {
        let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            let size = source.size
            let scale = min(16 / size.width, 16 / size.height)
            let target = NSSize(width: size.width * scale, height: size.height * scale)
            source.draw(
                in: NSRect(
                    x: (bounds.width - target.width) / 2, y: (bounds.height - target.height) / 2,
                    width: target.width, height: target.height))
            return true
        }
        image.isTemplate = true
        return image
    }
}
