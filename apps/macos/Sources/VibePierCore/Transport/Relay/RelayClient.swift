// SPDX-License-Identifier: MIT
//
// Carries the Android remote's text protocol through a WebSocket relay so the
// phone works away from the Mac's Wi-Fi and Bluetooth range. The Mac joins a
// room as `host`; the phone joins the same room as `client`; the server
// routes replies to each phone independently (see docs/relay-protocol.md).
//
// Only the control channel is relayed. Phone-microphone audio stays on Wi-Fi/BLE.

import AppKit
import CFNetwork
import CryptoKit
import Darwin
import Foundation
import VibeKit

/// Only this relay's URLSession uses the selected proxy. The original endpoint,
/// SNI and default certificate verification remain unchanged.
struct RelayHTTPProxy: Equatable {
    let host: String
    let port: Int

    static func parse(_ raw: String) -> RelayHTTPProxy? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), components.url != nil,
            components.scheme?.lowercased() == "http", components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            let rawHost = components.host
        else { return nil }
        let host = normalizedHost(rawHost)
        let port = components.port ?? 80
        guard (1...65535).contains(port), validHost(host) else { return nil }
        return RelayHTTPProxy(host: host, port: port)
    }

    static func selected(for url: URL, environment: [String: String] = ProcessInfo.processInfo.environment)
        -> RelayHTTPProxy?
    {
        if let explicit = environment["VIBEPIER_RELAY_PROXY"],
            !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            // An explicit, invalid value must not silently choose another route.
            return parse(explicit)
        }
        guard let host = url.host else { return nil }
        let secure = ["https", "wss"].contains(url.scheme?.lowercased() ?? "")
        let excluded =
            environment["NO_PROXY"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? environment["no_proxy"] ?? ""
        guard !bypasses(host: normalizedHost(host), port: url.port ?? (secure ? 443 : 80), exclusions: excluded) else {
            return nil
        }
        let keys = secure ? ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] : ["HTTP_PROXY", "http_proxy"]
        for key in keys {
            if let raw = environment[key], let proxy = parse(raw) { return proxy }
        }
        return nil
    }

    var connectionProxyDictionary: [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port, kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: host, kCFNetworkProxiesHTTPSPort as String: port,
        ]
    }

    private static func normalizedHost(_ source: String) -> String {
        var host = source.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") {
            var address = in6_addr()
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_pton(AF_INET6, host, &address) == 1,
                inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil
            {
                host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return host
    }
    private static func numericHost(_ host: String) -> Bool {
        var address = in_addr()
        var address6 = in6_addr()
        return inet_pton(AF_INET, host, &address) == 1 || inet_pton(AF_INET6, host, &address6) == 1
    }
    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        if host.contains(":") {
            var address = in6_addr()
            return inet_pton(AF_INET6, host, &address) == 1
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) {
            var address = in_addr()
            return inet_pton(AF_INET, host, &address) == 1
        }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func bypasses(host: String, port: Int, exclusions: String) -> Bool {
        for raw in exclusions.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            var entry = raw.lowercased()
            var entryPort: Int?
            if entry == "*" { return true }
            if entry.hasPrefix("["), let end = entry.firstIndex(of: "]") {
                let suffix = String(entry[entry.index(after: end)...])
                if !suffix.isEmpty {
                    guard suffix.hasPrefix(":"), let value = Int(suffix.dropFirst()) else { continue }
                    entryPort = value
                }
                entry = String(entry[entry.index(after: entry.startIndex)..<end])
            } else if entry.filter({ $0 == ":" }).count == 1, let colon = entry.lastIndex(of: ":") {
                guard let value = Int(entry[entry.index(after: colon)...]) else { continue }
                entryPort = value
                entry = String(entry[..<colon])
            }
            if let entryPort, entryPort != port { continue }
            if entry.hasPrefix("*.") {
                entry = String(entry.dropFirst(2))
            } else if entry.hasPrefix(".") {
                entry.removeFirst()
            }
            entry = normalizedHost(entry)
            if entry == "localhost",
                host == "localhost" || host == "::1" || (host.hasPrefix("127.") && numericHost(host))
            {
                return true
            }
            if host == entry || (!entry.isEmpty && !numericHost(entry) && host.hasSuffix("." + entry)) { return true }
        }
        return false
    }
}

