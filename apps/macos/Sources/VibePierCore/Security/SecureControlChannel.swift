// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Transport encryption is separate from session RPC encryption. A fresh host-issued
/// session prevents recorded control packets from becoming valid after a restart.
enum SecureControlEnvelope {
    static let hello = "vibepier-secure-hello2"
    static let ready = "vibepier-secure-ready2"
    static let incompatible = "vibepier-secure-incompatible2"
    static let frame = "vibepier-secure1"
    static let maximumPlaintext = 8192
    static let maximumFrame = 16_384

    struct Keys {
        let handshake: SymmetricKey
        let phone: SymmetricKey
        let mac: SymmetricKey

        init(root: Data) throws {
            guard root.count == 32 else { throw Failure.invalidKey }
            func derive(_ purpose: String) -> SymmetricKey {
                HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: SymmetricKey(data: root), salt: Data(),
                    info: Data("vibepier-control-v1/\(purpose)".utf8), outputByteCount: 32)
            }
            handshake = derive("handshake")
            phone = derive("phone")
            mac = derive("mac")
        }
    }

    enum Failure: Error { case invalidKey, invalidFrame, oversized }

    static func signature(_ fields: [String], key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(fields.joined(separator: "|").utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ signature: String, fields: [String], key: SymmetricKey) -> Bool {
        guard signature.count == 64 else { return false }
        var bytes = Data()
        let characters = Array(signature.utf8)
        for offset in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(decoding: characters[offset..<offset + 2], as: UTF8.self), radix: 16) else {
                return false
            }
            bytes.append(byte)
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            bytes, authenticating: Data(fields.joined(separator: "|").utf8), using: key)
    }

    static func seal(
        _ plaintext: Data, device: String, session: String, sequence: Int64, direction: String, keys: Keys
    ) throws -> Data {
        guard plaintext.count <= maximumPlaintext else { throw Failure.oversized }
        guard sequence > 0, ["phone", "mac"].contains(direction) else { throw Failure.invalidFrame }
        let aad = Data("vibepier-control-v1|\(direction)|\(device)|\(session)|\(sequence)".utf8)
        let box = try AES.GCM.seal(plaintext, using: direction == "phone" ? keys.phone : keys.mac, authenticating: aad)
        guard let combined = box.combined else { throw Failure.invalidFrame }
        return Data("\(frame) \(device) \(session) \(sequence) \(combined.base64EncodedString())".utf8)
    }

    static func open(_ fields: [String], direction: String, keys: Keys) throws -> Data {
        guard fields.count == 5, fields[0] == frame, let sequence = Int64(fields[3]), sequence > 0,
            ["phone", "mac"].contains(direction), let data = Data(base64Encoded: fields[4]),
            data.count >= 28, data.count <= maximumPlaintext + 28
        else { throw Failure.invalidFrame }
        let aad = Data("vibepier-control-v1|\(direction)|\(fields[1])|\(fields[2])|\(sequence)".utf8)
        return try AES.GCM.open(
            AES.GCM.SealedBox(combined: data), using: direction == "phone" ? keys.phone : keys.mac, authenticating: aad)
    }
}

/// Baseline controls/configuration/session RPC are required. Phone audio is optional per transport.
enum ControlProtocol {
    static let version = 1
    static let controls: UInt32 = 1
    static let configuration: UInt32 = 2
    static let sessions: UInt32 = 4
    static let phoneAudio: UInt32 = 8
    static let required: UInt32 = controls | configuration | sessions
    static let all: UInt32 = required | phoneAudio

