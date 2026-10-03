#!/usr/bin/env swift
// SPDX-License-Identifier: MIT
// Deterministic vector artwork and platform exports. Run from the repository root.
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brand = root.appendingPathComponent("assets/brand")
let mac = root.appendingPathComponent("apps/macos/Resources")
let android = root.appendingPathComponent("apps/android/app/src/main/res")
for directory in [brand, mac] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
let mint = NSColor(srgbRed: 114 / 255, green: 212 / 255, blue: 185 / 255, alpha: 1)
let graphite = NSColor(srgbRed: 15 / 255, green: 20 / 255, blue: 22 / 255, alpha: 1)
let curve = "M280 310 L454 626 Q480 674 509 626 L650 358"
let deck = "M288 752 H736"
let svgMark = """
<g fill="none" stroke="#72D4B9" stroke-width="96" stroke-linecap="round" stroke-linejoin="round">
  <path d="\(curve)"/>
  <path d="\(deck)"/>
</g>
<circle cx="718" cy="230" r="57" fill="#72D4B9"/>
"""
func svg(background: Bool) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="VibePier: work within reach">
    \(background ? "<rect width=\"1024\" height=\"1024\" rx=\"224\" fill=\"#0F1416\"/>" : "")
    \(svgMark)
    </svg>
    """
}
try svg(background: true).write(to: brand.appendingPathComponent("icon.svg"), atomically: true, encoding: .utf8)
try svg(background: false).write(to: brand.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)
func image(size: Int, background: Bool) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(m11: CGFloat(size) / 1024, m12: 0, m21: 0, m22: -CGFloat(size) / 1024, tX: 0, tY: CGFloat(size))
    (transform as NSAffineTransform).concat()
    if background {
        graphite.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024), xRadius: 224, yRadius: 224).fill()
    }
    mint.setStroke()
    let v = NSBezierPath(); v.move(to: NSPoint(x: 280, y: 310)); v.line(to: NSPoint(x: 454, y: 626))
    // Quadratic (454,626) -> (509,626) with control (480,674), converted exactly to cubic.
    v.curve(to: NSPoint(x: 509, y: 626), controlPoint1: NSPoint(x: 471.333333, y: 658), controlPoint2: NSPoint(x: 489.666667, y: 658))
    v.line(to: NSPoint(x: 650, y: 358)); v.lineWidth = 96; v.lineCapStyle = .round; v.lineJoinStyle = .round; v.stroke()
    let pier = NSBezierPath(); pier.move(to: NSPoint(x: 288, y: 752)); pier.line(to: NSPoint(x: 736, y: 752))
    pier.lineWidth = 96; pier.lineCapStyle = .round; pier.stroke()
    mint.setFill(); NSBezierPath(ovalIn: NSRect(x: 661, y: 173, width: 114, height: 114)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
try image(size: 1024, background: true).write(to: brand.appendingPathComponent("icon.png"))
try image(size: 1024, background: false).write(to: brand.appendingPathComponent("mark.png"))
let iconset = root.appendingPathComponent(".local/VibePier.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        try image(size: points * scale, background: true).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", mac.appendingPathComponent("VibePier.icns").path]
try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
let vector = """
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="1024" android:viewportHeight="1024">
    <group android:scaleX="0.72" android:scaleY="0.72" android:translateX="143.36" android:translateY="143.36">
        <path android:pathData="\(curve)" android:fillColor="#00000000" android:strokeColor="#72D4B9" android:strokeWidth="96" android:strokeLineCap="round" android:strokeLineJoin="round"/>
        <path android:pathData="\(deck)" android:fillColor="#00000000" android:strokeColor="#72D4B9" android:strokeWidth="96" android:strokeLineCap="round"/>
        <path android:pathData="M775,230 A57,57 0,1 1,661,230 A57,57 0,1 1,775,230" android:fillColor="#72D4B9"/>
    </group>
</vector>
"""
try vector.write(to: android.appendingPathComponent("drawable/ic_launcher_foreground.xml"), atomically: true, encoding: .utf8)
try vector.replacingOccurrences(of: "#72D4B9", with: "#FFFFFFFF").write(to: android.appendingPathComponent("drawable/ic_launcher_monochrome.xml"), atomically: true, encoding: .utf8)
print("Generated editable brand artwork, macOS icon, and Android adaptive icon layers.")
