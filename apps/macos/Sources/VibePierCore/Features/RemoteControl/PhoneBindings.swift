import Foundation
import VibeKit

/// Shared phone preferences. A separate atomic file avoids racing hardware configuration saves.
public final class PhoneBindings: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var value: String?
        public var generation: Int64
        public var version: String
        public var operation: String
        public var name: String
    }
    public struct Snapshot: Codable, Sendable {
        public var revision: String
        public var server: String
        public var generation: Int64
        public var entries: [String: Entry]
    }
    public static let shared = PhoneBindings(url: Paths.supportDirectory.appendingPathComponent("phone-bindings.json"))
    public static let changed = Notification.Name("VibePhoneBindingsChanged")
    public static let controls = ["knob-left", "knob-right", "cancel", "confirm", "talk", "knob-press"]
    public static let defaults = [
        "knob-left": "wheel-up", "knob-right": "wheel-down", "cancel": "escape", "confirm": "return", "talk": "rcmd",
        "knob-press": "backspace",
    ]
    private let lock = NSLock()
    private let url: URL
    private var state: Snapshot
    private var loadError: Error?
    init(url: URL) {
        self.url = url
        state = Snapshot(revision: UUID().uuidString, server: UUID().uuidString, generation: 0, entries: [:])
        if FileManager.default.fileExists(atPath: url.path) {
            do { state = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url)) } catch {
                loadError = error
            }
        }
    }
    public var snapshot: Snapshot { lock.withLock { state } }

    struct PortableEntry: Codable, Equatable {
        var value: String
        var name: String
    }
    static func validatePortable(_ entries: [String: PortableEntry]) throws {
        guard entries.count <= 256 else { throw CLIError(L10n.text("control.you_can_import_up_to_256_phone_bindings")) }
        for (key, entry) in entries {
            let valid =
                controls.contains { key == Self.key($0) }
                || application(for: key).map { !$0.isEmpty && $0.count <= 200 && !$0.contains(where: \.isWhitespace) }
                    == true
            guard valid, key.count <= 240, entry.name.count <= 200, entry.value.count <= 200 else {
                throw CLIError(L10n.text("control.invalid_phone_binding_settings"))
            }
            _ = try normalize(entry.value)
        }
    }
    func validateMerge(_ entries: [String: PortableEntry]) throws {
        try Self.validatePortable(entries)
        try lock.withLock {
            if let loadError { throw loadError }
            guard Set(state.entries.keys).union(entries.keys).count <= 256 else {
                throw CLIError(L10n.text("control.merging_would_exceed_256_phone_bindings"))
            }
            guard state.generation <= Int64.max - Int64(entries.count) else {
                throw CLIError(L10n.text("control.phone_binding_versions_are_exhausted"))
            }
        }
    }
    /// Preserve the destination server identity and give changed keys new conflict-resolution versions.
    func mergePortable(_ entries: [String: PortableEntry]) throws {
        try Self.validatePortable(entries)
        let changed: Bool = try lock.withLock {
            if let loadError { throw loadError }
            guard Set(state.entries.keys).union(entries.keys).count <= 256,
                state.generation <= Int64.max - Int64(entries.count)
            else { throw CLIError(L10n.text("control.phone_binding_count_or_version_is_out_of_range")) }
            var next = state
            var modified = false
            for (key, entry) in entries {
                let normalized = try Self.normalize(entry.value)
                if next.entries[key]?.value == normalized && next.entries[key]?.name == entry.name { continue }
                modified = true
                next.generation += 1
                next.entries[key] = Entry(
                    value: normalized, generation: next.generation,
                    version: UUID().uuidString, operation: UUID().uuidString, name: entry.name)
            }
            guard modified else { return false }
            next.revision = UUID().uuidString
            let data = try JSONEncoder().encode(next)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            state = next
            return true
        }
        if changed { NotificationCenter.default.post(name: Self.changed, object: self) }
    }
    public static func key(_ control: String, app: String = "") -> String {
        app.isEmpty ? "keys.\(control)" : "app.\(app).keys.\(control)"
    }
    public static func application(for key: String) -> String? {
        guard key.hasPrefix("app."), let control = controls.first(where: { key.hasSuffix(".keys.\($0)") }) else {
            return nil
        }
        return String(key.dropFirst(4).dropLast(".keys.\(control)".count))
    }
    public static func normalize(_ value: String) throws -> String {
        let codes = try Hotkey.parseHIDCodes(value)
        let names = codes.compactMap(Hotkey.name(forHIDCode:))
        guard names.count == codes.count else { throw CLIError(L10n.text("control.unsupported_key")) }
        return names.joined(separator: "+")
    }
    public static func label(_ text: String) -> String {
        guard let codes = try? Hotkey.parseHIDCodes(text) else { return text }
        let labels: [UInt16: String] = [
            0xE0: "⌃", 0xE1: "⇧", 0xE2: "⌥", 0xE3: "⌘", 0xE4: L10n.text("control.right"),
            0xE5: L10n.text("control.right_2"), 0xE6: L10n.text("control.right_3"), 0xE7: L10n.text("control.right_4"),
            2: "fn", 0x28: L10n.text("control.return"), 0x29: "Esc", 0x2A: "⌫", 0x2B: "Tab",
            0x2C: L10n.text("control.space"), 0x4C: "⌦", 0x4F: "→", 0x50: "←",
            0x51: "↓", 0x52: "↑", 0x105: L10n.text("control.wheel"), 0x106: L10n.text("control.wheel_2"),
        ]
        return codes.map { labels[$0] ?? Hotkey.name(forHIDCode: $0)?.uppercased() ?? "?" }.joined(separator: " ")
    }
    public static func hasModifier(_ text: String, modifier: String) -> Bool {
        guard let code = Hotkey.code(forName: modifier), let codes = try? Hotkey.parseHIDCodes(text) else {
            return false
        }
        return codes.contains(code)
    }
    public static func togglingModifier(_ text: String, modifier: String, enabled: Bool) throws -> String {
        guard let code = Hotkey.code(forName: modifier), (0xE0...0xE7).contains(code) else {
            throw CLIError(L10n.text("control.unknown_modifier_key"))
        }
        var codes = text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : try Hotkey.parseHIDCodes(text)
        codes.removeAll { $0 == code }
        if enabled { codes.insert(code, at: 0) }
        if codes.isEmpty { return "" }
        return try normalize(codes.compactMap(Hotkey.name(forHIDCode:)).joined(separator: "+"))
    }
    public static func choosingPreset(_ preset: String, text: String) throws -> String {
        let selected = try Hotkey.parseHIDCodes(preset)
        if selected.contains(where: { (0xE0...0xE7).contains($0) || $0 == 2 }) { return try normalize(preset) }
        let existing = text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : try Hotkey.parseHIDCodes(text)
        let modifiers = existing.filter { (0xE0...0xE7).contains($0) || $0 == 2 }
        return try normalize((modifiers + selected).compactMap(Hotkey.name(forHIDCode:)).joined(separator: "+"))
    }
    /// nil expectedVersion is a local edit. Empty means first migration; tombstones still win.
    @discardableResult public func set(
        key: String, value: String?, name: String = "", expectedVersion: String? = nil,
        operation: String = UUID().uuidString
    ) throws -> Bool {
        let valid =
            Self.controls.contains { key == Self.key($0) }
            || Self.application(for: key).map { !$0.isEmpty && $0.count <= 200 && !$0.contains(where: \.isWhitespace) }
                == true
        guard valid, key.count <= 240, name.count <= 200, operation.count <= 80 else {
            throw CLIError(L10n.text("control.invalid_phone_binding_settings"))
        }
        let normalized = try value.map(Self.normalize)
        let result: (accepted: Bool, changed: Bool) = try lock.withLock {
            if let loadError { throw loadError }
            if state.entries[key]?.operation == operation { return (true, false) }
            if let expectedVersion, expectedVersion != (state.entries[key]?.version ?? "") { return (false, false) }
            guard state.entries[key] != nil || state.entries.count < 256 else {
                throw CLIError(L10n.text("control.you_can_save_up_to_256_bindings"))
            }
            var next = state
            next.revision = UUID().uuidString
            next.generation += 1
            next.entries[key] = Entry(
                value: normalized, generation: next.generation, version: UUID().uuidString, operation: operation,
                name: name)
            let data = try JSONEncoder().encode(next)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            state = next
            return (true, true)
        }
        if result.changed { NotificationCenter.default.post(name: Self.changed, object: self) }
        return result.accepted
    }
    public func resolved(_ control: String, app: String = "") -> String {
        let entries = snapshot.entries
        return entries[Self.key(control, app: app)]?.value ?? entries[Self.key(control)]?.value ?? Self.defaults[
            control] ?? ""
    }
    /// Call only after the transport verifies an active subscribed peer.
    func reply(to text: String, sender: String) -> [Data]? {
        guard let data = text.data(using: .utf8), data.count <= 4096,
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            request["sender"] as? String == sender
        else { return nil }
        let type = request["type"] as? String
        if type == "vibepier-bindings-get1" {
            let snapshot = self.snapshot
            guard let data = try? JSONEncoder().encode(snapshot) else { return [] }
            let encoded = Array(data.base64EncodedString())
            let count = max(1, (encoded.count + 899) / 900)
            return (0..<count).compactMap { part in
                try? JSONSerialization.data(withJSONObject: [
                    "type": "vibepier-bindings1", "sender": sender,
                    "revision": snapshot.revision, "part": part, "parts": count,
                    "data": String(encoded[(part * 900)..<min(encoded.count, (part + 1) * 900)]),
                ])
            }
        }
        guard type == "vibepier-binding-set1", let key = request["key"] as? String,
            let operation = request["operation"] as? String, let version = request["version"] as? String,
            request["value"] is String || request["value"] is NSNull
        else { return nil }
        var ack: [String: Any] = [
            "type": "vibepier-binding-ack1", "sender": sender, "operation": operation, "key": key,
            "server": snapshot.server,
        ]
        do {
            ack["accepted"] = try set(
                key: key, value: request["value"] as? String, name: request["name"] as? String ?? "",
                expectedVersion: version, operation: operation)
        } catch {
            ack["accepted"] = false
            ack["error"] = L10n.text("mac.could_not_save_0", error)
        }
        if let entry = snapshot.entries[key], let data = try? JSONEncoder().encode(entry) {
            ack["entry"] = try? JSONSerialization.jsonObject(with: data)
        }
        return (try? JSONSerialization.data(withJSONObject: ack)).map { [$0] } ?? []
    }
}
