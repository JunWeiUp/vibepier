import Foundation

/// Charges a request until its completion is consumed, including across disconnects. No timeout frees live work.
final class SessionWorkBudget: @unchecked Sendable {
    struct Limits {
        var perDevice = 16
        var total = 64
        var bytesPerDevice = 2 * 1024 * 1024
        var bytesTotal = 8 * 1024 * 1024
    }
    enum Admission {
        case accepted(UUID)
        case duplicate, full
    }
    private struct Identity: Hashable {
        let device: String
        let id: String
    }
    private struct Charge {
        let identity: Identity
        let bytes: Int
        let exclusive: String?
        let lane: String
        var claimed = false
    }
    private struct Usage {
        var count = 0
        var bytes = 0
    }
    private let lock = NSLock()
    private let limits: Limits
    private let lanes: [String: Limits]
    private var tokens: [UUID: Charge] = [:]
    private var identities: [Identity: UUID] = [:]
    private var usage: [String: Usage] = [:]
    private var exclusive: [String: UUID] = [:]
    private var bytes = 0
    init(limits: Limits = Limits(), lanes: [String: Limits] = [:]) {
        self.limits = limits
        self.lanes = lanes
    }
    func begin(device: String, id: String, bytes count: Int, exclusive group: String? = nil, lane: String = "")
        -> Admission
    {
        lock.withLock {
            let identity = Identity(device: device, id: id)
            if identities[identity] != nil { return .duplicate }
            let current = usage[device] ?? Usage()
            guard count >= 0, count <= limits.bytesPerDevice, count <= limits.bytesTotal,
                tokens.count < limits.total, current.count < limits.perDevice,
                bytes <= limits.bytesTotal - count, current.bytes <= limits.bytesPerDevice - count,
                group == nil || exclusive[group!] == nil
            else { return .full }
            if !lanes.isEmpty {
                guard let partition = lanes[lane] else { return .full }
                let all = tokens.values.filter { $0.lane == lane }
                let own = all.filter { $0.identity.device == device }
                guard count <= partition.bytesPerDevice, count <= partition.bytesTotal,
                    all.count < partition.total, own.count < partition.perDevice,
                    all.reduce(0, { $0 + $1.bytes }) <= partition.bytesTotal - count,
                    own.reduce(0, { $0 + $1.bytes }) <= partition.bytesPerDevice - count
                else { return .full }
            }
            let token = UUID()
            tokens[token] = Charge(identity: identity, bytes: count, exclusive: group, lane: lane)
            identities[identity] = token
            usage[device] = Usage(count: current.count + 1, bytes: current.bytes + count)
            bytes += count
            if let group { exclusive[group] = token }
            return .accepted(token)
        }
    }
    /// Only the first provider callback may queue a completion; capacity is held until finish().
    func claimCompletion(_ token: UUID) -> Bool {
        lock.withLock {
            guard let charge = tokens[token], !charge.claimed else { return false }
            tokens[token]?.claimed = true
            return true
        }
    }
    @discardableResult func finish(_ token: UUID) -> Bool {
        lock.withLock {
            guard let charge = tokens.removeValue(forKey: token) else { return false }
            identities.removeValue(forKey: charge.identity)
            var current = usage[charge.identity.device] ?? Usage()
            current.count -= 1
            current.bytes -= charge.bytes
            if current.count == 0 {
                usage.removeValue(forKey: charge.identity.device)
            } else {
                usage[charge.identity.device] = current
            }
            bytes -= charge.bytes
            if let group = charge.exclusive { exclusive.removeValue(forKey: group) }
            return true
        }
    }
}

/// Fixed server-side partitions stay within 16 requests / 2 MiB per phone
/// and 64 requests / 8 MiB globally. A stuck provider cannot borrow another lane's capacity.
enum SessionRequestLane: String, CaseIterable {
    case codex, claude, account, controls
    case codexReceipt, claudeReceipt, accountReceipt

