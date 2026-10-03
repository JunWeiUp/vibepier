import CoreAudio
import Foundation

/// System-wide audio input device enumeration and default-device switching
/// via the CoreAudio HAL. No special permission is required.
public enum AudioManager {
    public struct InputDevice: Identifiable, Equatable, Sendable {
        public let id: AudioDeviceID
        public let name: String
        public let uid: String
    }

    public static func inputDevices() -> [InputDevice] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        ids.withUnsafeMutableBufferPointer { ptr in
            _ = ptr.baseAddress.map { AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, $0) }
        }

        var devices: [InputDevice] = []
        for id in ids {
            guard hasInputChannels(id) else { continue }
            devices.append(
                InputDevice(
                    id: id,
                    name: deviceName(id) ?? "Device \(id)",
                    uid: deviceUID(id) ?? ""))
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func defaultInputDevice() -> InputDevice? {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var id: AudioDeviceID = 0
        var size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id) == noErr else {
            return nil
        }
        return InputDevice(id: id, name: deviceName(id) ?? "", uid: deviceUID(id) ?? "")
    }

    @discardableResult
    public static func setDefaultInputDevice(uid: String) -> Bool {
        // Resolve by UID because AudioDeviceIDs are not stable across replugs.
        guard let target = inputDevices().first(where: { $0.uid == uid }) else { return false }
        return setDefaultInputDevice(target)
    }

    @discardableResult
    public static func setDefaultInputDevice(_ target: InputDevice) -> Bool {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var id = target.id
        let size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(systemObject, &address, 0, nil, size, &id) == noErr
    }

    // MARK: - Helpers

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let buffer = malloc(Int(size))!
        defer { free(buffer) }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        var channels = 0
        let listPointer = buffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        for audioBuffer in UnsafeMutableAudioBufferListPointer(listPointer) {
            channels += Int(audioBuffer.mNumberChannels)
        }
        return channels > 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioObjectPropertyName)
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        // CoreAudio's name/UID contract transfers a retained CFString to the caller.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }
}
