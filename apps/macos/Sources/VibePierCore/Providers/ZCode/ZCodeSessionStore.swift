import Foundation
import SQLite3

/// Reads the desktop's own session database. The IDs are never translated to
/// Claude or Codex IDs, and a read can never create or update a database.
final class ZCodeSQLiteReader {
    let path: String
    private let attachmentPath: String?
    private var database: OpaquePointer?
    private var inode: UInt64 = 0
    private var attachmentInode: UInt64 = 0
    init(path: String, attachmentPath: String? = nil) {
        self.path = path
        self.attachmentPath = attachmentPath
    }
    deinit { if let database { sqlite3_close(database) } }

    private func connection() throws -> OpaquePointer {
        let current =
            ((try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber]) as? NSNumber)?.uint64Value
            ?? 0
        let attached =
            attachmentPath.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0)[.systemFileNumber]) as? NSNumber
            }?.uint64Value ?? 0
        if current != inode || attached != attachmentInode, let database {
            sqlite3_close(database)
            self.database = nil
        }
        if let database { return database }
        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI, nil)
                == SQLITE_OK, let handle
        else {
            if let handle { sqlite3_close(handle) }
            throw CLIError(L10n.text("provider.no_local_zcode_sessions_found_open_zcode_first"))
        }
        sqlite3_busy_timeout(handle, 500)
        sqlite3_exec(handle, "PRAGMA query_only=1", nil, nil, nil)
        if let attachmentPath, FileManager.default.fileExists(atPath: attachmentPath) {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(handle, "ATTACH DATABASE ? AS desktop_tasks", -1, &statement, nil) == SQLITE_OK {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(
                    statement, 1, URL(fileURLWithPath: attachmentPath).absoluteString + "?mode=ro", -1, transient)
                let status = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard status == SQLITE_DONE else {
                    sqlite3_close(handle)
                    throw CLIError(L10n.text("provider.the_zcode_desktop_task_index_is_temporarily_unreadable"))
                }
            } else {
                sqlite3_close(handle)
                throw CLIError(L10n.text("provider.the_zcode_desktop_task_index_is_temporarily_unreadable"))
            }
        }
        database = handle
        inode = current
        attachmentInode = attached
        return handle
    }

    func rows(_ sql: String, bind: [Any] = []) throws -> [[String: Any]] {
        let database = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CLIError(L10n.text("provider.the_local_zcode_session_index_version_is_incompatible"))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() {
            let position = Int32(index + 1)
            if let value = value as? String {
                sqlite3_bind_text(statement, position, value, -1, transient)
            } else if let value = value as? Int64 {
                sqlite3_bind_int64(statement, position, value)
            } else if let value = value as? Int {
                sqlite3_bind_int64(statement, position, Int64(value))
            } else {
                sqlite3_bind_null(statement, position)
            }
        }
        var result: [[String: Any]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard let bytes = sqlite3_column_text(statement, column),
                        let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8)
                    else { throw CLIError(L10n.text("provider.could_not_read_the_zcode_session_try_again_later")) }
                    row[name] = text
                default: break
                }
            }
            result.append(row)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw CLIError(L10n.text("provider.could_not_read_the_zcode_session_try_again_later"))
        }
        return result
    }

    func version() throws -> String {
        let value = try rows("PRAGMA data_version").first?["data_version"] as? Int64 ?? 0
        return "\(inode):\(value)"
    }
}

final class ZCodeSessionStore {
    struct Turn {
        let userID: String
        let start: Int64
        let end: Int64
        let userParts: [[String: Any]]
        let partCount: Int
        let parts: [[String: Any]]
        let latest: [String: Any]
    }
    private let reader: ZCodeSQLiteReader
    private let index: ZCodeSQLiteReader?
    var path: String { reader.path }
    var indexPath: String? { index?.path }
    private static let visible = "time_archived IS NULL AND coalesce(task_type,'') != 'subagent_child'"
    private static let visibleMessage = "coalesce(json_extract(data,'$.semantics.uiVisibility'),'visible') != 'hidden'"
    private static let types = "('text','reasoning','tool','file','compaction','timeline')"
    private static let userMessage =
        "json_extract(data,'$.role')='user' AND coalesce(json_extract(data,'$.semantics.kind'),'user_prompt')='user_prompt'"
    private static let assistantPart =
        "(json_extract(m.data,'$.role')='assistant' OR json_extract(p.data,'$.type') IN ('timeline','compaction'))"
    private static let messageProjection =
        "json_object('role',json_extract(data,'$.role'),'time',json_extract(data,'$.time'),'modelSelection',json_extract(data,'$.modelSelection'),'modelId',json_extract(data,'$.modelId'),'providerId',json_extract(data,'$.providerId'),'mode',json_extract(data,'$.mode'),'planEnabled',json_extract(data,'$.planEnabled'),'tokens',json_extract(data,'$.tokens'),'anchor',json_extract(data,'$.anchor'),'metadata',json_object('inputClientId',json_extract(data,'$.metadata.inputClientId')))"

