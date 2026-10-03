import AppKit
import Foundation

public struct ApplicationShortcut: Codable, Sendable, Identifiable {
    public var id: Int { slot }
    public let slot: Int
    public let bundleID: String
    public let name: String
    public let iconPNG: String
    public let available: Bool
}

enum ApplicationShortcutChange {
    case set(index: Int, bundleID: String)
    case add(bundleID: String)
    case remove(index: Int)
    case move(index: Int, target: Int)
}

enum ApplicationShortcutAction: String, Sendable {
    case activate, hide
}

/// Cached on configuration changes; no app enumeration or image work per heartbeat.
final class ApplicationShortcuts: @unchecked Sendable {
    static let shared = ApplicationShortcuts()
    static let changed = Notification.Name("io.github.junweiup.vibepier.applicationShortcutsChanged")
    static let minimumSlots = 5
    private let lock = NSLock()
    private var entries: [ApplicationShortcut] = (0..<ApplicationShortcuts.minimumSlots).map {
        ApplicationShortcut(slot: $0, bundleID: "", name: L10n.text("control.not_set"), iconPNG: "", available: false)
    }
    private var revision = UUID().uuidString
    @MainActor private var launching = false

    static func normalized(_ ids: [String]?) -> [String] {
        let values = ids ?? []
        return values + Array(repeating: "", count: max(0, minimumSlots - values.count))
    }

