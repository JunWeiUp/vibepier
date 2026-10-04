import CryptoKit
import Foundation
import SQLite3

/// Private, disposable metadata index. Native JSONL remains the complete source;
/// only requested turns are decoded, and no transcript body is written here.
final class ClaudeHistoryIndex {
    enum Failure: Error, LocalizedError, Equatable {
        case unavailable, tooLarge
        var errorDescription: String? {
            L10n.text(
                self == .tooLarge ? "provider.claude_history_page_too_large" : "provider.claude_history_unavailable")
        }
    }
    static let maxPageBytes = 8 * 1024 * 1024
    static let maxRecordBytes = 8 * 1024 * 1024
    let url: URL
    private let directory: URL
    private var database: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private(set) var incarnation = UUID()
    private(set) var inode: UInt64 = 0
    private(set) var offset: UInt64 = 0
    private(set) var turnCount = 0
    private(set) var failure: Error?
    private var modified: Date?
    private var observedSize: UInt64 = 0
    private var indexedFingerprint: Data?
    private var revision = 0
    private(set) var cwd = ""
    private var firstTitle = ""
    private var generatedTitle = ""
    private var customTitle = ""
    private(set) var modelID: String?
    private(set) var switchedModel: (label: String, alias: String)?
    private(set) var effort = "default"
    private(set) var permissionMode = ""
    var title: String {
        !customTitle.isEmpty
            ? customTitle : !generatedTitle.isEmpty ? generatedTitle : !firstTitle.isEmpty ? firstTitle : "Claude Code"
    }
    var entries: [[String: Any]] { (try? latestEntries()) ?? [] }

