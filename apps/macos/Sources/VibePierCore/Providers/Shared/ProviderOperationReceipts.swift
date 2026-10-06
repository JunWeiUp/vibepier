import CryptoKit
import Foundation

/// Process-local provider receipts complement the durable SessionRemote journal. Retiring a
/// completed body never removes its identity; an unknown operation is never admitted again.
final class ProviderOperationReceipts: @unchecked Sendable {
    struct Limits {
        var records = 20_000
        var recordsPerClient = 2_000
        var bytes = 16 * 1024 * 1024
        var bytesPerClient = 4 * 1024 * 1024
    }
    struct Key: Hashable, Sendable {
        let client: String
        let operation: String
    }
    struct Ticket: Sendable {
        let key: Key
        let generation: UUID
    }
    enum Admission {
        case fresh(Ticket)
        case cached([String: Any])
    }
    private struct Record {
        let generation: UUID
        let hash: Data
        let context: SessionProviderReply.Context
        let baseBytes: Int
        var result: Data?
        var final = false
        var retired = false
        var observer: (@Sendable () throws -> [String: Any]?)?
        var observerBytes = 0
        var armed = false
        var extraBytes: Int { max(0, (result?.count ?? 0) - 512) }
        var bytes: Int { baseBytes + extraBytes + observerBytes }
    }
    private let lock = NSLock()
    private let limits: Limits
    private var records: [Key: Record] = [:]
    init(limits: Limits = Limits()) { self.limits = limits }

    static func mutable(_ operation: String) -> Bool {
        ["send", "new", "settings", "interrupt", "approve", "codexUsageReset"].contains(operation)
    }

    func begin(_ request: [String: Any], client: String) throws -> Admission {
        let context = SessionProviderReply.Context(request)
        guard Self.mutable(context.operation), !context.id.isEmpty, context.id.utf8.count <= 200,
            !client.isEmpty, client.utf8.count <= 1024,
            let encoded = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
            encoded.count <= 300_000
        else { throw CLIError(L10n.text("core.invalid_request")) }
        let key = Key(client: client, operation: context.id)
        let hash = Data(SHA256.hash(data: encoded))
        return try lock.withLock {
            if let existing = records[key] {
                guard existing.hash == hash else { throw CLIError(L10n.text("control.operation_id_conflict")) }
                return .cached(reply(existing))
            }
            let base =
                512 + client.utf8.count + context.id.utf8.count + context.operation.utf8.count
                + context.thread.utf8.count + context.cwd.utf8.count + context.fingerprint.utf8.count
                + context.accountId.utf8.count + context.creditId.utf8.count + 32
            guard records.count < limits.records,
                records.keys.filter({ $0.client == client }).count < limits.recordsPerClient,
                makeRoom(for: key, additional: base)
            else { throw CLIError(L10n.text("provider.receipt_capacity")) }
            let generation = UUID()
            records[key] = Record(generation: generation, hash: hash, context: context, baseBytes: base)
            return .fresh(Ticket(key: key, generation: generation))
        }
    }

