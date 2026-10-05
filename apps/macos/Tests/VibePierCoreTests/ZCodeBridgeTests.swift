import Foundation
import ImageIO
import SQLite3
import XCTest

@testable import VibePierCore

final class ZCodeBridgeTests: XCTestCase {
    func testProviderFailureWithoutVisiblePartsProducesFailedReplyWithoutRawDiagnostics() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try execute(
            fixture.database,
            "UPDATE message SET data='{\"role\":\"assistant\",\"error\":{\"name\":\"AiSdkModelAdapterError\",\"data\":{\"message\":\"private diagnostic\",\"attribution\":{\"providerErrorCode\":\"1113\"}}}}' WHERE id='msg_a_5'"
        )
        try execute(fixture.database, "DELETE FROM part WHERE message_id='msg_a_5'")
        let store = ZCodeSessionStore(path: fixture.database, indexPath: nil)
        let turn = try XCTUnwrap(store.window("sess_native", count: 1).turns.last)
        XCTAssertEqual(turn.latest["providerErrorCode"] as? String, "1113")
        let reply = try XCTUnwrap(ZCodeConversation.reply(turn))
        XCTAssertEqual(reply["status"] as? String, "failed")
        XCTAssertTrue((reply["text"] as? String ?? "").contains("1113"))
        XCTAssertFalse(
            String(decoding: try JSONSerialization.data(withJSONObject: turn.latest), as: UTF8.self).contains(
                "private diagnostic"))
        XCTAssertFalse(
            String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self).contains(
                "private diagnostic"))
    }

    func testVerifiedMessageAnchorMatchesNativeActiveTurnAndPreservesUncertainty() {
        let accepted: [String: Any] = ["accepted": true, "sessionId": "sess_fixture", "nativeMessageId": "msg_fixture"]
        let result = ZCodeBridge.withMessageAnchor(accepted)
        XCTAssertEqual(result["threadId"] as? String, "sess_fixture")
        XCTAssertEqual(result["turnId"] as? String, "msg_fixture")
        XCTAssertEqual(result["turnIdentityKind"] as? String, "nativeMessageAnchor")
        for patch: [String: Any] in [["unknown": true], ["accepted": false], ["ok": false], ["nativeMessageId": ""]] {
            XCTAssertNil(ZCodeBridge.withMessageAnchor(accepted.merging(patch) { $1 })["turnId"])
        }
        for patch: [String: Any] in [
            ["threadId": "other"], ["messageId": "other"], ["turnId": "other"], ["nativeTurnId": "other"],
        ] {
            XCTAssertEqual(ZCodeBridge.withMessageAnchor(accepted.merging(patch) { $1 })["unknown"] as? Bool, true)
        }
    }

    func testCreationReadDiagnosticsKeepOnlyReadinessFailureAndClearItOnSuccess() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let reply = Value()
        reply.value = ["ok": false, "error": "Synthetic native menu is not ready"]
        let bridge = ZCodeBridge(
            store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
            desktop: .init(snapshot: { _ in ["capabilities": ["new": true]] }, execute: { _, _, _, _ in reply.value }))
        defer { bridge.stopAll() }
        let client = UUID().uuidString
        let read: [String: Any] = [
            "op": "newOptions", "draftId": UUID().uuidString, "cwd": "/fixture", "text": "private draft",
        ]
        _ = try request(bridge, read, client: client)
        var row = try XCTUnwrap(ZCodeBridge.recentCreationReads().last { $0["client"] as? String == client })
        XCTAssertEqual(row["reason"] as? String, "Synthetic native menu is not ready")
        XCTAssertEqual(Set(row.keys), ["client", "ok", "reason"])
        XCTAssertFalse(String(describing: row).contains("private draft"))
        reply.value = ["ok": true, "creationVersion": 1]
        _ = try request(bridge, read, client: client)
        row = try XCTUnwrap(ZCodeBridge.recentCreationReads().last { $0["client"] as? String == client })
        XCTAssertEqual(row["ok"] as? Bool, true)
        XCTAssertNil(row["reason"])
    }

    func testExecutionCatalogSurvivesPageAndComposerOptionsProjection() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let native = Value()
        native.value = [
            "capabilities": ["send": true, "settings": true, "executionMode": true],
            "canSend": true, "executionModes": ZCodeDesktop.executionOptions(mode: "build"),
            "executionModePermissionCoupled": true, "composer": ["mode": "build", "executionMode": "default"],
        ]
        let bridge = ZCodeBridge(
            store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
            desktop: .init(snapshot: { _ in native.value }, execute: { _, _, _, _ in native.value }))
        defer { bridge.stopAll() }
        for op in ["open", "composerOptions"] {
            let page = try request(bridge, ["op": op, "threadId": "sess_native", "viewVersion": 1])
            XCTAssertEqual((page["executionModes"] as? [[String: Any]])?.count, 2)
            XCTAssertEqual(page["executionModePermissionCoupled"] as? Bool, true)
            XCTAssertEqual((page["capabilities"] as? [String: Bool])?["executionMode"], true)
        }
    }
    func testVerifiedDesktopOwnerEpochIsProjectedAndUnsupportedQueueIsExplicitlyEmpty() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let epoch = UUID().uuidString.lowercased()
        let bridge = ZCodeBridge(
            store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
            desktop: .init(
                snapshot: { _ in ["nativeOwnerEpoch": epoch, "capabilities": ["send": true], "canSend": true] },
                execute: { _, _, _, _ in [:] }))
        defer { bridge.stopAll() }
        let page = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
        XCTAssertEqual(page["nativeOwnerEpoch"] as? String, epoch)
        XCTAssertEqual((page["queuedMessages"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((page["capabilities"] as? [String: Bool])?["queue"], false)
    }

    func testMissingOrMalformedDesktopProofIsNeverSynthesizedFromNativeSessionIdentity() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for proof: Any? in [nil, "", 17] {
            let observed = Value()
            observed.value = ["capabilities": ["send": true], "canSend": true]
            observed.value["nativeOwnerEpoch"] = proof
            let bridge = ZCodeBridge(
                store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
                desktop: .init(
                    snapshot: { _ in observed.value }, execute: { _, _, _, _ in [:] }))
            let page = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
            XCTAssertNil(page["nativeOwnerEpoch"])
            XCTAssertNil(page["owner"])
            bridge.stopAll()
        }
    }

    func testOnlyInternalControlPreparationInvokesTheVerifiedOwnerRead() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seen = Value()
        let epoch = UUID().uuidString.lowercased()
        let bridge = ZCodeBridge(
            store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
            desktop: .init(
                snapshot: { _ in ["capabilities": ["send": true], "canSend": true] },
                execute: { _, _, _, _ in
                    XCTFail("Read preparation must not submit a native effect")
                    return [:]
                },
                prepareSnapshot: { session in
                    seen.value = ["session": session]
                    return ["nativeOwnerEpoch": epoch, "capabilities": ["send": true], "canSend": true]
                }))
        defer { bridge.stopAll() }
        let ordinary = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
        XCTAssertNil(ordinary["nativeOwnerEpoch"])
        XCTAssertTrue(seen.value.isEmpty)
        let prepared = try request(
            bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1, "verifyNativeOwner": true])
        XCTAssertEqual(prepared["nativeOwnerEpoch"] as? String, epoch)
        XCTAssertEqual(seen.value["session"] as? String, "sess_native")
    }

    func testNewOptionsAreBoundToTrustedPhoneAndValidDraftBeforeNativeDispatch() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seen = Value()
        let bridge = ZCodeBridge(
            store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
            desktop: .init(
                snapshot: { _ in ["capabilities": ["new": true]] },
                execute: { request, session, cwd, client in
                    seen.value = [
                        "draftId": request["draftId"] ?? "", "session": session, "cwd": cwd, "client": client,
                    ]
                    return ["creationVersion": 1, "models": [], "permissionModes": []]
                }))
        let draft = UUID().uuidString
        let result = try request(
            bridge, ["op": "newOptions", "draftId": draft, "cwd": "/fixture/project", "client": "forged"],
            client: "trusted-phone")
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(seen.value["client"] as? String, "trusted-phone")
        XCTAssertEqual(seen.value["session"] as? String, "", "No fabricated native thread may be used")
        XCTAssertEqual(seen.value["draftId"] as? String, draft)
        seen.value = [:]
        XCTAssertEqual(
            try request(bridge, ["op": "newOptions", "draftId": "invalid", "cwd": "/fixture/project"])["ok"] as? Bool,
            false)
        XCTAssertTrue(seen.value.isEmpty)
    }
    func testBlockedNativeAdapterExpiresQueuedSendButKeepsCachedReceiptAndOtherBridgeResponsive() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let blocked = expectation(description: "Synthetic native operation blocked")
        let originalDone = expectation(description: "Original operation finishes once")
        let observed = Value()
        let bridge = ZCodeBridge(
            store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
            desktop: .init(
                snapshot: { _ in ["capabilities": ["new": true]] },
                execute: { value, _, _, _ in
                    let id = value["id"] as? String ?? ""
                    var calls = observed.value
                    calls[id] = true
                    observed.value = calls
                    if id == "blocked" {
                        blocked.fulfill()
                        gate.wait()
                    }
                    return ["accepted": true, "threadId": "created-" + id, "cwd": "/fixture/project"]
                }))
        func creation(_ id: String) -> [String: Any] {
            ["op": "new", "id": id, "cwd": "/fixture/project", "text": "Synthetic test only"]
        }
        XCTAssertEqual(try request(bridge, creation("complete"))["accepted"] as? Bool, true)
        bridge.perform(try JSONSerialization.data(withJSONObject: creation("blocked")), client: "phone-a") { data in
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            XCTAssertEqual(value?["accepted"] as? Bool, true)
            originalDone.fulfill()
        }
        wait(for: [blocked], timeout: 2)
        XCTAssertEqual(try request(bridge, creation("blocked"))["unknown"] as? Bool, true)
        // Actual provider entry point: completed receipts never join the blocked state queue.
        XCTAssertEqual(
            try request(
                bridge,
                [
                    "op": "newReceiptCheck", "operation": "complete", "threadId": "",
                ])["threadId"] as? String, "created-complete")
        let independent = ZCodeBridge(store: ZCodeSessionStore(path: fixture.database, indexPath: nil))
        XCTAssertEqual(try request(independent, ["op": "list"])["ok"] as? Bool, true)
        let expired = expectation(description: "Queued mutation rejected before execution")
        bridge.perform(try JSONSerialization.data(withJSONObject: creation("expired")), client: "phone-b") { data in
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            XCTAssertEqual(value?["ok"] as? Bool, false)
            XCTAssertEqual(value?["retryable"] as? Bool, true)
            expired.fulfill()
        }
        wait(for: [expired], timeout: 9)
        gate.signal()
        wait(for: [originalDone], timeout: 2)
        XCTAssertEqual(try request(bridge, ["op": "list"])["ok"] as? Bool, true)
        XCTAssertNil(observed.value["expired"], "A timed-out queued send must never execute later")
        XCTAssertEqual(observed.value.count, 2)
    }

    private final class Value: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: Any] = [:]
        var value: [String: Any] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
    private struct Fixture {
        let directory: URL
        let database: String
        let index: String
    }

    func testTwoPhoneCreationRetriesAndLateLookupsNeverSubmitAgain() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = Value()
        let bridge = ZCodeBridge(
            store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
            desktop: .init(
                snapshot: { _ in ["capabilities": ["new": true]] },
                execute: { request, _, _, client in
                    if request["op"] as? String == "receiptCheck" {
                        return [
                            "accepted": true, "threadId": "created-" + client, "cwd": "/fixture/project",
                            "nativeMessageId": "message",
                        ]
                    }
                    var value = state.value
                    value[client] = (value[client] as? Int ?? 0) + 1
                    state.value = value
                    return ["unknown": true]
                }))
        defer { bridge.stopAll() }
        let intent: [String: Any] = ["op": "new", "id": "same-operation", "cwd": "/fixture/project", "text": "hello"]
        for client in ["phone-a", "phone-b"] {
            for _ in 0..<2 {
                XCTAssertEqual(try request(bridge, intent, client: client)["unknown"] as? Bool, true)
            }
            XCTAssertEqual(state.value[client] as? Int, 1)
            let lookedUp = try request(
                bridge,
                ["op": "newReceiptCheck", "operation": "same-operation", "threadId": "", "cwd": "/fixture/project"],
                client: client)
            XCTAssertEqual(lookedUp["threadId"] as? String, "created-" + client)
            XCTAssertEqual(try request(bridge, intent, client: client)["threadId"] as? String, "created-" + client)
            XCTAssertEqual(state.value[client] as? Int, 1)
        }
        var changed = intent
        changed["text"] = "different"
        XCTAssertEqual(try request(bridge, changed)["ok"] as? Bool, false)
        XCTAssertEqual(state.value["phone-a"] as? Int, 1)
    }

    func testDesktopReceivesTrustedClientAndReceiptKeysCannotCollideAcrossPhonesOrComponents() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let observed = Value()
        let bridge = ZCodeBridge(
            store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
            desktop: .init(
                snapshot: { _ in ["capabilities": ["new": true]] },
                execute: { _, _, _, client in
                    observed.value = ["client": client]
                    return ["unknown": true]
                }))
        defer { bridge.stopAll() }
        for client in ["phone-a", "phone-b"] {
            _ = try request(
                bridge, ["op": "new", "id": "same-operation", "cwd": "/fixture/project", "client": "forged-client"],
                client: client)
            XCTAssertEqual(observed.value["client"] as? String, client)
        }
        XCTAssertNotEqual(
            ZCodeDesktop.receiptKey(client: "a", session: "s", operation: "id"),
            ZCodeDesktop.receiptKey(client: "b", session: "s", operation: "id"))
        XCTAssertNotEqual(
            ZCodeDesktop.receiptKey(client: "a:b", session: "c", operation: "d"),
            ZCodeDesktop.receiptKey(client: "a", session: "b:c", operation: "d"))
    }

    func testCreationBaselineIncludesOtherProjectsArchivedAndSubagentTasksAndRefusesTruncation() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try execute(
            fixture.database, "INSERT INTO session VALUES('old_other','Old','/other',1000,1000,'subagent_child')")
        let store = ZCodeSessionStore(path: fixture.database, indexPath: nil)
        let baseline = try store.existingSessionIDs()
        XCTAssertEqual(baseline, ["sess_native", "old_other"])
        try execute(
            fixture.database, "UPDATE session SET directory='/fixture/project',time_archived=NULL WHERE id='old_other'")
        XCTAssertTrue(baseline.contains("old_other"), "Moving an old task never makes a new identity")
        XCTAssertThrowsError(try store.existingSessionIDs(limit: 1))
    }

    func testNativeReceiptSelectsFirstOrImmediateNextHumanNotLaterMatchingText() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = ZCodeSessionStore(path: fixture.database, indexPath: nil)
        XCTAssertEqual(try store.nativeUser("sess_native")?.text, "问题5")
        let first = try XCTUnwrap(store.nativeUser("sess_native", first: true))
        XCTAssertEqual(first.id, "msg_u_1")
        XCTAssertFalse(ZCodeDesktop.confirmation(before: nil, userID: first.id, observed: first.text, expected: "问题5"))
        let next = try XCTUnwrap(store.nativeUser("sess_native", first: true, after: "msg_u_2"))
        XCTAssertEqual(next.id, "msg_u_3")
        XCTAssertFalse(
            ZCodeDesktop.confirmation(before: "msg_u_2", userID: next.id, observed: next.text, expected: "问题5"))
        XCTAssertNil(try store.nativeUser("sess_native", first: true, after: "missing-anchor"))
        try execute(
            fixture.database, "INSERT INTO message VALUES('context','sess_native',0,1,?)",
            [try json(["role": "user", "semantics": ["kind": "context"]])])
        XCTAssertEqual(try store.nativeUser("sess_native", first: true)?.id, "msg_u_1")
        try execute(
            fixture.database, "INSERT INTO message VALUES('duplicate-order','sess_native',10,1,?)",
            [try json(["role": "user"])])
        XCTAssertNil(try store.nativeUser("sess_native", first: true), "Ambiguous human order cannot confirm")
    }

    func testNativeReceiptKeepsCompleteTextIncludingNulAndRejectsOversizedBody() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = ZCodeSessionStore(path: fixture.database, indexPath: nil)
        let full = "prefix\0" + String(repeating: "完整", count: 8000)
        try execute(
            fixture.database, "UPDATE part SET data=? WHERE id='prt_user_1'",
            [try json(["type": "text", "text": full])])
        let observed = try store.nativeUser("sess_native", first: true)?.text
        XCTAssertEqual(observed?.utf8.count, full.utf8.count)
        XCTAssertTrue(observed == full, "Native text must preserve the complete body across embedded NUL")
        let oversized = String(repeating: "x", count: 120_001)
        try execute(
            fixture.database, "UPDATE part SET data=? WHERE id='prt_user_1'",
            [try json(["type": "text", "text": oversized])])
        XCTAssertNil(try store.nativeUser("sess_native", first: true))
    }

    func testNativeReceiptBoundsTextPartCountAndAggregateBytes() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = ZCodeSessionStore(path: fixture.database, indexPath: nil)
        for index in 1...64 {
            try execute(
                fixture.database, "INSERT INTO part VALUES(?,?,?,?,?,?)",
                ["extra_\(index)", "msg_u_1", "sess_native", index, 1, try json(["type": "text", "text": "x"])])
        }
        XCTAssertNil(try store.nativeUser("sess_native", first: true))
        try execute(fixture.database, "DELETE FROM part WHERE id LIKE 'extra_%'")
        let part = try json(["type": "text", "text": String(repeating: "x", count: 70_000)])
        try execute(fixture.database, "UPDATE part SET data=? WHERE id='prt_user_1'", [part])
        try execute(fixture.database, "INSERT INTO part VALUES('second','msg_u_1','sess_native',1,1,?)", [part])
        XCTAssertNil(try store.nativeUser("sess_native", first: true))
    }
    private func execute(_ path: String, _ sql: String, _ values: [Any] = []) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CLIError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            if let text = value as? String {
                sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            } else if let number = value as? Int {
                sqlite3_bind_int64(statement, Int32(index + 1), Int64(number))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CLIError(String(cString: sqlite3_errmsg(db))) }
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func image() throws -> String {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (png as Data).base64EncodedString()
    }
    private func fixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zcode-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = Fixture(
            directory: dir, database: dir.appendingPathComponent("db.sqlite").path,
            index: dir.appendingPathComponent("tasks.sqlite").path)
        try execute(
            fixture.database,
            "CREATE TABLE session(id TEXT PRIMARY KEY,title TEXT,directory TEXT,time_updated INTEGER,time_archived INTEGER,task_type TEXT)"
        )
        try execute(
            fixture.database,
            "CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,sequence INTEGER,time_updated INTEGER,data TEXT)")
        try execute(
            fixture.database,
            "CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,session_id TEXT,sequence INTEGER,time_updated INTEGER,data TEXT)"
        )
        try execute(
            fixture.database, "INSERT INTO session VALUES('sess_native','原生会话','/fixture/project',5000,NULL,NULL)")
        for number in 1...5 {
            let user = "msg_u_\(number)"
            let assistant = "msg_a_\(number)"
            try execute(
                fixture.database, "INSERT INTO message VALUES(?,?,?,?,?)",
                [
                    user, "sess_native", number * 10, 5000,
                    try json([
                        "role": "user", "semantics": ["kind": "user_prompt", "uiVisibility": "visible"],
                        "modelSelection": ["modelId": "GLM-fixture"],
                    ]),
                ])
            try execute(
                fixture.database, "INSERT INTO part VALUES(?,?,?,?,?,?)",
                [
                    "prt_user_\(number)", user, "sess_native", 0, 5000,
                    try json(["type": "text", "text": "问题\(number)"]),
                ])
            try execute(
                fixture.database, "INSERT INTO message VALUES(?,?,?,?,?)",
                [
                    assistant, "sess_native", number * 10 + 1, 5000,
                    try json(["role": "assistant", "modelId": "GLM-fixture", "time": ["completed": 5000]]),
                ])
            let count = number == 5 ? 12 : 1
            for index in 0..<count {
                let part: [String: Any]
                if index == 0 || index == 2 || index == 11 {
                    part = ["type": "text", "text": "答复\(number)-\(index)"]
                } else if index == 3 {
                    part = [
                        "type": "tool", "tool": "Edit",
                        "state": [
                            "status": "completed",
                            "input": ["file_path": "/fixture/a.swift", "old_string": "old", "new_string": "new"],
                            "metadata": [
                                "display": [
                                    "kind": "file_diff", "filePath": "/fixture/a.swift", "additions": 1, "deletions": 1,
                                    "images": String(repeating: "HUGE_IMAGE_BODY", count: 30000),
                                    "structuredPatch": [
                                        [
                                            "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                                            "lines": ["-old", "+new"],
                                        ]
                                    ],
                                ]
                            ],
                        ],
                    ]
                } else if index == 10 {
                    let png = try image()
                    part = [
                        "type": "tool", "tool": "mcp__node_repl__js",
                        "state": [
                            "status": "completed", "input": ["code": "draw()"],
                            "metadata": [
                                "display": [
                                    "kind": "node_repl_images", "images": [["mimeType": "image/png", "base64": png]],
                                    "media": [
                                        ["mimeType": "image/png", "data": png],
                                        ["mimeType": "audio/wav", "data": "ignore"],
                                    ],
                                ]
                            ],
                        ],
                    ]
                } else {
                    part = [
                        "type": "tool", "tool": "Bash",
                        "state": [
                            "status": "completed", "input": ["command": "printf step-\(index)", "description": "测试命令"],
                            "output": String(repeating: "OUTPUT_BODY_", count: 3000),
                        ],
                    ]
                }
                try execute(
                    fixture.database, "INSERT INTO part VALUES(?,?,?,?,?,?)",
                    ["prt_\(number)_\(index)", assistant, "sess_native", index, 5000, try json(part)])
            }
        }
        return fixture
    }
    func testUserArtifactImageResolvesThroughSelectedNativeSession() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cli = fixture.directory.appendingPathComponent("cli")
        let database = cli.appendingPathComponent("db/db.sqlite")
        let folder = cli.appendingPathComponent("artifacts/sess_native")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: fixture.database, toPath: database.path)
        let artifact = "tool-result-12345678-1234-1234-1234-123456789abc"
        let uri = "zcode-artifact://sess_native/" + artifact
        let dataURL = "data:image/png;base64," + (try image())
        try dataURL.write(
            to: folder.appendingPathComponent("prompt-attachment-upload-opaque-\(artifact).txt"),
            atomically: true, encoding: .utf8)
        try execute(
            database.path, "INSERT INTO part VALUES(?,?,?,?,?,?)",
            [
                "prt_user_image", "msg_u_5", "sess_native", 1, 5001,
                try json(["type": "file", "mime": "image/png", "url": uri, "metadata": ["artifactUri": uri]]),
            ])
        let bridge = ZCodeBridge(store: ZCodeSessionStore(path: database.path, indexPath: nil))
        let page = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
        let rows = try XCTUnwrap(page["messages"] as? [[String: Any]])
        let images = try XCTUnwrap(rows[0]["images"] as? [[String: Any]])
        XCTAssertEqual(images.first?["id"] as? String, "msg_u_5#0")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self).contains(uri))
        for size in ["thumb", "large"] {
            let photo = try request(
                bridge,
                [
                    "op": "image", "threadId": "sess_native", "viewVersion": 1,
                    "imageId": "msg_u_5#0", "size": size,
                ])
            XCTAssertEqual(photo["ok"] as? Bool, true)
            XCTAssertEqual(
                Array(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(photo["image"] as? String))).prefix(2)),
                [0xff, 0xd8])
        }
    }

    private func request(_ bridge: ZCodeBridge, _ source: [String: Any], client: String = "phone-a") throws -> [String:
        Any]
    {
        let value = Value()
        let done = expectation(description: "zcode reply")
        bridge.perform(try JSONSerialization.data(withJSONObject: source), client: client) { data in
            value.value = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        return value.value
    }

    func testSubmissionBoundaryFailureKeepsUnknownIndependentOfDiagnosticLanguage() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for diagnostic in ["Native acknowledgement lost", "原生回执丢失", "{0} 100%"] {
            let bridge = ZCodeBridge(
                store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
                desktop: .init(
                    snapshot: { _ in ["capabilities": ["send": true], "canSend": true] },
                    execute: { _, _, _, _ in
                        try UnconfirmedDesktopMutation.attempting { throw CLIError(diagnostic) }
                        return [:]
                    }))
            _ = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
            let result = try request(
                bridge,
                [
                    "op": "send", "id": UUID().uuidString, "threadId": "sess_native", "viewVersion": 1,
                    "text": "synthetic message",
                ])
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(result["unknown"] as? Bool, true)
            XCTAssertNotEqual(result["accepted"] as? Bool, true)
            XCTAssertTrue((result["error"] as? String)?.contains(diagnostic) == true)
            bridge.stopAll()
        }
    }

    func testPreflightErrorDoesNotInferReceiptStateFromItsWording() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bridge = ZCodeBridge(
            store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
            desktop: .init(
                snapshot: { _ in ["capabilities": ["send": true], "canSend": true] },
                execute: { _, _, _, _ in
                    throw CLIError("synthetic preflight failure: 发送结果未确认")
                }))
        _ = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
        let result = try request(
            bridge,
            [
                "op": "send", "id": "preflight-only", "threadId": "sess_native", "viewVersion": 1,
                "text": "synthetic message",
            ])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertNil(result["unknown"])
        bridge.stopAll()
    }

    func testDesktopRepliesBindVerifiedSessionAndRejectConflictingNativeIdentity() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for identity in ["", "sess_native", "sess_other"] {
            let bridge = ZCodeBridge(
                store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
                desktop: .init(
                    snapshot: { _ in ["capabilities": ["settings": true]] },
                    execute: { _, _, _, _ in
                        var reply: [String: Any] = ["accepted": true, "applied": true]
                        if !identity.isEmpty { reply["sessionId"] = identity }
                        return reply
                    }))
            _ = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
            let intent: [String: Any] = [
                "op": "settings", "id": UUID().uuidString, "threadId": "sess_native", "viewVersion": 1,
            ]
            let value = try request(bridge, intent)
            let receipt = SessionProviderReply(
                try JSONSerialization.data(withJSONObject: value), request: .init(intent), mutable: true)
            if identity == "sess_other" {
                XCTAssertEqual(value["ok"] as? Bool, false)
                XCTAssertEqual(value["unknown"] as? Bool, true)
                XCTAssertFalse(receipt.definitive)
            } else {
                XCTAssertEqual(value["threadId"] as? String, "sess_native")
                XCTAssertEqual(value["ok"] as? Bool, true)
                XCTAssertTrue(receipt.definitive)
                let checked = try request(
                    bridge,
                    ["op": "settingsReceiptCheck", "operation": intent["id"]!, "threadId": "sess_native"])
                XCTAssertEqual(checked["threadId"] as? String, "sess_native")
                XCTAssertEqual(checked["accepted"] as? Bool, true)
                let unrelated = try request(
                    bridge,
                    ["op": "settingsReceiptCheck", "operation": "different-operation", "threadId": "sess_native"])
                XCTAssertEqual(unrelated["unknown"] as? Bool, true)
                XCTAssertNotEqual(unrelated["accepted"] as? Bool, true)
            }
            bridge.stopAll()
        }
    }

    func testNativeFirstPageAndLazySequenceAndBodiesAreBounded() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bridge = ZCodeBridge(store: ZCodeSessionStore(path: fixture.database, indexPath: nil))
        let page = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
        XCTAssertEqual(page["provider"] as? String, "zcode")
        XCTAssertEqual(page["threadId"] as? String, "sess_native")
        XCTAssertEqual(page["canSend"] as? Bool, false)
        let rows = try XCTUnwrap(page["messages"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["msg_u_5", "reply-msg_u_5"])
        let sequence = try XCTUnwrap(rows[1]["sequence"] as? [[String: Any]])
        XCTAssertEqual(sequence.count, 8)
        XCTAssertEqual(sequence.first?["index"] as? Int, 4)
        let firstBytes = try JSONSerialization.data(withJSONObject: page)
        XCTAssertLessThan(firstBytes.count, 14_000)
        XCTAssertFalse(String(decoding: firstBytes, as: UTF8.self).contains("OUTPUT_BODY_"))
        XCTAssertFalse(String(decoding: firstBytes, as: UTF8.self).contains("HUGE_IMAGE_BODY"))
        XCTAssertFalse(String(decoding: firstBytes, as: UTF8.self).contains("iVBOR"))
        let toolImages = try XCTUnwrap(
            sequence.first(where: { $0["id"] as? String == "prt_5_10" })?["images"] as? [[String: Any]])
        XCTAssertEqual(toolImages.compactMap { $0["id"] as? String }, ["prt_5_10#0", "prt_5_10#1"])
        let photo = try request(
            bridge, ["op": "image", "threadId": "sess_native", "viewVersion": 1, "imageId": "prt_5_10#1"])
        XCTAssertEqual(
            Array(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(photo["image"] as? String))).prefix(2)), [0xff, 0xd8])
        let earlier = try request(
            bridge,
            [
                "op": "parts", "threadId": "sess_native", "viewVersion": 1, "messageId": "reply-msg_u_5",
                "sequence": true, "offset": 0, "before": 4,
            ])
        let parts = try XCTUnwrap(earlier["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["kind"] as? String }, ["text", "command", "text", "file"])
        XCTAssertEqual(parts.map { $0["id"] as? String }, ["prt_5_0", "prt_5_1", "prt_5_2", "prt_5_3"])
        XCTAssertFalse(try json(earlier).contains("OUTPUT_BODY_"))
        XCTAssertFalse(try json(earlier).contains("HUGE_IMAGE_BODY"))
        let command = try request(
            bridge,
            ["op": "message", "threadId": "sess_native", "viewVersion": 1, "messageId": "prt_5_1", "withPart": true])
        XCTAssertEqual((command["text"] as? String)?.count, 12_000)
        XCTAssertEqual(command["nextOffset"] as? Int, 12_000)
        let edit = try request(
            bridge, ["op": "message", "threadId": "sess_native", "viewVersion": 1, "messageId": "prt_5_3"])
        XCTAssertTrue((edit["text"] as? String ?? "").contains("@@ -1,1 +1,1 @@\n-old\n+new"))
        let history = try request(
            bridge, ["op": "history", "threadId": "sess_native", "viewVersion": 1, "before": "msg_u_5"])
        XCTAssertEqual(
            (history["messages"] as? [[String: Any]])?.filter { $0["role"] as? String == "user" }.map {
                $0["id"] as? String
            }, ["msg_u_2", "msg_u_3", "msg_u_4"])
        XCTAssertEqual(history["hasOlder"] as? Bool, true)
        bridge.stopAll()
    }

    func testMarkdownReadsUseSelectedNativeSessionDirectoryAndKeepAttachmentsDisabled() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = fixture.directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "# ZCode 工作区".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "private".write(
            to: fixture.directory.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        try execute(fixture.database, "UPDATE session SET directory=? WHERE id='sess_native'", [project.path])
        let bridge = ZCodeBridge(store: ZCodeSessionStore(path: fixture.database, indexPath: nil))
        let read: [String: Any] = [
            "op": "readMarkdownFile", "threadId": "sess_native", "viewVersion": 1, "path": "README.md",
            "cwd": fixture.directory.path,
        ]
        XCTAssertEqual(try request(bridge, read)["ok"] as? Bool, false)
        let page = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
        XCTAssertEqual((page["capabilities"] as? [String: Bool])?["markdownFiles"], true)
        XCTAssertEqual((page["capabilities"] as? [String: Bool])?["attachments"], false)
        XCTAssertEqual(try request(bridge, read)["text"] as? String, "# ZCode 工作区")
        var outside = read
        outside["path"] = "../outside.md"
        XCTAssertEqual(try request(bridge, outside)["ok"] as? Bool, false, "client cwd cannot enlarge workspace scope")
        var other = read
        other["threadId"] = "unknown-session"
        XCTAssertEqual(try request(bridge, other)["ok"] as? Bool, false)
        let browse = try request(
            bridge, ["op": "browseFiles", "threadId": "sess_native", "viewVersion": 1, "folder": ""])
        XCTAssertEqual((browse["entries"] as? [[String: Any]])?.compactMap { $0["path"] as? String }, ["README.md"])
        _ = try request(bridge, ["op": "close", "viewVersion": 2])
        XCTAssertEqual(try request(bridge, read)["ok"] as? Bool, false)
        bridge.stopAll()
    }
    func testOlderMarkdownReferenceIsGrantedOnlyAfterItsNativePageAndClearedOnSessionSwitch() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = fixture.directory.appendingPathComponent("workspace")
        let skill = fixture.directory.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "# 较早的技能引用".write(to: skill, atomically: true, encoding: .utf8)
        try execute(fixture.database, "UPDATE session SET directory=? WHERE id='sess_native'", [project.path])
        try execute(
            fixture.database, "UPDATE part SET data=? WHERE id='prt_2_0'",
            [try json(["type": "text", "text": "[Skill](<\(skill.path)>)"])])
        try execute(
            fixture.database, "INSERT INTO session VALUES('sess_other','另一会话',?,5000,NULL,NULL)", [project.path])
        let bridge = ZCodeBridge(store: ZCodeSessionStore(path: fixture.database, indexPath: nil))
        _ = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
        let read: [String: Any] = [
            "op": "readMarkdownFile", "threadId": "sess_native", "viewVersion": 1, "path": skill.path,
        ]
        XCTAssertEqual(try request(bridge, read)["ok"] as? Bool, false)
        _ = try request(bridge, ["op": "history", "threadId": "sess_native", "viewVersion": 1, "before": "msg_u_5"])
        XCTAssertEqual(try request(bridge, read)["text"] as? String, "# 较早的技能引用")
        _ = try request(bridge, ["op": "open", "threadId": "sess_other", "viewVersion": 2])
        var other = read
        other["threadId"] = "sess_other"
        other["viewVersion"] = 2
        other["referencedPaths"] = [skill.path]
        XCTAssertEqual(try request(bridge, other)["ok"] as? Bool, false)
        _ = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 3])
        var reopened = read
        reopened["viewVersion"] = 3
        XCTAssertEqual(
            try request(bridge, reopened)["ok"] as? Bool, false,
            "the closed view's historical grants must not survive reopening")
        bridge.stopAll()
    }

    func testConditionalCacheAndTwoPhonesKeepIndependentPageLifetimes() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bridge = ZCodeBridge(store: ZCodeSessionStore(path: fixture.database, indexPath: nil))
        let page = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
        let cached = try request(
            bridge, ["op": "sync", "threadId": "sess_native", "viewVersion": 1, "knownVersion": page["cacheVersion"]!])
        XCTAssertEqual(cached["unchanged"] as? Bool, true)
        XCTAssertNil(cached["messages"])
        _ = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1], client: "phone-b")
        _ = try request(bridge, ["op": "close", "viewVersion": 2])
        XCTAssertEqual(
            try request(bridge, ["op": "sync", "threadId": "sess_native", "viewVersion": 1])["ok"] as? Bool, false)
        XCTAssertEqual(
            try request(bridge, ["op": "sync", "threadId": "sess_native", "viewVersion": 1], client: "phone-b")["ok"]
                as? Bool, true)
        bridge.stopAll()
    }

    func testRunningOutputGrowthDoesNotChangeCollapsedPageFingerprint() {
        var part: [String: Any] = [
            "id": "prt_native", "type": "tool", "tool": "Bash", "nativeVersion": "1",
            "state": ["status": "running", "input": ["command": "make test"], "output": "one"],
        ]
        let first = ZCodeConversation.sequence([part], offset: 0)
        part["nativeVersion"] = "2"
        part["state"] = ["status": "running", "input": ["command": "make test"], "output": "one\ntwo"]
        let next = ZCodeConversation.sequence([part], offset: 0)
        XCTAssertEqual(
            CodexConversation.fingerprint(["sequence": first]), CodexConversation.fingerprint(["sequence": next]))
        part["state"] = ["status": "completed", "input": ["command": "make test"], "output": "one\ntwo"]
        XCTAssertNotEqual(
            CodexConversation.fingerprint(["sequence": first]),
            CodexConversation.fingerprint(["sequence": ZCodeConversation.sequence([part], offset: 0)]))
    }

    func testSendabilityOnlyChangePushesAnEventAndListCapsStayFresh() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let live = Value()
        live.value = ["capabilities": ["send": true, "new": false], "canSend": false]
        let bridge = ZCodeBridge(
            store: ZCodeSessionStore(path: fixture.database, indexPath: nil),
            desktop: .init(snapshot: { _ in live.value }, execute: { _, _, _, _ in [:] }))
        _ = try request(bridge, ["op": "open", "threadId": "sess_native", "viewVersion": 1])
        let updated = expectation(description: "capability-only update")
        bridge.event = { _, data in
            if let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                row["canSend"] as? Bool == true
            {
                updated.fulfill()
            }
        }
        live.value = ["capabilities": ["send": true, "new": false], "canSend": true]
        bridge.refresh()
        wait(for: [updated], timeout: 2)
        let first = try request(bridge, ["op": "list", "limit": 8])
        XCTAssertEqual((first["capabilities"] as? [String: Bool])?["new"], false)
        live.value = ["capabilities": ["new": true], "canSend": false]
        XCTAssertEqual(
            (try request(bridge, ["op": "list", "limit": 8])["capabilities"] as? [String: Bool])?["new"], true)
        bridge.stopAll()
    }

    func testLateAndReplacedTaskIndexFiltersArchivedRowsAndKeepsPinnedOrder() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try execute(
            fixture.database, "INSERT INTO session VALUES('sess_other','Other','/fixture/other',9000,NULL,NULL)")
        let store = ZCodeSessionStore(path: fixture.database, indexPath: fixture.index)
        XCTAssertEqual(
            (try store.list(search: "", offset: 0, cwd: nil, limit: 8)["threads"] as? [[String: Any]])?.first?["id"]
                as? String, "sess_other")
        func createIndex(_ pinned: String, archiveOther: Int) throws {
            try execute(
                fixture.index,
                "CREATE TABLE tasks(task_id TEXT PRIMARY KEY,title TEXT,pinned INTEGER,archived INTEGER,deleted INTEGER,updated_at INTEGER,meta_json TEXT,task_status TEXT)"
            )
            try execute(
                fixture.index, "INSERT INTO tasks VALUES('sess_native',?,1,0,0,6000,?,'running')",
                [pinned, try json(["model": "GLM-fixture", "mode": "ask", "secret": "never expose"])])
            try execute(
                fixture.index, "INSERT INTO tasks VALUES('sess_other','Other',0,?,0,9000,'{}','completed')",
                [archiveOther])
        }
        try createIndex("Pinned native", archiveOther: 0)
        XCTAssertEqual(
            (try store.list(search: "", offset: 0, cwd: nil, limit: 8)["threads"] as? [[String: Any]])?.first?["title"]
                as? String, "Pinned native")
        XCTAssertNil((try store.summary("sess_native")["selection"] as? [String: Any])?["secret"])
        XCTAssertEqual(try store.summary("sess_native")["status"] as? String, "running")
        XCTAssertEqual(try store.summary("sess_native")["updatedAt"] as? Int64, 6000)
        try FileManager.default.moveItem(atPath: fixture.index, toPath: fixture.index + ".old")
        try createIndex("Renamed native", archiveOther: 1)
        let rows = try XCTUnwrap(store.list(search: "", offset: 0, cwd: nil, limit: 8)["threads"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["title"] as? String, "Renamed native")
        XCTAssertThrowsError(try store.summary("sess_other"))
    }

    func testDatabaseReadsCannotModifyNativeFiles() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = try Data(contentsOf: URL(fileURLWithPath: fixture.database))
        let reader = ZCodeSQLiteReader(path: fixture.database)
        XCTAssertEqual(try reader.rows("PRAGMA query_only").first?["query_only"] as? Int64, 1)
        XCTAssertThrowsError(try reader.rows("CREATE TABLE forbidden(value TEXT)"))
        XCTAssertEqual(before, try Data(contentsOf: URL(fileURLWithPath: fixture.database)))
    }
}
