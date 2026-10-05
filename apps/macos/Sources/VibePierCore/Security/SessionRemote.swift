import AppKit
import CryptoKit
import Foundation
import Security

public struct AuthorizedPhone: Identifiable, Sendable {
    public let id: String
    public let name: String
}

public struct PhoneAPKDeviceSnapshot: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let installedVersion: String?
    public let status: PhoneAPKStatus?
}
public struct PhoneAPKSnapshot: Sendable {
    public let phones: [PhoneAPKDeviceSnapshot]
    public let latestVersion: String?
    public let publishing: Bool
}

struct SessionEnvelope {
    static func aad(device: String, packet: String, direction: String) -> Data {
        Data("vibepier-session-v1|\(direction)|\(device)|\(packet)".utf8)
    }
    static func seal(_ data: Data, key: Data, device: String, packet: String, direction: String) throws -> Data {
        guard key.count == 32 else { throw CLIError(L10n.text("control.invalid_device_key")) }
        guard
            let result = try AES.GCM.seal(
                data, using: SymmetricKey(data: key),
                authenticating: aad(device: device, packet: packet, direction: direction)
            ).combined
        else { throw CLIError(L10n.text("control.encryption_failed")) }
        return result
    }
    static func open(_ data: Data, key: Data, device: String, packet: String, direction: String) throws -> Data {
        guard key.count == 32 else { throw CLIError(L10n.text("control.invalid_device_key")) }
        return try AES.GCM.open(
            AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key),
            authenticating: aad(device: device, packet: packet, direction: direction))
    }
    static func frames(
        _ data: Data, device: String, packet: String, sender: String, fragmentChars: Int = 900, requestID: String? = nil
    ) -> [Data] {
        guard fragmentChars == 900 || (fragmentChars == 7200 && requestID != nil) else { return [] }
        let text = Array(data.base64EncodedString().utf8)
        let parts = (text.count + fragmentChars - 1) / fragmentChars
        var frames: [Data] = []
        for i in stride(from: 0, to: text.count, by: fragmentChars) {
            var frame: [String: Any] = [
                "type": "vibepier-session1", "device": device, "sender": sender, "packet": packet,
                "part": i / fragmentChars, "parts": parts,
                "data": String(decoding: text[i..<min(i + fragmentChars, text.count)], as: UTF8.self),
            ]
            if fragmentChars == 7200 { frame["request"] = requestID }
            guard let bytes = try? JSONSerialization.data(withJSONObject: frame, options: [.withoutEscapingSlashes]),
                bytes.count <= (fragmentChars == 7200 ? SecureControlEnvelope.maximumPlaintext : 4096)
            else { return [] }
            frames.append(bytes)
        }
        return frames
    }
}

