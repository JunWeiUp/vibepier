import Foundation
import SQLite3
import XCTest

@testable import VibePierCore

final class ReadOnlySQLiteReaderTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("native.sqlite")
    }

    private func execute(_ path: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    func testMissingDatabaseIsNeverCreatedAndExistingDatabaseCannotBeMutated() throws {
        let path = try fixture()
        let reader = ReadOnlySQLiteReader(path: path.path)
        XCTAssertThrowsError(try reader.rows("SELECT 1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        try execute(path, "CREATE TABLE sample(id INTEGER); INSERT INTO sample VALUES(7);")
        XCTAssertThrowsError(try reader.rows("DELETE FROM sample"))
        _ = try reader.rows("PRAGMA query_only=0;")
        XCTAssertThrowsError(try reader.rows("DELETE FROM sample"))
        XCTAssertEqual(try reader.rows("SELECT id FROM sample").first?["id"] as? Int64, 7)
    }

    func testReadPreservesEmbeddedNulUnicodeAndTypedValues() throws {
        let path = try fixture()
        try execute(path, "CREATE TABLE sample(text TEXT); INSERT INTO sample VALUES('前' || char(0) || '后🐱');")
        let reader = ReadOnlySQLiteReader(path: path.path)
        let row = try XCTUnwrap(
            reader.rows("SELECT text, 1 AS integer_value, 1.5 AS real_value FROM sample WHERE ? = ?", bind: [9, 9])
                .first)
        XCTAssertEqual(row["text"] as? String, "前\0后🐱")
        XCTAssertEqual(row["integer_value"] as? Int64, 1)
        XCTAssertEqual(row["real_value"] as? Double, 1.5)
    }

    func testVersionTracksExternalWritesAndReopensReplacedDatabase() throws {
        let path = try fixture()
        try execute(path, "CREATE TABLE sample(id INTEGER); INSERT INTO sample VALUES(1);")
        let reader = ReadOnlySQLiteReader(path: path.path)
        let initial = try reader.version()
        try execute(path, "INSERT INTO sample VALUES(2);")
        XCTAssertNotEqual(try reader.version(), initial)
        let replacement = path.deletingLastPathComponent().appendingPathComponent("replacement.sqlite")
        try execute(replacement, "CREATE TABLE sample(id INTEGER); INSERT INTO sample VALUES(3);")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: replacement, to: path)
        XCTAssertNotEqual(try reader.version(), initial)
        XCTAssertEqual(try reader.rows("SELECT id FROM sample").compactMap { $0["id"] as? Int64 }, [3])
    }
}
