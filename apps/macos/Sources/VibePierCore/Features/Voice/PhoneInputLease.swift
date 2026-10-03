import Foundation

/// A temporary default-input change owned exclusively by a phone talk gesture.
/// Persist before switching so a process crash cannot leave the phone input selected.
final class PhoneInputLease {
    typealias Device = AudioManager.InputDevice
    private struct Lease: Codable {
        let originalUID: String
        let phoneUID: String
    }
    private let file: URL
    private let devices: () -> [Device]
    private let current: () -> Device?
    private let select: (Device) -> Bool
    private var lease: Lease?

    init(
        file: URL = Paths.supportDirectory.appendingPathComponent("phone-input-lease.json"),
        devices: @escaping () -> [Device] = { AudioManager.inputDevices() },
        current: @escaping () -> Device? = { AudioManager.defaultInputDevice() },
        select: @escaping (Device) -> Bool = { AudioManager.setDefaultInputDevice($0) }
    ) {
        self.file = file
        self.devices = devices
        self.current = current
        self.select = select
    }
    @discardableResult func recover() -> Bool {
        loadPending() && restore()
    }
    func begin(target: Device) throws {
        guard loadPending(), restore() else {
            throw CLIError(L10n.text("control.the_previous_microphone_has_not_been_restored_yet_retry_shortly"))
        }
        guard let existing = current() else {
            throw CLIError(L10n.text("control.could_not_read_the_mac_s_current_microphone"))
        }
        // A previously selected phone channel must never become the normal idle input.
        guard let original = existing.uid == target.uid ? fallback(excluding: target.uid) : existing else {
            throw CLIError(L10n.text("control.no_mac_microphone_is_available_to_restore"))
        }
        let saved = Lease(originalUID: original.uid, phoneUID: target.uid)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        lease = saved
        guard select(target), current()?.uid == target.uid else {
            _ = restore()
            throw CLIError(L10n.text("control.could_not_temporarily_switch_to_the_phone_microphone"))
        }
    }
    private func loadPending() -> Bool {
        // Every entry point must honor a pending crash-recovery record, including
        // begin() after startup recovery failed. Never overwrite unreadable state.
        if lease == nil, FileManager.default.fileExists(atPath: file.path) {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size <= 4096, let data = try? Data(contentsOf: file),
                let saved = try? JSONDecoder().decode(Lease.self, from: data),
                !saved.originalUID.isEmpty, !saved.phoneUID.isEmpty,
                saved.originalUID != saved.phoneUID
            else { return false }
            lease = saved
        }
        return true
    }
    @discardableResult func restore() -> Bool {
        guard let saved = lease else { return true }
        guard let selected = current() else { return false }
        if selected.uid == saved.phoneUID {
            guard
                let original = devices().first(where: { $0.uid == saved.originalUID && $0.uid != saved.phoneUID })
                    ?? fallback(excluding: saved.phoneUID), select(original), current()?.uid == original.uid
            else { return false }
        }
        // A manual selection made during a gesture takes precedence.
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            lease = nil
            return true
        } catch { return false }
    }
    private func fallback(excluding uid: String) -> Device? {
        let available = devices().filter { $0.uid != uid && !$0.name.hasPrefix("BlackHole") }
        return available.first { $0.name.contains("MacBook") || $0.name.contains("Built-in") }
            ?? available.first
    }
}
