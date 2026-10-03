import CryptoKit
import Foundation

/// Shared by every provider. Unknown and retired operation IDs never become eligible for execution again.
final class SessionReceiptJournal {
    struct Receipt: Codable {
        var hash: String
        var thread: String
        var result: Data?
        var created: Double
        var intent: Data?
        var retired: Bool?
    }
    struct Limits {
        var fileBytes = 16 * 1024 * 1024
        var deviceBytes = 4 * 1024 * 1024
        var payloadBytes = 300_000
        var activeRecords = 2000
        var totalRecords = 20_000
    }
    enum Reservation {
        case fresh
        case complete(Data)
        case unknown, conflict
    }
    enum Failure: Error, CustomStringConvertible {
        case invalid, full
        var description: String {
            L10n.text(
                self == .full
                    ? "session.receipt_storage_is_full_retry_later"
                    : "control.receipt_storage_could_not_be_read_check_on_the_mac")
        }
    }
    typealias Commit = (Data, Data?) throws -> Void
    private let file: URL
    private let limits: Limits
    private let clock: () -> Double
    private let commit: Commit
    private var records: [String: Receipt]
    private var revision: Data?
    private var storageFailed = false

    init(
        file: URL, limits: Limits = Limits(), clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
        commit: Commit? = nil
    ) throws {
        self.file = file
        self.limits = limits
        self.clock = clock
        self.commit =
            commit ?? { data, revision in
                try ReceiptJournalFile.commit(data, to: file, expected: revision, limit: limits.fileBytes)
            }
        let bytes = try ReceiptJournalFile.read(file, limit: limits.fileBytes)
        revision = bytes.map(Self.digest)
        // Missing is distinct from corrupt, oversized, unreadable, or a symlink. Never start empty on a read error.
        records = try bytes.map { try JSONDecoder().decode([String: Receipt].self, from: $0) } ?? [:]
        guard records.count <= limits.totalRecords,
            records.allSatisfy({ Self.valid($0.key, $0.value, payloadLimit: limits.payloadBytes) })
        else { throw Self.invalidStorage }
    }

    var isReliable: Bool { !storageFailed }
    func receipt(_ key: String) -> Receipt? { records[key] }
    func reserve(_ key: String, hash: String, thread: String, intent: Data? = nil) throws -> Reservation {
        if let old = records[key] {
            guard old.hash == hash, old.thread == thread else { return .conflict }
            if let result = old.result { return .complete(result) }
            return .unknown
        }
        guard !storageFailed else { throw Self.invalidStorage }
        let now = clock()
        let receipt = Receipt(hash: hash, thread: thread, created: now, intent: intent)
        guard Self.valid(key, receipt, payloadLimit: limits.payloadBytes) else { throw Self.invalidStorage }
        var next = records.mapValues { old -> Receipt in
            guard old.result != nil, now - old.created >= 7 * 86400 else { return old }
            // Keep the fingerprint/ID tombstone. A phone may still hold an unknown receipt after the reply was lost.
            return Receipt(hash: old.hash, thread: old.thread, created: old.created, retired: true)
        }
        guard next.count < limits.totalRecords,
            next.values.filter({ $0.retired != true }).count < limits.activeRecords
        else { throw Self.full }
        next[key] = receipt
        let data = try checkedEncoding(next, reserveResults: true)
        try publish(next, data: data)
        return .fresh
    }

    func complete(_ key: String, result: Data) throws {
        guard let original = records[key], original.retired != true else {
            throw CLIError(L10n.text("session.the_original_operation_receipt_does_not_exist"))
        }
        if let existing = original.result {
            guard existing == result else { throw Self.invalidStorage }
            return
        }
        guard !storageFailed, result.count <= limits.payloadBytes else { throw Self.invalidStorage }
        var next = records
        next[key]?.result = result
        next[key]?.intent = nil
        // New reservations preallocate room for a maximal result; legacy entries can still complete within actual limits.
        let data = try checkedEncoding(next, reserveResults: false)
        try publish(next, data: data)
    }

    private func checkedEncoding(_ next: [String: Receipt], reserveResults: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(next)
        func reserved(_ values: [String: Receipt]) -> Int {
            guard reserveResults else { return 0 }
            let pending = values.values.filter { $0.result == nil && $0.retired != true }.count
            return pending * (4 * ((limits.payloadBytes + 2) / 3) + 32)
        }
        guard data.count + reserved(next) <= limits.fileBytes else { throw Self.full }
        let groups = Dictionary(grouping: next.keys, by: { String($0.split(separator: ":", maxSplits: 1).first ?? "") })
        for keys in groups.values {
            let values = Dictionary(uniqueKeysWithValues: keys.map { ($0, next[$0]!) })
            guard try encoder.encode(values).count + reserved(values) <= limits.deviceBytes else { throw Self.full }
        }
        return data
    }

    private func publish(_ next: [String: Receipt], data: Data) throws {
        do { try commit(data, revision) } catch {
            // A commit may have reached rename before sync failed. Never reuse this stale in-memory generation.
            storageFailed = true
            throw error
        }
        records = next
        revision = Self.digest(data)
    }

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func valid(_ key: String, _ receipt: Receipt, payloadLimit: Int) -> Bool {
        !key.isEmpty && key.utf8.count <= 256 && !receipt.hash.isEmpty && receipt.hash.utf8.count <= 128
            && receipt.thread.utf8.count <= 1024 && receipt.created.isFinite && receipt.created >= 0
            && (receipt.intent?.count ?? 0) <= payloadLimit && (receipt.result?.count ?? 0) <= payloadLimit
            && (receipt.retired != true || (receipt.result == nil && receipt.intent == nil))
    }
    private static var invalidStorage: Failure { .invalid }
    private static var full: Failure { .full }
}