/// Provider RPC uses the same device trust store as remote controls. Provider credentials stay on the Mac.
public final class SessionRemote: @unchecked Sendable {
    public static let shared = SessionRemote()
    public static let accessChanged = DeviceTrustStore.changed
    private struct Route {
        let peer: String
        let sender: String
        let send: @Sendable ([Data]) -> Void
    }
    private let queue = DispatchQueue(label: "vibepier.codex-remote")
    private let apk = PhoneAPK()
    private let appVersions = PhoneAppVersions()
    private let apkWorkers = APKPreparationWorkers()
    private var apkReservations = APKStageReservations()
    private var publishingAPK: APKPreparationJob?
    private let codexUsage = CodexUsage()
    private let coordinator = AgentSessionCoordinator(
        registry: try! AgentAdapterRegistry(CurrentV1AgentAdapter.production()))
    private let trust = DeviceTrustStore.shared
    private let runtimeHost = AgentRuntimeHost()
    private lazy var agentService: AgentSessionService? = makeAgentService()
    private var journal: SessionReceiptJournal?
    private var inbox = SessionPacketInbox()
    private var routes: [String: Route] = [:]
    private var lastPeer: [String: Double] = [:]
    private var lease: DispatchWorkItem?
    private var pairResults: [String: Data] = [:]
    private var pairing = Set<String>()
    private var outgoing:
        [String: (device: String, frames: [Data], created: Double, fastPeer: String?, provider: String?)] = [:]
    /// Final replies produced while the phone had no live route (e.g. its screen locked mid-creation). Bounded and
    /// short-lived; the journal stays authoritative and the phone's read-only operation lookup covers anything dropped.
    private var undelivered: [String: [(data: Data, created: Double)]] = [:]
    private var readReplies = SessionReadReplies()
    private var providerPolicy = SessionProviderPolicy()
    private let executions = SessionWorkBudget(lanes: SessionRequestLane.limits)
    private let events = SessionWorkBudget()
    private let ingress = SessionWorkBudget(
        limits: .init(perDevice: 4096, total: 8192, bytesPerDevice: 4 * 1024 * 1024, bytesTotal: 16 * 1024 * 1024))
    private var taskViews: [String: TaskViewIntent] = [:]
    private let receiptFile = Paths.supportDirectory.appendingPathComponent("codex-receipts.json")
    private init() {
        journal = try? SessionReceiptJournal(file: receiptFile)
        coordinator.event = { [weak self] client, provider, data in
            guard let self else { return }
            self.queue.async { self.agentService?.receiveCurrentV1Event(data, provider: provider, client: client) }
            self.enqueueEvent(data, device: client, provider: provider)
        }
        runtimeHost.event = { [weak self] client, adapter, data in
            guard let self else { return }
            self.queue.async {
                self.agentService?.receiveAdapterEvent(
                    data, adapterID: adapter,
                    provider: adapter.hasPrefix("codex.") ? "codex" : "claude", client: client)
            }
        }
    }
    func warmOptions() {
        let policy = queue.sync { providerPolicy }
        coordinator.warmOptions(policy: policy)
    }
    func restoreAgentRuntimes() { runtimeHost.restoreExplicitConfiguration() }
    func agentRuntimeCommand(_ request: [String: Any], completion: @escaping @Sendable (Data) -> Void) {
        runtimeHost.localCommand(request, completion: completion)
    }
    /// Uses only existing authenticated routes and the regular encrypted event budget.
    func taskCompleted(_ event: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        queue.async {
            for device in self.routes.keys where self.trust.key(for: device) != nil {
                self.enqueueEvent(data, device: device, provider: event["provider"] ?? "")
            }
        }
    }
    func configureProviders(_ policy: SessionProviderPolicy) {
        queue.sync {
            guard policy.revision >= providerPolicy.revision, policy != providerPolicy else { return }
            providerPolicy = policy
            agentService?.configurePolicy(policy)
            readReplies.removeAll()
            outgoing = outgoing.filter { $0.value.provider.map(policy.isEnabled) ?? true }
            for device in routes.keys {
                coordinator.stopObservation(
                    client: device, providers: Set(SessionV1Contract.providers.filter { !policy.isEnabled($0) }))
                runtimeHost.stop(client: device)
                taskViews.removeValue(forKey: device)
                sendObject(["event": "providersChanged", "providerAccess": policy.object], device: device)
            }
        }
    }
    var providerAccessSnapshot: [String: Any] { queue.sync { providerPolicy.object } }
    private func providerDisabled(_ id: String, device: String) {
        sendObject(
            [
                "id": id, "ok": false, "code": "provider_disabled",
                "error": L10n.text("providers.disabled_on_mac"), "providerAccess": providerPolicy.object,
            ], device: device)
    }
    public func phoneAppVersion(_ device: String) -> [String: Any]? { queue.sync { appVersions.installed(device) } }
    public func latestAndroidVersion() -> [String: Any]? { queue.sync { appVersions.latest } }
    /// One asynchronous snapshot keeps the main thread out of the session queue.
    public func apkSnapshot() async -> PhoneAPKSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                func label(_ version: [String: Any]?) -> String? {
                    guard let version, let name = version["versionName"] as? String,
                        let code = version["versionCode"] as? Int
                    else { return nil }
                    return "\(name) (\(code))"
                }
                continuation.resume(
                    returning: PhoneAPKSnapshot(
                        phones: self.trust.phones.map {
                            PhoneAPKDeviceSnapshot(
                                id: $0.id, name: $0.name, installedVersion: label(self.appVersions.installed($0.id)),
                                status: self.apkReservations.status($0.id) ?? self.apk.status($0.id))
                        }, latestVersion: label(self.appVersions.latest), publishing: self.publishingAPK != nil))
            }
        }
    }
    public func publishAndroidUpdate(_ url: URL, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            guard self.publishingAPK == nil else {
                completion(L10n.text("updates.preparation_busy"))
                return
            }
            let job = APKPreparationJob()
            self.publishingAPK = job
            let root = self.appVersions.root
            guard
                self.apkWorkers.submit({
                    let prepared = Result { try PhoneAppVersions.prepare(url, root: root, job: job) }
                    self.queue.async {
                        guard self.publishingAPK === job else {
                            if case .success(let value) = prepared { value.apk.discard() }
                            completion(L10n.text("updates.preparation_cancelled"))
                            return
                        }
                        self.publishingAPK = nil
                        do {
                            let value = try prepared.get()
                            do { try self.appVersions.adopt(value) } catch {
                                value.apk.discard()
                                throw error
                            }
                            for device in self.routes.keys where self.trust.key(for: device) != nil {
                                self.sendObject(["event": "apkAvailable"], device: device)
                            }
                            completion(nil)
                        } catch { completion(String(describing: error)) }
                    }
                })
            else {
                self.publishingAPK = nil
                completion(L10n.text("updates.preparation_busy"))
                return
            }
        }
    }
    public func stageLatestAndroidUpdate(device: String, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            guard let artifact = self.appVersions.artifact else {
                completion(L10n.text("updates.no_release"))
                return
            }
            self.prepareAPK(artifact.url, device: device, digest: artifact.sha256, completion: completion)
        }
    }
    public func apkStatus(_ device: String) -> PhoneAPKStatus? {
        queue.sync { apkReservations.status(device) ?? apk.status(device) }
    }
    public func stageAPK(_ url: URL, device: String, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { self.prepareAPK(url, device: device, digest: nil, completion: completion) }
    }
    /// Called on the session queue; file work retains its worker until it actually exits.
    private func prepareAPK(
        _ url: URL, device: String, digest: String?, completion: @escaping @Sendable (String?) -> Void
    ) {
        guard let key = trust.key(for: device) else {
            completion(L10n.text("control.authorize_this_phone_first"))
            return
        }
        if let digest, apk.matchingActive(digest, device: device) != nil {
            completion(nil)
            return
        }
        guard apk.status(device)?.phase.isActive != true, apkReservations.reservation(device) == nil else {
            completion(L10n.text("updates.active_transfer"))
            return
        }
        guard
            let reservation = apkReservations.begin(
                device: device, key: key, name: String(url.lastPathComponent.prefix(160)), digest: digest)
        else {
            completion(L10n.text("updates.preparation_busy"))
            return
        }
        let root = apk.root
        guard
            apkWorkers.submit({
                let prepared = Result { try PreparedAPK.prepare(url, root: root, job: reservation.job) }
                self.queue.async {
                    guard
                        self.apkReservations.claim(
                            device: device, reservation: reservation, currentKey: self.trust.key(for: device))
                    else {
                        if case .success(let value) = prepared { value.discard() }
                        completion(L10n.text("updates.preparation_cancelled"))
                        return
                    }
                    do {
                        let value = try prepared.get()
                        if let digest, value.sha256 != digest || self.appVersions.artifact?.sha256 != digest {
                            value.discard()
                            throw CLIError(L10n.text("updates.invalid_metadata"))
                        }
                        do { try self.apk.adopt(value, device: device) } catch {
                            value.discard()
                            throw error
                        }
                        self.sendObject(["event": "apkAvailable"], device: device)
                        completion(nil)
                    } catch { completion(String(describing: error)) }
                }
            })
        else {
            apkReservations.cancel(device)
            completion(L10n.text("updates.preparation_busy"))
            return
        }
    }
    public func cancelAPK(_ device: String) {
        queue.async {
            self.apkReservations.cancel(device)
            // The system owns an installation once it has started; no misleading cancellation then.
            if self.apk.status(device)?.phase.canCancel == true { self.apk.cancel(device) }
        }
    }
    public func dismissAPKStatus(_ device: String) {
        queue.async {
            if self.apk.status(device)?.phase.isActive == false { self.apk.cancel(device) }
        }
    }
    public func authorizedPhones() -> [AuthorizedPhone] {
        trust.phones
    }
    public func revoke(_ id: String, completion: @escaping @Sendable (String?) -> Void = { _ in }) {
        queue.async {
            do { try self.trust.revoke(id) } catch {
                completion(L10n.text("control.revocation_was_not_saved_retry_0", error))
                return
            }
            self.apkReservations.cancel(id)
            self.apk.cancel(id)
            self.appVersions.revoke(id)
            self.routes.removeValue(forKey: id)
            self.coordinator.stopObservation(client: id, forgetNegotiation: true)
            self.agentService?.close(client: id)
            self.runtimeHost.stop(client: id)
            self.taskViews.removeValue(forKey: id)
            self.outgoing = self.outgoing.filter { $0.value.device != id }
            self.inbox.revoke(id)
            self.readReplies.remove(device: id)
            completion(nil)
        }
    }
    func touch(_ peer: String) {
        queue.async {
            if self.routes.values.contains(where: { $0.peer == peer }) {
                self.lastPeer[peer] = ProcessInfo.processInfo.systemUptime
                self.armLease()
            }
        }
    }
    func disconnected(_ peer: String) { queue.async { self.removePeer(peer) } }
    func stop() {
        queue.async {
            self.apkReservations.cancelAll()
            self.publishingAPK?.cancel()
            self.publishingAPK = nil
            for client in self.routes.keys {
                self.agentService?.close(client: client)
                self.runtimeHost.stop(client: client)
            }
            self.routes.removeAll()
            self.taskViews.removeAll()
            self.inbox.discardPartial()
            self.readReplies.removeAll()
            self.outgoing.removeAll()
            self.lastPeer.removeAll()
            self.pairResults.removeAll()
            self.lease?.cancel()
            self.lease = nil
            self.coordinator.stopAllObservations()
        }
    }
    private func removePeer(_ peer: String) {
        for id in routes.filter({ $0.value.peer == peer }).keys {
            routes.removeValue(forKey: id)
            taskViews.removeValue(forKey: id)
            coordinator.stopObservation(client: id, forgetNegotiation: true)
            agentService?.close(client: id)
            runtimeHost.stop(client: id)
        }
        lastPeer.removeValue(forKey: peer)
        pairResults.removeValue(forKey: peer)
    }
    private func armLease() {
        lease?.cancel()
        lease = nil
        guard let next = lastPeer.values.min() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for peer in self.lastPeer.filter({ now - $0.value >= 13 }).keys { self.removePeer(peer) }
            self.armLease()
        }
        lease = work
        queue.asyncAfter(deadline: .now() + max(0.1, next + 13 - ProcessInfo.processInfo.systemUptime), execute: work)
    }
    /// Called only after CoreBluetooth has accepted an encrypted write from this subscribed central.
    func requestPair(_ data: Data, peer: String) {
        guard data.count <= SecureControlEnvelope.maximumPlaintext,
            case .accepted(let ticket) = ingress.begin(device: "pair:" + peer, id: UUID().uuidString, bytes: data.count)
        else { return }
        queue.async {
            defer { self.ingress.finish(ticket) }
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let device = value["device"] as? String, UUID(uuidString: device) != nil,
                let rawName = value["name"] as? String, !self.pairing.contains(peer), self.pairing.count < 2
            else { return }
            let name = String(rawName.prefix(60))
            self.pairing.insert(peer)
            self.pairResults[peer] = Data("{\"state\":\"pending\"}".utf8)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = L10n.text("control.allow_0_to_connect_to_this_mac", name)
                alert.informativeText =
                    L10n.text("control.this_phone_can_control_shortcuts_and_apps_use_voice_input_view_and_c")
                alert.addButton(withTitle: L10n.text("control.allow_this_phone"))
                alert.addButton(withTitle: L10n.text("control.deny"))
                NSApp.activate(ignoringOtherApps: true)
                let allowed = alert.runModal() == .alertFirstButtonReturn
                self.queue.async {
                    defer { self.pairing.remove(peer) }
                    guard allowed else {
                        self.pairResults[peer] = Data("{\"state\":\"denied\"}".utf8)
                        return
                    }
                    var key = Data(count: 32)
                    guard
                        key.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) })
                            == errSecSuccess
                    else { return }
                    do {
                        try self.trust.authorize(id: device, name: name, key: key)
                        self.pairResults[peer] = try JSONSerialization.data(withJSONObject: [
                            "state": "approved", "device": device, "key": key.base64EncodedString(),
                        ])
                    } catch {
                        self.pairResults[peer] = Data("{\"state\":\"error\"}".utf8)
                    }
                }
            }
        }
    }
    /// Only served by a readEncryptionRequired GATT characteristic; never a plaintext notification.
    func pairResult(_ peer: String) -> Data { queue.sync { pairResults[peer] ?? Data("{\"state\":\"none\"}".utf8) } }
    func receive(_ data: Data, peer: String, sender: String, send: @escaping @Sendable ([Data]) -> Void) {
        guard data.count <= SecureControlEnvelope.maximumPlaintext,
            case .accepted(let ticket) = ingress.begin(device: sender, id: UUID().uuidString, bytes: data.count)
        else { return }
        queue.async {
            defer { self.ingress.finish(ticket) }
            self.accept(data, peer: peer, sender: sender, send: send)
        }
    }
    private func recoverUpload(sender: String, packet: String) {
        queue.asyncAfter(deadline: .now() + 0.15) {
            guard let missing = self.inbox.missingUpload(sender: sender, packet: packet) else { return }
            self.sendObject(missing, device: sender)
            self.recoverUpload(sender: sender, packet: packet)
        }
    }
    private func accept(_ data: Data, peer: String, sender: String, send: @escaping @Sendable ([Data]) -> Void) {
        guard let key = trust.key(for: sender) else { return }
        guard let message = inbox.receive(data, sender: sender, key: key, allowsUploads: !peer.hasPrefix("ble:")),
            let id = message.request["id"] as? String
        else {
            if let packet = inbox.recoveryPacket(data, sender: sender) { recoverUpload(sender: sender, packet: packet) }
            return
        }
        let request = message.request
        let clear = message.clear
        let device = sender
        let now = ProcessInfo.processInfo.systemUptime
        outgoing = outgoing.filter { now - $0.value.created < 180 }
        routes[device] = Route(peer: peer, sender: sender, send: send)
        lastPeer[peer] = now
        armLease()
        if let held = undelivered.removeValue(forKey: device) {
            for reply in held where now - reply.created < 600 { self.send(reply.data, device: device) }
        }
        if request["op"] as? String == "resend", let original = request["packet"] as? String,
            let saved = outgoing[original], saved.device == device,
            saved.fastPeer == nil || saved.fastPeer == peer
        {
            send(saved.frames)
            return
        }
        if ["notificationSubscribe", "providers"].contains(request["op"] as? String ?? "") {
            // Authenticated no-op establishes the route even without opening a conversation.
            var response: [String: Any] = ["id": id, "ok": true, "providerAccess": providerPolicy.object]
            if let capabilities = coordinator.describe(
                client: device, requestedVersion: request["agentCapabilityVersion"], policy: providerPolicy)
            {
                response["agentCapabilities"] = extendedCapabilities(capabilities)
            }
            if agentService != nil {
                response["agentProfiles"] = [
                    "versions": [2], "minimumClientVersion": 2, "methods": AgentSessionProfile.methods,
                ]
            }
            sendObject(response, device: device)
            return
        }
        if request["op"] as? String == "agentRequest" {
            acceptAgentRequest(request, clear: clear, device: device)
            return
        }
        if request["op"] as? String == "relaySetup" {
            // Sensitive setup is available only to an enrolled phone on the encrypted BLE path.
            guard peer.hasPrefix("ble:"), let config = try? Config.load(), let settings = RelaySettings(config) else {
                sendObject(["id": id, "ok": false, "configured": false], device: device)
                return
            }
            sendObject(["id": id, "ok": true, "configured": true, "code": settings.pairingCode], device: device)
            return
        }
        if request["op"] as? String == "appVersion" {
            do {
                sendObject(try appVersions.report(request, device: device).merging(["id": id]) { $1 }, device: device)
            } catch { sendObject(["id": id, "ok": false, "error": String(describing: error)], device: device) }
            return
        }
        if request["op"] as? String == "androidUpdateStage" {
            requestAndroidUpdate(request, device: device, id: id, bytes: clear.count, now: now)
            return
        }
        if request["op"] as? String == "fileCancel", let ticket = request["ticket"] as? String {
            BinaryFileTransfers.shared.cancelTicket(device: device, ticket: ticket)
            sendObject(["id": id, "ok": true], device: device)
            return
        }
        if ["apkOffer", "apkChunk", "apkStatus", "apkBinary", "apkProgress"].contains(request["op"] as? String ?? "") {
            do {
                let response = try apk.reply(request, device: device, peer: peer).merging(["id": id]) { $1 }
                let fast = apk.fastDownload(request, device: device, peer: peer)
                sendObject(response, device: device, fragmentChars: fast ? 7200 : 900, requestID: fast ? id : nil)
            } catch {
                sendObject(["id": id, "ok": false, "error": String(describing: error)], device: device)
            }
            return
        }
        if ["appUsage", "appUsageSet"].contains(request["op"] as? String ?? "") {
            // This source-wide operation is available only after the device envelope was authenticated.
            // Set is idempotent; unlike session mutations, it neither starts nor unlocks a desktop application.
            guard let ticket = beginWork(request, device: device, bytes: clear.count) else { return }
            Task { @MainActor [weak self] in
                var reply: [String: Any]
                do { reply = try ApplicationUsage.shared.reply(request, device: device) } catch {
                    reply = ["ok": false, "error": String(describing: error)]
                }
                reply["id"] = id
                guard let self else { return }
                let bytes = try? JSONSerialization.data(withJSONObject: reply)
                self.queue.async {
                    defer { self.executions.finish(ticket) }
                    if let bytes { self.send(bytes, device: device) }
                }
            }
            return
        }
        // Kept out of the receipt journal and reply cache, which would otherwise store the password on disk or in memory.
        if request["op"] as? String == "unlockStatus" {
            sendObject(ScreenLock.status().merging(["id": id]) { $1 }, device: device)
            return
        }
        if request["op"] as? String == "unlockPassword" {
            guard let ticket = beginWork(request, device: device, bytes: clear.count, exclusive: "password") else {
                return
            }
            let password = request["password"] as? String ?? ""
            // Verifying against Open Directory can take a while; keep it off the transport queue.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var reply: [String: Any]
                do {
                    try ScreenLock.save(password)
                    reply = ScreenLock.status()
                } catch { reply = ["ok": false, "error": String(describing: error)] }
                reply["id"] = id
                guard let self else { return }
                let data = try? JSONSerialization.data(withJSONObject: reply)
                self.queue.async {
                    defer { self.executions.finish(ticket) }
                    if let data { self.send(data, device: device) }
                }
            }
            return
        }
        if request["op"] as? String == "receipt" {
            guard let operation = request["operation"] as? String, UUID(uuidString: operation) != nil else {
                sendObject(["id": id, "ok": false, "error": L10n.text("core.invalid_request")], device: device)
                return
            }
            guard let journal, journal.isReliable else {
                sendObject(
                    [
                        "id": id, "ok": false, "state": "unknown",
                        "error": L10n.text("control.receipt_storage_could_not_be_read_check_on_the_mac"),
                    ], device: device)
                return
            }
            let saved = journal.receipt(device + ":" + operation)
            var result: [String: Any] = [
                "id": id, "operation": operation, "ok": true,
                "state": saved == nil ? "notFound" : saved?.result == nil ? "unknown" : "complete",
            ]
            if let saved, saved.result == nil, saved.retired != true {
                var lookup: [String: Any] = ["op": "receiptCheck", "threadId": saved.thread, "operation": operation]
                let original = saved.intent.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if let original, ["settings", "interrupt"].contains(original["op"] as? String ?? "") {
                    lookup = original
                    lookup["op"] =
                        original["op"] as? String == "settings" ? "settingsReceiptCheck" : "interruptReceiptCheck"
                }
                if let original, ["queueSteer", "queueDelete"].contains(original["op"] as? String ?? "") {
                    lookup = original
                    lookup["action"] = original["op"] as? String == "queueDelete" ? "delete" : "steer"
                    lookup["op"] = "queueReceiptCheck"
                }
                if let original, original["op"] as? String == "new" {
                    lookup = Self.creationReceiptLookup(original, operation: operation, thread: saved.thread)
                }
                if original?["op"] as? String == "codexUsageReset" {
                    lookup["op"] = "codexUsageResetReceipt"
                    lookup["accountId"] = original?["accountId"]
                    lookup["creditId"] = original?["creditId"]
                }
                lookup["originalOperation"] = original?["op"]
                lookup["provider"] = original?["provider"]
                let approvalFingerprint =
                    original?["op"] as? String == "approve" ? original?["fingerprint"] as? String : nil
                let originalOperation = original?["op"] as? String ?? ""
                let originalCwd = original?["cwd"] as? String ?? ""
                let originalAccountId = original?["accountId"] as? String ?? ""
                let originalCreditId = original?["creditId"] as? String ?? ""
                let originalExecutionMode = original?["executionMode"] as? String ?? ""
                if let bytes = try? JSONSerialization.data(withJSONObject: lookup) {
                    guard
                        case .accepted(let ticket) = executions.begin(
                            device: device, id: id, bytes: bytes.count,
                            lane: SessionRequestLane.resolve(lookup, receipt: true))
                    else {
                        sendObject(["id": id, "ok": true, "state": "unknown", "operation": operation], device: device)
                        return
                    }
                    perform(bytes, provider: lookup["provider"] as? String, client: device) { [weak self] reply in
                        guard let self, self.executions.claimCompletion(ticket) else { return }
                        let reply = reply.count <= 300_000 ? reply : Data()
                        self.queue.async { [weak self] in
                            guard let self else { return }
                            defer { self.executions.finish(ticket) }
                            if let body = SessionProviderReply.resolvedLookup(
                                reply, thread: saved.thread, operation: originalOperation,
                                cwd: originalCwd, fingerprint: approvalFingerprint ?? "",
                                accountId: originalAccountId, creditId: originalCreditId,
                                executionMode: originalExecutionMode)
                            {
                                var receipt = body
                                receipt["id"] = operation
                                if receipt["accepted"] == nil { receipt["accepted"] = body["ok"] as? Bool == true }
                                let context = SessionProviderReply.Context([
                                    "id": operation, "op": originalOperation, "threadId": saved.thread,
                                    "fingerprint": approvalFingerprint ?? "", "cwd": originalCwd,
                                    "accountId": originalAccountId, "creditId": originalCreditId,
                                ])
                                let checked = SessionProviderReply(
                                    (try? JSONSerialization.data(withJSONObject: receipt)) ?? Data(),
                                    request: context, mutable: true
                                ).saving { bytes in
                                    guard let journal = self.journal else {
                                        throw CLIError(L10n.text("core.invalid_receipt"))
                                    }
                                    try journal.complete(device + ":" + operation, result: bytes)
                                }
                                if checked.definitive {
                                    self.sendObject(
                                        [
                                            "id": id, "ok": true, "state": "complete", "operation": operation,
                                            "receipt": checked.object,
                                        ], device: device)
                                } else {
                                    self.sendObject(
                                        [
                                            "id": id, "ok": true, "state": "unknown", "operation": operation,
                                            "error": L10n.text("control.receipt_result_save_failed"),
                                        ], device: device)
                                }
                            } else {
                                self.sendObject(
                                    ["id": id, "ok": true, "state": "unknown", "operation": operation], device: device)
                            }
                        }
                    }
                    return
                }
            }
            if saved?.retired == true { result["retired"] = true }
            if let data = saved?.result { result["receipt"] = try? JSONSerialization.jsonObject(with: data) }
            sendObject(result, device: device)
            return
        }
        if request["op"] as? String == "close" { BinaryFileTransfers.shared.cancelMedia(device: device) }
        let descriptor = SessionV1Contract.descriptor(request["op"] as? String ?? "")
        let mutable = descriptor?.durableMutation == true

        let receiptKey = journal?.existingKey(device: device, operation: id) ?? device + ":" + id
        let hash = CodexConversation.fingerprint(request.filter { $0.key != "sentAt" })
        guard providerPolicy.permits(request, recordedMutation: mutable && journal?.receipt(receiptKey) != nil) else {
            providerDisabled(id, device: device)
            return
        }
        if !mutable {
            switch readReplies.lookup(receiptKey, hash: hash, now: now) {
            case .conflict:
                sendObject(
                    ["id": id, "ok": false, "error": L10n.text("control.operation_id_conflict")], device: device)
                return
            case .complete(let bytes):
                self.send(bytes, device: device, provider: SessionProviderPolicy.contentProvider(request))
                return
            case .pending: return
            case .missing: break
            }
        }
        // Existing mutation receipts can be read/replayed even when fresh execution capacity is full.
        let known = mutable && journal?.receipt(receiptKey) != nil
        if !known, let failure = coordinator.freshMutationFailure(request, client: device) {
            sendObject(
                [
                    "id": id, "ok": false, "code": failure,
                    "error": L10n.text(
                        failure == "agent_upgrade_required" ? "agent.upgrade_required" : "agent.capability_unavailable"),
                ],
                device: device)
            return
        }
        let ticket = known ? nil : beginWork(request, device: device, bytes: clear.count)
        guard known || ticket != nil else { return }
        var dispatched = false
        defer { if !dispatched, let ticket { executions.finish(ticket) } }
        if mutable {
            guard let journal else {
                sendObject(
                    [
                        "id": id, "ok": false, "unknown": true,
                        "error": L10n.text(
                            "control.receipt_storage_could_not_be_read_nothing_was_sent_check_on_the_mac"),
                    ], device: device)
                return
            }
            do {
                switch try journal.reserve(
                    receiptKey, hash: hash, thread: request["threadId"] as? String ?? "", intent: clear)
                {
                case .fresh: break
                case .complete(let result):
                    self.send(result, device: device)
                    return
                case .unknown:
                    sendObject(
                        [
                            "id": id, "ok": false, "unknown": true,
                            "error": L10n.text("control.checking_the_send_result_do_not_send_it_again"),
                        ], device: device)
                    return
                case .conflict:
                    sendObject(
                        ["id": id, "ok": false, "error": L10n.text("control.operation_id_conflict")], device: device)
                    return
                }
            } catch {
                sendObject(
                    [
                        "id": id, "ok": false,
                        "unknown": (error as? SessionReceiptJournal.Failure) != .full,
                        "error": (error as? SessionReceiptJournal.Failure) == .full
                            ? L10n.text("session.receipt_storage_is_full_retry_later")
                            : L10n.text("control.receipt_storage_could_not_be_read_check_on_the_mac"),
                    ], device: device)
                return
            }
        }
        guard let ticket else { return }  // A known reservation always returns above; it cannot become fresh.
        if !mutable && !readReplies.reserve(receiptKey, device: device, hash: hash, now: now) {
            sendBusy(id, device: device)
            return
        }
        let taskView = TaskViewIntent(request).map { intent in
            var captured = intent
            captured.completion = ConversationActivity.shared.viewCompletion(provider: intent.provider, id: intent.id)
            return captured
        }
        if let taskView {
            taskViews[device] = taskView
        } else if request["op"] as? String == "close" {
            taskViews.removeValue(forKey: device)
        }
        let replyContext = SessionProviderReply.Context(request)
        let accessProvider = SessionProviderPolicy.provider(request)
        let independent = descriptor?.contentProviderScope == false
        dispatched = true
        perform(clear, provider: request["provider"] as? String, client: device) { [weak self] result in
            guard let self, self.executions.claimCompletion(ticket) else { return }
            let result = result.count <= 300_000 ? result : Data()
            self.queue.async { [weak self] in
                guard let self else { return }
                defer { self.executions.finish(ticket) }
                if !mutable && !independent && !self.providerPolicy.isEnabled(accessProvider) {
                    self.providerDisabled(id, device: device)
                    return
                }
                var reply = SessionProviderReply(result, request: replyContext, mutable: mutable)
                if mutable {
                    reply = reply.saving { bytes in
                        guard let journal = self.journal else { throw CLIError(L10n.text("core.invalid_receipt")) }
                        try journal.complete(receiptKey, result: bytes)
                    }
                }
                let object = reply.object
                let bytes = reply.data
                if !mutable { self.readReplies.complete(receiptKey, hash: hash, result: bytes) }
                if let taskView { self.finishTaskView(object, device: device, provider: taskView.provider) }
                self.send(bytes, device: device, provider: !mutable && !independent ? accessProvider : nil)
            }
        }
    }
    /// The durable original carries the exact configuration and attachment scope.
    /// Receipt recovery changes only routing fields and never submits that intent again.
    static func creationReceiptLookup(_ original: [String: Any], operation: String, thread: String) -> [String: Any] {
        var lookup = original
        lookup["op"] = "newReceiptCheck"
        lookup["operation"] = operation
        lookup["threadId"] = thread
        return lookup
    }
    private func requestAndroidUpdate(_ request: [String: Any], device: String, id: String, bytes: Int, now: Double) {
        let receiptKey = device + ":" + id
        let hash = CodexConversation.fingerprint(request.filter { $0.key != "sentAt" })
        switch readReplies.lookup(receiptKey, hash: hash, now: now) {
        case .conflict:
            sendObject(["id": id, "ok": false, "error": L10n.text("control.operation_id_conflict")], device: device)
            return
        case .complete(let reply):
            send(reply, device: device)
            return
        case .pending: return
        case .missing: break
        }
        guard let ticket = beginWork(request, device: device, bytes: bytes) else { return }
        guard readReplies.reserve(receiptKey, device: device, hash: hash, now: now) else {
            executions.finish(ticket)
            sendBusy(id, device: device)
            return
        }
        let originalKey = trust.key(for: device)
        @Sendable func finish(_ error: String?) {
            defer { self.executions.finish(ticket) }
            guard self.trust.key(for: device) == originalKey, originalKey != nil else {
                self.readReplies.abandon(receiptKey, hash: hash)
                return
            }
            var response: [String: Any] = ["id": id, "ok": error == nil]
            if let error { response["error"] = error }
            if error == nil, let status = self.apkReservations.status(device) ?? self.apk.status(device) {
                response.merge([
                    "transfer": status.transfer, "name": status.name, "size": status.size,
                    "phase": status.phase.rawValue,
                ]) { $1 }
            }
            guard let reply = try? JSONSerialization.data(withJSONObject: response) else { return }
            self.readReplies.complete(receiptKey, hash: hash, result: reply)
            self.send(reply, device: device)
        }
        do {
            let artifact = try appVersions.requestedUpdate(request)
            if let pending = apkReservations.reservation(device), pending.digest == artifact.sha256 {
                finish(nil)
                return
            }
            prepareAPK(artifact.url, device: device, digest: artifact.sha256) { error in
                self.queue.async { finish(error) }
            }
        } catch { finish(String(describing: error)) }
    }
    private func finishTaskView(_ page: [String: Any], device: String, provider: String) {
        guard routes[device] != nil, let view = taskViews[device], view.isReady(page, provider: provider) else {
            return
        }
        taskViews.removeValue(forKey: device)
        ConversationActivity.shared.markViewed(provider: provider, id: view.id, completion: view.completion)
    }
    private func sendBusy(_ id: String, device: String) {
        sendObject(["id": id, "ok": false, "error": L10n.text("control.requests_busy")], device: device)
    }
    private func beginWork(_ request: [String: Any], device: String, bytes: Int, exclusive: String? = nil) -> UUID? {
        guard let id = request["id"] as? String else { return nil }
        switch executions.begin(
            device: device, id: id, bytes: bytes, exclusive: exclusive, lane: SessionRequestLane.resolve(request))
        {
        case .accepted(let ticket): return ticket
        case .duplicate: return nil  // Original callback owns this request; never enqueue a second action.
        case .full:
            sendBusy(id, device: device)
            return nil
        }
    }
    private func enqueueEvent(_ data: Data, device: String, provider: String) {
        guard data.count <= 300_000,
            case .accepted(let ticket) = events.begin(device: device, id: UUID().uuidString, bytes: data.count)
        else { return }
        queue.async {
            defer { self.events.finish(ticket) }
            self.sendConversationEvent(data, device: device, provider: provider)
        }
    }
    private func sendConversationEvent(_ data: Data, device: String, provider: String) {
        guard providerPolicy.isEnabled(provider) else { return }
        if let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            finishTaskView(page, device: device, provider: provider)
        }
        send(data, device: device, provider: provider)
    }
    private func extendedCapabilities(_ value: [String: Any]) -> [String: Any] {
        var result = value
        result["adapters"] =
            (value["adapters"] as? [[String: Any]] ?? []).map { $0.merging(["default": true]) { $1 } }
            + runtimeHost.descriptors().map { $0.merging(["default": false]) { $1 } }
        return result
    }
    private func makeAgentService() -> AgentSessionService? {
        guard
            let directory = try? AgentSessionDirectory(
                file: Paths.supportDirectory.appendingPathComponent("agent-sessions.json"))
        else { return nil }
        let binding = AgentSessionService.Journal(
            read: { [weak self] key, done in
                self?.withAgentJournal(key: key, completion: done) { journal, actual in
                    journal.receipt(actual).map {
                        .init(
                            hash: $0.hash, thread: $0.thread, result: $0.result,
                            intent: $0.intent, retired: $0.retired == true, evidence: $0.evidence)
                    }
                }
            },
            reserve: { [weak self] key, hash, scope, intent, done in
                self?.withAgentJournal(key: key, completion: done) { journal, actual in
                    switch try journal.reserve(actual, hash: hash, thread: scope, intent: intent) {
                    case .fresh: return .fresh
                    case .complete(let data): return .complete(data)
                    case .unknown: return .unknown
                    case .conflict: return .conflict
                    }
                }
            },
            complete: { [weak self] key, data, done in
                self?.withAgentJournal(key: key, completion: done) { journal, actual in
                    try journal.complete(actual, result: data)
                }
            },
            recordEvidence: { [weak self] key, data, done in
                self?.withAgentJournal(key: key, completion: done) { journal, actual in
                    try journal.recordEvidence(actual, evidence: data)
                }
            })
        let service = AgentSessionService(
            directory: directory,
            execute: { [weak self] data, provider, client, done in
                guard let self else { return }
                self.queue.async {
                    guard self.trust.key(for: client) != nil else {
                        done(AgentSessionProfile.data(["ok": false, "code": "unauthorized_device"]))
                        return
                    }
                    let fields = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                    if SessionV1Contract.descriptor(fields["op"] as? String ?? "")?.durableMutation == true,
                        !self.providerPolicy.isEnabled(provider)
                    {
                        done(AgentSessionProfile.data(["ok": false, "code": "provider_disabled"]))
                        return
                    }
                    let adapter = fields["agentAdapterId"] as? String ?? provider + ".currentV1"
                    if adapter == provider + ".currentV1" {
                        self.perform(data, provider: provider, client: client, completion: done)
                    } else {
                        self.runtimeHost.perform(data, adapter: adapter, client: client, completion: done)
                    }
                }
            }, journal: binding,
            describe: { [weak self] client, done in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    let current =
                        self.coordinator.describe(client: client, requestedVersion: 1, policy: self.providerPolicy)
                        ?? [:]
                    done(AgentSessionProfile.data(self.extendedCapabilities(current)))
                }
            },
            freshMutationFailure: { [weak self] data, client, done in
                guard let self else { return }
                let fields = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                if let adapter = fields["agentAdapterId"] as? String, !adapter.hasSuffix(".currentV1") {
                    self.runtimeHost.freshMutationFailure(data, client: client, completion: done)
                } else {
                    self.queue.async {
                        let current = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                        done(self.coordinator.freshMutationFailure(current, client: client))
                    }
                }
            },
            eventSink: { [weak self] client, data in
                guard let self, data.count <= 300_000,
                    case .accepted(let ticket) = self.events.begin(
                        device: client, id: UUID().uuidString, bytes: data.count)
                else { return }
                self.queue.async {
                    defer { self.events.finish(ticket) }
                    guard self.trust.key(for: client) != nil, self.routes[client] != nil,
                        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let body = object["body"] as? [String: Any], let event = body["data"] as? [String: Any],
                        let provider = event["provider"] as? String, SessionV1Contract.providers.contains(provider),
                        self.providerPolicy.isEnabled(provider)
                    else { return }
                    self.send(data, device: client, provider: provider)
                }
            }, additionalAdapters: { [weak self] in self?.runtimeHost.adapterProviders() ?? [:] })
        service.configurePolicy(providerPolicy)
        return service
    }
    private func withAgentJournal<T: Sendable>(
        key: String, completion: @escaping @Sendable (Result<T, Error>) -> Void,
        _ work: @escaping @Sendable (SessionReceiptJournal, String) throws -> T
    ) {
        queue.async {
            guard let journal = self.journal, journal.isReliable, let split = key.firstIndex(of: ":") else {
                completion(.failure(AgentSessionProfile.Failure(code: "agent_receipt_storage_unavailable")))
                return
            }
            let device = String(key[..<split])
            let operation = String(key[key.index(after: split)...])
            let actual = journal.existingKey(device: device, operation: operation) ?? key
            completion(Result { try work(journal, actual) })
        }
    }
    private func acceptAgentRequest(_ outer: [String: Any], clear: Data, device: String) {
        let id = outer["id"] as? String ?? ""
        do {
            let request = try AgentSessionProfile.decode(outer)
            guard let service = agentService else {
                rejectAgentBeforeDispatch(
                    request, code: "agent_index_invalid", device: device, uncertain: request.mutable)
                return
            }
            service.admissionProvider(request, client: device) { [weak self] provider in
                self?.queue.async { [weak self] in
                    guard let self, self.trust.key(for: device) != nil else { return }
                    let lane =
                        provider.map {
                            SessionRequestLane.resolve(["provider": $0], receipt: request.method == "operation.get")
                        }
                        ?? SessionRequestLane.controls.rawValue
                    let admission = self.executions.begin(device: device, id: id, bytes: clear.count, lane: lane)
                    guard case .accepted(let ticket) = admission else {
                        if case .full = admission {
                            let recorded =
                                request.operationID.flatMap { self.journal?.existingKey(device: device, operation: $0) }
                                != nil
                            let uncertain = request.mutable && (recorded || self.journal?.isReliable != true)
                            self.rejectAgentBeforeDispatch(
                                request, code: "capacity_exceeded", device: device, uncertain: uncertain)
                        }
                        return
                    }
                    service.perform(request, client: device) { [weak self] result in
                        guard let self, self.executions.claimCompletion(ticket) else { return }
                        self.queue.async {
                            defer { self.executions.finish(ticket) }
                            let scoped =
                                !request.mutable
                                && !["operation.get", "session.unobserve", "agent.describe"].contains(request.method)
                            if scoped, let provider, !self.providerPolicy.isEnabled(provider) {
                                self.sendObject(
                                    [
                                        "id": id, "ok": false, "code": "provider_disabled",
                                        "body": ["agentProtocol": 2, "requestId": id, "code": "provider_disabled"],
                                    ], device: device)
                            } else {
                                self.send(result, device: device, provider: scoped ? provider : nil)
                            }
                        }
                    }
                }
            }
        } catch {
            let code = (error as? AgentSessionProfile.Failure)?.code ?? "agent_request_invalid"
            // A malformed request cannot invalidate an earlier reservation held by the phone.
            sendObject(
                [
                    "id": id, "ok": false, "code": code,
                    "body": ["agentProtocol": 2, "requestId": id, "code": code],
                ], device: device)
        }
    }
    private func rejectAgentBeforeDispatch(
        _ request: AgentSessionProfile.Request, code: String, device: String, uncertain: Bool
    ) {
        var body: [String: Any] = ["agentProtocol": 2, "requestId": request.id, "code": code]
        if request.mutable {
            body["operationId"] = request.operationID
            body["target"] = request.target
            body["status"] = uncertain ? "unknown" : "rejected"
            body["result"] = ["code": code]
        }
        var reply: [String: Any] = ["id": request.id, "ok": false, "code": code, "body": body]
        if uncertain { reply["unknown"] = true }
        sendObject(reply, device: device)
    }
    /// All providers share the authorized device channel; older phones default to Codex.
    private func perform(
        _ data: Data, provider: String?, client: String, completion: @escaping @Sendable (Data) -> Void
    ) {
        if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            ["applications", "applicationShortcutSet"].contains(request["op"] as? String ?? "")
        {
            // Only these two configuration commands may cross from the authenticated phone to the local runtime.
            // Rebuild the allowlisted payload; never forward a caller-supplied local command.
            DispatchQueue.global(qos: .userInitiated).async {
                let fields = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                var command: [String: Any] = [
                    "cmd": fields["op"] as? String == "applications" ? "phone-applications" : "phone-application-set"
                ]
                for key in ["index", "bundleID", "revision"] { command[key] = fields[key] }
                let reply =
                    ControlSocket.request(command, timeout: 8) ?? [
                        "ok": false, "error": L10n.text("control.application_selection_unavailable"),
                    ]
                completion((try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
            }
            return
        }
        if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            ["codexUsage", "codexUsageReset", "codexUsageResetReceipt"].contains(request["op"] as? String ?? "")
        {
            codexUsage.perform(data, client: client, completion: completion)
            return
        }
        if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let operation = request["op"] as? String, ["lockScreen", "unlockScreen"].contains(operation)
        {
            DispatchQueue.global(qos: .userInitiated).async {
                var result: [String: Any]
                do {
                    if operation == "lockScreen" { try ScreenLock.lockNow() } else { try ScreenLock.unlockNow() }
                    result = ScreenLock.status()
                } catch {
                    result = [
                        "ok": false, "error": String(describing: error), "locked": ScreenLock.locked(),
                        "configured": ScreenLock.configured(),
                    ]
                }
                completion((try? JSONSerialization.data(withJSONObject: result)) ?? Data())
            }
            return
        }
        coordinator.performCurrentV1(data, provider: provider, trustedClient: client, completion: completion)
    }
    private func sendObject(_ value: [String: Any], device: String, fragmentChars: Int = 900, requestID: String? = nil)
    {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) {
            send(data, device: device, fragmentChars: fragmentChars, requestID: requestID)
        }
    }
    private func send(
        _ data: Data, device: String, fragmentChars: Int = 900, requestID: String? = nil, provider: String? = nil
    ) {
        guard data.count <= 300_000 else {
            // Never drop a reply silently: the phone would wait on "正在打开" forever.
            if let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String {
                sendObject(
                    [
                        "id": id, "ok": false,
                        "error": L10n.text("control.the_content_is_too_large_to_transfer_to_the_phone"),
                    ], device: device)
            }
            // A pushed page has no request to answer; pages are budgeted well under this, and the next sync repairs it.
            return
        }
        guard let route = routes[device], let key = trust.key(for: device) else {
            // Only request replies are held; pushed pages and events are repaired by the next sync.
            if trust.key(for: device) != nil, requestID == nil,
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] is String
            {
                let now = ProcessInfo.processInfo.systemUptime
                var held = (undelivered[device] ?? []).filter { now - $0.created < 600 }
                if held.count >= 32 { held.removeFirst() }
                held.append((data, now))
                undelivered[device] = held
                if undelivered.count > 16, let stale = undelivered.keys.first(where: { $0 != device }) {
                    undelivered.removeValue(forKey: stale)
                }
            }
            return
        }
        let packet = UUID().uuidString
        guard let sealed = try? SessionEnvelope.seal(data, key: key, device: device, packet: packet, direction: "mac")
        else { return }
        let frames = SessionEnvelope.frames(
            sealed, device: device, packet: packet, sender: route.sender, fragmentChars: fragmentChars,
            requestID: requestID)
        guard !frames.isEmpty else { return }
        let own = outgoing.filter { $0.value.device == device }
        if own.count >= 8, let oldest = own.min(by: { $0.value.created < $1.value.created })?.key {
            outgoing.removeValue(forKey: oldest)
        }
        if outgoing.count >= 24, let oldest = outgoing.min(by: { $0.value.created < $1.value.created })?.key {
            outgoing.removeValue(forKey: oldest)
        }
        outgoing[packet] = (
            device, frames, ProcessInfo.processInfo.systemUptime, fragmentChars == 7200 ? route.peer : nil, provider
        )
        route.send(frames)
    }
}
