import Foundation
import SQLite3

/// Reads an existing native database without creating or modifying it.
final class ReadOnlySQLiteReader {
    enum Failure: Error { case unavailable, incompatibleQuery, unreadable }
    let path: String
    private var database: OpaquePointer?
    private var inode: UInt64 = 0
    init(path: String) {
        self.path = path
    }
    deinit { if let database { sqlite3_close(database) } }

    private func connection() throws -> OpaquePointer {
        let current =
            ((try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber]) as? NSNumber)?.uint64Value
            ?? 0
        if current != inode, let database {
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
            throw Failure.unavailable
        }
        sqlite3_busy_timeout(handle, 500)
        sqlite3_exec(handle, "PRAGMA query_only=1", nil, nil, nil)
        database = handle
        inode = current
        return handle
    }

    func rows(_ sql: String, bind: [Any] = []) throws -> [[String: Any]] {
        let database = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.incompatibleQuery
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
                    else { throw Failure.unreadable }
                    row[name] = text
                default: break
                }
            }
            result.append(row)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw Failure.unreadable
        }
        return result
    }

    func version() throws -> String {
        let value = try rows("PRAGMA data_version").first?["data_version"] as? Int64 ?? 0
        return "\(inode):\(value)"
    }
}