    @discardableResult func finish(_ ticket: Ticket, result: [String: Any]) -> [String: Any] {
        lock.withLock {
            guard var record = records[ticket.key], record.generation == ticket.generation else {
                return Self.unknown()
            }
            // Preserve the first definitive outcome, including a retired one.
            guard !record.final else { return reply(record) }
            let bytes = (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
            let checked = SessionProviderReply(bytes, request: record.context, mutable: true)
            let extra = max(0, checked.data.count - 512)
            guard
                makeRoom(
                    for: ticket.key,
                    additional: extra - record.extraBytes - (checked.definitive ? record.observerBytes : 0))
            else { return reply(record) }
            record.result = checked.data
            record.final = checked.definitive
            if record.final {
                record.observer = nil
                record.observerBytes = 0
            }
            records[ticket.key] = record
            return checked.object
        }
    }

    /// `missing` may answer only when this process holds no record at all, for example after a restart.
    /// It must be a read-only native observation; it never runs while an operation is still in flight.
    func lookup(
        client: String, operation: String, thread: String, kind: String,
        missing: (() -> [String: Any]?)? = nil
    ) -> [String: Any] {
        let key = Key(client: client, operation: operation)
        let (record, known): (Record?, Bool) = lock.withLock {
            guard let record = records[key] else { return (nil, false) }
            guard record.context.thread == thread, record.context.operation == kind else { return (nil, true) }
            return (record, true)
        }
        guard let record else { return known ? Self.unknown() : missing?() ?? Self.unknown() }
        if !record.final, record.armed, let observer = record.observer, let observed = try? observer() {
            return finish(Ticket(key: key, generation: record.generation), result: observed)
        }
        return reply(record)
    }

    /// Cached operation replays and final receipt queries need no provider queue or native observer.
    /// A replay of a running send stays unknown even when admission rejects fresh work.
    func cachedReply(
        _ data: Data, client: String, provider: String,
        operations: Set<String> = ["receiptCheck", "newReceiptCheck", "settingsReceiptCheck", "interruptReceiptCheck"]
    ) -> Data? {
        guard data.count <= 300_000,
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let op = request["op"] as? String
        else { return nil }
        if Self.mutable(op), let operation = request["id"] as? String,
            let encoded = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        {
            let hash = Data(SHA256.hash(data: encoded))
            let value: [String: Any]? = lock.withLock {
                guard let record = records[Key(client: client, operation: operation)] else { return nil }
                guard record.hash == hash else {
                    return ["ok": false, "error": L10n.text("control.operation_id_conflict")]
                }
                return reply(record)
            }
            guard var value else { return nil }
            value["provider"] = provider
            return try? JSONSerialization.data(withJSONObject: value)
        }
        guard operations.contains(op) else { return nil }
        let kind =
            request["originalOperation"] as? String
            ?? ["newReceiptCheck": "new", "settingsReceiptCheck": "settings", "interruptReceiptCheck": "interrupt"][op]
            ?? "send"
        let key = Key(client: client, operation: request["operation"] as? String ?? request["id"] as? String ?? "")
        let value: [String: Any]? = lock.withLock {
            guard let record = records[key], record.final, record.context.operation == kind,
                record.context.thread == (request["threadId"] as? String ?? "")
            else { return nil }
            return reply(record)
        }
        guard var value else { return nil }
        value["provider"] = provider
        return try? JSONSerialization.data(withJSONObject: value)
    }

    /// Reserve captured proof memory before starting an operation. The observer is read-only,
    /// and is armed only after the actual submission succeeds, not merely after opening a draft.
    func observe(_ ticket: Ticket, bytes: Int, using observer: @escaping @Sendable () throws -> [String: Any]?) throws {
        try lock.withLock {
            guard var record = records[ticket.key], record.generation == ticket.generation, !record.final,
                record.observer == nil, bytes >= 0, bytes <= limits.bytesPerClient,
                makeRoom(for: ticket.key, additional: bytes)
            else { throw CLIError(L10n.text("provider.receipt_capacity")) }
            record.observer = observer
            record.observerBytes = bytes
            records[ticket.key] = record
        }
    }

    func arm(_ ticket: Ticket) {
        lock.withLock {
            guard records[ticket.key]?.generation == ticket.generation else { return }
            records[ticket.key]?.armed = true
        }
    }

    /// A read-only native observer may improve an unknown record, never overwrite a final outcome.
    @discardableResult func reconcile(
        client: String, operation: String, thread: String, kind: String, result: [String: Any]
    ) -> [String: Any] {
        let ticket: Ticket? = lock.withLock {
            let key = Key(client: client, operation: operation)
            guard let record = records[key], record.context.thread == thread, record.context.operation == kind else {
                return nil
            }
            return Ticket(key: key, generation: record.generation)
        }
        guard let ticket else { return Self.unknown() }
        return finish(ticket, result: result)
    }

    private func reply(_ record: Record) -> [String: Any] {
        if let result = record.result, let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any] {
            return object
        }
        var result = Self.unknown()
        if record.retired { result["retired"] = true }
        return result
    }

    private func makeRoom(for key: Key, additional: Int) -> Bool {
        func fits() -> Bool {
            records.values.reduce(0) { $0 + $1.bytes } + additional <= limits.bytes
                && records.filter { $0.key.client == key.client }.values.reduce(0) { $0 + $1.bytes } + additional
                    <= limits.bytesPerClient
        }
        if fits() { return true }
        // Free completed bodies only. Identities, fingerprints and unknown results remain protected.
        let candidates = records.keys.filter {
            $0 != key && records[$0]?.final == true && (records[$0]?.extraBytes ?? 0) > 0
        }
        .sorted { ($0.client == key.client ? 0 : 1) < ($1.client == key.client ? 0 : 1) }
        for candidate in candidates {
            records[candidate]?.result = nil
            records[candidate]?.retired = true
            if fits() { return true }
        }
        return false
    }

    static func unknown() -> [String: Any] { ["ok": false, "unknown": true, "accepted": false] }
}
