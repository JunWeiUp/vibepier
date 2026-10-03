import AVFoundation
import AudioToolbox
import Foundation
import VibeKit

/// Independent IMA-ADPCM frames: LE predictor, step index, reserved byte, then low/high nibbles.
/// Each packet resets predictor state, so loss does not corrupt subsequent speech.
enum PhoneAudioCodec {
    static let steps = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    static let shifts = [-1, -1, -1, -1, 2, 4, 6, 8]
    static func decode(_ data: Data, samples: Int) -> [Float]? {
        let bytes = [UInt8](data)
        guard [160, 320, 480, 960].contains(samples), bytes.count == 4 + samples / 2, bytes[2] <= 88, bytes[3] == 0
        else { return nil }
        var predictor = Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8))
        var index = Int(bytes[2])
        var result = [Float(predictor) / 32768]
        for i in 0..<(samples - 1) {
            let nibble = Int((bytes[4 + i / 2] >> (i % 2 * 4)) & 15)
            let step = steps[index]
            var difference = step >> 3
            if nibble & 1 != 0 { difference += step >> 2 }
            if nibble & 2 != 0 { difference += step >> 1 }
            if nibble & 4 != 0 { difference += step }
            predictor = min(32767, max(-32768, predictor + (nibble & 8 != 0 ? -difference : difference)))
            index = min(88, max(0, index + shifts[nibble & 7]))
            result.append(Float(predictor) / 32768)
        }
        return result
    }
}

/// A live stream exists only while the phone holds talk. Never routes to speakers.
final class PhoneMicrophone: @unchecked Sendable {
    static let shared = PhoneMicrophone()
    private let prepareOverride: (@Sendable (Int) throws -> Void)?
    private let cleanupOverride: (@Sendable () -> Void)?
    private let pressKeys: @Sendable ([UInt16]) throws -> Void
    private let releaseKeys: @Sendable ([UInt16]) throws -> Void
    private let foreground: @Sendable () -> String
    init(
        prepare: (@Sendable (Int) throws -> Void)? = nil, cleanup: (@Sendable () -> Void)? = nil,
        press: @escaping @Sendable ([UInt16]) throws -> Void = { try KeySynth.press($0) },
        release: @escaping @Sendable ([UInt16]) throws -> Void = { try KeySynth.release($0) },
        foreground: @escaping @Sendable () -> String = { FrontmostApplication.current().bundleID }
    ) {
        prepareOverride = prepare
        cleanupOverride = cleanup
        pressKeys = press
        releaseKeys = release
        self.foreground = foreground
    }
    private let queue = DispatchQueue(label: "vibepier.phone-microphone")
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let inputLease = PhoneInputLease()
    private var owner = ""
    private var session = ""
    private var recent: [String] = []
    private var heldCodes: [UInt16] = []
    private var rate = 16000
    private var packetMs = 20
    private var missingPackets = 0
    private var droppedPackets = 0
    private var lastSequence = -1
    private var buffered = 0
    private var watchdog: DispatchWorkItem?
    private var packets = 0
    private var peak: Float = 0
    var active: Bool { queue.sync { !session.isEmpty } }
    var status: [String: Any] {
        queue.sync {
            [
                "active": !session.isEmpty, "packets": packets, "peak": peak, "sampleRate": rate,
                "engineRunning": engine?.isRunning ?? false, "bufferedFrames": buffered,
                "packetMs": packetMs, "missingPackets": missingPackets, "droppedPackets": droppedPackets,
                "driverAvailable": AudioManager.inputDevices().contains { $0.name == "BlackHole 2ch" },
            ]
        }
    }
    func recoverInputAfterRestart() {
        queue.sync {
            if !inputLease.recover() {
                FileHandle.standardError.write(Data("phone microphone: pending input recovery\n".utf8))
            }
        }
    }
    func stop() { queue.sync { finish() } }
    func disconnect(_ peer: String) { queue.async { if self.owner == peer { self.finish() } } }

