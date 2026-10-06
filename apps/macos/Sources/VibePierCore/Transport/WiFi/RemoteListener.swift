// SPDX-License-Identifier: MIT
//
// Receives button events from the Android remote over UDP. Each datagram is one
// line of text. Application subscriptions receive JSON status replies:
//
//     vibepier1 <sender> <seq> <control> <down|up|step> [keys] [app=<bundleID>]
//     vibepier-watch1 <sender>
//
// `keys` is the hotkey the phone has bound to the button, such as `cmd+return`
// or `wheel-up`. Without it the Mac uses its own binding. The phone sends each event a few times for loss tolerance. `sender` is a
// random ID per app launch and `seq` increases per event, so repeats are dropped.

import AppKit
import Foundation
import VibeKit

struct RemoteEvent: Equatable {
    var sender: String
    var seq: UInt64
    var control: Control?
    var applicationSlot: Int? = nil
    var applicationAction: ApplicationShortcutAction = .activate
    /// "down", "up", or "step".
    var event: String
    /// The hotkey chosen on the phone, or nil for the Mac's own binding.
    var keys: String? = nil
    var applicationID: String? = nil
    /// A repeated delete is a complete tap, never a held key waiting for UDP up.
    var isMomentary: Bool { event == "step" || control == .knobLeft || control == .knobRight }

    static func parse(_ text: String) -> RemoteEvent? {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if (5...6).contains(parts.count), parts[0] == "vibepier-launch1", let seq = UInt64(parts[2]),
            let slot = Int(parts[3]), slot >= -1, !parts[4].isEmpty
        {
            let action: ApplicationShortcutAction
            if parts.count == 5 {
                action = .activate
            } else if parts[5] == "action=hide" {
                action = .hide
            } else {
                return nil
            }
            return RemoteEvent(
                sender: parts[1], seq: seq, control: nil, applicationSlot: slot,
                applicationAction: action, event: "step", applicationID: parts[4])
        }
        guard (5...7).contains(parts.count), parts[0] == "vibepier1", let seq = UInt64(parts[2]),
            let control = Control(name: parts[3]), ["down", "up", "step"].contains(parts[4])
        else { return nil }
        if parts.count == 7 && (!parts[6].hasPrefix("app=") || parts[6].count <= 4) { return nil }
        return RemoteEvent(
            sender: parts[1], seq: seq, control: control, event: parts[4], keys: parts.count >= 6 ? parts[5] : nil,
            applicationID: parts.count == 7 ? String(parts[6].dropFirst(4)) : nil)
    }
}

/// Drops repeated datagrams of the same event.
struct RemoteDeduplicator {
    private var recent: [String] = []
    private var seen: Set<String> = []
    let capacity = 64

    mutating func isNew(_ e: RemoteEvent) -> Bool {
        let key = "\(e.sender):\(e.seq)"
        guard seen.insert(key).inserted else { return false }
        recent.append(key)
        if recent.count > capacity { seen.remove(recent.removeFirst()) }
        return true
    }

    /// One application tap may cross multiple transports while their routes change.
    mutating func isNewApplication(_ event: RemoteEvent) -> Bool {
        var event = event
        if event.sender.hasPrefix("relay:") { event.sender = String(event.sender.dropFirst(6)) }
        if event.sender.hasPrefix("ble:") {
            event.sender = String(event.sender.split(separator: ":", maxSplits: 2).last ?? "")
        }
        return isNew(event)
    }
}

/// Relay-issued punches authorize a particular phone at a particular UDP
/// endpoint. Another phone's sender cannot reuse that endpoint's admission.
struct DirectAdmissions {
    private struct Lease {
        let sender: String
        var expires: TimeInterval
    }
    private var tokens: [String: Lease] = [:]
    private var endpoints: [String: Lease] = [:]

    mutating func offer(sender: String, token: String, now: TimeInterval) -> Bool {
        guard !sender.isEmpty, sender.count <= 64, !sender.contains(where: \.isWhitespace),
            (16...64).contains(token.count), token.allSatisfy(\.isHexDigit)
        else { return false }
        tokens = tokens.filter { $0.value.expires > now }
        if let other = tokens[token], other.sender != sender { return false }
        let remaining = tokens.filter { $0.value.sender != sender }
        guard remaining.count < 32 else { return false }
        tokens = remaining
        tokens[token] = Lease(sender: sender, expires: now + 120)
        return true
    }

    func hasToken(_ token: String, sender: String, now: TimeInterval) -> Bool {
        guard let lease = tokens[token] else { return false }
        return lease.sender == sender && lease.expires > now
    }

