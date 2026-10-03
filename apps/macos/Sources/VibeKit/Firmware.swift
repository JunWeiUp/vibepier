// SPDX-License-Identifier: MIT
//
// Firmware images and the over-the-air (OTA) update state machine.
//
// Recovered from -[KehwinDevice startDeviceUpgrade:], -[KehwinDevice
// startDongleUpgrade:], the onMessage*Upgrade* handlers and FirmwareHelper in
// kwdm.dylib. No AU05 image ships with Ulanzi Studio. Images come from
// https://api.ulanzistudio.com/api/vibekey/firmware/checkUpdate.
//
// Image layout:
//     bytes 0...31   header
//       byte 4         target: 0 = dongle, 1 = mic, 2 = either
//       bytes 5...7    customer code (sent in the connect message)
//       bytes 28...31  payload length, little-endian
//     bytes 32...    payload
//
// The payload is cut into 1024-byte frames. Each frame is sent as 32-byte
// packages. A frame checksum is the plain byte sum, and the image checksum is
// the sum of the frame checksums.

import Foundation
import VibeLocalization

public enum FirmwareTarget: String, Sendable, CaseIterable {
    case dongle
    case device

    /// Message type used for this target's upgrade traffic.
    public var messageType: UInt8 {
        self == .dongle ? MessageType.dongleUpgrade.rawValue : MessageType.deviceUpgrade.rawValue
    }
    /// Pause between data packages, from the AU05 row of `KKDeviceInfoTable` (ms).
    public var packageIntervalMs: Int { self == .dongle ? 2 : 10 }
    /// Resend interval of the connect message (ms).
    var connectIntervalMs: Int { self == .dongle ? 200 : 500 }
    /// Product identifier used by the Ulanzi update API.
    public var apiProductID: String { self == .dongle ? "AU05_USB" : "AU05_Device" }
}

public enum FirmwareError: Error, CustomStringConvertible {
    case tooSmall(Int)
    case wrongTarget(UInt8, FirmwareTarget)
    case truncated(expected: Int, actual: Int)
    case stepTimeout(String)
    case programFailed(frame: Int)
    case updateFailed(UInt8)

    public var description: String {
        switch self {
        case .tooSmall(let n): return L10n.text("hardware.image_too_small", n)
        case .wrongTarget(let b, let t):
            return L10n.text("hardware.wrong_target", b, t.rawValue)
        case .truncated(let e, let a): return L10n.text("hardware.image_truncated", e, a)
        case .stepTimeout(let s): return L10n.text("hardware.update_timeout", s)
        case .programFailed(let f): return L10n.text("hardware.program_failed", f)
        case .updateFailed(let r): return L10n.text("hardware.update_failed", r)
        }
    }
}

public struct FirmwareImage: Sendable {
    public static let headerLength = 32
    public static let frameLength = 1024
    public static let packageLength = 32

    public let header: [UInt8]
    public let payload: [UInt8]
    public let frames: [[UInt8]]

    public var targetByte: UInt8 { header[4] }
    public var customCode: [UInt8] { Array(header[5..<8]) }
    public var payloadLength: UInt32 { readLE32(header, 28) }
    public var totalChecksum: UInt32 { frames.reduce(0) { $0 &+ FirmwareImage.checksum($1) } }

    public init(data: Data, target: FirmwareTarget) throws {
        let bytes = [UInt8](data)
        // `(length >> 11) < 5` in startDeviceUpgrade / startDongleUpgrade.
        guard bytes.count >> 11 >= 5 else { throw FirmwareError.tooSmall(bytes.count) }
        let type = bytes[4]
        switch target {
        case .device where type != 1 && type != 2:
            throw FirmwareError.wrongTarget(type, target)
        case .dongle where type & 0xFD != 0:
            throw FirmwareError.wrongTarget(type, target)
        default: break
        }
        header = Array(bytes[0..<FirmwareImage.headerLength])
        let length = Int(readLE32(header, 28))
        let available = bytes.count - FirmwareImage.headerLength
        guard length <= available else { throw FirmwareError.truncated(expected: length, actual: available) }
        payload = Array(bytes[FirmwareImage.headerLength..<(FirmwareImage.headerLength + length)])
        var out: [[UInt8]] = []
        var offset = 0
        while offset < payload.count {
            let end = min(payload.count, offset + FirmwareImage.frameLength)
            out.append(Array(payload[offset..<end]))
            offset = end
        }
        frames = out
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    }