    init(
        path: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode/cli/db/db.sqlite")
            .path,
        indexPath: String? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".zcode/v2/tasks-index.sqlite"
        ).path
    ) {
        reader = ZCodeSQLiteReader(path: path, attachmentPath: indexPath)
        index = indexPath.map { ZCodeSQLiteReader(path: $0) }
    }

    func version() throws -> String { try reader.version() + ":" + ((try? index?.version()) ?? "") }

    /// Include every project and archived task: moving an old task must not make it look newly created.
    func existingSessionIDs(limit: Int = 100_000) throws -> Set<String> {
        guard limit > 0, limit <= 100_000 else { throw CLIError(L10n.text("provider.desktop_input_changed")) }
        let rows = try reader.rows("SELECT substr(id,1,257) AS id FROM session LIMIT ?", bind: [limit + 1])
        let ids = rows.compactMap { $0["id"] as? String }
        guard rows.count <= limit, ids.count == rows.count, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
        else {
            throw CLIError(L10n.text("provider.zcode_receipt_baseline_unavailable"))
        }
        return Set(ids)
    }

    /// Full human text for mutation confirmation, independent of the paginated display projection.
    /// First/after selects the immediate next human message, never a later matching duplicate.
    func nativeUser(_ session: String, first: Bool = false, after: String? = nil) throws -> (id: String, text: String)?
    {
        var parameters: [Any] = [session]
        var boundary = ""
        if let after {
            guard
                let sequence = try reader.rows(
                    "SELECT sequence FROM message WHERE session_id=? AND id=? AND \(Self.userMessage) AND \(Self.visibleMessage)",
                    bind: [session, after]
                ).first?["sequence"] as? Int64
            else { return nil }
            boundary = " AND sequence>?"
            parameters.append(sequence)
        }
        let order = first ? "ASC" : "DESC"
        let users = try reader.rows(
            "SELECT substr(id,1,257) AS id,sequence FROM message WHERE session_id=? AND \(Self.userMessage) AND \(Self.visibleMessage)\(boundary) ORDER BY sequence \(order),id \(order) LIMIT 2",
            bind: parameters)
        guard let user = users.first, let id = user["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
            let sequence = user["sequence"] as? Int64,
            users.count < 2 || users[1]["sequence"] as? Int64 != sequence
        else { return nil }
        let rows = try reader.rows(
            "SELECT CASE WHEN sum(length(CAST(data AS BLOB))) OVER ()<=2097152 THEN data END AS data FROM (SELECT data FROM part WHERE session_id=? AND message_id=? AND json_extract(data,'$.type')='text' ORDER BY sequence,id LIMIT 65)",
            bind: [session, id])
        guard !rows.isEmpty, rows.count <= 64 else { return nil }
        var texts: [String] = []
        var bytes = 0
        for row in rows {
            // Older system SQLite JSON extraction truncates a JSON string at embedded NUL.
            // Decode bounded raw JSON with Foundation so a prefix cannot become a false receipt.
            guard let text = Self.json(row["data"])["text"] as? String else { return nil }
            bytes += text.utf8.count + (texts.isEmpty ? 0 : 1)
            guard bytes <= 120_000 else { return nil }
            texts.append(text)
        }
        return (id, texts.joined(separator: "\n"))
    }
    private static func like(_ value: String) -> String {
        "%"
            + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }
    static func json(_ value: Any?) -> [String: Any] {
        guard let text = value as? String else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }
    private func decorate(_ source: [String: Any]) -> [String: Any] {
        var row = source
        row["cwd"] = source["directory"] as? String ?? ""
        row["project"] = URL(fileURLWithPath: source["directory"] as? String ?? "").lastPathComponent
        row["updatedAt"] = source["time_updated"] ?? 0
        row["pinned"] = false
        if let index, let id = source["id"] as? String,
            let task = try? index.rows(
                "SELECT title,pinned,meta_json,task_status,updated_at FROM tasks WHERE task_id=? AND coalesce(deleted,0)=0 AND coalesce(archived,0)=0 LIMIT 1",
                bind: [id]
            ).first
        {
            if let title = task["title"] as? String, !title.isEmpty { row["title"] = title }
            row["pinned"] = (task["pinned"] as? Int64 ?? 0) != 0
            let metadata = Self.json(task["meta_json"])
            row["selection"] = metadata.filter {
                ["model", "mode", "thoughtLevel"].contains($0.key) && $0.value is String
            }
            if let updated = task["updated_at"] { row["updatedAt"] = updated }
            let status = task["task_status"] as? String ?? metadata["status"] as? String ?? ""
            if status == "running" { row["status"] = "running" } else if status == "error" { row["status"] = "failed" }
        }
        row.removeValue(forKey: "directory")
        row.removeValue(forKey: "time_updated")
        return row
    }
    func summary(_ session: String) throws -> [String: Any] {
        let tasks = hasIndex
        let from = tasks ? "session s LEFT JOIN desktop_tasks.tasks t ON t.task_id=s.id" : "session s"
        let visible = tasks ? "AND (t.task_id IS NULL OR (coalesce(t.deleted,0)=0 AND coalesce(t.archived,0)=0))" : ""
        guard !session.isEmpty, session.utf8.count <= 200,
            let row = try reader.rows(
                "SELECT s.id,s.title,s.directory,s.time_updated FROM \(from) WHERE s.id=? AND s.\(Self.visible) \(visible)",
                bind: [session]
            ).first
        else {
            throw CLIError(L10n.text("provider.this_zcode_desktop_session_was_not_found"))
        }
        return decorate(row)
    }
    func list(search: String, offset: Int, cwd: String?, limit: Int) throws -> [String: Any] {
        let limit = min(20, max(1, limit))
        let start = min(100_000, max(0, offset))
        let query = Self.like(search)
        let tasks = hasIndex
        let from = tasks ? "session s LEFT JOIN desktop_tasks.tasks t ON t.task_id=s.id" : "session s"
        let title = tasks ? "coalesce(nullif(t.title,''),s.title)" : "s.title"
        var sql =
            "SELECT s.id,\(title) AS title,s.directory,s.time_updated FROM \(from) WHERE s.\(Self.visible) AND (\(title) LIKE ? ESCAPE '\\' OR s.directory LIKE ? ESCAPE '\\')"
        if tasks { sql += " AND (t.task_id IS NULL OR (coalesce(t.deleted,0)=0 AND coalesce(t.archived,0)=0))" }
        var values: [Any] = [query, query]
        if let cwd {
            sql += " AND s.directory=?"
            values.append(cwd)
        }
        sql +=
            " ORDER BY "
            + (tasks ? "coalesce(t.pinned,0) DESC,coalesce(t.updated_at,s.time_updated) DESC," : "s.time_updated DESC,")
            + "s.id ASC LIMIT ? OFFSET ?"
        values += [limit + 1, start]
        let rows = try reader.rows(sql, bind: values)
        return [
            "threads": rows.prefix(limit).map { row -> [String: Any] in
                var value = decorate(row)
                value.removeValue(forKey: "selection")
                return value
            }, "nextOffset": rows.count > limit ? start + limit : -1,
        ]
    }
    func projects(search: String, offset: Int, limit: Int) throws -> [String: Any] {
        let limit = min(100, max(1, limit))
        let start = min(100_000, max(0, offset))
        let tasks = hasIndex
        let from = tasks ? "session s LEFT JOIN desktop_tasks.tasks t ON t.task_id=s.id" : "session s"
        let visible = tasks ? "AND (t.task_id IS NULL OR (coalesce(t.deleted,0)=0 AND coalesce(t.archived,0)=0))" : ""
        let rows = try reader.rows(
            "SELECT s.directory AS cwd,count(*) AS count,max(s.time_updated) AS updatedAt FROM \(from) WHERE s.\(Self.visible) \(visible) AND s.directory LIKE ? ESCAPE '\\' GROUP BY s.directory ORDER BY max(s.time_updated) DESC,s.directory ASC LIMIT ? OFFSET ?",
            bind: [Self.like(search), limit + 1, start])
        return [
            "projects": rows.prefix(limit).map { row -> [String: Any] in
                var row = row
                row["project"] = URL(fileURLWithPath: row["cwd"] as? String ?? "").lastPathComponent
                return row
            }, "nextOffset": rows.count > limit ? start + limit : -1,
        ]
    }
    private var hasIndex: Bool { indexPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    private func beforeSequence(_ before: String?, session: String) throws -> Int64 {
        guard let before else { return Int64.max }
        var id = before
        if id.hasPrefix("reply-") { id = String(id.dropFirst(6)) }
        guard
            let row = try reader.rows("SELECT sequence FROM message WHERE session_id=? AND id=?", bind: [session, id])
                .first,
            let sequence = row["sequence"] as? Int64
        else { throw CLIError(L10n.text("provider.the_session_changed_refresh_before_retrying")) }
        return sequence
    }
    func window(_ session: String, before: String? = nil, count: Int = ConversationReply.recentTurns) throws -> (
        turns: [Turn], hasOlder: Bool
    ) {
        let boundary = try beforeSequence(before, session: session)
        let count = max(1, min(3, count))
        let rows = try reader.rows(
            "SELECT id,sequence FROM message WHERE session_id=? AND sequence<? AND \(Self.userMessage) AND \(Self.visibleMessage) ORDER BY sequence DESC,id DESC LIMIT ?",
            bind: [session, boundary, count + 1])
        let turns = try rows.prefix(count).reversed().map { row -> Turn in
            try turn(session, userID: row["id"] as? String ?? "")
        }
        return (turns, rows.count > count)
    }
    func turn(_ session: String, userID: String) throws -> Turn {
        guard
            let user = try reader.rows(
                "SELECT sequence,\(Self.messageProjection) AS data FROM message WHERE session_id=? AND id=? AND \(Self.userMessage) AND \(Self.visibleMessage)",
                bind: [session, userID]
            ).first,
            let start = user["sequence"] as? Int64
        else { throw CLIError(L10n.text("provider.the_message_changed_refresh_to_continue")) }
        let end =
            try reader.rows(
                "SELECT min(sequence) AS boundary FROM message WHERE session_id=? AND sequence>? AND \(Self.userMessage) AND \(Self.visibleMessage)",
                bind: [session, start]
            ).first?["boundary"] as? Int64 ?? Int64.max
        let last = try reader.rows(
            "SELECT \(Self.messageProjection) AS data FROM message WHERE session_id=? AND sequence>=? AND sequence<? AND \(Self.visibleMessage) ORDER BY sequence DESC,id DESC LIMIT 1",
            bind: [session, start, end]
        ).first
        let total = try partCount(session, start: start, end: end)
        let parts = try sequence(
            session, start: start, end: end, offset: max(0, total - ConversationReply.recentParts),
            limit: ConversationReply.recentParts)
        let userProjection =
            "json_object('type',json_extract(data,'$.type'),'text',substr(json_extract(data,'$.text'),1,12000),'nativeTextLength',length(json_extract(data,'$.text')),'mime',json_extract(data,'$.mime'),'filename',json_extract(data,'$.filename'),'imageDeferred',json_extract(data,'$.type')='file')"
        let userParts = try reader.rows(
            "SELECT id,\(userProjection) AS data,time_updated FROM part WHERE session_id=? AND message_id=? AND json_extract(data,'$.type') IN ('text','file') ORDER BY sequence,id",
            bind: [session, userID]
        ).map(Self.decodePart)
        var latest = Self.json(last?["data"])
        latest["user"] = Self.json(user["data"])
        return Turn(
            userID: userID, start: start, end: end, userParts: userParts, partCount: total, parts: parts, latest: latest
        )
    }
    private func partCount(_ session: String, start: Int64, end: Int64) throws -> Int {
        Int(
            try reader.rows(
                "SELECT count(*) AS count FROM part p JOIN message m ON m.id=p.message_id AND m.session_id=p.session_id WHERE p.session_id=? AND m.sequence>=? AND m.sequence<? AND \(Self.assistantPart) AND coalesce(json_extract(m.data,'$.semantics.uiVisibility'),'visible')!='hidden' AND json_extract(p.data,'$.type') IN \(Self.types)",
                bind: [session, start, end]
            ).first?["count"] as? Int64 ?? 0)
    }
    /// Only one page of prose and small tool headers crosses this query. Outputs,
    /// edit bodies and serialized tool results stay in SQLite until expanded.
    func sequence(_ session: String, start: Int64, end: Int64, offset: Int, limit: Int) throws -> [[String: Any]] {
        let projection = """
            json_object('type',json_extract(p.data,'$.type'), 'text',substr(json_extract(p.data,'$.text'),1,12000),
              'time',json_extract(p.data,'$.time'),
              'nativeTextLength',length(json_extract(p.data,'$.text')), 'tool',substr(json_extract(p.data,'$.tool'),1,200),
              'nativeImageCount',CASE WHEN json_type(p.data,'$.state.metadata.display.images')='array' THEN json_array_length(p.data,'$.state.metadata.display.images') ELSE 0 END+
                (SELECT count(*) FROM json_each(CASE WHEN json_type(p.data,'$.state.metadata.display.media')='array' THEN json_extract(p.data,'$.state.metadata.display.media') ELSE '[]' END) WHERE json_extract(value,'$.mimeType') LIKE 'image/%'),
              'mime',json_extract(p.data,'$.mime'), 'filename',substr(json_extract(p.data,'$.filename'),1,400),
              'imageDeferred',json_extract(p.data,'$.type')='file',
              'timelineType',json_extract(p.data,'$.timelineType'), 'status',json_extract(p.data,'$.status'),
              'toModel',json_extract(p.data,'$.toModel'), 'toModelSelection',json_extract(p.data,'$.toModelSelection'),
              'timelineStatus',json_extract(p.data,'$.timelineStatus'),
              'state',json_object('status',json_extract(p.data,'$.state.status'),
                'input',json_object('command',substr(json_extract(p.data,'$.state.input.command'),1,400),
                  'description',substr(json_extract(p.data,'$.state.input.description'),1,200),
                  'file_path',substr(json_extract(p.data,'$.state.input.file_path'),1,400), 'path',substr(json_extract(p.data,'$.state.input.path'),1,400)),
                'metadata',json_object('display',json_object('kind',json_extract(p.data,'$.state.metadata.display.kind'),
                  'filePath',substr(json_extract(p.data,'$.state.metadata.display.filePath'),1,400),'additions',json_extract(p.data,'$.state.metadata.display.additions'),
                  'deletions',json_extract(p.data,'$.state.metadata.display.deletions'),'truncated',json_extract(p.data,'$.state.metadata.display.truncated'))),
                'time',json_extract(p.data,'$.state.time')))
            """
        return try reader.rows(
            "SELECT p.id,p.time_updated,\(projection) AS data FROM part p JOIN message m ON m.id=p.message_id AND m.session_id=p.session_id WHERE p.session_id=? AND m.sequence>=? AND m.sequence<? AND \(Self.assistantPart) AND coalesce(json_extract(m.data,'$.semantics.uiVisibility'),'visible')!='hidden' AND json_extract(p.data,'$.type') IN \(Self.types) ORDER BY m.sequence,p.sequence,p.id LIMIT ? OFFSET ?",
            bind: [session, start, end, max(0, min(8, limit)), max(0, offset)]
        ).map(Self.decodePart)
    }
    private static func decodePart(_ row: [String: Any]) -> [String: Any] {
        var part = json(row["data"])
        part["id"] = row["id"]
        part["nativeVersion"] = String(row["time_updated"] as? Int64 ?? 0)
        return part
    }
    func part(_ session: String, id: String) throws -> [String: Any]? {
        try reader.rows(
            "SELECT id,data,time_updated FROM part WHERE session_id=? AND id=? LIMIT 1", bind: [session, id]
        ).first.map(Self.decodePart)
    }
    func messageParts(_ session: String, id: String) throws -> [[String: Any]] {
        try reader.rows(
            "SELECT id,data,time_updated FROM part WHERE session_id=? AND message_id=? ORDER BY sequence,id",
            bind: [session, id]
        ).map(Self.decodePart)
    }
    func replyText(_ session: String, turn: Turn) throws -> String {
        let rows = try reader.rows(
            "SELECT json_extract(p.data,'$.text') AS text FROM part p JOIN message m ON m.id=p.message_id AND m.session_id=p.session_id WHERE p.session_id=? AND m.sequence>=? AND m.sequence<? AND json_extract(m.data,'$.role')='assistant' AND coalesce(json_extract(m.data,'$.semantics.uiVisibility'),'visible')!='hidden' AND json_extract(p.data,'$.type')='text' ORDER BY m.sequence,p.sequence,p.id",
            bind: [session, turn.start, turn.end])
        return rows.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }
}