    mutating func admit(endpoint: String, sender: String, token: String, now: TimeInterval) -> Bool {
        guard hasToken(token, sender: sender, now: now) else { return false }
        endpoints = endpoints.filter { $0.value.expires > now }
        if let other = endpoints[endpoint], other.sender != sender { return false }
        guard endpoints[endpoint] != nil || endpoints.count < 64 else { return false }
        endpoints[endpoint] = Lease(sender: sender, expires: now + 60)
        return true
    }

    mutating func allows(endpoint: String, sender: String, now: TimeInterval, renew: Bool = true) -> Bool {
        guard let lease = endpoints[endpoint], lease.sender == sender, lease.expires > now else { return false }
        if renew { endpoints[endpoint]?.expires = now + 60 }
        return true
    }

    static func sender(in text: String) -> String? {
        if let sender = RemoteEvent.parse(text)?.sender { return sender }
        let fields = text.split(whereSeparator: \.isWhitespace)
        if fields.count == 2,
            ["vibepier-watch1", "vibepier-ack1", "vibepier-slots1", "vibepier-current1"].contains(String(fields[0]))
        {
            return String(fields[1])
        }
        if (fields.count == 5 && ["vibepier-audio1", SecureControlEnvelope.frame].contains(String(fields[0])))
            || (fields.count == 7 && String(fields[0]) == SecureControlEnvelope.hello)
        {
            return String(fields[1])
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["sender"] as? String
    }

    mutating func removeAll() {
        tokens.removeAll()
        endpoints.removeAll()
    }
}

final class RemoteListener: @unchecked Sendable {
    static let defaultPort: UInt16 = 47800
    private let queue = DispatchQueue(label: "vibepier.remote")
    private var sources: [DispatchSourceRead] = []
    private var fd4: Int32 = -1
    private var fd6: Int32 = -1
    private var port: UInt16 = 0
    private var dedup = RemoteDeduplicator()
    private let sessionRemote: @Sendable () -> any SessionRemoteRouting
    private let microphoneAllowed: @Sendable () -> Bool
    private let microphone: @Sendable () -> PhoneMicrophone
    private let handler: @Sendable (RemoteEvent) -> Void
    private let application: @Sendable () -> FrontmostApplication
    private let leaseSeconds: TimeInterval
    private var applicationObserver: NSObjectProtocol?
    private var shortcutsObserver: NSObjectProtocol?
    private var currentApplicationObserver: NSObjectProtocol?
    private var bindingsObserver: NSObjectProtocol?
    private var trustObserver: NSObjectProtocol?
    private let security: SecureControlServer
    private struct Client {
        var endpoint: UDPEndpoint
        var sender: String
        var expires: TimeInterval
        var confirmed = false
        let identity = UUID()
        var held: [Control: RemoteEvent] = [:]
    }
    private var clients: [String: Client] = [:]
    private var expiry: DispatchWorkItem?
    private var lastPublishedPeers: [String] = []
    private var lastPublishedDevices: [String] = []
    /// Punch tokens learned over the authenticated relay, and the internet sources they admitted.
    private var directAdmissions = DirectAdmissions()
    private var publicAddress: (value: String, at: TimeInterval)?
    private var stunTransactions: Set<[UInt8]> = []
    private var pendingAnswers: [@Sendable ([String]) -> Void] = []
    private var running: Bool { !sources.isEmpty }

    var connectedAddresses: [String] {
        queue.sync { addresses() }
    }
    var connectedDeviceIDs: [String] { queue.sync { deviceIDs() } }

    private func deviceIDs() -> [String] {
        let now = ProcessInfo.processInfo.systemUptime
        return Array(Set(clients.values.filter { $0.confirmed && $0.expires > now }.map(\.sender))).sorted()
    }

    private func addresses() -> [String] {
        let now = ProcessInfo.processInfo.systemUptime
        return Array(Set(clients.values.filter { $0.confirmed && $0.expires > now }.map(\.endpoint.host))).sorted()
    }

    private func updatePresence() {
        let now = ProcessInfo.processInfo.systemUptime
        for id in clients.keys.filter({ clients[$0]!.expires <= now || security.device(for: $0) != clients[$0]!.sender }
        ) { dropClient(id, disconnectSecurity: security.device(for: id) != clients[id]?.sender) }
        let peers = addresses()
        let devices = deviceIDs()
        if peers != lastPublishedPeers || devices != lastPublishedDevices {
            lastPublishedPeers = peers
            lastPublishedDevices = devices
            NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: self)
        }
        expiry?.cancel()
        expiry = nil
        if let next = clients.values.map(\.expires).min() {
            let work = DispatchWorkItem { [weak self] in self?.updatePresence() }
            expiry = work
            queue.asyncAfter(deadline: .now() + max(0.01, next - now), execute: work)
        }
    }