    public static func packages(of frame: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: frame.count, by: packageLength).map {
            Array(frame[$0..<min(frame.count, $0 + packageLength)])
        }
    }
}

/// Drives one firmware update over an authenticated session.
public final class FirmwareUpdater: @unchecked Sendable {
    public let session: VibeSession
    public var stepTimeout: TimeInterval = 10
    public var onProgress: (@Sendable (Double, String) -> Void)?

    private let lock = NSLock()
    private var inbox: [UpgradeEvent] = []

    public init(session: VibeSession) {
        self.session = session
    }

    public func run(image: FirmwareImage, target: FirmwareTarget) async throws {
        let type = target.messageType
        let listener = session.addListener { [weak self] event in
            if case .message(.upgrade(let t, let e), _) = event, t == type {
                self?.push(e)
            }
        }
        defer { session.removeListener(listener) }

        report(0, L10n.text("hardware.connecting"))
        let connect = UpgradeRequest.connect(
            target: type, fileLength: image.payloadLength, customCode: image.customCode)
        _ = try await exchange(connect, every: target.connectIntervalMs, step: L10n.text("hardware.connect_step")) {
            if case .connected = $0 { return true }
            return false
        }

        var frameIndex = 0
        while frameIndex < image.frames.count {
            let frame = image.frames[frameIndex]
            let packages = FirmwareImage.packages(of: frame)
            let checksum = FirmwareImage.checksum(frame)
            var toSend = Array(0..<packages.count)
            var attempts = 0
            while true {
                attempts += 1
                if attempts > 20 { throw FirmwareError.stepTimeout(L10n.text("hardware.frame_transfer", frameIndex)) }
                for i in toSend {
                    try session.sendNow(
                        UpgradeRequest.data(target: type, packageIndex: i, chunk: packages[i]),
                        name: "upgrade.data")
                    try await sleepMs(target.packageIntervalMs)
                }
                let reply = try await exchange(
                    UpgradeRequest.receivePackageNum(target: type, checksum: checksum),
                    every: target.packageIntervalMs + 5 + 40, step: L10n.text("hardware.receive_packages_step")
                ) {
                    if case .receivePackageNum = $0 { return true }
                    return false
                }
                guard case .receivePackageNum(let mask, let deviceSum) = reply else { continue }
                let missing = (0..<packages.count).filter { i in i < 32 && mask & (1 << UInt32(i)) == 0 }
                if !missing.isEmpty {
                    toSend = missing
                    continue
                }
                if deviceSum != checksum {
                    toSend = Array(0..<packages.count)
                    continue
                }
                break
            }
            let programInterval = target.packageIntervalMs + (packages.count & 3 != 0 ? 10 : 20)
            let done = try await exchange(
                UpgradeRequest.enableProgram(
                    target: type, frameIndex: frameIndex,
                    packageCount: packages.count),
                every: programInterval + 40, step: L10n.text("hardware.program_frame", frameIndex)
            ) {
                if case .programComplete = $0 { return true }
                return false
            }
            guard case .programComplete(let result, _, let index) = done else { continue }
            if result == 0 { throw FirmwareError.programFailed(frame: frameIndex) }
            // The vendor advances when the device echoes the current frame, and
            // otherwise jumps to the frame the device asks for.
            frameIndex = Int(index) == frameIndex ? frameIndex + 1 : Int(index)
            report(
                Double(frameIndex) / Double(image.frames.count),
                L10n.text("hardware.frame_progress", frameIndex, image.frames.count))
        }

        report(1, L10n.text("hardware.verifying"))
        let sumReply = try await exchange(
            UpgradeRequest.checkAllSum(target: type), every: 50, step: L10n.text("hardware.checksum_step")
        ) {
            if case .checkAllSum = $0 { return true }
            return false
        }
        guard case .checkAllSum(let deviceTotal) = sumReply else {
            throw FirmwareError.stepTimeout(L10n.text("hardware.checksum_step"))
        }
        let matched = deviceTotal == image.totalChecksum
        let final = try await exchange(
            UpgradeRequest.allPageCompleteResult(target: type, matched: matched),
            every: 100, step: L10n.text("hardware.finish_step")
        ) {
            if case .result = $0 { return true }
            return false
        }
        guard case .result(let r) = final, r != 0, matched else {
            if case .result(let r) = final { throw FirmwareError.updateFailed(r) }
            throw FirmwareError.updateFailed(0)
        }
        report(1, L10n.text("hardware.done"))
    }