    /// Both transports authenticate a subscribed endpoint before calling this function.
    func receive(_ text: String, peer: String, sender: String, canBegin: Bool = true) -> Data? {
        queue.sync {
            if text.hasPrefix("vibepier-audio1 ") {
                let fields = text.split(separator: " ")
                guard fields.count == 5, fields[1] == sender, owner == peer, fields[2] == session,
                    let sequence = Int(fields[3]), sequence > lastSequence, sequence <= 1_000_000_000,
                    let data = Data(base64Encoded: String(fields[4])),
                    let samples = PhoneAudioCodec.decode(data, samples: rate * packetMs / 1000),
                    let player, let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
                else { return nil }
                guard engine?.isRunning == true else {
                    let token = session
                    finish()
                    return response(
                        sender: sender, token: token, ready: false,
                        error: L10n.text("control.the_mac_audio_device_changed_press_and_hold_the_voice_key_again"))
                }
                missingPackets += sequence - lastSequence - 1
                lastSequence = sequence
                packets += 1
                peak = max(peak, samples.map { abs($0) }.max() ?? 0)
                armWatchdog()
                // Discard stale backlog on congested connections instead of playing seconds late.
                guard buffered < rate / 3 else {
                    droppedPackets += 1
                    return nil
                }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer {
                    buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
                }
                buffered += samples.count
                let token = session
                player.scheduleBuffer(buffer) { [weak self] in
                    self?.queue.async { [weak self] in
                        guard let self, self.session == token else { return }
                        self.buffered = max(0, self.buffered - samples.count)
                    }
                }
                return nil
            }
            guard let data = text.data(using: .utf8),
                let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                request["type"] as? String == "vibepier-mic1", request["sender"] as? String == sender,
                let token = request["session"] as? String, token.count == 32,
                token.allSatisfy({ $0.isHexDigit }), let action = request["action"] as? String
            else { return nil }
            let identity = peer + ":" + token
            if action == "end" {
                remember(identity)
                if owner == peer && session == token { finish() }
                return response(sender: sender, token: token, ready: false)
            }
            guard action == "begin" else { return nil }
            if recent.contains(identity) {
                return response(
                    sender: sender, token: token, ready: false,
                    error: L10n.text("control.this_voice_session_has_ended_press_and_hold_again"))
            }
            if owner == peer && session == token { return response(sender: sender, token: token, ready: true) }
            guard session.isEmpty, canBegin else {
                return response(
                    sender: sender, token: token, ready: false,
                    error: L10n.text("control.another_voice_session_is_active_end_it_first"))
            }
            let requestedPacketMs = request["packetMs"] as? Int ?? 20
            guard [20, 60].contains(requestedPacketMs), request["button"] as? String == "talk",
                let keys = request["keys"] as? String, keys.count <= 80,
                let codes = try? Hotkey.parseHIDCodes(keys), !codes.isEmpty,
                let sampleRate = request["rate"] as? Int, [8000, 16000].contains(sampleRate),
                let app = request["app"] as? String, app == foreground()
            else {
                return response(
                    sender: sender, token: token, ready: false,
                    error: L10n.text("control.the_active_app_changed_press_and_hold_the_voice_key_again"))
            }
            do {
                if let prepareOverride { try prepareOverride(sampleRate) } else { try prepare(sampleRate: sampleRate) }
                owner = peer
                session = token
                rate = sampleRate
                lastSequence = -1
                buffered = 0
                packets = 0
                peak = 0
                packetMs = requestedPacketMs
                missingPackets = 0
                droppedPackets = 0
                heldCodes = codes
                try pressKeys(codes)
                armWatchdog()
                return response(sender: sender, token: token, ready: true)
            } catch {
                finish()
                return response(sender: sender, token: token, ready: false, error: "\(error)")
            }
        }
    }
    private func prepare(sampleRate: Int) throws {
        guard let target = AudioManager.inputDevices().first(where: { $0.name == "BlackHole 2ch" }) else {
            throw CLIError(L10n.text("control.blackhole_2ch_is_not_installed_install_the_audio_driver_on_the_mac_f"))
        }
        // A default-input change can stop AVAudioEngine through a configuration notification.
        // Complete the input switch before constructing/starting the output engine.
        try inputLease.begin(target: target)
        let audio = AVAudioEngine()
        engine = audio
        guard let unit = audio.outputNode.audioUnit else {
            throw CLIError(L10n.text("control.could_not_create_phone_audio_output"))
        }
        var id = target.id
        guard
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                UInt32(MemoryLayout.size(ofValue: id))) == noErr
        else {
            throw CLIError(L10n.text("control.could_not_connect_to_the_blackhole_audio_input"))
        }
        var actual: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: actual))
        guard
            AudioUnitGetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr,
            actual == target.id
        else {
            throw CLIError(L10n.text("control.phone_audio_routing_verification_failed"))
        }
        let source = AVAudioPlayerNode()
        player = source
        audio.attach(source)
        audio.connect(
            source, to: audio.mainMixerNode,
            format: AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1))
        audio.prepare()
        try audio.start()
        source.play()
    }
    private func armWatchdog() {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        watchdog = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }
    private func remember(_ identity: String) {
        if !recent.contains(identity) { recent.append(identity) }
        if recent.count > 64 { recent.removeFirst() }
    }
    private func finish() {
        watchdog?.cancel()
        watchdog = nil
        if !heldCodes.isEmpty { try? releaseKeys(heldCodes) }
        heldCodes = []
        if !session.isEmpty { remember(owner + ":" + session) }
        cleanupOverride?()
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        buffered = 0
        owner = ""
        session = ""
        if !inputLease.restore() { retryInputRestore(remaining: 3) }
    }
    private func retryInputRestore(remaining: Int) {
        guard remaining > 0 else {
            FileHandle.standardError.write(
                Data("phone microphone: could not restore input; will retry on next session/startup\n".utf8))
            return
        }
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.session.isEmpty else { return }
            if !self.inputLease.restore() { self.retryInputRestore(remaining: remaining - 1) }
        }
    }
    private func response(sender: String, token: String, ready: Bool, error: String? = nil) -> Data? {
        var value: [String: Any] = [
            "type": "vibepier-mic-state1", "sender": sender, "session": token, "ready": ready, "packetMs": packetMs,
        ]
        if let error { value["error"] = error }
        return try? JSONSerialization.data(withJSONObject: value)
    }
}