    static func versions(_ field: String) -> [Int]? {
        let fields = field.split(separator: ",", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.count <= 8 else { return nil }
        let values = fields.compactMap { Int($0) }
        guard values.count == fields.count, values.allSatisfy({ (1...255).contains($0) }),
            values.map(String.init).joined(separator: ",") == field,
            values == Array(Set(values)).sorted()
        else { return nil }
        return values
    }

    static func capabilities(_ field: String) -> UInt32? {
        guard let value = UInt32(field), value <= 65_535, String(value) == field else { return nil }
        return value
    }

    static func permits(_ payload: Data, capabilities: UInt32) -> Bool {
        guard capabilities & required == required else { return false }
        let audio: Bool
        if payload.starts(with: Data("vibepier-audio1 ".utf8)) {
            audio = true
        } else if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            audio = ["vibepier-mic1", "vibepier-mic-state1"].contains(object["type"] as? String ?? "")
        } else {
            audio = false
        }
        return !audio || capabilities & phoneAudio != 0
    }
}

/// A bounded sliding window accepts reordered UDP packets without accepting a replay.
struct ControlReplayWindow {
    private var highest: Int64 = 0
    private var received: Set<Int64> = []
    private let width: Int64 = 1024

    mutating func accept(_ sequence: Int64) -> Bool {
        guard sequence > 0, sequence > highest - width, !received.contains(sequence) else { return false }
        highest = max(highest, sequence)
        received = received.filter { $0 > highest - width }
        received.insert(sequence)
        return true
    }
}

final class SecureControlServer: @unchecked Sendable {
    enum Result {
        case handshake(Data)
        case message(device: String, payload: Data)
        case rejected
    }

    private struct Session {
        let device: String
        let id: String
        let clientNonce: String
        let keys: SecureControlEnvelope.Keys
        let fingerprint: Data
        let capabilities: UInt32
        var received = ControlReplayWindow()
        var sent: Int64 = 0
        var expires: TimeInterval
    }

    private struct HelloReceipt {
        let peer: String
        let session: String?
        let requestSignature: String
        let reply: Data
        let expires: TimeInterval
    }

    private let lock = NSLock()
    private let keyForDevice: @Sendable (String) -> Data?
    private let clock: @Sendable () -> TimeInterval
    private let capabilities: UInt32
    private var sessions: [String: Session] = [:]
    private var hellos: [String: HelloReceipt] = [:]
    private let idleLifetime: TimeInterval = 30

    init(
        keyForDevice: @escaping @Sendable (String) -> Data?,
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        capabilities: UInt32 = ControlProtocol.all
    ) {
        self.keyForDevice = keyForDevice
        self.clock = clock
        self.capabilities = capabilities & ControlProtocol.all
    }

    func receive(_ data: Data, peer: String) -> Result {
        lock.withLock {
            guard data.count <= SecureControlEnvelope.maximumFrame, let text = String(data: data, encoding: .utf8)
            else {
                return .rejected
            }
            let fields = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 || fields.count == 7, UUID(uuidString: fields[1]) != nil,
                let root = keyForDevice(fields[1]), root.count == 32
            else { return .rejected }
            let now = clock()
            sessions = sessions.filter { $0.value.expires > now }
            hellos = hellos.filter { $0.value.expires > now }
            if fields[0] == SecureControlEnvelope.hello {
                return acceptHello(fields, peer: peer, root: root, now: now)
            }
            guard fields[0] == SecureControlEnvelope.frame, var session = sessions[peer],
                session.device == fields[1], session.id == fields[2],
                session.fingerprint == Data(SHA256.hash(data: root)), let sequence = Int64(fields[3]),
                let payload = try? SecureControlEnvelope.open(fields, direction: "phone", keys: session.keys),
                session.received.accept(sequence), ControlProtocol.permits(payload, capabilities: session.capabilities)
            else { return .rejected }
            session.expires = now + idleLifetime
            sessions[peer] = session
            return .message(device: session.device, payload: payload)
        }
    }