    init(url: URL) throws {
        self.url = url
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vibepier-history-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            guard
                sqlite3_open_v2(
                    directory.appendingPathComponent("index.sqlite").path, &database,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
            else { throw Failure.unavailable }
            try execute("PRAGMA journal_mode=MEMORY")
            try execute("PRAGMA cache_size=-64")
            try execute("PRAGMA max_page_count=16384")
            try execute("CREATE TABLE turns (id INTEGER PRIMARY KEY, start INTEGER NOT NULL, end INTEGER NOT NULL)")
            try execute("CREATE TABLE refs (id TEXT NOT NULL, turn INTEGER NOT NULL, PRIMARY KEY(id,turn))")
            try execute("CREATE TABLE native_ids (id TEXT NOT NULL, offset INTEGER NOT NULL, PRIMARY KEY(id,offset))")
        } catch {
            if let database {
                sqlite3_close(database)
                self.database = nil
            }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let database { sqlite3_close(database) }
        ClaudeHistoryCache.shared.remove(incarnation)
        try? FileManager.default.removeItem(at: directory)
    }
    private func statement(_ sql: String, _ bind: [Any] = []) throws -> OpaquePointer {
        let result: OpaquePointer
        if let cached = statements[sql] {
            result = cached
            sqlite3_reset(result)
            sqlite3_clear_bindings(result)
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                throw Failure.unavailable
            }
            statements[sql] = prepared
            result = prepared
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bind.enumerated() {
            if let value = value as? String {
                sqlite3_bind_text(result, Int32(i + 1), value, -1, transient)
            } else if let value = value as? Int {
                sqlite3_bind_int64(result, Int32(i + 1), Int64(value))
            } else if let value = value as? UInt64 {
                guard value <= UInt64(Int64.max) else { throw Failure.tooLarge }
                sqlite3_bind_int64(result, Int32(i + 1), Int64(value))
            }
        }
        return result
    }
    private func execute(_ sql: String, _ bind: [Any] = []) throws {
        let statement = try statement(sql, bind)
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw Failure.unavailable }
    }
    private func numbers(_ sql: String, _ bind: [Any] = []) throws -> [[Int64]] {
        let statement = try statement(sql, bind)
        var rows: [[Int64]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_int64(statement, $0) })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw Failure.unavailable }
        return rows
    }
    private func reset() throws {
        ClaudeHistoryCache.shared.remove(incarnation)
        incarnation = UUID()
        inode = 0
        offset = 0
        observedSize = 0
        indexedFingerprint = nil
        turnCount = 0
        revision = 0
        cwd = ""
        firstTitle = ""
        generatedTitle = ""
        customTitle = ""
        modelID = nil
        switchedModel = nil
        effort = "default"
        permissionMode = ""
        try execute("DELETE FROM turns")
        try execute("DELETE FROM refs")
        try execute("DELETE FROM native_ids")
    }
    /// Reads at most 64 KiB at once; an unfinished record is re-read on the next
    /// append, never interpreted as a completed native message.
    @discardableResult
    static func scan(_ url: URL, from: UInt64, to: UInt64, visit: (Data, UInt64, UInt64) throws -> Void) throws
        -> UInt64
    {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: from)
        var cursor = from
        var start = from
        var remainder = Data()
        while cursor < to {
            guard let block = try file.read(upToCount: Int(min(64 * 1024, to - cursor))), !block.isEmpty else {
                throw Failure.unavailable
            }
            cursor += UInt64(block.count)
            var position = block.startIndex
            while position < block.endIndex {
                let end = block[position...].firstIndex(of: 10) ?? block.endIndex
                let count = end - position
                guard count <= maxRecordBytes - remainder.count else { throw Failure.tooLarge }
                remainder.append(block[position..<end])
                if end < block.endIndex {
                    let next = cursor - UInt64(block.endIndex - end - 1)
                    try visit(remainder, start, next)
                    remainder.removeAll(keepingCapacity: false)
                    start = next
                    position = end + 1
                } else {
                    position = end
                }
            }
        }
        return start
    }
    @discardableResult
    func refresh() -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                let size = (attrs[.size] as? NSNumber)?.uint64Value,
                let node = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
                let date = attrs[.modificationDate] as? Date
            else { throw Failure.unavailable }
            var prefixChanged = false
            if node == inode, size >= offset, offset > 0, let indexedFingerprint {
                prefixChanged = try sourceFingerprint(through: offset) != indexedFingerprint
            }
            if node != inode || size < offset || (size == offset && modified != nil && modified != date)
                || prefixChanged || failure != nil
            {
                try reset()
            }
            inode = node
            modified = date
            observedSize = size
            guard size > offset else {
                failure = nil
                return false
            }
            let previous = offset
            try execute("BEGIN TRANSACTION")
            do {
                let next = try Self.scan(url, from: offset, to: size) { data, start, end in
                    guard !data.isEmpty else { return }
                    guard let entry = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw Failure.unavailable
                    }
                    try self.consume(entry, start: start, end: end)
                }
                let after = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (after[.systemFileNumber] as? NSNumber)?.uint64Value == node,
                    ((after[.size] as? NSNumber)?.uint64Value ?? 0) >= size
                else { throw Failure.unavailable }
                let fingerprint = try sourceFingerprint(through: next)
                try execute("COMMIT")
                offset = next
                indexedFingerprint = fingerprint
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            failure = nil
            if offset != previous {
                revision += 1
                ClaudeHistoryCache.shared.remove(incarnation)
            }
            return offset != previous
        } catch {
            failure = error
            ClaudeHistoryCache.shared.remove(incarnation)
            return false
        }
    }
    private func reference(_ id: String, turn: Int) throws {
        guard !id.isEmpty, id.utf8.count <= 512, !id.contains("\0") else { return }
        try execute("INSERT OR IGNORE INTO refs VALUES (?,?)", [id, turn])
    }
    private func consume(_ entry: [String: Any], start: UInt64, end: UInt64) throws {
        if let value = entry["cwd"] as? String, !value.isEmpty {
            guard value.utf8.count <= 16_384 else { throw Failure.tooLarge }
            cwd = value
        }
        if let value = entry["permissionMode"] as? String { permissionMode = String(value.prefix(100)) }
        if entry["type"] as? String == "custom-title", let value = entry["customTitle"] as? String, !value.isEmpty {
            customTitle = String(value.prefix(80))
        }
        if entry["type"] as? String == "ai-title", let value = entry["aiTitle"] as? String {
            generatedTitle = String(value.prefix(80))
        }
        if entry["type"] as? String == "assistant",
            let value = (entry["message"] as? [String: Any])?["model"] as? String, value.hasPrefix("claude")
        {
            modelID = String(value.prefix(256))
            switchedModel = nil
        }
        if entry["subtype"] as? String == "local_command", let run = entry["commandRun"] as? [String: Any] {
            if run["command"] as? String == "effort" {
                effort = String((run["args"] as? String ?? "").prefix(100)).lowercased()
            }
            if run["command"] as? String == "model", let output = entry["content"] as? String,
                let label = output.split(separator: "`").dropFirst().first
            {
                switchedModel = (
                    String(label.prefix(256)).replacingOccurrences(of: " (default)", with: ""),
                    String((run["args"] as? String ?? "").prefix(100)).lowercased()
                )
            }
        }
        let user = ClaudeTranscript.userMessage(entry)
        if let user {
            if firstTitle.isEmpty { firstTitle = String(user.text.prefix(80)) }
            try execute("INSERT INTO turns VALUES (?,?,?)", [turnCount, start, end])
            turnCount += 1
        } else if turnCount == 0, entry["isSidechain"] as? Bool != true,
            entry["type"] as? String == "assistant"
                || (entry["type"] as? String == "system" && entry["subtype"] as? String == "api_error")
        {
            try execute("INSERT INTO turns VALUES (?,?,?)", [0, start, end])
            turnCount = 1
        }
        if let id = entry["uuid"] as? String, !id.isEmpty, id.utf8.count <= 512, !id.contains("\0") {
            try execute("INSERT OR IGNORE INTO native_ids VALUES (?,?)", [id, start])
        }
        guard turnCount > 0 else { return }
        let turn = turnCount - 1
        try execute("UPDATE turns SET end=? WHERE id=?", [end, turn])
        if let id = entry["uuid"] as? String {
            try reference(id, turn: turn)
            try reference("reply-" + id, turn: turn)
            if let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                for (i, block) in blocks.enumerated() {
                    try reference(id + "-\(i)", turn: turn)
                    try reference("reply-" + id + "-\(i)", turn: turn)
                    if let tool = block["id"] as? String { try reference(tool, turn: turn) }
                }
            }
        }
    }
    func turn(containing id: String) throws -> Int? {
        if let failure { throw failure }
        let base = id.components(separatedBy: "#").first ?? id
        let rows = try numbers("SELECT turn FROM refs WHERE id=? LIMIT 2", [base])
        guard rows.count == 1 else { return nil }
        return Int(rows[0][0])
    }
    func readEntries(start: Int, end: Int) throws -> [[String: Any]] {
        if let failure { throw failure }
        try verifySource()
        guard start < end else { return [] }
        let ranges = try numbers("SELECT start,end FROM turns WHERE id>=? AND id<? ORDER BY id LIMIT 4", [start, end])
        guard let first = ranges.first, let last = ranges.last else { return [] }
        let lower = UInt64(first[0])
        let upper = UInt64(last[1])
        guard upper >= lower, upper - lower <= Self.maxPageBytes else { throw Failure.tooLarge }
        let key = "\(revision):\(start):\(end)"
        if let cached = ClaudeHistoryCache.shared.get(incarnation, key: key) { return cached }
        var result: [[String: Any]] = []
        try Self.scan(url, from: lower, to: upper) { data, _, _ in
            guard result.count < 32_768 else { throw Failure.tooLarge }
            if !data.isEmpty {
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw Failure.unavailable
                }
                result.append(value)
            }
        }
        try verifySource()
        ClaudeHistoryCache.shared.put(incarnation, key: key, entries: result, bytes: Int(upper - lower))
        return result
    }
    func latestEntries() throws -> [[String: Any]] {
        try readEntries(start: max(0, turnCount - ConversationReply.recentTurns), end: turnCount)
    }
    func projected(containing id: String? = nil, count: Int = ConversationReply.recentTurns) throws -> [[[String: Any]]]
    {
        let end: Int
        if let id {
            guard let turn = try turn(containing: id) else { return [] }
            end = turn + 1
        } else {
            end = turnCount
        }
        return ClaudeTranscript.turns(try readEntries(start: max(0, end - count), end: end))
    }
    func older(before id: String) throws -> (rows: [[String: Any]], start: Int)? {
        guard let turn = try turn(containing: id) else { return nil }
        let start = max(0, turn - ConversationReply.olderTurns)
        return (ConversationReply.preview(ClaudeTranscript.messages(try readEntries(start: start, end: turn))), start)
    }
    /// Late confirmations scan appended native records independently of retained
    /// pages. A reused old UUID or ambiguous matching prompt remains unknown.
    func confirmedMessage(after start: UInt64, text: String) -> String? {
        let expected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard failure == nil, start <= offset, !expected.isEmpty else { return nil }
        var matches: [String] = []
        do {
            try verifySource()
            try Self.scan(url, from: start, to: offset) { data, _, _ in
                guard let entry = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let message = ClaudeSendReceipt.message(entry), message.text == expected
                else { return }
                guard message.id.utf8.count <= 512,
                    !message.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else { throw Failure.unavailable }
                let old = try self.numbers(
                    "SELECT offset FROM native_ids WHERE id=? AND offset<? LIMIT 1", [message.id, start])
                if !old.isEmpty { throw Failure.unavailable }
                matches.append(message.id)
                guard matches.count <= 1 else { throw Failure.unavailable }
            }
            try verifySource()
            return matches.count == 1 ? matches[0] : nil
        } catch { return nil }
    }
    /// A record that began before submission must not become new receipt evidence merely when its newline arrives.
    func receiptBoundary() throws -> UInt64 {
        if let failure { throw failure }
        try verifySource()
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        guard observedSize == offset, size == offset else { throw Failure.unavailable }
        return offset
    }
    private func sourceFingerprint(through end: UInt64) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = min(UInt64(4096), end)
        var hash = SHA256()
        for start in [UInt64(0), end - length] {
            try file.seek(toOffset: start)
            let data = try file.read(upToCount: Int(length)) ?? Data()
            guard data.count == Int(length) else { throw Failure.unavailable }
            hash.update(data: data)
        }
        return Data(hash.finalize())
    }
    private func verifySource() throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
            (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == inode,
            ((attrs[.size] as? NSNumber)?.uint64Value ?? 0) >= offset,
            indexedFingerprint == (try sourceFingerprint(through: offset))
        else { throw Failure.unavailable }
    }
    static var cachedBodyBytes: Int { ClaudeHistoryCache.shared.retainedBytes }
}

/// One aggregate body-cache budget, including all ClaudeBridge instances. Large
/// requested turns are transient; no decoded full-history projection is retained.
private final class ClaudeHistoryCache: @unchecked Sendable {
    static let shared = ClaudeHistoryCache()
    private struct Value {
        let key: String
        let entries: [[String: Any]]
        let bytes: Int
    }
    private let lock = NSLock()
    private var values: [UUID: Value] = [:]
    private var order: [UUID] = []
    private var bytes = 0
    var retainedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
    func get(_ id: UUID, key: String) -> [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[id], value.key == key else { return nil }
        order.removeAll { $0 == id }
        order.append(id)
        return value.entries
    }
    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(id)
    }
    private func removeLocked(_ id: UUID) {
        if let old = values.removeValue(forKey: id) { bytes -= old.bytes }
        order.removeAll { $0 == id }
    }
    func put(_ id: UUID, key: String, entries: [[String: Any]], bytes count: Int) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(id)
        guard count <= 1024 * 1024 else { return }
        while bytes + count > 4 * 1024 * 1024 || values.count >= 16 {
            guard let first = order.first else { break }
            removeLocked(first)
        }
        values[id] = Value(key: key, entries: entries, bytes: count)
        order.append(id)
        bytes += count
    }
}