    /// Preserve old five-position configurations while allowing the list to grow.
    static func applying(_ change: ApplicationShortcutChange, to ids: [String]?) throws -> [String] {
        var values = normalized(ids)
        func validate(_ bundleID: String) throws {
            guard bundleID.count <= 255,
                bundleID.isEmpty
                    || (bundleID.contains(".") && !bundleID.contains(where: { $0.isWhitespace || $0 == "/" }))
            else { throw CLIError(L10n.text("core.invalid_application_identifier")) }
        }
        switch change {
        case .set(let index, let bundleID):
            guard values.indices.contains(index) else { throw CLIError(L10n.text("core.invalid_application_slot")) }
            try validate(bundleID)
            values[index] = bundleID
        case .add(let bundleID):
            try validate(bundleID)
            guard !bundleID.isEmpty else { throw CLIError(L10n.text("control.choose_an_application_to_add")) }
            if let empty = values.firstIndex(of: "") { values[empty] = bundleID } else { values.append(bundleID) }
        case .remove(let index):
            guard values.indices.contains(index) else { throw CLIError(L10n.text("core.invalid_application_slot")) }
            if values.count > minimumSlots { values.remove(at: index) } else { values[index] = "" }
        case .move(let index, let target):
            guard values.indices.contains(index) else { throw CLIError(L10n.text("core.invalid_application_slot")) }
            guard values.indices.contains(target) else { throw CLIError(L10n.text("core.invalid_destination_slot")) }
            values.swapAt(index, target)
        }
        return values
    }
    var snapshot: (revision: String, entries: [ApplicationShortcut]) {
        lock.withLock { (revision, entries) }
    }
    @MainActor func configure(_ ids: [String]?) {
        let values = Self.normalized(ids)
        if snapshot.entries.map(\.bundleID) == values { return }
        let updated = values.enumerated().map { slot, id in
            let url = id.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            }
            return ApplicationShortcut(
                slot: slot, bundleID: id, name: name ?? (id.isEmpty ? L10n.text("control.not_set") : id),
                iconPNG: url.map(Self.icon) ?? "", available: url != nil)
        }
        lock.withLock {
            entries = updated
            revision = UUID().uuidString
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
        NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: nil)
    }
    @MainActor private static func icon(_ url: URL) -> String {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        // 128 physical pixels cover a 32dp icon even on 4x-density Android screens.
        for edge in [128] {
            guard
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap)
            else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            source.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge))
            NSGraphicsContext.restoreGraphicsState()
            if let data = bitmap.representation(using: .png, properties: [:]), data.count <= 80000 {
                return data.base64EncodedString()
            }
        }
        return ""
    }
    func frames(sender: String) -> [Data] {
        let state = snapshot
        return state.entries.flatMap { item -> [Data] in
            let bytes = Array(item.iconPNG.utf8)
            let count = max(1, (bytes.count + 899) / 900)
            return (0..<count).compactMap { part in
                let start = min(part * 900, bytes.count)
                let chunk = String(decoding: bytes[start..<min(start + 900, bytes.count)], as: UTF8.self)
                return try? JSONSerialization.data(withJSONObject: [
                    "type": "vibepier-slot1", "sender": sender,
                    "revision": state.revision, "count": state.entries.count, "slot": item.slot,
                    "bundleID": item.bundleID,
                    "name": item.name, "iconPNG": chunk, "iconPart": part, "iconParts": count,
                    "available": item.available,
                ])
            }
        }
    }

    /// Current-app slot is ephemeral. A delayed click must never open its former app.
    static func validationError(
        slot: Int, bundleID: String, action: ApplicationShortcutAction,
        entries: [ApplicationShortcut], frontmost: String, locked: Bool
    ) -> String? {
        guard !bundleID.isEmpty else {
            return L10n.text("control.the_application_settings_changed_select_the_app_again")
        }
        if slot == -1 {
            guard bundleID == frontmost else { return L10n.text("control.the_active_mac_app_changed_select_it_again") }
        } else {
            guard let item = entries.first(where: { $0.slot == slot }),
                !item.bundleID.isEmpty, item.bundleID == bundleID
            else { return L10n.text("control.the_application_settings_changed_select_the_app_again") }
        }
        if action == .hide {
            guard !locked else { return L10n.text("control.the_mac_is_locked_unlock_it_before_hiding_the_app") }
            guard bundleID == frontmost else { return L10n.text("control.the_active_mac_app_changed_select_it_again") }
        }
        return nil
    }

    @MainActor func perform(slot: Int, bundleID: String, action: ApplicationShortcutAction) async -> String? {
        switch action {
        case .activate: return await activate(slot: slot, bundleID: bundleID)
        case .hide: return hide(slot: slot, bundleID: bundleID)
        }
    }

    /// Hide only the still-active target; do not activate an old app before hiding it.
    @MainActor func hide(slot: Int, bundleID: String) -> String? {
        guard !launching else { return L10n.text("control.the_application_is_opening_retry_shortly") }
        let app = NSWorkspace.shared.frontmostApplication
        if let error = Self.validationError(
            slot: slot, bundleID: bundleID, action: .hide,
            entries: snapshot.entries, frontmost: app?.bundleIdentifier ?? "",
            locked: ScreenLock.locked())
        {
            return error
        }
        guard let app, app.isActive, app.bundleIdentifier == bundleID else {
            return L10n.text("control.the_active_mac_app_changed_select_it_again")
        }
        return app.hide() ? nil : L10n.text("control.could_not_hide_0", app.localizedName ?? bundleID)
    }

    /// Only the Mac-configured bundle at this slot may be opened, never an arbitrary phone path.
    @MainActor func activate(slot: Int, bundleID: String) async -> String? {
        guard !launching else { return L10n.text("control.the_application_is_opening_retry_shortly") }
        let state = snapshot
        if let error = Self.validationError(
            slot: slot, bundleID: bundleID, action: .activate,
            entries: state.entries, frontmost: FrontmostApplication.current().bundleID,
            locked: ScreenLock.locked())
        {
            return error
        }
        // This entry already is the foreground app, so it never needs launching.
        if slot == -1 { return nil }
        guard let item = state.entries.first(where: { $0.slot == slot }) else {
            return L10n.text("control.the_application_settings_changed_select_the_app_again")
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) else {
            return L10n.text("control.application_not_found_0", item.name)
        }
        launching = true
        defer { launching = false }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: options)
            return nil
        } catch { return L10n.text("control.could_not_open_0_1", item.name, error.localizedDescription) }
    }
}
