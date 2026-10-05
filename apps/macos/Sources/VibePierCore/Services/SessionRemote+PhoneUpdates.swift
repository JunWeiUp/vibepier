import AppKit
import CryptoKit
import Foundation
import Security

/// Android update publishing, staging and phone-requested installs: a service beside the agent gateway.
extension SessionRemote {
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
    func requestAndroidUpdate(_ request: [String: Any], device: String, id: String, bytes: Int, now: Double) {
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
}
