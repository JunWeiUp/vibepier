import AppKit
@preconcurrency import CoreBluetooth
import Foundation
import VibeKit

/// BLE uses the same commands as UDP, framed by newline and split at the ATT MTU.
struct RemoteLineBuffer {
    private var bytes = Data()
    mutating func append(_ data: Data) -> [String] {
        bytes.append(data)
        guard bytes.count <= SecureControlEnvelope.maximumFrame else {
            bytes.removeAll()
            return []
        }
        var lines: [String] = []
        while let end = bytes.firstIndex(of: 10) {
            if let line = String(data: bytes[..<end], encoding: .utf8) { lines.append(line) }
            bytes.removeSubrange(...end)
        }
        return lines
    }
}

final class BluetoothRemote: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    static var serviceID: CBUUID { CBUUID(string: "A5780001-2BD2-4D66-ABE6-7C9F0F4B9100") }
    static var commandID: CBUUID { CBUUID(string: "A5780002-2BD2-4D66-ABE6-7C9F0F4B9100") }
    static var stateID: CBUUID { CBUUID(string: "A5780003-2BD2-4D66-ABE6-7C9F0F4B9100") }
    static var sessionPairID: CBUUID { CBUUID(string: "A5780004-2BD2-4D66-ABE6-7C9F0F4B9100") }
    private let queue = DispatchQueue(label: "vibepier.bluetooth")
    private var manager: CBPeripheralManager?
    private var stateCharacteristic: CBMutableCharacteristic?
    private var observer: NSObjectProtocol?
    private var shortcutsObserver: NSObjectProtocol?
    private var currentApplicationObserver: NSObjectProtocol?
    private var bindingsObserver: NSObjectProtocol?
    private var trustObserver: NSObjectProtocol?
    private let security = SecureControlServer(
        keyForDevice: { DeviceTrustStore.shared.key(for: $0) },
        capabilities: ControlProtocol.required | ControlProtocol.phoneAudio)
    private var buffers: [UUID: RemoteLineBuffer] = [:]
    private var centrals: [UUID: CBCentral] = [:]
    private var senders: [UUID: String] = [:]
    private var held: [UUID: [Control: RemoteEvent]] = [:]
    private var pending = BluetoothNotificationQueue()
    private var chatPending: [(UUID, Data)] = []
    private var dedup = RemoteDeduplicator()
    private var label = L10n.text("mac.not_started")
    private let sessionRemote: @Sendable () -> any SessionRemoteRouting
    private let microphoneAllowed: @Sendable () -> Bool
    private let handler: @Sendable (RemoteEvent) -> Void
    init(
        microphoneAllowed: @escaping @Sendable () -> Bool = { true },
        sessionRemote: @escaping @Sendable () -> any SessionRemoteRouting = { SessionRemote.shared },
        handler: @escaping @Sendable (RemoteEvent) -> Void
    ) {
        self.sessionRemote = sessionRemote
        self.microphoneAllowed = microphoneAllowed
        self.handler = handler
    }
    var status: [String: Any] {
        queue.sync {
            [
                "state": label, "connectedCount": Set(senders.values).count,
                "deviceIDs": Array(Set(senders.values)).sorted(),
                "authorization": CBManager.authorization.rawValue, "managerState": manager?.state.rawValue ?? -1,
            ]
        }
    }
    func start() {
        label =
            CBManager.authorization == .notDetermined
            ? L10n.text("control.waiting_for_system_bluetooth_permission") : L10n.text("control.preparing_bluetooth")
        manager = CBPeripheralManager(delegate: self, queue: queue)
        bindingsObserver = NotificationCenter.default.addObserver(
            forName: PhoneBindings.changed, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.publish() }
        }
        shortcutsObserver = NotificationCenter.default.addObserver(
            forName: ApplicationShortcuts.changed, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.publish() }
        }
        currentApplicationObserver = NotificationCenter.default.addObserver(
            forName: CurrentApplicationShortcut.changed, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.publish() }
        }
        trustObserver = NotificationCenter.default.addObserver(
            forName: DeviceTrustStore.changed, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                for id in self.senders.keys.filter({ self.security.device(for: $0.uuidString) != self.senders[$0] }) {
                    self.dropPeerState(id)
                }
                self.changed()
            }
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.queue.async { [weak self] in self?.publish() } }
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
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        queue.sync {
            manager?.stopAdvertising()
            manager?.removeAllServices()
            manager?.delegate = nil
            manager = nil
            for id in Array(centrals.keys) { dropPeerState(id) }
            security.disconnectAll()
            centrals.removeAll()
            senders.removeAll()
            buffers.removeAll()
            pending.removeAll()
            chatPending.removeAll()
        }
    }
    private func changed(_ value: String? = nil) {
        if let value { label = value }
        NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: self)
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            for id in centrals.keys { sessionRemote().disconnected("ble:" + id.uuidString) }
            for id in Array(centrals.keys) { dropPeerState(id) }
            security.disconnectAll()
            centrals.removeAll()
            senders.removeAll()
            buffers.removeAll()
            pending.removeAll()
            chatPending.removeAll()
            for id in Array(held.keys) { releaseKeys(id) }
            let text: String
            switch peripheral.state {
            case .unauthorized: text = L10n.text("control.allow_vibepier_to_use_bluetooth_in_system_settings")
            case .poweredOff: text = L10n.text("control.bluetooth_is_off_on_the_mac")
            case .unsupported: text = L10n.text("control.this_mac_does_not_support_ble")
            default: text = L10n.text("control.preparing_bluetooth")
            }
            changed(text)
            return
        }
        let command = CBMutableCharacteristic(
            type: Self.commandID, properties: [.write], value: nil,
            permissions: [.writeable, .writeEncryptionRequired])
        let state = CBMutableCharacteristic(type: Self.stateID, properties: [.notify], value: nil, permissions: [])
        stateCharacteristic = state
        let service = CBMutableService(type: Self.serviceID, primary: true)
        let pair = CBMutableCharacteristic(
            type: Self.sessionPairID, properties: [.read], value: nil,
            permissions: [.readable, .readEncryptionRequired])
        service.characteristics = [command, state, pair]
        peripheral.removeAllServices()
        peripheral.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            changed(L10n.text("control.bluetooth_service_failed_0", error.localizedDescription))
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceID],
            CBAdvertisementDataLocalNameKey: "VibePier",
        ])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        changed(
            error.map { L10n.text("control.bluetooth_advertising_failed_0", $0.localizedDescription) }
                ?? L10n.text("control.ready_to_connect"))
    }
    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        centrals[central.identifier] = central
    }
    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        dropPeerState(central.identifier)
        centrals.removeValue(forKey: central.identifier)
        buffers.removeValue(forKey: central.identifier)
        pending.remove(central.identifier)
        PhoneMicrophone.shared.disconnect("ble:" + central.identifier.uuidString)
        sessionRemote().disconnected("ble:" + central.identifier.uuidString)
        chatPending.removeAll { $0.0 == central.identifier }
        releaseKeys(central.identifier)
        changed()
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard
            requests.allSatisfy({
                $0.characteristic.uuid == Self.commandID && $0.offset == 0 && $0.value != nil
                    && centrals[$0.central.identifier] != nil
            })
        else {
            peripheral.respond(to: first, withResult: .requestNotSupported)
            return
        }
        for request in requests {
            guard let data = request.value else { continue }
            let id = request.central.identifier
            let lines = buffers[id, default: RemoteLineBuffer()].append(data)
            for wire in lines {
                let outer = wire.split(whereSeparator: \.isWhitespace)
                guard let central = centrals[id] else { continue }
                // Encrypted GATT permits explicit enrollment and a minimal discovery reply only.
                if outer.count == 2, outer[0] == "vibepier-discover1", UUID(uuidString: String(outer[1])) != nil {
                    enqueue(Data("vibepier-available1 \(outer[1]) 1".utf8), central: central, wire: true)
                    continue
                }
                if let data = wire.data(using: .utf8), data.count <= 4096,
                    let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    value["type"] as? String == "vibepier-session-pair1",
                    let device = value["device"] as? String, UUID(uuidString: device) != nil,
                    value["sender"] as? String == device
                {
                    sessionRemote().requestPair(data, peer: "ble:" + id.uuidString)
                    continue
                }
                let previousSession = security.sessionIdentifier(for: id.uuidString)
                let line: String
                let device: String
                switch security.receive(Data(wire.utf8), peer: id.uuidString) {
                case .handshake(let reply):
                    if previousSession != security.sessionIdentifier(for: id.uuidString) {
                        dropPeerState(id, disconnectSecurity: false)
                    }
                    enqueue(reply, central: central, wire: true)
                    continue
                case .message(let authenticatedDevice, let payload):
                    guard let text = String(data: payload, encoding: .utf8),
                        DirectAdmissions.sender(in: text) == authenticatedDevice
                    else { continue }
                    line = text
                    device = authenticatedDevice
                case .rejected: continue
                }
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.first == "vibepier-watch1" || senders[id] == device else { continue }
                if parts.count == 2, parts[0] == "vibepier-watch1" {
                    guard parts[1].count <= 64 else { continue }
                    let isNew = senders[id] == nil
                    senders[id] = String(parts[1])
                    sessionRemote().touch("ble:" + id.uuidString)
                    if isNew { changed() }
                    publish(to: id)
                } else if let sender = senders[id], line.contains("vibepier-session1"),
                    let bytes = line.data(using: .utf8)
                {
                    let sessionID = security.sessionIdentifier(for: id.uuidString)
                    sessionRemote().receive(bytes, peer: "ble:" + id.uuidString, sender: sender) {
                        [weak self] frames in
                        self?.queue.async { [weak self] in
                            guard let self, self.centrals[id] != nil,
                                self.security.sessionIdentifier(for: id.uuidString) == sessionID,
                                self.chatPending.count + frames.count <= 1024
                            else { return }
                            self.chatPending.append(contentsOf: frames.map { (id, $0) })
                            self.flush()
                        }
                    }
                } else if parts.count == 2, parts[0] == "vibepier-slots1", senders[id] == String(parts[1]),
                    let central = centrals[id]
                {
                    // Do not enqueue duplicate icon transfers while a previous one is draining.
                    guard pending.count < 64 else { continue }
                    for data in ApplicationShortcuts.shared.frames(sender: String(parts[1])) {
                        enqueue(data, central: central)
                    }
                    flush()
                } else if parts.count == 2, parts[0] == "vibepier-current1", senders[id] == String(parts[1]),
                    let central = centrals[id]
                {
                    guard pending.count < 64 else { continue }
                    for data in CurrentApplicationShortcut.shared.frames(sender: String(parts[1])) {
                        enqueue(data, central: central)
                    }
                    flush()
                } else if let sender = senders[id], let central = centrals[id],
                    let frames = PhoneBindings.shared.reply(to: line, sender: sender)
                {
                    for data in frames { enqueue(data, central: central) }
                    flush()
                } else if let sender = senders[id], let central = centrals[id],
                    line.hasPrefix("vibepier-audio1 ") || line.contains("vibepier-mic1")
                {
                    if let data = PhoneMicrophone.shared.receive(
                        line, peer: "ble:" + id.uuidString, sender: sender, canBegin: microphoneAllowed())
                    {
                        enqueue(data, central: central)
                        flush()
                    }
                } else if let event = RemoteEvent.parse(line), senders[id] == event.sender {
                    if dedup.isNew(event) {
                        if let control = event.control {
                            if event.event == "down" && !event.isMomentary { held[id, default: [:]][control] = event }
                            if event.event == "up" { held[id]?[control] = nil }
                        }
                        handler(event)
                    }
                }
            }
        }
        peripheral.respond(to: first, withResult: .success)
        flush()
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.sessionPairID, centrals[request.central.identifier] != nil else {
            peripheral.respond(to: request, withResult: .readNotPermitted)
            return
        }
        let data = sessionRemote().pairResult("ble:" + request.central.identifier.uuidString)
        guard request.offset <= data.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = data.subdata(in: request.offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
    }
    private func dropPeerState(_ id: UUID, disconnectSecurity: Bool = true) {
        if disconnectSecurity { security.disconnect(id.uuidString) }
        senders.removeValue(forKey: id)
        pending.remove(id)
        chatPending.removeAll { $0.0 == id }
        PhoneMicrophone.shared.disconnect("ble:" + id.uuidString)
        sessionRemote().disconnected("ble:" + id.uuidString)
        releaseKeys(id)
    }

    private func releaseKeys(_ id: UUID) {
        guard let events = held.removeValue(forKey: id) else { return }
        for var event in events.values {
            event.event = "up"
            handler(event)
        }
    }

    private func publish(to id: UUID? = nil) {
        let app = FrontmostApplication.current()
        let shortcuts = ApplicationShortcuts.shared.snapshot
        for (peer, sender) in senders where id == nil || id == peer {
            guard let central = centrals[peer],
                let data = try? JSONSerialization.data(withJSONObject: [
                    "type": "vibepier-app1", "sender": sender, "bundleID": app.bundleID, "name": app.name,
                    "shortcutsRevision": shortcuts.revision, "shortcutsCount": shortcuts.entries.count,
                    "currentAppRevision": CurrentApplicationShortcut.shared.snapshot.revision,
                    "bindingsRevision": PhoneBindings.shared.snapshot.revision,
                    "stamp": Int64(ProcessInfo.processInfo.systemUptime * 1_000_000),
                ])
            else { continue }
            enqueue(data, central: central)
        }
        flush()
    }
    private func enqueue(_ payload: Data, central: CBCentral, urgent: Bool = false, wire: Bool = false) {
        guard let value = wire ? payload : security.seal(payload, peer: central.identifier.uuidString) else { return }
        let size = min(512, max(1, central.maximumUpdateValueLength))
        let chunks = (value.count + 1 + size - 1) / size
        guard pending.count + chunks <= 65536 else { return }
        pending.append(value, peer: central.identifier, size: size, urgent: urgent)
    }
    private func flush() {
        guard let manager, let stateCharacteristic else { return }
        while true {
            if pending.betweenLines, !PhoneMicrophone.shared.active, !chatPending.isEmpty {
                let (id, frame) = chatPending.removeFirst()
                if let central = centrals[id] { enqueue(frame, central: central, urgent: true) }
            }
            guard let frame = pending.first(allowPriority: !PhoneMicrophone.shared.active) else { return }
            if let sender = senders[frame.peer], security.device(for: frame.peer.uuidString) != sender {
                dropPeerState(frame.peer)
                continue
            }
            guard let central = centrals[frame.peer] else {
                pending.remove(frame.peer)
                continue
            }
            guard manager.updateValue(frame.data, for: stateCharacteristic, onSubscribedCentrals: [central]) else {
                return
            }
            pending.removeFirst()
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flush() }
}