    private func acceptHello(_ fields: [String], peer: String, root: Data, now: TimeInterval) -> Result {
        guard fields.count == 7, UUID(uuidString: fields[2]) != nil, let timestamp = Int64(fields[3]),
            abs(now - Double(timestamp)) <= 120, let keys = try? SecureControlEnvelope.Keys(root: root),
            SecureControlEnvelope.verify(fields[6], fields: Array(fields.prefix(6)), key: keys.handshake),
            let versions = ControlProtocol.versions(fields[4]), let offered = ControlProtocol.capabilities(fields[5])
        else { return .rejected }
        let receiptKey = fields[1] + ":" + fields[2]
        if let previous = hellos[receiptKey] {
            guard previous.peer == peer, previous.requestSignature == fields[6],
                sessions[peer]?.id == previous.session
            else { return .rejected }
            return .handshake(previous.reply)
        }
        // Reject excess traffic instead of evicting replay records that are still valid.
        guard hellos.count < 512,
            hellos.keys.lazy.filter({ $0.hasPrefix(fields[1] + ":") }).count < 64,
            sessions[peer] != nil || sessions.count < 64,
            sessions[peer]?.device == fields[1] || sessions.values.lazy.filter({ $0.device == fields[1] }).count < 4
        else { return .rejected }
        let selected = offered & capabilities
        let failure =
            !versions.contains(ControlProtocol.version)
            ? "version"
            : selected & ControlProtocol.required != ControlProtocol.required ? "capabilities" : nil
        if let failure {
            sessions.removeValue(forKey: peer)
            let replyFields = [
                SecureControlEnvelope.incompatible, fields[1], fields[2], failure,
                String(ControlProtocol.version), String(capabilities),
            ]
            let reply = Data(
                (replyFields + [SecureControlEnvelope.signature(replyFields, key: keys.handshake)]).joined(
                    separator: " "
                ).utf8)
            hellos[receiptKey] = HelloReceipt(
                peer: peer, session: nil, requestSignature: fields[6], reply: reply, expires: now + 300)
            return .handshake(reply)
        }
        let id = UUID().uuidString.lowercased()
        let replyFields = [
            SecureControlEnvelope.ready, fields[1], fields[2], id, String(ControlProtocol.version), String(selected),
        ]
        let reply = Data(
            (replyFields + [SecureControlEnvelope.signature(replyFields, key: keys.handshake)]).joined(separator: " ")
                .utf8)
        sessions[peer] = Session(
            device: fields[1], id: id, clientNonce: fields[2], keys: keys, fingerprint: Data(SHA256.hash(data: root)),
            capabilities: selected, expires: now + idleLifetime)
        hellos[receiptKey] = HelloReceipt(
            peer: peer, session: id, requestSignature: fields[6], reply: reply, expires: now + 300)
        return .handshake(reply)
    }

    func seal(_ payload: Data, peer: String) -> Data? {
        lock.withLock {
            guard var session = sessions[peer], session.expires > clock(), session.sent < Int64.max,
                let root = keyForDevice(session.device), session.fingerprint == Data(SHA256.hash(data: root))
            else {
                sessions.removeValue(forKey: peer)
                return nil
            }
            let sequence = session.sent + 1
            guard ControlProtocol.permits(payload, capabilities: session.capabilities) else { return nil }
            guard
                let frame = try? SecureControlEnvelope.seal(
                    payload, device: session.device, session: session.id, sequence: sequence, direction: "mac",
                    keys: session.keys)
            else { return nil }
            session.sent = sequence
            sessions[peer] = session
            return frame
        }
    }

    func device(for peer: String) -> String? {
        lock.withLock {
            guard let session = sessions[peer], session.expires > clock(),
                let root = keyForDevice(session.device), session.fingerprint == Data(SHA256.hash(data: root))
            else { return nil }
            return session.device
        }
    }

    func sessionIdentifier(for peer: String) -> String? {
        lock.withLock {
            guard let session = sessions[peer], session.expires > clock(),
                let root = keyForDevice(session.device), session.fingerprint == Data(SHA256.hash(data: root))
            else { return nil }
            return session.id
        }
    }

    func disconnectAll() { lock.withLock { sessions.removeAll() } }

    func disconnect(_ peer: String) { lock.withLock { _ = sessions.removeValue(forKey: peer) } }

    func revoke(_ device: String) {
        lock.withLock {
            sessions = sessions.filter { $0.value.device != device }
            // Keep hello replay receipts until their normal expiry.
        }
    }
}
