import CoreAudio
import Foundation

/// Only the talk action touches this state. Device-list changes invalidate the
/// cache through a CoreAudio notification, with no polling or per-press files.
final class TalkInputRouter: @unchecked Sendable {
    static let shared = TalkInputRouter(observeDevices: true)
    typealias Device = AudioManager.InputDevice
    private let lock = NSLock()
    private let list: @Sendable () -> [Device]
    private let current: @Sendable () -> Device?
    private let select: @Sendable (Device) -> Bool
    private var cachedDevices: [Device]?
    private var previous: Device?
    private var listener: AudioObjectPropertyListenerBlock?
    private let notifications = DispatchQueue(label: "vibepier.audio-devices")

    init(
        observeDevices: Bool = false,
        list: @escaping @Sendable () -> [Device] = { AudioManager.inputDevices() },
        current: @escaping @Sendable () -> Device? = { AudioManager.defaultInputDevice() },
        select: @escaping @Sendable (Device) -> Bool = { AudioManager.setDefaultInputDevice($0) }
    ) {
        self.list = list
        self.current = current
        self.select = select
        if observeDevices {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.invalidateDevices() }
            self.listener = listener
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, notifications, listener)
        }
    }

    deinit {
        if let listener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, notifications, listener)
        }
    }

    func invalidateDevices() { lock.withLock { cachedDevices = nil } }

    private func devices() -> [Device] {
        if let cachedDevices { return cachedDevices }
        let result = list()
        cachedDevices = result
        return result
    }

    func press() throws {
        try lock.withLock {
            guard previous == nil else { return }
            guard let original = current() else {
                throw CLIError(L10n.text("control.could_not_read_the_current_input_device"))
            }
            var target = devices().first { $0.name.contains("AU05") }
            if target == nil {
                cachedDevices = nil
                target = devices().first { $0.name.contains("AU05") }
            }
            // Without AU05, for example from the phone remote, dictate with the current input.
            guard let target else { return }
            if original.uid != target.uid && !select(target) {
                cachedDevices = nil
                guard let fresh = devices().first(where: { $0.uid == target.uid }), select(fresh) else {
                    throw CLIError(L10n.text("control.could_not_switch_to_au05"))
                }
            }
            previous = original
        }
    }

    func release() throws {
        try lock.withLock {
            guard let original = previous else { return }
            // Respect a manual input change made while the talk key was held.
            guard current()?.name.contains("AU05") == true else {
                previous = nil
                return
            }
            let target =
                devices().first { $0.uid == original.uid }
                ?? devices().first { $0.name.contains("MacBook") }
                ?? devices().first { !$0.name.contains("AU05") }
            guard let target else { throw CLIError(L10n.text("control.no_input_device_is_available_to_restore")) }
            if !select(target) {
                cachedDevices = nil
                guard let fresh = devices().first(where: { $0.uid == target.uid }), select(fresh) else {
                    throw CLIError(L10n.text("control.could_not_restore_the_previous_input_device"))
                }
            }
            previous = nil
        }
    }
}
