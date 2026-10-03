import AppKit
import XCTest

@testable import VibePierApp

@MainActor
final class TaskCompositeIconTests: XCTestCase {
    private let scale: CGFloat = 4
    private func activity(running: Int, unread: Int) -> TaskActivityJSON {
        .init(runningCount: running, unreadCount: unread, sessions: [])
    }
    private func maskBase() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.red.setFill()
            NSBezierPath(rect: NSRect(x: 2, y: 2, width: 14, height: 14)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
    private func bitmap(size: NSSize, appearance: NSAppearance, drawing: () -> Void) throws -> NSBitmapImageRep {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        appearance.performAsCurrentDrawingAppearance { drawing() }
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }
    private func render(_ image: NSImage, appearance: NSAppearance) throws -> NSBitmapImageRep {
        try bitmap(size: image.size, appearance: appearance) {
            image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    private func color(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
    }
    private func resolved(_ color: NSColor, appearance: NSAppearance) throws -> NSColor {
        var value: NSColor?
        appearance.performAsCurrentDrawingAppearance { value = color.usingColorSpace(.deviceRGB) }
        return try XCTUnwrap(value)
    }
    private func assertColor(
        _ actual: NSColor, equals expected: NSColor, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.04, file: file, line: line)
    }

    func testEmptyActivityUsesOriginalTemplateImageWithoutCompositing() {
        let base = maskBase()
        let image = TaskActivityCompositeIcon.image(base: base, activity: .empty)
        XCTAssertTrue(image === base)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    func testSameUncachedCompositeRetintsMaskAndRingForDrawingAppearanceWhileDotsStayGreen() throws {
        let layout = TaskIndicatorLayout(runningCount: 1, unreadCount: 3)
        let image = TaskActivityCompositeIcon.image(base: maskBase(), activity: activity(running: 1, unread: 3))
        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.cacheMode, .never)
        XCTAssertEqual(image.size, NSSize(width: layout.width, height: 18))
        var baseLuminances: [CGFloat] = []
        for name in [NSAppearance.Name.aqua, .darkAqua, .vibrantLight, .vibrantDark] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let pixels = try render(image, appearance: appearance)
            let label = try resolved(.labelColor, appearance: appearance)
            let green = try resolved(.systemGreen, appearance: appearance)
            let base = try color(pixels, x: 9, y: 9)
            assertColor(base, equals: label)
            baseLuminances.append((base.redComponent + base.greenComponent + base.blueComponent) / 3)
            assertColor(try color(pixels, x: layout.position(0).x + 1.75, y: 9), equals: label)
            // The ring's hole and the template's empty corners must remain transparent.
            XCTAssertLessThan(try color(pixels, x: layout.position(0).x, y: 9).alphaComponent, 0.02)
            XCTAssertLessThan(try color(pixels, x: 1, y: 1).alphaComponent, 0.02)
            assertColor(try color(pixels, x: layout.position(2).x, y: 9), equals: green)
            for x in [CGFloat(19), CGFloat(27.5)] {
                for y in 0..<18 { XCTAssertLessThan(try color(pixels, x: x, y: CGFloat(y)).alphaComponent, 0.02) }
            }
        }
        XCTAssertGreaterThan(abs(baseLuminances[0] - baseLuminances[1]), 0.4)
    }

    func testDenseCompositeKeepsAll257SeparateGreenDotsInsideTheDeclaredGeometry() throws {
        let layout = TaskIndicatorLayout(runningCount: 1, unreadCount: 257)
        let image = TaskActivityCompositeIcon.image(base: maskBase(), activity: activity(running: 1, unread: 257))
        XCTAssertEqual(image.size.width, 157)
        let pixels = try render(image, appearance: XCTUnwrap(NSAppearance(named: .darkAqua)))
        let dots = greenComponents(pixels)
        XCTAssertEqual(dots.count, 257)
        let expected = (1..<layout.markerCount).map { layout.position($0).x * scale }
        for dot in dots {
            XCTAssertTrue(expected.contains { abs($0 - dot.midX) <= 1 })
            XCTAssertGreaterThanOrEqual(dot.minX, 29 * scale - 1)
            XCTAssertLessThanOrEqual(dot.maxX, layout.width * scale)
            XCTAssertGreaterThanOrEqual(dot.minY, 0)
            XCTAssertLessThanOrEqual(dot.maxY, 18 * scale)
            XCTAssertLessThanOrEqual(dot.width, 2 * scale + 2)
            XCTAssertLessThanOrEqual(dot.height, 2 * scale + 2)
        }
    }

    func testTintMaskCannotPaintTheOpaqueBackgroundIntoEmptyTemplateCorners() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let image = TaskActivityCompositeIcon.image(base: maskBase(), activity: activity(running: 1, unread: 3))
        let background = NSColor(white: 0.4, alpha: 1)
        let pixels = try bitmap(size: image.size, appearance: appearance) {
            background.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
            image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
        }
        let expected = try XCTUnwrap(background.usingColorSpace(.deviceRGB))
        assertColor(try color(pixels, x: 1, y: 1), equals: expected)
        assertColor(try color(pixels, x: 19, y: 9), equals: expected)
        assertColor(try color(pixels, x: 27.5, y: 9), equals: expected)
    }

