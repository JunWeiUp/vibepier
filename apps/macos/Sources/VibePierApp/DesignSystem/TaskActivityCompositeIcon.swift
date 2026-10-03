import AppKit

/// A standard status-item image. Repaint against the drawing appearance instead of caching a light/dark bitmap.
enum TaskActivityCompositeIcon {
    static func image(base: NSImage, activity: TaskActivityJSON) -> NSImage {
        let layout = TaskIndicatorLayout(runningCount: activity.runningCount, unreadCount: activity.unreadCount)
        guard layout.markerCount > 0 else { return base }
        let image = NSImage(size: NSSize(width: layout.width, height: TaskIndicatorLayout.canvasSize), flipped: false) {
            bounds in
            guard let graphics = NSGraphicsContext.current else { return false }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let canvas = NSRect(
                x: 0, y: 0, width: TaskIndicatorLayout.canvasSize, height: TaskIndicatorLayout.canvasSize)
            // Isolate the mask so sourceIn cannot use the opaque menu-bar background as destination alpha.
            graphics.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            base.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)
            // Preserve the template's alpha, including the transparent canvas around a narrow symbol.
            NSGraphicsContext.current?.compositingOperation = .sourceIn
            NSColor.labelColor.setFill()
            NSBezierPath(rect: canvas).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            graphics.cgContext.endTransparencyLayer()
            for index in 0..<layout.markerCount {
                let point = layout.position(index)
                let size = layout.markerSize(index)
                let marker = NSRect(
                    x: point.x - size / 2, y: bounds.height - point.y - size / 2, width: size, height: size)
                if layout.isRunningMarker(index) {
                    NSColor.labelColor.setStroke()
                    let ring = NSBezierPath(ovalIn: marker.insetBy(dx: 0.5, dy: 0.5))
                    ring.lineWidth = 1
                    ring.stroke()
                } else {
                    NSColor.systemGreen.setFill()
                    NSBezierPath(ovalIn: marker).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        return image
    }
}