    static var limits: [String: SessionWorkBudget.Limits] {
        Dictionary(
            uniqueKeysWithValues: allCases.map { lane in
                let count: Int
                let bytes: Int
                switch lane {
                case .codex, .claude: (count, bytes) = (3, 384 * 1024)
                case .account: (count, bytes) = (2, 256 * 1024)
                default: (count, bytes) = (1, 128 * 1024)
                }
                return (
                    lane.rawValue,
                    .init(perDevice: count, total: count * 4, bytesPerDevice: bytes, bytesTotal: bytes * 4)
                )
            })
    }

    static func resolve(_ request: [String: Any], receipt: Bool = false) -> String {
        let operation = request["op"] as? String ?? ""
        let category = SessionV1Contract.descriptor(operation)?.laneCategory
        if category == "account" {
            return (receipt ? Self.accountReceipt : .account).rawValue
        }
        if category == "controls" {
            return Self.controls.rawValue
        }
        switch request["provider"] as? String ?? "codex" {
        case "claude": return (receipt ? Self.claudeReceipt : .claude).rawValue
        case "", "codex": return (receipt ? Self.codexReceipt : .codex).rawValue
        default: return Self.controls.rawValue
        }
    }
}

/// Queue-confined read-only replies. Pending entries are never evicted to make room for completed content.
struct SessionReadReplies {
    enum Match {
        case missing, pending, conflict
        case complete(Data)
    }
    struct Limits {
        var perDevice = 128
        var total = 512
        var bytesPerDevice = 2 * 1024 * 1024
        var bytesTotal = 8 * 1024 * 1024
    }
    private struct Entry {
        let device: String
        let hash: String
        let created: Double
        var result: Data?
    }
    private let limits: Limits
    private var entries: [String: Entry] = [:]
    init(limits: Limits = Limits()) { self.limits = limits }
    mutating func lookup(_ key: String, hash: String, now: Double) -> Match {
        entries = entries.filter { $0.value.result == nil || now - $0.value.created < 180 }
        guard let entry = entries[key] else { return .missing }
        guard entry.hash == hash else { return .conflict }
        if let result = entry.result { return .complete(result) }
        return .pending
    }
    mutating func reserve(_ key: String, device: String, hash: String, now: Double) -> Bool {
        guard entries[key] == nil else { return false }
        guard makeRoom(device: device, addedCount: 1, addedBytes: 0, except: nil) else { return false }
        entries[key] = Entry(device: device, hash: hash, created: now)
        return true
    }
    mutating func complete(_ key: String, hash: String, result: Data) {
        guard let entry = entries[key], entry.hash == hash, entry.result == nil else { return }
        guard makeRoom(device: entry.device, addedCount: 0, addedBytes: result.count, except: key) else {
            entries.removeValue(forKey: key)  // Work has finished; a future read may ask again.
            return
        }
        entries[key]?.result = result
    }
    mutating func removeAll() { entries.removeAll() }
    mutating func abandon(_ key: String, hash: String) {
        guard let entry = entries[key], entry.hash == hash, entry.result == nil else { return }
        entries.removeValue(forKey: key)
    }
    mutating func remove(device: String) { entries = entries.filter { $0.value.device != device } }
    private mutating func makeRoom(device: String, addedCount: Int, addedBytes: Int, except key: String?) -> Bool {
        guard addedBytes <= limits.bytesPerDevice, addedBytes <= limits.bytesTotal else { return false }
        while true {
            let own = entries.filter { $0.value.device == device }
            let ownFull =
                own.count + addedCount > limits.perDevice
                || own.values.reduce(0, { $0 + ($1.result?.count ?? 0) }) + addedBytes > limits.bytesPerDevice
            let full =
                entries.count + addedCount > limits.total
                || entries.values.reduce(0, { $0 + ($1.result?.count ?? 0) }) + addedBytes > limits.bytesTotal
            if !ownFull && !full { return true }
            guard
                let oldest = entries.filter({
                    $0.key != key && $0.value.result != nil && (!ownFull || $0.value.device == device)
                }).min(by: { $0.value.created < $1.value.created })?.key
            else { return false }
            entries.removeValue(forKey: oldest)
        }
    }
}