struct RelaySettings: Equatable {
    var url: URL
    var room: String
    var secret: String
    var dnsRecovery: Bool

    init?(url: String?, room: String?, secret: String?, dnsRecovery: Bool = false) {
        guard let text = url?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
            let parsed = URL(string: text), ["ws", "wss"].contains(parsed.scheme?.lowercased() ?? ""),
            parsed.host?.isEmpty == false, parsed.user == nil, parsed.password == nil, parsed.fragment == nil,
            !dnsRecovery || parsed.scheme?.lowercased() == "wss",
            let room = room?.trimmingCharacters(in: .whitespaces), Self.validRoom(room),
            let secret = secret?.trimmingCharacters(in: .whitespaces), Self.validSecret(secret)
        else { return nil }
        self.url = parsed
        self.room = room
        self.secret = secret
        self.dnsRecovery = dnsRecovery
    }

    init?(_ config: Config) {
        self.init(
            url: config.relayURL, room: config.relayRoom,
            secret: RelayCredentialStore.read(url: config.relayURL, room: config.relayRoom),
            dnsRecovery: config.relayDNSRecovery ?? false)
    }

    static func validRoom(_ room: String) -> Bool {
        (1...64).contains(room.count)
            && room.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    static func validSecret(_ secret: String) -> Bool {
        (32...256).contains(secret.count) && !secret.contains(where: \.isWhitespace)
    }

    /// Pasted into the phone's relay dialog; contains the secret, so it is shown only on request.
    var pairingCode: String {
        "vibepierrelay1 \(url.absoluteString) \(room) \(secret)" + (dnsRecovery ? " dns=alidns" : "")
    }

    static func hello(role: String, room: String, secret: String, timestamp: Int64, nonce: String, version: Int = 1)
        -> String
    {
        let prefix = "vibepier-relay\(version)"
        let message = "\(prefix)|\(role)|\(room)|\(timestamp)|\(nonce)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return "\(prefix) hello \(role) \(room) \(timestamp) \(nonce) \(hex)"
    }

    static func randomHex(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

final class RelayClient: @unchecked Sendable {
    static let peer = "relay"
    private let queue = DispatchQueue(label: "vibepier.relay")
    private let settings: RelaySettings
    private let leaseSeconds: TimeInterval
    private let security: SecureControlServer
    private let sessionRemote: @Sendable () -> any SessionRemoteRouting
    private let handler: @Sendable (RemoteEvent) -> Void
    private let application: @Sendable () -> FrontmostApplication
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var running = false
    private var retryDelay: TimeInterval = 1
    private var retry: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private var pongPending = false
    private var label = L10n.text("mac.not_started")
    private struct Phone {
        let sender: String
        let sessionID = UUID()
        var confirmed = false
        var expires: TimeInterval
        var held: [Control: RemoteEvent] = [:]
        var dedup = RemoteDeduplicator()
    }
    private var phones: [String: Phone] = [:]
    private let transport: (@Sendable (String, Data) -> Void)?
    private var lease: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Handles a phone's direct-path offer (sender, token, candidates) and reports this Mac's candidates.
    var directOffer: (@Sendable (String, String, [String], @escaping @Sendable ([String]) -> Void) -> Void)?

    init(
        settings: RelaySettings, leaseSeconds: TimeInterval = 12,
        application: @escaping @Sendable () -> FrontmostApplication = { .current() },
        transport: (@Sendable (String, Data) -> Void)? = nil,
        keyForDevice: @escaping @Sendable (String) -> Data? = { DeviceTrustStore.shared.key(for: $0) },
        sessionRemote: @escaping @Sendable () -> any SessionRemoteRouting = { SessionRemote.shared },
        handler: @escaping @Sendable (RemoteEvent) -> Void
    ) {
        self.sessionRemote = sessionRemote
        self.security = SecureControlServer(
            keyForDevice: keyForDevice, capabilities: ControlProtocol.required)
        self.settings = settings
        self.leaseSeconds = leaseSeconds
        self.application = application
        self.transport = transport
        self.handler = handler
    }

    var status: [String: Any] {
        queue.sync {
            [
                "state": label, "connectedCount": connectedCount, "deviceIDs": connectedDeviceIDs,
                "url": settings.url.absoluteString, "room": settings.room, "dnsRecovery": settings.dnsRecovery,
            ] as [String: Any]
        }
    }

    private var connectedCount: Int {
        connectedDeviceIDs.count
    }
    private var connectedDeviceIDs: [String] {
        let now = ProcessInfo.processInfo.systemUptime
        return Array(Set(phones.values.filter { $0.confirmed && $0.expires > now }.map(\.sender))).sorted()
    }

    private static func codexPeer(_ route: String) -> String { "relay:\(route)" }

    func start() {
        let center = NotificationCenter.default
        for name in [PhoneBindings.changed, ApplicationShortcuts.changed, CurrentApplicationShortcut.changed] {
            observers.append(
                (
                    center,
                    center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                        self?.queue.async { [weak self] in self?.publish() }
                    }
                ))
        }
        observers.append(
            (
                center,
                center.addObserver(forName: DeviceTrustStore.changed, object: nil, queue: nil) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        for peer in self.phones.keys.filter({ self.security.device(for: $0) != self.phones[$0]!.sender }
                        ) { self.dropPhone(peer) }
                        self.armLease()
                        self.connectionChanged()
                    }
                }
            ))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            (
                workspace,
                workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil)
                { [weak self] _ in
                    self?.queue.async { [weak self] in self?.publish() }
                }
            ))
        queue.async {
            self.running = true
            self.connect()
        }
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        queue.sync {
            running = false
            generation += 1
            retry?.cancel()
            retry = nil
            tearDown()
            dropPhones()
            session?.invalidateAndCancel()
            session = nil
            label = L10n.text("mac.not_started")
        }
    }

    // MARK: Connection

    private func connect() {
        guard running, transport == nil else { return }
        generation += 1
        let current = generation
        if session == nil {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 15
            configuration.connectionProxyDictionary =
                RelayHTTPProxy.selected(for: settings.url)?.connectionProxyDictionary
            session = URLSession(configuration: configuration)
        }
        guard let session else { return }
        let task = session.webSocketTask(with: settings.url)
        task.maximumMessageSize = 2 << 20
        self.task = task
        changed(L10n.text("control.connecting_to_the_relay"))
        task.resume()
        let hello = RelaySettings.hello(
            role: "host", room: settings.room, secret: settings.secret,
            timestamp: Int64(Date().timeIntervalSince1970), nonce: RelaySettings.randomHex(bytes: 16), version: 2)
        task.send(.string(hello)) { [weak self] error in
            guard let error else { return }
            self?.queue.async { [weak self] in
                self?.fail(current, L10n.text("control.relay_connection_failed_0", error.localizedDescription))
            }
        }
        receive(task, current)
    }

    private func receive(_ task: URLSessionWebSocketTask, _ current: Int) {
        task.receive { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self, current == self.generation else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text, current)
                    if current == self.generation { self.receive(task, current) }
                case .success:
                    self.receive(task, current)
                case .failure(let error):
                    self.fail(current, L10n.text("control.relay_disconnected_0", error.localizedDescription))
                }
            }
        }
    }

    private func fail(_ current: Int, _ reason: String, delay: TimeInterval? = nil) {
        guard current == generation, running else { return }
        generation += 1
        tearDown()
        dropPhones()
        let wait = delay ?? retryDelay
        retryDelay = min(30, retryDelay * 2)
        changed(L10n.text("control.0_retrying_in_1_s", reason, Int(wait)))
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retry = work
        queue.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func tearDown() {
        pingTimer?.cancel()
        pingTimer = nil
        pongPending = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func startPing(_ current: Int) {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, current == self.generation, let task = self.task else { return }
            if self.pongPending {
                self.fail(current, L10n.text("control.the_relay_did_not_respond"))
                return
            }
            self.pongPending = true
            task.sendPing { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, current == self.generation else { return }
                    if let error {
                        self.fail(current, L10n.text("control.relay_disconnected_0", error.localizedDescription))
                    } else {
                        self.pongPending = false
                    }
                }
            }
        }
        pingTimer = timer
        timer.resume()
    }

    // MARK: Messages

    /// Server-assigned connection IDs separate devices even if they share a room.
    static func routedPayload(_ line: String) -> (peer: String, data: Data)? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "vibepier-relay2", parts[1] == "from",
            validPeer(parts[2]), parts[3].utf8.count <= ((1 << 20) + 2) / 3 * 4,
            let data = Data(base64Encoded: String(parts[3])), data.count <= 1 << 20,
            String(data: data, encoding: .utf8) != nil
        else { return nil }
        return (String(parts[2]), data)
    }

    private static func validPeer(_ peer: Substring) -> Bool {
        peer.count == 32 && peer.allSatisfy { $0.isASCII && ("0123456789abcdef".contains($0)) }
    }

    func handle(_ line: String, _ current: Int) {
        guard line.hasPrefix("vibepier-relay2 ") else { return }
        if let (peer, data) = Self.routedPayload(line) {
            dispatch(String(decoding: data, as: UTF8.self), peer: peer)
            return
        }
        let parts = line.split(separator: " ")
        switch parts.dropFirst().first {
        case "ok":
            retryDelay = 1
            startPing(current)
            connectionChanged()
        case "error":
            let reason = parts.dropFirst(2).first.map(String.init) ?? "unknown"
            let text =
                [
                    "auth": L10n.text("control.the_relay_secret_does_not_match"),
                    "clock": L10n.text("control.the_mac_clock_is_incorrect"),
                    "replay": L10n.text("control.repeated_handshake_rejected"),
                ][reason] ?? reason
            fail(
                current, L10n.text("control.relay_rejected_the_connection_0", text), delay: reason == "auth" ? 60 : nil)
        case "peer":
            if parts.count == 4, parts[2] == "down", Self.validPeer(parts[3]) {
                dropPhone(String(parts[3]))
                armLease()
                connectionChanged()
            }
        default: break
        }
    }

    /// Same command set as UDP/BLE, bound to one server-authenticated connection.
    func dispatch(_ wire: String, peer: String = RelayClient.peer) {
        let previousSession = security.sessionIdentifier(for: peer)
        let line: String
        let device: String
        switch security.receive(Data(wire.utf8), peer: peer) {
        case .handshake(let reply):
            if previousSession != security.sessionIdentifier(for: peer) { dropPhone(peer, disconnectSecurity: false) }
            sendWire(reply, to: peer)
            return
        case .message(let authenticatedDevice, let payload):
            guard let clear = String(data: payload, encoding: .utf8),
                DirectAdmissions.sender(in: clear) == authenticatedDevice
            else { return }
            line = clear
            device = authenticatedDevice
        case .rejected: return
        }
        let parts = line.split(whereSeparator: \.isWhitespace)
        let now = ProcessInfo.processInfo.systemUptime
        if parts.count == 2, parts[0] == "vibepier-watch1", parts[1].count <= 64 {
            let value = String(parts[1])
            if phones[peer]?.sender != value || (phones[peer]?.expires ?? 0) <= now {
                dropPhone(peer, disconnectSecurity: false)
                // A reconnect gets a new server ID; retire only this sender's stale socket.
                for previous in phones.keys.filter({ phones[$0]?.sender == value }) { dropPhone(previous) }
                guard phones.count < 32 else { return }
                phones[peer] = Phone(sender: value, expires: now + leaseSeconds)
            } else {
                phones[peer]?.expires = now + leaseSeconds
            }
            armLease()
            sessionRemote().touch(Self.codexPeer(peer))
            publish(to: peer)
            return
        }
        guard let phone = phones[peer], phone.expires > now else { return }
        let sender = phone.sender
        guard sender == device else { return }
        if parts.count == 2, parts[0] == "vibepier-ack1", parts[1] == sender {
            if !phone.confirmed {
                phones[peer]?.confirmed = true
                connectionChanged()
            }
        } else if line.contains("\"vibepier-direct-offer1\"") {
            offerDirect(line, peer: peer, phone: phone)
        } else if line.contains("vibepier-session1") {
            sessionRemote().receive(Data(line.utf8), peer: Self.codexPeer(peer), sender: sender) {
                [weak self] frames in
                self?.queue.async { [weak self] in
                    for frame in frames { self?.sendIfActive(frame, to: peer, sessionID: phone.sessionID) }
                }
            }
        } else if parts.count == 2, parts[0] == "vibepier-slots1", parts[1] == sender {
            for frame in ApplicationShortcuts.shared.frames(sender: sender) { send(frame, to: peer) }
        } else if parts.count == 2, parts[0] == "vibepier-current1", parts[1] == sender {
            for frame in CurrentApplicationShortcut.shared.frames(sender: sender) { send(frame, to: peer) }
        } else if let frames = PhoneBindings.shared.reply(to: line, sender: sender) {
            for frame in frames { send(frame, to: peer) }
        } else if line.hasPrefix("vibepier-audio1 ") || line.contains("vibepier-mic1") {
            // Audio is not relayed; the phone falls back to the Mac microphone.
        } else if let event = RemoteEvent.parse(line), event.sender == sender {
            guard phones[peer]?.dedup.isNew(event) == true else { return }
            if let control = event.control {
                if event.event == "down" && !event.isMomentary { phones[peer]?.held[control] = event }
                if event.event == "up" { phones[peer]?.held[control] = nil }
            }
            handler(event)
        }
    }

    private func offerDirect(_ line: String, peer: String, phone: Phone) {
        guard let directOffer,
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            object["type"] as? String == "vibepier-direct-offer1", object["sender"] as? String == phone.sender,
            let token = object["token"] as? String, let candidates = object["candidates"] as? [String]
        else { return }
        directOffer(phone.sender, token, candidates) { [weak self] mine in
            self?.queue.async { [weak self] in
                guard let self,
                    let data = try? JSONSerialization.data(
                        withJSONObject: [
                            "type": "vibepier-direct-answer1", "sender": phone.sender, "token": token,
                            "candidates": mine,
                        ] as [String: Any])
                else { return }
                self.sendIfActive(data, to: peer, sessionID: phone.sessionID)
            }
        }
    }

    private func armLease() {
        lease?.cancel()
        lease = nil
        guard let next = phones.values.map(\.expires).min() else { return }
        let delay = max(0, next - ProcessInfo.processInfo.systemUptime) + 0.05
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for peer in self.phones.keys.filter({ self.phones[$0]!.expires <= now }) {
                self.dropPhone(peer, disconnectSecurity: false)
            }
            self.armLease()
            self.connectionChanged()
        }
        lease = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dropPhone(_ peer: String, disconnectSecurity: Bool = true) {
        if disconnectSecurity { security.disconnect(peer) }
        guard let phone = phones.removeValue(forKey: peer) else { return }
        for var event in phone.held.values {
            event.event = "up"
            handler(event)
        }
        sessionRemote().disconnected(Self.codexPeer(peer))
    }

    private func dropPhones() {
        lease?.cancel()
        lease = nil
        for peer in Array(phones.keys) { dropPhone(peer) }
        security.disconnectAll()
        changed()
    }

    private func connectionChanged() {
        let count = connectedCount
        changed(
            count > 0
                ? L10n.text("control.phones_connected_via_relay_0", count)
                : L10n.text("control.relay_connected_waiting_for_a_phone"))
    }

    private func publish() {
        for peer in Array(phones.keys) { publish(to: peer) }
    }

    private func publish(to peer: String) {
        guard let phone = phones[peer], phone.expires > ProcessInfo.processInfo.systemUptime else { return }
        let app = application()
        let shortcuts = ApplicationShortcuts.shared.snapshot
        guard
            let data = try? JSONSerialization.data(withJSONObject: [
                "type": "vibepier-app1", "sender": phone.sender, "bundleID": app.bundleID, "name": app.name,
                "shortcutsRevision": shortcuts.revision, "shortcutsCount": shortcuts.entries.count,
                "currentAppRevision": CurrentApplicationShortcut.shared.snapshot.revision,
                "bindingsRevision": PhoneBindings.shared.snapshot.revision,
                "stamp": Int64(ProcessInfo.processInfo.systemUptime * 1_000_000),
            ])
        else { return }
        send(data, to: peer)
    }

    private func sendIfActive(_ data: Data, to peer: String, sessionID: UUID) {
        guard let phone = phones[peer], phone.sessionID == sessionID,
            phone.expires > ProcessInfo.processInfo.systemUptime
        else { return }
        send(data, to: peer)
    }

    private func send(_ data: Data, to peer: String) {
        guard let frame = security.seal(data, peer: peer) else { return }
        sendWire(frame, to: peer)
    }

    private func sendWire(_ data: Data, to peer: String) {
        guard data.count <= SecureControlEnvelope.maximumFrame else { return }
        if let transport {
            transport(peer, data)
            return
        }
        task?.send(.string("vibepier-relay2 to \(peer) \(data.base64EncodedString())")) { _ in }
    }

    private func changed(_ value: String? = nil) {
        if let value { label = value }
        NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: self)
    }
}
