import Foundation
import SQLite3
import XCTest

@testable import VibePierCore

final class CodexMobileVisibilityTests: XCTestCase {
    func testPhoneCreatedThreadsAppearButOtherOriginsAndSubagentsStayHidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("threads.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE threads(id TEXT,name TEXT,title TEXT,cwd TEXT,is_pinned INTEGER,recency_at_ms INTEGER,rollout_path TEXT,archived INTEGER,agent_path TEXT,source TEXT,originator TEXT);
            INSERT INTO threads VALUES('phone','Phone session','','/demo',0,100,'',0,NULL,'vscode','vibepier');
            INSERT INTO threads VALUES('desktop','Desktop session','','/demo',0,90,'',0,NULL,'vscode','Codex Desktop');
            INSERT INTO threads VALUES('background','Background session','','/demo',0,101,'',0,NULL,'appServer','vibepier');
            INSERT INTO threads VALUES('foreign-background','Other background','','/other',0,111,'',0,NULL,'appServer','Codex Desktop');
            INSERT INTO threads VALUES('unknown','Other app','','/other',0,110,'',0,NULL,'vscode','unknown');
            INSERT INTO threads VALUES('archived','Archived','','/other',0,120,'',1,NULL,'vscode','vibepier');
            INSERT INTO threads VALUES('subagent','Subagent','','/other',0,130,'',0,'child','vscode','vibepier');
            ALTER TABLE threads ADD COLUMN updated_at_ms INTEGER DEFAULT 0;
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let store = CodexThreadStore(path: path)
        let rows = try XCTUnwrap(store.list(search: "", offset: 0)["threads"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["background", "phone", "desktop"])
        let projectRows = try XCTUnwrap(store.list(search: "", offset: 0, cwd: "/demo")["threads"] as? [[String: Any]])
        XCTAssertEqual(projectRows.count, 3)
        let projects = try XCTUnwrap(store.projects(search: "")["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?["cwd"] as? String, "/demo")
    }
}
