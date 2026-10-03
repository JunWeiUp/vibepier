import AppKit
import Foundation

/// The dynamic first dock entry is independent of the configured application list.
/// App metadata and its 128px icon are refreshed only when the frontmost app changes.
final class CurrentApplicationShortcut: @unchecked Sendable {
    static let shared = CurrentApplicationShortcut()
    static let changed = Notification.Name("io.github.junweiup.vibepier.currentApplicationShortcutChanged")

    private let lock = NSLock()
    private var revision = UUID().uuidString
    private var entry = ApplicationShortcut(
        slot: -1, bundleID: "", name: L10n.text("control.unknown_application"), iconPNG: "", available: false)
    // Lifecycle access is restricted to the @MainActor methods below.
    private var observer: NSObjectProtocol?

    var snapshot: (revision: String, entry: ApplicationShortcut) {
        lock.withLock { (revision, entry) }
    }

    @MainActor func startObserving() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.observer != nil else { return }
                self.refresh()
            }
        }
        refresh()
    }

    @MainActor func stopObserving() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    @MainActor private func refresh() {
        let app = NSWorkspace.shared.frontmostApplication
        let url = app?.bundleURL
        let bundleID = app?.bundleIdentifier ?? url.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? ""
        let name =
            app?.localizedName
            ?? url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? L10n.text("control.unknown_application")
        let previous = snapshot.entry
        guard previous.bundleID != bundleID || previous.name != name else { return }
        let source = app?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        update(
            entry: ApplicationShortcut(
                slot: -1, bundleID: bundleID, name: name,
                iconPNG: source.map(Self.icon) ?? "", available: app != nil && !bundleID.isEmpty))
    }

    /// Injectable cache update; a repeated activation keeps both revision and icon stable.
    func update(entry value: ApplicationShortcut) {
        let didChange = lock.withLock {
            guard entry.bundleID != value.bundleID || entry.name != value.name else { return false }
            entry = ApplicationShortcut(
                slot: -1, bundleID: value.bundleID, name: value.name,
                iconPNG: value.iconPNG, available: value.available)
            revision = UUID().uuidString
            return true
        }
        guard didChange else { return }
        NotificationCenter.default.post(name: Self.changed, object: nil)
        NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: nil)
    }

    @MainActor private static func icon(_ source: NSImage) -> String {
        let edge = 128
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return "" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 80000 else { return "" }
        return data.base64EncodedString()
    }

    /// These frames are sent on explicit icon requests, never on the four-second status lease.
    func frames(sender: String) -> [Data] {
        let state = snapshot
        let bytes = Array(state.entry.iconPNG.utf8)
        let count = max(1, (bytes.count + 899) / 900)
        return (0..<count).compactMap { part in
            let start = min(part * 900, bytes.count)
            let chunk = String(decoding: bytes[start..<min(start + 900, bytes.count)], as: UTF8.self)
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: [
                        "type": "vibepier-current1", "sender": sender, "revision": state.revision,
                        "slot": -1, "bundleID": state.entry.bundleID, "name": state.entry.name,
                        "iconPNG": chunk, "iconPart": part, "iconParts": count, "available": state.entry.available,
                    ], options: [.sortedKeys]), data.count < 4096
            else { return nil }
            return data
        }
    }
}