    // MARK: Helpers

    private func report(_ fraction: Double, _ text: String) {
        onProgress?(fraction, text)
    }

    private func push(_ e: UpgradeEvent) {
        lock.lock()
        inbox.append(e)
        lock.unlock()
    }

    private func clearInbox() {
        lock.lock()
        inbox.removeAll()
        lock.unlock()
    }

    private func take(_ match: (UpgradeEvent) -> Bool) -> UpgradeEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = inbox.firstIndex(where: match) else { return nil }
        let e = inbox.remove(at: i)
        inbox.removeAll()
        return e
    }

    /// Sends `bytes` every `every` ms until a matching upgrade event arrives.
    private func exchange(
        _ bytes: [UInt8], every: Int, step: String,
        _ match: @escaping (UpgradeEvent) -> Bool
    ) async throws -> UpgradeEvent {
        clearInbox()
        let deadline = Date().addingTimeInterval(stepTimeout)
        var nextSend = Date.distantPast
        while Date() < deadline {
            if let e = take(match) { return e }
            if Date() >= nextSend {
                try session.sendNow(bytes, name: "upgrade.\(step)")
                nextSend = Date().addingTimeInterval(Double(max(every, 5)) / 1000)
            }
            try await sleepMs(5)
        }
        throw FirmwareError.stepTimeout(step)
    }

    private func sleepMs(_ ms: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
}

/// Client for the vendor update-check endpoint.
public struct FirmwareUpdateInfo: Sendable {
    public var needUpdate: Bool
    public var version: String?
    public var downloadURL: URL?
    public var notes: String?
    public var raw: String
}

public enum FirmwareAPI {
    public static let base = "https://api.ulanzistudio.com/api"

    /// Sends the same request as `VibeOtaManager::requestVibeKeyOtaCheck`.
    /// It transmits the dongle serial number and the current firmware version to Ulanzi.
    public static func check(
        serial: String, target: FirmwareTarget, currentVersion: String,
        language: String = "en"
    ) async throws -> FirmwareUpdateInfo {
        var c = URLComponents(string: base + "/vibekey/firmware/checkUpdate")!
        c.queryItems = [
            URLQueryItem(name: "deviceSn", value: serial),
            URLQueryItem(name: "pid", value: target.apiProductID),
            URLQueryItem(name: "ver", value: currentVersion),
            URLQueryItem(name: "lang", value: language),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let text = String(decoding: data, as: UTF8.self)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let d = (json["data"] as? [String: Any]) ?? json
        func bool(_ v: Any?) -> Bool {
            if let b = v as? Bool { return b }
            if let n = v as? NSNumber { return n.boolValue }
            if let s = v as? String { return s == "1" || s.lowercased() == "true" }
            return false
        }
        return FirmwareUpdateInfo(
            needUpdate: bool(d["needUpdate"]),
            version: d["version"] as? String,
            downloadURL: (d["downloadUrl"] as? String).flatMap(URL.init(string:)),
            notes: d["versionInfo"] as? String,
            raw: text)
    }
}