    init(
        application: @escaping @Sendable () -> FrontmostApplication = { .current() },
        leaseSeconds: TimeInterval = 12,
        microphoneAllowed: @escaping @Sendable () -> Bool = { true },
        microphone: @escaping @Sendable () -> PhoneMicrophone = { PhoneMicrophone.shared },
        keyForDevice: @escaping @Sendable (String) -> Data? = { DeviceTrustStore.shared.key(for: $0) },
        sessionRemote: @escaping @Sendable () -> any SessionRemoteRouting = { SessionRemote.shared },
        handler: @escaping @Sendable (RemoteEvent) -> Void
    ) {
        self.sessionRemote = sessionRemote
        security = SecureControlServer(keyForDevice: keyForDevice)
        self.microphoneAllowed = microphoneAllowed
        self.microphone = microphone
        self.application = application
        self.leaseSeconds = leaseSeconds
        self.handler = handler
    }

    func start(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw CLIError(L10n.text("cli.udp_socket_failed", errno)) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let err = errno
            close(fd)
            throw CLIError(L10n.text("cli.udp_bind_failed", port, err))
        }
        // IPv6 is optional (direct path only); a separate v6-only socket leaves IPv4 broadcast discovery untouched.
        var v6: Int32 = -1
        let fd6 = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        if fd6 >= 0 {
            setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd6, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = port.bigEndian
            addr6.sin6_addr = in6addr_any
            let rc6 = withUnsafePointer(to: &addr6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            if rc6 == 0 { v6 = fd6 } else { close(fd6) }
        }
        queue.sync {
            self.port = port
            self.fd4 = fd
            self.fd6 = v6
            for descriptor in [fd, v6] where descriptor >= 0 {
                let src = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                src.setEventHandler { [weak self] in self?.receive(descriptor) }
                src.setCancelHandler { close(descriptor) }
                sources.append(src)
                src.resume()
            }
        }
        bindingsObserver = NotificationCenter.default.addObserver(
            forName: PhoneBindings.changed, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.publishApplication() }
        }
        shortcutsObserver = NotificationCenter.default.addObserver(
            forName: ApplicationShortcuts.changed, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.publishApplication() }
        }
        currentApplicationObserver = NotificationCenter.default.addObserver(
            forName: CurrentApplicationShortcut.changed, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.publishApplication() }
        }
        trustObserver = NotificationCenter.default.addObserver(
            forName: DeviceTrustStore.changed, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.updatePresence() }
        }
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.publishApplication() }
        }
    }

    func stop() {
        if let trustObserver { NotificationCenter.default.removeObserver(trustObserver) }
        trustObserver = nil
        if let bindingsObserver { NotificationCenter.default.removeObserver(bindingsObserver) }
        bindingsObserver = nil
        if let shortcutsObserver { NotificationCenter.default.removeObserver(shortcutsObserver) }
        shortcutsObserver = nil
        if let currentApplicationObserver { NotificationCenter.default.removeObserver(currentApplicationObserver) }
        currentApplicationObserver = nil
        if let applicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver)
            self.applicationObserver = nil
        }
        queue.sync {
            for source in sources { source.cancel() }
            sources.removeAll()
            fd4 = -1
            fd6 = -1
            for id in Array(clients.keys) { dropClient(id) }
            security.disconnectAll()
            directAdmissions.removeAll()
            let answers = pendingAnswers
            pendingAnswers.removeAll()
            for answer in answers { answer([]) }
            expiry?.cancel()
            expiry = nil
        }
    }

    // MARK: Direct path

    /// Called with an offer the phone sent over the relay: remembers its token, punches
    /// towards its candidates, and answers with this Mac's own candidates.
    func acceptDirect(
        sender: String, token: String, candidates: [String], answer: @escaping @Sendable ([String]) -> Void
    ) {
        queue.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            guard running, directAdmissions.offer(sender: sender, token: token, now: now) else {
                answer([])
                return
            }
            let targets = candidates.prefix(8).compactMap { UDPEndpoint(candidate: $0, fd4: fd4, fd6: fd6) }
            let punch = Data("vibepier-punch1 \(sender) \(token)".utf8)
            for delay in [0, 0.15, 0.4, 0.8, 1.5, 2.5, 4] {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.running,
                        self.directAdmissions.hasToken(
                            token, sender: sender,
                            now: ProcessInfo.processInfo.systemUptime)
                    else { return }
                    for target in targets { target.send(punch) }
                }
            }
            if let cached = publicAddress, now - cached.at < 120 {
                answer(ownCandidates())
                return
            }
            pendingAnswers.append(answer)
            queryPublicAddress()
            queue.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.flushAnswers() }
        }
    }

    private func ownCandidates() -> [String] {
        var list = publicAddress.map { [$0.value] } ?? []
        for candidate in UDPEndpoint.interfaceCandidates(port: port, includeIPv6: fd6 >= 0)
        where !list.contains(candidate) {
            list.append(candidate)
        }
        return list
    }

    private func flushAnswers() {
        let answers = pendingAnswers
        pendingAnswers.removeAll()
        guard !answers.isEmpty else { return }
        let mine = ownCandidates()
        for answer in answers { answer(mine) }
    }

    /// Asks public STUN servers, from the listening socket itself, which IPv4 address:port the NAT shows.
    private func queryPublicAddress() {
        STUN.resolve { [weak self] servers in
            self?.queue.async { [weak self] in
                guard let self, self.running else { return }
                for server in servers {
                    guard let target = UDPEndpoint(candidate: server, fd4: self.fd4, fd6: -1) else { continue }
                    var transaction = [UInt8](repeating: 0, count: 12)
                    _ = SecRandomCopyBytes(kSecRandomDefault, 12, &transaction)
                    self.stunTransactions.insert(transaction)
                    target.send(STUN.request(transaction: transaction))
                }
            }
        }
    }

    private func receivePunch(_ parts: [Substring], from endpoint: UDPEndpoint) {
        let now = ProcessInfo.processInfo.systemUptime
        guard parts.count == 3,
            directAdmissions.admit(
                endpoint: endpoint.id,
                sender: String(parts[1]), token: String(parts[2]), now: now)
        else { return }
        endpoint.send(Data("vibepier-punch-ok1 \(parts[1]) \(parts[2])".utf8))
    }

    // MARK: Receive

    private func receive(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: SecureControlEnvelope.maximumFrame + 1)
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &length) }
        }
        guard n > 0, let endpoint = UDPEndpoint(fd: fd, storage: storage, length: length) else { return }
        let bytes = Array(buf[0..<n])
        if STUN.isResponse(bytes) {
            if stunTransactions.remove(STUN.transaction(bytes)) != nil, let mapped = STUN.mappedAddress(bytes) {
                publicAddress = (mapped, ProcessInfo.processInfo.systemUptime)
                flushAnswers()
            }
            return
        }
        let wire = String(decoding: bytes, as: UTF8.self)
        let outer = wire.split(whereSeparator: \.isWhitespace)
        let id = endpoint.id
        if outer.first == "vibepier-punch1" {
            receivePunch(outer, from: endpoint)
            return
        }
        if !endpoint.isLocal {
            // Internet sources only after a punch carrying a relay-issued token.
            let now = ProcessInfo.processInfo.systemUptime
            guard let sender = DirectAdmissions.sender(in: wire),
                directAdmissions.allows(endpoint: id, sender: sender, now: now, renew: false)
            else { return }
        }
        let previousSession = security.sessionIdentifier(for: id)
        let text: String
        let device: String
        switch security.receive(Data(bytes), peer: id) {
        case .handshake(let reply):
            if !endpoint.isLocal, let sender = DirectAdmissions.sender(in: wire) {
                _ = directAdmissions.allows(endpoint: id, sender: sender, now: ProcessInfo.processInfo.systemUptime)
            }
            if previousSession != security.sessionIdentifier(for: id) { dropClient(id, disconnectSecurity: false) }
            endpoint.send(reply)
            return
        case .message(let authenticatedDevice, let payload):
            guard let clear = String(data: payload, encoding: .utf8),
                DirectAdmissions.sender(in: clear) == authenticatedDevice
            else { return }
            text = clear
            device = authenticatedDevice
            if !endpoint.isLocal {
                _ = directAdmissions.allows(endpoint: id, sender: device, now: ProcessInfo.processInfo.systemUptime)
            }
        case .rejected: return
        }
        let parts = text.split(whereSeparator: \.isWhitespace)
        if parts.count == 2, parts[0] == "vibepier-ack1", clients[id]?.sender == String(parts[1]) {
            clients[id]?.confirmed = true
            updatePresence()
            return
        }
        if parts.count == 2, parts[0] == "vibepier-watch1", parts[1].count <= 64 {
            let now = ProcessInfo.processInfo.systemUptime
            for id in clients.keys.filter({
                clients[$0]!.expires <= now || security.device(for: $0) != clients[$0]!.sender
            }) { dropClient(id, disconnectSecurity: security.device(for: id) != clients[id]?.sender) }
            guard clients[id] != nil || clients.count < 32 else { return }
            if clients[id]?.sender == device {
                clients[id]?.endpoint = endpoint
                clients[id]?.expires = now + leaseSeconds
            } else {
                dropClient(id, disconnectSecurity: false)
                clients[id] = Client(endpoint: endpoint, sender: device, expires: now + leaseSeconds)
            }
            sessionRemote().touch("udp:" + id)
            updatePresence()
            publishApplication()
            return
        }
        if parts.count == 2, parts[0] == "vibepier-slots1", running, clients[id]?.sender == String(parts[1]) {
            for data in ApplicationShortcuts.shared.frames(sender: String(parts[1])) { send(data, to: endpoint) }
            return
        }
        if parts.count == 2, parts[0] == "vibepier-current1", running, let client = clients[id],
            client.sender == String(parts[1]), client.expires > ProcessInfo.processInfo.systemUptime
        {
            for data in CurrentApplicationShortcut.shared.frames(sender: client.sender) { send(data, to: endpoint) }
            return
        }
        if let client = clients[id], client.expires > ProcessInfo.processInfo.systemUptime,
            text.contains("vibepier-session1")
        {
            let identity = client.identity
            sessionRemote().receive(Data(text.utf8), peer: "udp:" + id, sender: client.sender) {
                [weak self] frames in
                self?.queue.async { [weak self] in
                    guard let self, self.running, let client = self.clients[id], client.identity == identity else {
                        return
                    }
                    for frame in frames { self.send(frame, to: client.endpoint) }
                }
            }
            return
        }
        if let client = clients[id], client.expires > ProcessInfo.processInfo.systemUptime,
            let frames = PhoneBindings.shared.reply(to: text, sender: client.sender)
        {
            for data in frames { send(data, to: endpoint) }
            return
        }
        if let client = clients[id], client.expires > ProcessInfo.processInfo.systemUptime,
            text.hasPrefix("vibepier-audio1 ") || text.contains("vibepier-mic1")
        {
            if let data = microphone().receive(
                text, peer: "udp:" + id, sender: client.sender, canBegin: microphoneAllowed())
            {
                send(data, to: endpoint)
            }
            return
        }
        guard let client = clients[id], client.sender == device, client.expires > ProcessInfo.processInfo.systemUptime,
            let e = RemoteEvent.parse(text), e.sender == device, dedup.isNew(e)
        else { return }
        if let control = e.control {
            if e.event == "down" && !e.isMomentary { clients[id]?.held[control] = e }
            if e.event == "up" { clients[id]?.held[control] = nil }
        }
        handler(e)
    }

    private func send(_ data: Data, to endpoint: UDPEndpoint) {
        guard let frame = security.seal(data, peer: endpoint.id) else { return }
        endpoint.send(frame)
    }

    private func dropClient(_ id: String, disconnectSecurity: Bool = true) {
        if disconnectSecurity { security.disconnect(id) }
        guard let client = clients.removeValue(forKey: id) else { return }
        for var event in client.held.values {
            event.event = "up"
            handler(event)
        }
        microphone().disconnect("udp:" + id)
        sessionRemote().disconnected("udp:" + id)
    }

    private func publishApplication() {
        // Queued callbacks after stop must not write to a closed/reused descriptor.
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for id in clients.keys.filter({ clients[$0]!.expires <= now || security.device(for: $0) != clients[$0]!.sender }
        ) { dropClient(id, disconnectSecurity: security.device(for: id) != clients[id]?.sender) }
        let app = application()
        let shortcuts = ApplicationShortcuts.shared.snapshot
        for client in clients.values {
            let payload: [String: Any] = [
                "type": "vibepier-app1", "sender": client.sender,
                "bundleID": app.bundleID, "name": app.name, "bindingsRevision": PhoneBindings.shared.snapshot.revision,
                "shortcutsRevision": shortcuts.revision, "shortcutsCount": shortcuts.entries.count,
                "currentAppRevision": CurrentApplicationShortcut.shared.snapshot.revision,
                "stamp": Int64(now * 1_000_000),
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            send(data, to: client.endpoint)
        }
    }
}
