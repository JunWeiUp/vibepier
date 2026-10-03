import CryptoKit
import Foundation

public struct PhoneAPKStatus: Sendable {
    public let transfer: String
    public let name: String
    public let size: Int
    public let received: Int
    public let state: String
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
        var phase = "pending"
        var received = 0
        var state = L10n.text("control.waiting_for_the_phone_open_vibepier_on_it")
    }
    private let root: URL
    private var transfers: [String: Transfer] = [:]
    init(root: URL = Paths.supportDirectory.appendingPathComponent("phone-apk")) {
        self.root = root
        // Offers do not survive a desktop restart. Remove abandoned immutable snapshots.
        try? FileManager.default.removeItem(at: root)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func stage(_ url: URL, device: String) throws {
        guard url.pathExtension.lowercased() == "apk" else {
            throw CLIError(L10n.text("control.choose_a_complete_apk_file_split_apks_and_xapk_are_not_supported"))
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= Self.maxSize else {
            throw CLIError(L10n.text("control.the_apk_must_be_between_1_byte_and_512_mb"))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let snapshot = root.appendingPathComponent(id + ".apk")
        try FileManager.default.copyItem(at: url, to: snapshot)
        do {
            let handle = try FileHandle(forReadingFrom: snapshot)
            defer { try? handle.close() }
            var hash = SHA256()
            var total = 0
            while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                hash.update(data: bytes)
                total += bytes.count
            }
            guard total == size else {
                throw CLIError(L10n.text("control.the_file_changed_while_being_copied_select_it_again"))
            }
            if let old = transfers[device] { try? FileManager.default.removeItem(at: old.file) }
            transfers[device] = Transfer(
                id: id, name: String(url.lastPathComponent.prefix(160)), file: snapshot, size: size,
                sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
    }
    func cancel(_ device: String) {
        if let old = transfers.removeValue(forKey: device) { try? FileManager.default.removeItem(at: old.file) }
    }
    func status(_ device: String) -> PhoneAPKStatus? {
        guard let t = transfers[device] else { return nil }
        return PhoneAPKStatus(transfer: t.id, name: t.name, size: t.size, received: t.received, state: t.state)
    }
    func reply(_ request: [String: Any], device: String) throws -> [String: Any] {
        let op = request["op"] as? String ?? ""
        guard var t = transfers[device] else {
            if op == "apkChunk" {
                return ["ok": false, "cancelled": true, "error": L10n.text("control.the_mac_cancelled_the_transfer")]
            }
            return ["ok": true]
        }
        if op == "apkOffer", ["success", "cancelled", "failed"].contains(t.phase) { return ["ok": true] }
        if op == "apkOffer" {
            return ["ok": true, "transfer": t.id, "name": t.name, "size": t.size, "sha256": t.sha256]
        }
        guard request["transfer"] as? String == t.id else {
            throw CLIError(L10n.text("control.the_installation_task_was_cancelled_or_replaced_start_receiving_agai"))
        }
        if op == "apkChunk" {
            guard !["success", "cancelled", "failed"].contains(t.phase) else {
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
            t.received = max(t.received, offset)
            t.state = L10n.text("control.transferring")
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
            if ["success", "cancelled", "failed"].contains(t.phase) { return ["ok": true] }
            t.phase = state
            t.state = label
            if let detail = request["detail"] as? String, !detail.isEmpty {
                t.state += "：" + String(detail.prefix(180))
            }
            if ["received", "permission", "installing", "success"].contains(state) { t.received = t.size }
            transfers[device] = t
            if ["success", "cancelled", "failed"].contains(state) { try? FileManager.default.removeItem(at: t.file) }
            return ["ok": true]
        }
        throw CLIError(L10n.text("control.unknown_apk_operation"))
    }
}
