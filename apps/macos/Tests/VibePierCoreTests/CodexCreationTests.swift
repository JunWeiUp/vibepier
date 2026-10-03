import Foundation
import SQLite3
import XCTest

@testable import VibePierCore

final class CodexCreationTests: XCTestCase {
    private let thread = "00000000-0000-4000-8000-000000000001"
    private let turn = "00000000-0000-4000-8000-000000000002"
    private let project = "00000000-0000-4000-8000-000000000003"
    private let cwd = "/Users/demo/Project"
    private let prompt = "Check C++ & 中文\nKeep the complete request."

    private func rows(body: String? = nil, id: String? = nil) -> [[String: Any]] {
        let metadata: [String: Any] = ["turn_id": turn, "content_item_kinds": ["user.text"]]
        return [
            [
                "type": "session_meta",
                "payload": ["id": id ?? thread, "cwd": cwd, "source": "vscode", "originator": "Codex Desktop"],
            ],
            ["type": "event_msg", "payload": ["type": "task_started", "turn_id": turn]],
            [
                "type": "response_item",
                "payload": [
                    "type": "message", "role": "user", "id": "context-item",
                    "content": [["type": "input_text", "text": prompt]],
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": turn, "content_item_kinds": ["agents_md.instructions"],
                    ],
                ],
            ],
            [
                "type": "response_item",
                "payload": [
                    "type": "message", "role": "user", "id": "native-user-item",
                    "content": [["type": "input_text", "text": body ?? prompt + "\n"]],
                    "internal_chat_message_metadata_passthrough": metadata,
                ],
            ],
        ]
    }
    private func encoded(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { result, row in
            result.append(try JSONSerialization.data(withJSONObject: row))
            result.append(10)
        }
    }
    private func match(_ rows: [[String: Any]]) throws -> (message: String, turn: String)? {
        CodexCreationReceipt.firstUser(in: try encoded(rows), threadID: thread, cwd: cwd, text: prompt)
    }

    func testNativeReceiptUsesFirstHumanMessageAndFullBody() throws {
        let result = try XCTUnwrap(match(rows()))
        XCTAssertEqual(result.message, "native-user-item")
        XCTAssertEqual(result.turn, turn)
        XCTAssertNotNil(try match(rows(body: prompt)))
        XCTAssertNil(try match(rows(body: prompt + "other text")))
        XCTAssertNil(try match(rows(body: String(prompt.prefix(10)))))
        XCTAssertNil(try match(rows(body: prompt + "\n\n")))
        var serialized = rows()
        var payload = serialized[3]["payload"] as! [String: Any]
        payload["internal_chat_message_metadata_passthrough"] = String(
            decoding: try JSONSerialization.data(
                withJSONObject:
                    payload["internal_chat_message_metadata_passthrough"]!), as: UTF8.self)
        serialized[3]["payload"] = payload
        XCTAssertNotNil(try match(serialized))
    }

    func testContextOrLaterUserMessageCannotBeMistakenForInitialSubmission() throws {
        var values = rows(body: "unrelated first message")
        values.append(rows().last!)
        XCTAssertNil(try match(values))
        XCTAssertNil(try match(Array(rows().dropLast())))
        let metadata = rows()[0]["payload"] as! [String: Any]
        for (key, value) in [
            ("id", UUID().uuidString), ("cwd", "/other"), ("source", "cli"), ("originator", "other-app"),
        ] {
            var changed = rows()
            var invalid = metadata
            invalid[key] = value
            changed[0]["payload"] = invalid
            XCTAssertNil(try match(changed))
        }
    }

    func testUnknownMessageSchemaOrIdentityNeverConfirmsCreation() throws {
        for change in ["missing-id", "missing-metadata", "wrong-turn", "attachment", "two-parts"] {
            var values = rows()
            var user = values[3]["payload"] as! [String: Any]
            switch change {
            case "missing-id": user["id"] = ""
            case "missing-metadata": user.removeValue(forKey: "internal_chat_message_metadata_passthrough")
            case "wrong-turn":
                user["internal_chat_message_metadata_passthrough"] = [
                    "turn_id": UUID().uuidString, "content_item_kinds": ["user.text"],
                ]
            case "attachment":
                user["internal_chat_message_metadata_passthrough"] = [
                    "turn_id": turn, "content_item_kinds": ["user.image", "user.text"],
                ]
            default:
                user["content"] = [["type": "input_text", "text": prompt], ["type": "input_text", "text": "extra"]]
            }
            values[3]["payload"] = user
            XCTAssertNil(try match(values), change)
        }
        let bytes = try encoded(rows())
        XCTAssertNil(CodexCreationReceipt.firstUser(in: bytes.dropLast(), threadID: thread, cwd: cwd, text: prompt))
        XCTAssertNil(
            CodexCreationReceipt.firstUser(
                in: Data("not json\n".utf8) + bytes, threadID: thread, cwd: cwd, text: prompt))
    }

    func testFlowWaitsForVerifiedComposerAndSubmitsExactlyOnce() throws {
        var opened = 0
        var prepared = 0
        var submitted = 0
        var reads = 0
        let receipt = CodexCreationReceipt(
            threadID: thread, title: "Fixture", cwd: cwd, messageID: "native", turnID: turn)
        let result = try CodexCreationFlow.run(
            open: { opened += 1 },
            prepare: {
                prepared += 1
                return prepared < 3 ? nil : { submitted += 1 }
            },
            receipt: {
                reads += 1
                return reads < 4 ? nil : receipt
            }, wait: {}, attempts: 10)
        XCTAssertEqual(result, receipt)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(prepared, 3)
        XCTAssertEqual(submitted, 1)
    }

    func testFlowNeverConfirmsBeforeSubmitOrRetriesAfterUncertainAction() throws {
        var reads = 0
        var submits = 0
        XCTAssertThrowsError(
            try CodexCreationFlow.run(
                open: {}, prepare: { nil },
                receipt: {
                    reads += 1
                    return nil
                }, wait: {}, attempts: 3)
        ) { XCTAssertTrue($0 is UnconfirmedDesktopMutation) }
        XCTAssertEqual(reads, 0)
        XCTAssertThrowsError(
            try CodexCreationFlow.run(
                open: {},
                prepare: {
                    {
                        submits += 1
                        throw CLIError("synthetic native timeout")
                    }
                },
                receipt: {
                    reads += 1
                    return nil
                }, wait: {}, attempts: 3)
        ) { XCTAssertTrue($0 is UnconfirmedDesktopMutation) }
        XCTAssertEqual(submits, 1)
        XCTAssertEqual(reads, 0)
        submits = 0
        XCTAssertThrowsError(
            try CodexCreationFlow.run(
                open: {}, prepare: { { submits += 1 } }, receipt: { nil },
                wait: {}, attempts: 8)
        ) { XCTAssertTrue($0 is UnconfirmedDesktopMutation) }
        XCTAssertEqual(submits, 1)
    }

    func testSlowComposerInspectionCannotSubmitAfterTheDeadline() {
        var now = 0.0
        var submitted = 0
        XCTAssertThrowsError(
            try CodexCreationFlow.run(
                open: {},
                prepare: {
                    now = 21
                    return { submitted += 1 }
                }, receipt: { nil }, wait: {}, clock: { now })
        ) { XCTAssertTrue($0 is UnconfirmedDesktopMutation) }
        XCTAssertEqual(submitted, 0)
    }

    func testComposerEvidenceMustMatchEntireDraftProjectAndUniqueControls() {
        typealias Evidence = CodexNewComposer.Evidence
        for labels in [("Change project: Project", "Send"), ("切换项目：Project", "发送")] {
            XCTAssertTrue(
                CodexNewComposer.accepts(
                    Evidence(
                        draft: prompt, projectLabels: [labels.0], sendLabels: [labels.1],
                        editableCount: 1, frontmost: true, focused: true), text: prompt, projectName: "Project"))
        }
        for evidence in [
            Evidence(
                draft: prompt + " edited", projectLabels: ["Change project: Project"], sendLabels: ["Send"],
                editableCount: 1, frontmost: true, focused: true),
            Evidence(
                draft: prompt, projectLabels: ["Change project: Other"], sendLabels: ["Send"], editableCount: 1,
                frontmost: true, focused: true),
            Evidence(
                draft: prompt, projectLabels: ["Change project: Project"], sendLabels: ["Send", "Send"],
                editableCount: 1, frontmost: true, focused: true),
            Evidence(
                draft: prompt, projectLabels: ["Change project: Project"], sendLabels: ["Send"], editableCount: 2,
                frontmost: true, focused: true),
            Evidence(
                draft: prompt, projectLabels: ["Change project: Project"], sendLabels: ["Send"], editableCount: 1,
                frontmost: false, focused: true),
            Evidence(
                draft: prompt, projectLabels: ["Change project: Project"], sendLabels: ["Send"], editableCount: 1,
                frontmost: true, focused: false),
        ] { XCTAssertFalse(CodexNewComposer.accepts(evidence, text: prompt, projectName: "Project")) }
        var worktree = Evidence(
            draft: prompt, projectLabels: ["Change project: Project"], sendLabels: ["Send"],
            editableCount: 1, frontmost: true, focused: true)
        worktree.alternateExecution = true
        XCTAssertFalse(CodexNewComposer.accepts(worktree, text: prompt, projectName: "Project"))
    }

    func testDeepLinkBindsNativeProjectAndCodexModeAndPreservesPlus() throws {
        let url = try CodexCreationFlow.url(
            project: CodexCreationProject(id: project, name: "Project", cwd: cwd), text: prompt)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(values, ["path": cwd, "projectId": project, "mode": "codex", "prompt": prompt])
        XCTAssertTrue(url.absoluteString.contains("C%2B%2B"))
    }

    func testIndexSnapshotIgnoresOldCLIAndForeignThreadsAndRefusesAmbiguity() throws {
        let fixture = try Index()
        let store = CodexThreadStore(path: fixture.path.path)
        try fixture.insertThread(id: thread, cwd: cwd, text: prompt, created: 100, rollout: "")
        let snapshot = try store.creationSnapshot(cwd: cwd, since: 100)
        XCTAssertNil(try store.created(snapshot: snapshot, text: prompt))
        let fresh = UUID().uuidString
        let rollout = fixture.directory.appendingPathComponent("fresh.jsonl")
        try encoded(rows(id: fresh)).write(to: rollout)
        try fixture.insertThread(id: fresh, cwd: cwd, text: prompt, created: 101, rollout: rollout.path, source: "cli")
        XCTAssertNil(try store.created(snapshot: snapshot, text: prompt))
        try fixture.sql("UPDATE threads SET source='vscode',originator='other' WHERE id=?", [fresh])
        XCTAssertNil(try store.created(snapshot: snapshot, text: prompt))
        try fixture.sql("UPDATE threads SET originator='Codex Desktop' WHERE id=?", [fresh])
        XCTAssertEqual(try store.created(snapshot: snapshot, text: prompt)?.threadID, fresh)
        // All real observed has_user_event values are zero; native message metadata confirms the receipt instead.
        let concurrent = UUID().uuidString
        try fixture.insertThread(id: concurrent, cwd: cwd, text: prompt, created: 102, rollout: "/missing")
        XCTAssertNil(try store.created(snapshot: snapshot, text: prompt))
        try fixture.sql("UPDATE threads SET archived=1 WHERE id=?", [concurrent])
        XCTAssertNil(
            try store.created(snapshot: snapshot, text: prompt),
            "Archiving one candidate does not prove which was submitted")
    }

    func testProjectIdentityRejectsDuplicateNamesOrMultipleRoots() throws {
        let fixture = try Index()
        let store = CodexThreadStore(path: fixture.path.path)
        try fixture.sql("INSERT INTO projects VALUES (?,?)", [project, "Project"])
        try fixture.sql("INSERT INTO project_roots VALUES (?,?)", [project, cwd])
        XCTAssertEqual(
            try store.creationProject(cwd: cwd), CodexCreationProject(id: project, name: "Project", cwd: cwd))
        try fixture.sql("INSERT INTO projects VALUES (?,?)", [UUID().uuidString, "Project"])
        XCTAssertThrowsError(try store.creationProject(cwd: cwd))
        try fixture.sql("DELETE FROM projects WHERE id!=?", [project])
        for names in [("Café", "Cafe\u{301}"), ("Project Team", "Project  Team")] {
            try fixture.sql("UPDATE projects SET name=? WHERE id=?", [names.0, project])
            try fixture.sql("INSERT INTO projects VALUES (?,?)", [UUID().uuidString, names.1])
            XCTAssertThrowsError(try store.creationProject(cwd: cwd), "Equivalent accessible names are ambiguous")
            try fixture.sql("DELETE FROM projects WHERE id!=?", [project])
        }
        try fixture.sql("INSERT INTO project_roots VALUES (?,?)", [project, "/other"])
        XCTAssertThrowsError(try store.creationProject(cwd: cwd))
    }

    func testMovingAnExistingThreadCannotTurnItIntoACreationReceipt() throws {
        let fixture = try Index()
        let store = CodexThreadStore(path: fixture.path.path)
        let rollout = fixture.directory.appendingPathComponent("old.jsonl")
        try encoded(rows()).write(to: rollout)
        try fixture.insertThread(id: thread, cwd: "/other", text: prompt, created: 99, rollout: rollout.path)
        let snapshot = try store.creationSnapshot(cwd: cwd, since: 100)
        try fixture.sql("UPDATE threads SET cwd=?,created_at_ms=101 WHERE id=?", [cwd, thread])
        XCTAssertNil(try store.created(snapshot: snapshot, text: prompt))
    }

    private final class Index {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-create-" + UUID().uuidString)
        var path: URL { directory.appendingPathComponent("state.sqlite") }
        private var db: OpaquePointer?
        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw CLIError("fixture database") }
            try sql(
                "CREATE TABLE threads (id TEXT,name TEXT,title TEXT,cwd TEXT,created_at_ms INTEGER,first_user_message TEXT,rollout_path TEXT,source TEXT,originator TEXT,agent_path TEXT,archived INTEGER,has_user_event INTEGER)"
            )
            try sql("CREATE TABLE projects (id TEXT,name TEXT)")
            try sql("CREATE TABLE project_roots (project_id TEXT,path TEXT)")
        }
        deinit {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: directory)
        }
        func sql(_ text: String, _ values: [String] = []) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, text, -1, &statement, nil) == SQLITE_OK else { throw CLIError("fixture SQL") }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() {
                sqlite3_bind_text(
                    statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CLIError("fixture step") }
        }
        func insertThread(
            id: String, cwd: String, text: String, created: Int, rollout: String, source: String = "vscode"
        ) throws {
            try sql(
                "INSERT INTO threads VALUES (?,'','Fixture',?,?,?,?,?,'Codex Desktop',NULL,0,0)",
                [id, cwd, String(created), text, rollout, source])
        }
    }
}