    private func greenComponents(_ image: NSBitmapImageRep) -> [CGRect] {
        let width = image.pixelsWide
        let height = image.pixelsHigh
        var green = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                green[y * width + x] =
                    color.alphaComponent > 0.1 && color.greenComponent > color.redComponent + 0.08
                    && color.greenComponent > color.blueComponent + 0.08
            }
        }
        var result: [CGRect] = []
        for start in green.indices where green[start] {
            green[start] = false
            var queue = [start]
            var cursor = 0
            var minX = start % width
            var maxX = minX
            var minY = start / width
            var maxY = minY
            while cursor < queue.count {
                let pixel = queue[cursor]
                cursor += 1
                let x = pixel % width
                let y = pixel / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let next = ny * width + nx
                    if green[next] {
                        green[next] = false
                        queue.append(next)
                    }
                }
            }
            result.append(
                CGRect(
                    x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1),
                    height: CGFloat(maxY - minY + 1)))
        }
        return result
    }

    func testExportCompositeIconLightAndDarkFixturesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VIBEPIER_TASK_ICON_PREVIEW_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VIBEPIER_TASK_ICON_PREVIEW_DIR to export the AppKit composite fixtures")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = try symbolBase()
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let size = NSSize(width: 460, height: 340)
        for (name, appearance) in [("light", light), ("dark", dark)] {
            let image = try bitmap(size: size, appearance: appearance) {
                drawSheet(base: base, appearance: appearance, dark: name == "dark", offset: 0)
            }
            try save(image, to: directory.appendingPathComponent("task-composite-fixtures-\(name).png"))
        }
        let comparison = try bitmap(size: NSSize(width: size.width * 2, height: size.height), appearance: light) {
            drawSheet(base: base, appearance: light, dark: false, offset: 0)
            drawSheet(base: base, appearance: dark, dark: true, offset: size.width)
        }
        try save(comparison, to: directory.appendingPathComponent("task-composite-fixtures-comparison.png"))
        try
            "AppKit TaskActivityCompositeIcon · SYNTHETIC COMPONENT FIXTURES · NOT LIVE SCREENSHOTS\n4x pixels; real production NSImage drawing handler; explicit aqua/darkAqua drawing appearance; six activity states; no production data or settings.\n"
            .write(
                to: directory.appendingPathComponent("task-composite-fixtures.txt"), atomically: true, encoding: .utf8)
    }

    private func symbolBase() throws -> NSImage {
        let symbol = try XCTUnwrap(NSImage(systemSymbolName: "waveform", accessibilityDescription: nil))
        let source = try XCTUnwrap(symbol.withSymbolConfiguration(.init(pointSize: 15, weight: .medium)))
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            let scale = min(16 / source.size.width, 16 / source.size.height)
            let width = source.size.width * scale
            let height = source.size.height * scale
            source.draw(
                in: NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
            )
            return true
        }
        image.isTemplate = true
        return image
    }
    private func drawSheet(base: NSImage, appearance: NSAppearance, dark: Bool, offset: CGFloat) {
        appearance.performAsCurrentDrawingAppearance {
            let background = dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.98, alpha: 1)
            background.setFill()
            NSBezierPath(rect: NSRect(x: offset, y: 0, width: 460, height: 340)).fill()
            func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false) {
                NSAttributedString(
                    string: value,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
                .draw(at: NSPoint(x: offset + x, y: y))
            }
            text("AppKit TaskActivityCompositeIcon · FIXTURE", x: 14, y: 312, size: 15, bold: true)
            text("\(dark ? "深色" : "浅色") · 组件图，非实机截图 · 4× 像素 · 图标高度 18pt", x: 14, y: 294, size: 10)
            let cases = [
                ("无任务", 0, 0), ("1 个运行任务", 1, 0), ("3 个未查看完成", 0, 3), ("运行 + 3 个完成", 1, 3), ("运行 + 25 个完成", 1, 25),
                ("运行 + 257 个完成", 1, 257),
            ]
            for (index, entry) in cases.enumerated() {
                let y = CGFloat(253 - index * 42)
                let activity = activity(running: entry.1, unread: entry.2)
                let image = TaskActivityCompositeIcon.image(base: base, activity: activity)
                text(entry.0, x: 14, y: y + 5, size: 12, bold: true)
                text("\(entry.1) 运行 · \(entry.2) 未查看 · \(image.size.width.formatted())pt", x: 14, y: y - 9, size: 10)
                (dark ? NSColor(white: 0.23, alpha: 1) : NSColor(white: 0.90, alpha: 1)).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: offset + 225, y: y - 3, width: 205, height: 24), xRadius: 3, yRadius: 3
                ).fill()
                image.draw(
                    in: NSRect(x: offset + 235, y: y, width: image.size.width, height: image.size.height), from: .zero,
                    operation: .sourceOver, fraction: 1)
            }
            text("静态测试数据；未读取真实会话、设备或网络。", x: 14, y: 15, size: 10)
        }
    }
    private func save(_ image: NSBitmapImageRep, to file: URL) throws {
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try png.write(to: file, options: .atomic)
    }
}
