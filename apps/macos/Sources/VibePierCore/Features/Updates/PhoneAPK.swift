import CryptoKit
import Foundation

public enum PhoneAPKPhase: String, Sendable {
    case preparing, pending, transferring, received, permission, installing, success, cancelled, failed
    public var isActive: Bool { ![.success, .cancelled, .failed].contains(self) }
    public var canCancel: Bool { isActive && self != .installing }
}

public struct PhoneAPKStatus: Sendable {
    public let transfer: String
    public let name: String
    public let size: Int
    public let received: Int
    public let state: String
    public let phase: PhoneAPKPhase
}

/// Accessed only on SessionRemote's serial queue. Each snapshot belongs to one authorized phone.
final class PhoneAPK {
    static let maxSize = 512 * 1024 * 1024
    private struct Transfer {
        let id: String
        let name: String
        let file: URL
        let size: Int
        let sha256: String
        var downloadPeer: String?
        var downloadToken: String?
        var phase: PhoneAPKPhase = .pending
        var received = 0
        var state = L10n.text("control.waiting_for_the_phone_open_vibepier_on_it")
    }
    let root: URL
    private var transfers: [String: Transfer] = [:]
    init(root: URL = Paths.supportDirectory.appendingPathComponent("phone-apk")) {
        self.root = root
        // Offers do not survive a desktop restart. Remove abandoned immutable snapshots.
        try? FileManager.default.removeItem(at: root)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    /// Synchronous convenience for isolated tests. Production preparation uses APKPreparationWorkers.
    func stage(_ url: URL, device: String) throws {
        let prepared = try PreparedAPK.prepare(url, root: root, job: APKPreparationJob())
        do { try adopt(prepared, device: device) } catch {
            prepared.discard()
            throw error
        }
    }
    func adopt(_ prepared: PreparedAPK, device: String) throws {
        guard transfers[device]?.phase.isActive != true else {
            throw CLIError(L10n.text("updates.active_transfer"))
        }
        if let old = transfers[device] { try? FileManager.default.removeItem(at: old.file) }
        transfers[device] = Transfer(
            id: prepared.id, name: prepared.name, file: prepared.file, size: prepared.size, sha256: prepared.sha256)
    }
    func matchingActive(_ digest: String, device: String) -> PhoneAPKStatus? {
        guard let transfer = transfers[device], transfer.phase.isActive, transfer.sha256 == digest else { return nil }
        return status(device)
    }
    func cancel(_ device: String) {
        if let old = transfers.removeValue(forKey: device) {
            BinaryFileTransfers.shared.cancelAPK(device: device, transfer: old.id)
            try? FileManager.default.removeItem(at: old.file)
        }
    }
    func status(_ device: String) -> PhoneAPKStatus? {
        guard let t = transfers[device] else { return nil }
        return PhoneAPKStatus(
            transfer: t.id, name: t.name, size: t.size, received: t.received, state: t.state, phase: t.phase)
    }
    func fastDownload(_ request: [String: Any], device: String, peer: String) -> Bool {
        guard peer.hasPrefix("relay:"), let t = transfers[device], t.downloadPeer == peer,
            let token = t.downloadToken, request["downloadToken"] as? String == token,
            request["transfer"] as? String == t.id, request["op"] as? String == "apkChunk"
        else { return false }
        return true
    }
    func reply(_ request: [String: Any], device: String, peer: String = "") throws -> [String: Any] {
        let op = request["op"] as? String ?? ""
        guard var t = transfers[device] else {
            if op == "apkChunk" {
                return ["ok": false, "cancelled": true, "error": L10n.text("control.the_mac_cancelled_the_transfer")]
            }
            return ["ok": true]
        }
        if op == "apkOffer", !t.phase.isActive { return ["ok": true] }
        if op == "apkOffer" {
            var offer: [String: Any] = [
                "ok": true, "transfer": t.id, "name": t.name, "size": t.size, "sha256": t.sha256,
            ]
            if BinaryFileTransfers.shared.available { offer["binaryVersion"] = 1 }
            if peer.hasPrefix("relay:"), request["downloadVersion"] as? Int == 1,
                let token = request["id"] as? String, UUID(uuidString: token) != nil
            {
                t.downloadPeer = peer
                t.downloadToken = token
                offer["download"] = [
                    "version": 1, "token": token, "fragmentChars": 7200, "chunkBytes": 128 * 1024, "window": 4,
                ]
            } else {
                t.downloadPeer = nil
                t.downloadToken = nil
            }
            transfers[device] = t
            return offer
        }
        guard request["transfer"] as? String == t.id else {
            throw CLIError(L10n.text("control.the_installation_task_was_cancelled_or_replaced_start_receiving_agai"))
        }
        if op == "apkProgress" {
            guard t.phase.isActive, let ticket = request["binaryTicket"] as? String,
                BinaryFileTransfers.shared.ownsAPKTicket(device: device, transfer: t.id, ticket: ticket),
                let offset = request["durableOffset"] as? Int, offset >= 0, offset <= t.size
            else { throw CLIError(L10n.text("core.invalid_request")) }
            t.received = max(t.received, offset)
            transfers[device] = t
            return ["ok": true]
        }
        if op == "apkBinary" {
            guard t.phase.isActive, let offset = request["offset"] as? Int, offset >= 0, offset < t.size,
                let profile = BinaryFileTransfers.shared.apkOffer(
                    device: device, transfer: t.id, file: t.file, size: t.size, offset: offset,
                    requestID: request["id"] as? String ?? "")
            else { return ["ok": true, "binaryUnavailable": true] }
            t.phase = .transferring
            t.state = L10n.text("control.transferring")
            transfers[device] = t
            return ["ok": true, "transfer": t.id, "binary": profile]
        }
        if op == "apkChunk" {
            guard t.phase.isActive else {
                throw CLIError(L10n.text("control.the_installation_task_has_ended_send_the_apk_again"))
            }
            guard let offset = request["offset"] as? Int, offset >= 0, offset < t.size else {
                throw CLIError(L10n.text("control.invalid_apk_chunk_offset"))
            }
            let limit = min(128 * 1024, max(1024, request["limit"] as? Int ?? 8192))
            let handle = try FileHandle(forReadingFrom: t.file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let bytes = try handle.read(upToCount: min(limit, t.size - offset)) ?? Data()
            guard !bytes.isEmpty else {
                throw CLIError(L10n.text("control.could_not_read_the_apk_snapshot_send_it_again"))
            }
            // Offset is acknowledged bytes, rather than bytes merely sent to the transport.
            if request["downloadToken"] != nil {
                guard fastDownload(request, device: device, peer: peer),
                    let durable = request["durableOffset"] as? Int, durable >= 0, durable <= t.size
                else {
                    throw CLIError(L10n.text("control.invalid_apk_chunk_offset"))
                }
                t.received = max(t.received, durable)
            } else {
                // Only legacy single-flight clients acknowledge by their next requested offset.
                guard t.downloadToken == nil else { throw CLIError(L10n.text("core.invalid_request")) }
                t.received = max(t.received, offset)
            }
            if [.pending, .transferring].contains(t.phase) {
                t.phase = .transferring
                t.state = L10n.text("control.transferring")
            }
            transfers[device] = t
            return ["ok": true, "transfer": t.id, "offset": offset, "data": bytes.base64EncodedString()]
        }
        if op == "apkStatus" {
            let states = [
                "received": L10n.text("control.file_verified_waiting_for_install_confirmation_on_the_phone"),
                "permission": L10n.text("control.allow_installation_from_this_source_on_the_phone"),
                "installing": L10n.text("control.installing_waiting_for_the_system_result"),
                "success": L10n.text("control.installation_succeeded"),
                "cancelled": L10n.text("control.cancelled_on_the_phone"),
                "failed": L10n.text("control.installation_failed"),
            ]
            guard let state = request["state"] as? String, let label = states[state] else {
                throw CLIError(L10n.text("control.invalid_installation_state"))
            }
            if !t.phase.isActive { return ["ok": true] }
            t.phase = PhoneAPKPhase(rawValue: state)!
            t.state = label
            if let detail = request["detail"] as? String, !detail.isEmpty {
                t.state += "：" + String(detail.prefix(180))
            }
            if ["received", "permission", "installing", "success"].contains(state) { t.received = t.size }
            transfers[device] = t
            if ["received", "success", "cancelled", "failed"].contains(state) {
                BinaryFileTransfers.shared.cancelAPK(device: device, transfer: t.id)
            }
            if ["success", "cancelled", "failed"].contains(state) { try? FileManager.default.removeItem(at: t.file) }
            return ["ok": true]
        }
        throw CLIError(L10n.text("control.unknown_apk_operation"))
    }
}
