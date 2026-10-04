import Foundation
import VibeKit

/// A deliberate allowlist: never serialize Config or a device/provider store wholesale.
struct PreferencesArchive: Codable {
    struct KeyAction: Codable {
        var keys: String
        var on: String?
        var keysOn: String?
        var keysMode: String?
        var sequential: Bool?
        var switchInput: Bool?
    }
    struct MacSettings: Codable {
        var firmwareButtons: [String: String]?
        var keyboardActions: [String: KeyAction]?
        var hardware: Settings?
        var applicationShortcuts: [String]?
        var heartbeatMode: String?
        var replayBindings: Bool?
    }
    var format = "vibepier-preferences"
    var version = 1
    var mac: MacSettings
    var phoneBindings: [String: PhoneBindings.PortableEntry]
    static let maximumBytes = 256 * 1024

    init(config: Config, bindings: PhoneBindings.Snapshot) {
        mac = MacSettings(
            firmwareButtons: config.buttons,
            keyboardActions: config.actions?.compactMapValues { action in
                guard let keys = action.keys else { return nil }
                return KeyAction(
                    keys: keys, on: action.on, keysOn: action.keysOn, keysMode: action.keysMode,
                    sequential: action.sequential, switchInput: action.switchInput)
            }, hardware: config.settings, applicationShortcuts: config.applicationShortcuts,
            heartbeatMode: config.heartbeatMode, replayBindings: config.replayBindings)
        phoneBindings = bindings.entries.compactMapValues { entry in
            entry.value.map { PhoneBindings.PortableEntry(value: $0, name: entry.name, label: entry.label) }
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CLIError(L10n.text("core.the_settings_archive_exceeds_256_kib")) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else {
            throw CLIError(L10n.text("core.the_settings_archive_exceeds_256_kib"))
        }
        return data
    }

    func validate() throws {
        guard format == "vibepier-preferences", version == 1 else {
            throw CLIError(L10n.text("core.unsupported_settings_archive_version"))
        }
        for (name, value) in mac.firmwareButtons ?? [:] {
            guard let control = Control(name: name), value.count <= 200 else {
                throw CLIError(L10n.text("core.invalid_device_key_settings"))
            }
            _ = try Apply.target(value, control: control)
        }
        for (name, action) in mac.keyboardActions ?? [:] {
            guard Control(name: name) != nil, action.keys.count <= 200,
                action.on.map({ ["press", "release", "both"].contains($0) }) ?? true,
                action.keysOn.map({ ["press", "release", "both"].contains($0) }) ?? true,
                action.keysMode.map({ ["tap", "hold"].contains($0) }) ?? true
            else { throw CLIError(L10n.text("core.invalid_desktop_shortcut_settings")) }
            _ = try Hotkey.parseHIDCodes(action.keys)
        }
        if let mode = mac.heartbeatMode, HeartbeatMode(rawValue: mode) == nil {
            throw CLIError(L10n.text("core.invalid_heartbeat_mode"))
        }
        if let value = mac.hardware {
            guard value.brightness.map({ $0 <= 20 }) ?? true,
                value.motorStrength.map({ $0 <= 255 }) ?? true,
                value.lightMode.map({ $0 <= 2 }) ?? true
            else { throw CLIError(L10n.text("core.device_brightness_vibration_or_light_mode_is_out_of_range")) }
        }
        if let ids = mac.applicationShortcuts {
            guard ids.count <= 256 else { throw CLIError(L10n.text("core.too_many_app_shortcuts")) }
            for (index, id) in ids.enumerated() {
                _ = try ApplicationShortcuts.applying(.set(index: index, bundleID: id), to: ids)
            }
        }
        try PhoneBindings.validatePortable(phoneBindings)
    }

    /// Merge included sections, preserving destination secrets, scripts, paths, privacy choices and enrollment.
    func merging(into current: Config) throws -> Config {
        try validate()
        var next = current
        if let buttons = mac.firmwareButtons {
            next.buttons = (current.buttons ?? [:]).merging(buttons) { _, new in new }
        }
        if let actions = mac.keyboardActions {
            var merged = current.actions ?? [:]
            for (name, portable) in actions {
                var action = merged[name] ?? HostAction()
                action.keys = portable.keys
                action.on = portable.on
                action.keysOn = portable.keysOn
                action.keysMode = portable.keysMode
                action.sequential = portable.sequential
                action.switchInput = portable.switchInput
                merged[name] = action
            }
            next.actions = merged
        }
        if let hardware = mac.hardware { next.settings = hardware }
        if let ids = mac.applicationShortcuts { next.applicationShortcuts = ids }
        if let mode = mac.heartbeatMode { next.heartbeatMode = mode }
        if let replay = mac.replayBindings { next.replayBindings = replay }
        return next
    }

    /// Each store commits atomically. If the second store fails, restore the original config before returning.
    func apply(to current: Config, bindings: PhoneBindings, save: (Config) throws -> Void) throws -> Config {
        let next = try merging(into: current)
        try bindings.validateMerge(phoneBindings)
        try save(next)
        do { try bindings.mergePortable(phoneBindings) } catch {
            do { try save(current) } catch {
                throw CLIError(L10n.text("core.could_not_save_phone_bindings_or_roll_back_the_main_configuration_ch"))
            }
            throw error
        }
        return next
    }
}
