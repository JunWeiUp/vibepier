import CryptoKit
import Foundation
import XCTest

@testable import VibePierCore

/// A phone-side wire client. Tests still enter the production authentication/decryption boundary.
final class SecureTestPhone: @unchecked Sendable {
    static let primary = "00000000-0000-4000-8000-000000000001"
    static let secondary = "00000000-0000-4000-8000-000000000002"
    static let other = "00000000-0000-4000-8000-000000000003"
    static func root(for device: String) -> Data? {
        guard [primary, secondary, other].contains(device) else { return nil }
        return Data(SHA256.hash(data: Data(device.utf8)))
    }
    let device: String
    private let keys: SecureControlEnvelope.Keys
    private let lock = NSLock()
    private var nonce = UUID().uuidString
    private var session: String?
    private var sequence: Int64 = 0
    private var replay = ControlReplayWindow()

    init(device: String = primary) throws {
        self.device = device
        keys = try SecureControlEnvelope.Keys(root: XCTUnwrap(Self.root(for: device)))
    }
    func hello() -> Data {
        lock.withLock {
            let fields = [
                SecureControlEnvelope.hello, device, nonce, String(Int64(Date().timeIntervalSince1970)), "1", "15",
            ]
            return Data(
                (fields + [SecureControlEnvelope.signature(fields, key: keys.handshake)]).joined(separator: " ").utf8)
        }
    }
    func receive(_ wire: Data) throws -> Data? {
        try lock.withLock {
            let fields = String(decoding: wire, as: UTF8.self).split(separator: " ").map(String.init)
            guard fields.count == 5 || fields.count == 7, fields[1] == device else {
                throw SecureControlEnvelope.Failure.invalidFrame
            }
            if fields[0] == SecureControlEnvelope.ready {
                guard fields.count == 7, fields[2] == nonce, fields[4] == "1",
                    let mask = ControlProtocol.capabilities(fields[5]),
                    mask & ControlProtocol.required == ControlProtocol.required,
                    SecureControlEnvelope.verify(fields[6], fields: Array(fields.prefix(6)), key: keys.handshake)
                else { throw SecureControlEnvelope.Failure.invalidFrame }
                session = fields[3]
                return nil
            }
            guard fields[2] == session, let number = Int64(fields[3]) else {
                throw SecureControlEnvelope.Failure.invalidFrame
            }
            let clear = try SecureControlEnvelope.open(fields, direction: "mac", keys: keys)
            guard replay.accept(number) else { throw SecureControlEnvelope.Failure.invalidFrame }
            return clear
        }
    }
    func seal(_ text: String) throws -> Data {
        try lock.withLock {
            sequence += 1
            return try SecureControlEnvelope.seal(
                Data(text.utf8), device: device, session: XCTUnwrap(session),
                sequence: sequence, direction: "phone", keys: keys)
        }
    }
}

/// Adapts existing behavior assertions to the real encrypted relay wire format.
final class AuthenticatedRelay: @unchecked Sendable {
    private var client: RelayClient!
    private let lock = NSLock()
    private var phones: [String: SecureTestPhone] = [:]
    init(
        settings: RelaySettings, application: @escaping @Sendable () -> FrontmostApplication = { .current() },
        leaseSeconds: TimeInterval = 12, transport: (@Sendable (String, Data) -> Void)? = nil,
        keyForDevice: @escaping @Sendable (String) -> Data? = SecureTestPhone.root,
        sessionRemote: @escaping @Sendable () -> any SessionRemoteRouting = { TestSessionRouter() },
        handler: @escaping @Sendable (RemoteEvent) -> Void
    ) {
        client = RelayClient(
            settings: settings, leaseSeconds: leaseSeconds, application: application,
            transport: { [weak self] peer, data in
                do {
                    let phone = self?.lock.withLock { self?.phones[peer] }
                    if let payload = try phone?.receive(data) { transport?(peer, payload) }
                } catch { XCTFail("Invalid server ciphertext: \(error)") }
            }, keyForDevice: keyForDevice, sessionRemote: sessionRemote, handler: handler)
    }
    var status: [String: Any] { client.status }
    var directOffer: (@Sendable (String, String, [String], @escaping @Sendable ([String]) -> Void) -> Void)? {
        get { client.directOffer }
        set { client.directOffer = newValue }
    }
    func dispatch(_ text: String, peer: String = RelayClient.peer) throws {
        var phone = lock.withLock { phones[peer] }
        if phone == nil {
            let created = try SecureTestPhone(device: XCTUnwrap(DirectAdmissions.sender(in: text)))
            lock.withLock { phones[peer] = created }
            client.dispatch(String(decoding: created.hello(), as: UTF8.self), peer: peer)
            phone = created
        }
        client.dispatch(String(decoding: try XCTUnwrap(phone).seal(text), as: UTF8.self), peer: peer)
    }
    func handle(_ text: String, _ current: Int) { client.handle(text, current) }
    func start() {
        client.start()
        _ = client.status
    }
    func stop() { client.stop() }
}

final class SecureUDPTestPhone {
    let phone: SecureTestPhone
    private let fd: Int32
    private var address = sockaddr_in()
    init(port: UInt16, device: String = SecureTestPhone.primary) throws {
        phone = try SecureTestPhone(device: device)
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SecureControlEnvelope.Failure.invalidFrame }
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
    }
    deinit { close(fd) }
    func sendWire(_ data: Data) {
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(sent, data.count)
    }
    func receiveWire(milliseconds: Int = 1000) -> Data? {
        var timeout = timeval(tv_sec: milliseconds / 1000, tv_usec: Int32((milliseconds % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: SecureControlEnvelope.maximumFrame + 1)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? Data(buffer.prefix(count)) : nil
    }
    func connect() throws {
        sendWire(phone.hello())
        XCTAssertNil(try phone.receive(XCTUnwrap(receiveWire())))
    }
    func send(_ text: String) throws { sendWire(try phone.seal(text)) }
    func receive() throws -> [String: Any] {
        let clear = try XCTUnwrap(phone.receive(XCTUnwrap(receiveWire())))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: clear) as? [String: Any])
    }
}

struct TestSessionRouter: SessionRemoteRouting {
    func touch(_ peer: String) {}
    func disconnected(_ peer: String) {}
    func receive(_ data: Data, peer: String, sender: String, send: @escaping @Sendable ([Data]) -> Void) {}
    func requestPair(_ data: Data, peer: String) {}
    func pairResult(_ peer: String) -> Data { Data() }
}
