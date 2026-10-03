import Foundation
import SQLite3

struct CodexThreadStore: Sendable {
    let path: String
    init(
        path: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite")
            .path
    ) { self.path = path }
    static let visible = """
        archived=0 AND agent_path IS NULL
        AND source IN ('vscode','cli') AND (originator IS NULL OR originator IN ('Codex Desktop','codex_desktop','codex_work_desktop','codex_cli_rs','vibepier'))
        """
    /// `cwd` limits the list to one project; nil lists every project.
    func list(search: String, offset: Int, cwd: String? = nil, limit: Int = 20) throws -> [String: Any] {
        let limit = max(1, min(limit, 20))
        let offset = max(0, min(offset, 100_000))
        let sql = """
            SELECT id, CASE WHEN name IS NOT NULL AND name != '' THEN name ELSE title END, cwd, is_pinned, recency_at_ms, rollout_path
            FROM threads WHERE \(Self.visible)
            AND (coalesce(nullif(name,''),title) LIKE ? ESCAPE '\\' OR cwd LIKE ? ESCAPE '\\')
            AND (? IS NULL OR cwd = ?)
            ORDER BY \(cwd == nil ? "is_pinned DESC, " : "")recency_at_ms DESC, id DESC LIMIT \(limit + 1) OFFSET ?
            """
        let query = Self.like(search)
        let now = Date()
        let rows = try select(sql, bind: [query, query, cwd, cwd, max(0, min(offset, 100_000))]) { text, int in
            var row: [String: Any] = [
                "id": text(0), "title": text(1), "project": URL(fileURLWithPath: text(2)).lastPathComponent,
                "cwd": text(2),
                "pinned": int(3) != 0, "updatedAt": int(4),
            ]
            if Self.running(rollout: text(5), now: now) { row["status"] = "running" }
            return row
        }
        return ["threads": Array(rows.prefix(limit)), "nextOffset": rows.count > limit ? offset + limit : -1]
    }
    /// One row per working directory, most recently active first.
    func projects(search: String, offset: Int = 0, limit: Int = 100) throws -> [String: Any] {
        let limit = max(1, min(limit, 100))
        let offset = max(0, min(offset, 100_000))
        let sql = """
            SELECT cwd, count(*), max(recency_at_ms) FROM threads WHERE \(Self.visible) AND cwd LIKE ? ESCAPE '\\'
            GROUP BY cwd ORDER BY max(recency_at_ms) DESC LIMIT \(limit + 1) OFFSET \(offset)
            """
        let rows = try select(sql, bind: [Self.like(search)]) { text, int in
            [
                "cwd": text(0), "project": URL(fileURLWithPath: text(0)).lastPathComponent, "count": int(1),
                "updatedAt": int(2),
            ] as [String: Any]
        }
        // A task only runs in a thread touched recently, so the rollout tails read stay few.
        let now = Date()
        let recent = try select(
            "SELECT cwd, rollout_path FROM threads WHERE \(Self.visible) AND updated_at_ms > ? ORDER BY updated_at_ms DESC LIMIT 200",
            bind: [Int(now.timeIntervalSince1970 * 1000) - 86_400_000]
        ) { text, _ in ["cwd": text(0), "rollout": text(1)] }
        var running: [String: Int] = [:]
        let visible = Set(rows.prefix(limit).compactMap { $0["cwd"] as? String })
        for row in recent
        where visible.contains(row["cwd"] as? String ?? "")
            && Self.running(rollout: row["rollout"] as? String ?? "", now: now)
        { running[row["cwd"] as? String ?? "", default: 0] += 1 }
        return [
            "nextOffset": rows.count > limit ? offset + limit : -1,
            "projects": rows.prefix(limit).map { row in
                var row = row
                if let count = running[row["cwd"] as? String ?? ""] { row["running"] = count }
                return row
            },
        ]
    }
    /// The state DB has no run state; the rollout does: a turn runs from `task_started` until `task_complete` or `turn_aborted`.
    /// A rollout untouched for half an hour belongs to a turn that died without closing, not one still working.
    static func running(rollout path: String, now: Date, stale: TimeInterval = 1800) -> Bool {
        guard !path.isEmpty, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) < stale,
            let size = (attributes[.size] as? NSNumber)?.uint64Value, let handle = FileHandle(forReadingAtPath: path)
        else { return false }
        defer { try? handle.close() }
        let started = Data(#""payload":{"type":"task_started""#.utf8)
        let finished = [
            Data(#""payload":{"type":"task_complete""#.utf8), Data(#""payload":{"type":"turn_aborted""#.utf8),
        ]
        // Rollouts grow to hundreds of megabytes; read only enough of the tail to find the latest marker.
        for window in [UInt64(256 << 10), 2 << 20, 8 << 20] {
            let length = min(size, window)
            guard (try? handle.seek(toOffset: size - length)) != nil,
                let tail = try? handle.read(upToCount: Int(length))
            else { return false }
            let start = tail.range(of: started, options: .backwards)?.lowerBound
            let end = finished.compactMap { tail.range(of: $0, options: .backwards)?.lowerBound }.max()
            if start != nil || end != nil { return (start ?? -1) > (end ?? -1) }
            if length == size { return false }
        }
        return false
    }
    /// New threads may only start in a directory Codex already lists as a project.
    func isProject(_ cwd: String) throws -> Bool {
        try !select("SELECT 1 FROM threads WHERE \(Self.visible) AND cwd = ? LIMIT 1", bind: [cwd]) { _, _ in [:] }
            .isEmpty
    }
    /// Native project identity must resolve to exactly this one root and an unambiguous displayed name.
    func creationProject(cwd: String) throws -> CodexCreationProject {
        let sql = """
            SELECT p.id,p.name FROM projects p JOIN project_roots r ON r.project_id=p.id
            WHERE r.path=? AND p.name!=''
              AND (SELECT count(*) FROM project_roots WHERE project_id=p.id)=1
            LIMIT 2
            """
        let rows = try select(sql, bind: [cwd]) { text, _ in ["id": text(0), "name": text(1)] }
        guard rows.count == 1, let id = rows[0]["id"] as? String, UUID(uuidString: id) != nil,
            let name = rows[0]["name"] as? String, name.utf8.count <= 512
        else { throw CLIError(L10n.text("session.codex_creation_project_unverified")) }
        let identity = CodexCreationProject.labelIdentity(name)
        let names = try select("SELECT name FROM projects LIMIT 10001", bind: []) { text, _ in ["name": text(0)] }
        guard !identity.isEmpty, names.count <= 10000,
            names.filter({ CodexCreationProject.labelIdentity($0["name"] as? String ?? "") == identity }).count == 1
        else { throw CLIError(L10n.text("session.codex_creation_project_unverified")) }
        return CodexCreationProject(id: id, name: name, cwd: cwd)
    }

    func creationSnapshot(cwd: String, since: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws
        -> CodexCreationSnapshot
    {
        // Include other projects too: moving an existing thread must never make its identity look new.
        let rows = try select("SELECT id FROM threads LIMIT 100001", bind: []) { text, _ in
            ["id": text(0)]
        }
        guard rows.count <= 100000 else { throw CLIError(L10n.text("session.codex_creation_project_unverified")) }
        return CodexCreationSnapshot(cwd: cwd, since: since, existingIDs: Set(rows.compactMap { $0["id"] as? String }))
    }

    /// A matching timestamp/title is insufficient: require a new desktop ID and its exact first native user record.
    func created(snapshot: CodexCreationSnapshot, text expected: String) throws -> CodexCreationReceipt? {
        let sql = """
            SELECT id, CASE WHEN name IS NOT NULL AND name != '' THEN name ELSE title END, rollout_path, archived FROM threads
            WHERE agent_path IS NULL AND source='vscode'
              AND originator IN ('Codex Desktop','codex_desktop')
              AND cwd=? AND created_at_ms>=? AND first_user_message=? ORDER BY created_at_ms,id LIMIT 33
            """
        let rows = try select(sql, bind: [snapshot.cwd, Int(snapshot.since), expected]) { text, int in
            ["id": text(0), "title": text(1), "rollout": text(2), "archived": int(3)]
        }.filter { !snapshot.existingIDs.contains($0["id"] as? String ?? "") }
        // Identical concurrent creations are ambiguous even if only one rollout has flushed so far.
        guard rows.count == 1, rows[0]["archived"] as? Int64 == 0,
            let id = rows[0]["id"] as? String, UUID(uuidString: id) != nil,
            let rollout = rows[0]["rollout"] as? String,
            let native = CodexCreationReceipt.read(rollout: rollout, threadID: id, cwd: snapshot.cwd, text: expected)
        else { return nil }
        return CodexCreationReceipt(
            threadID: id, title: rows[0]["title"] as? String ?? "", cwd: snapshot.cwd,
            messageID: native.message, turnID: native.turn)
    }
    private static func like(_ search: String) -> String {
        "%"
            + search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }
    private func select(_ sql: String, bind values: [Any?], row: ((Int32) -> String, (Int32) -> Int64) -> [String: Any])
        throws -> [[String: Any]]
    {
        var (db, statement, status) = try prepare(sql, flags: SQLITE_OPEN_READONLY)
        // A WAL database that Codex has closed has no -wal/-shm files, and a read-only connection cannot create
        // them, so it fails to open. Reconnect without CREATE so SQLite can recreate them; the connection stays query-only.
        if status & 0xff == SQLITE_CANTOPEN {
            sqlite3_close(db)
            (db, statement, status) = try prepare(sql, flags: SQLITE_OPEN_READWRITE, queryOnly: true)
        }
        defer { sqlite3_close(db) }
        guard status == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw CLIError(
                message.hasPrefix("no such")
                    ? L10n.text("session.the_codex_session_index_version_is_incompatible")
                    : L10n.text("session.could_not_read_codex_sessions_0", message))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let n = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, n, text, -1, transient)
            case let number as Int: sqlite3_bind_int64(statement, n, Int64(number))
            default: sqlite3_bind_null(statement, n)
            }
        }
        var rows: [[String: Any]] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            rows.append(
                row(
                    { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" },
                    { sqlite3_column_int64(statement, $0) }))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw CLIError(L10n.text("session.could_not_read_codex_sessions_retry")) }
        return rows
    }
    private func prepare(_ sql: String, flags: Int32, queryOnly: Bool = false) throws -> (
        OpaquePointer, OpaquePointer?, Int32
    ) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw CLIError(L10n.text("session.no_local_codex_sessions_found_open_codex_first"))
        }
        sqlite3_busy_timeout(db, 500)
        if queryOnly { sqlite3_exec(db, "PRAGMA query_only=1", nil, nil, nil) }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        return (db, statement, sqlite3_extended_errcode(db) == SQLITE_OK ? status : sqlite3_extended_errcode(db))
    }
}
