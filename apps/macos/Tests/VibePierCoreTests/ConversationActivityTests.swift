import Foundation
import SQLite3
import XCTest

@testable import VibePierCore

final class ConversationActivityTests: XCTestCase {
    private func observation(
        _ id: String = "a", provider: String = "codex", phase: ConversationActivityObservation.Phase = .completed,
        turn: String? = "turn-a", completion: String? = "done-a", unread: Bool? = nil
    ) -> ConversationActivityObservation {
        .init(
            provider: provider, id: id, title: "Original title", phase: phase, run: turn, completion: completion,
            nativeUnread: unread)
    }

    func testPhoneCompletionEventsExcludeHistoryFailuresAndDuplicateRevisions() {
        var ledger = ConversationActivityLedger()
        let historical = observation()
        XCTAssertNil(ledger.completionEvent(historical, baseline: true))
        XCTAssertNil(ledger.completionEvent(historical, baseline: false))
        ledger.observe(historical, baseline: true)
        XCTAssertNil(ledger.completionEvent(historical, baseline: false))
        ledger.observe(observation(phase: .running, turn: "turn-b", completion: "done-a"), baseline: false)
        XCTAssertNil(
            ledger.completionEvent(observation(phase: .failed, turn: "turn-b", completion: nil), baseline: false))
        XCTAssertNil(ledger.completionEvent(observation(turn: "wrong-turn", completion: "done-b"), baseline: false))
        let completed = observation(turn: "turn-b", completion: "done-b", unread: false)
        XCTAssertNil(ledger.completionEvent(completed, baseline: true))
        let event = ledger.completionEvent(completed, baseline: false)
        XCTAssertEqual(event?["event"], "taskCompleted")
        XCTAssertEqual(event?["threadId"], completed.id)
        XCTAssertEqual(event?["eventId"]?.count, 64)
        XCTAssertEqual(Set(event?.keys.map { $0 } ?? []), ["event", "eventId", "provider", "threadId"])
        ledger.observe(completed, baseline: false)
        XCTAssertNil(ledger.completionEvent(completed, baseline: false))
        XCTAssertNotNil(ledger.completionEvent(observation(turn: "turn-c", completion: "done-c"), baseline: false))
    }

    func testStartupBaselinesHistoryButImportsExplicitNativeUnread() {
        var ledger = ConversationActivityLedger()
        ledger.observe(observation(), baseline: true)
        ledger.observe(observation("b", unread: true), baseline: true)
        ledger.observe(observation("failed", phase: .failed, unread: true), baseline: true)
        XCTAssertEqual(ledger.snapshot["unreadCount"] as? Int, 1)
        XCTAssertNil(ledger.entries["codex:a"]?.unread)
        XCTAssertNil(ledger.entries["codex:failed"]?.unread)
        XCTAssertEqual(ledger.entries["codex:b"]?.unread, "done-a")
    }

    func testRunningCompletionDeduplicationAndViewingWhileRunning() {
        var ledger = ConversationActivityLedger()
        ledger.observe(observation(unread: true), baseline: true)
        ledger.observe(observation(phase: .running, turn: "turn-b", completion: "done-a"), baseline: false)
        ledger.markViewed(provider: "codex", id: "a", completion: "done-a")
        XCTAssertEqual(ledger.snapshot["runningCount"] as? Int, 1)
        XCTAssertEqual(ledger.snapshot["unreadCount"] as? Int, 0)
        let complete = observation(turn: "turn-b", completion: "done-b")
        ledger.observe(complete, baseline: false)
        ledger.observe(complete, baseline: false)
        XCTAssertEqual(ledger.snapshot["unreadCount"] as? Int, 1)
        ledger.markViewed(provider: "codex", id: "a", completion: "done-a")
        XCTAssertEqual(ledger.entries["codex:a"]?.unread, "done-b", "late navigation cannot consume a newer completion")
        ledger.markViewed(provider: "codex", id: "a", completion: "done-b")
        ledger.observe(complete, baseline: false)
        XCTAssertNil(ledger.entries["codex:a"]?.unread, "repeated provider updates do not resurrect a viewed revision")
    }

    func testMarkAllViewedClearsOnlyListedDotsAndLaterCompletionsStillMark() {
        var ledger = ConversationActivityLedger()
        for provider in ["codex", "claude"] {
            ledger.observe(observation(provider: provider, unread: true), baseline: true)
        }
        ledger.observe(observation("late", unread: true), baseline: true)
        ledger.observe(observation("busy", phase: .running, completion: nil), baseline: false)
        XCTAssertEqual(ledger.markAllViewed(keys: ["codex:a", "claude:a", "codex:busy", "codex:missing"]), 2)
        XCTAssertEqual(ledger.snapshot["unreadCount"] as? Int, 1, "a dot finished after the panel rendered is kept")
        XCTAssertEqual(ledger.entries["codex:late"]?.unread, "done-a")
        XCTAssertEqual(ledger.snapshot["runningCount"] as? Int, 1)
        ledger.observe(observation(provider: "claude", unread: true), baseline: false)
        XCTAssertNil(
            ledger.entries["claude:a"]?.unread, "native unread for the same revision does not resurrect the dot")
        ledger.observe(
            observation(provider: "claude", turn: "turn-b", completion: "done-b", unread: true), baseline: false)
        XCTAssertEqual(ledger.entries["claude:a"]?.unread, "done-b")
    }

    func testSameIDAcrossProvidersAndFailureAreIndependent() {
        var ledger = ConversationActivityLedger()
        for provider in ["codex", "claude"] {
            ledger.observe(observation(provider: provider, unread: true), baseline: true)
        }
        ledger.markViewed(provider: "claude", id: "a", completion: "done-a")
        XCTAssertEqual(ledger.snapshot["unreadCount"] as? Int, 1)
        ledger.observe(observation("abort", phase: .running, completion: nil), baseline: false)
        ledger.observe(observation("abort", phase: .failed, completion: nil), baseline: false)
        XCTAssertNil(ledger.entries["codex:abort"]?.unread)
        XCTAssertEqual(ledger.snapshot["runningCount"] as? Int, 0)
    }

    func testPersistedUnsupportedProviderActivityIsFilteredBeforeFirstSnapshot() throws {
        let file = temporary().appendingPathComponent("ledger.json")
        var ledger = ConversationActivityLedger()
        ledger.observe(
            observation("retired-running", provider: "retired-provider", phase: .running, completion: nil),
            baseline: true)
        ledger.observe(observation("retired-unread", provider: "retired-provider", unread: true), baseline: true)
        ledger.observe(observation("supported", provider: "codex", unread: true), baseline: true)
        try JSONEncoder().encode(ledger).write(to: file)
        let activity = ConversationActivity(file: file, source: FixtureSource(observation("supported", unread: true)))
        XCTAssertEqual(activity.snapshot["runningCount"] as? Int, 0)
        XCTAssertEqual(activity.snapshot["unreadCount"] as? Int, 1)
        let sessions = try XCTUnwrap(activity.snapshot["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.compactMap { $0["provider"] as? String }, ["codex"])
    }

    func testRestartPreservesUnreadViewedAndObservedRunningTurn() throws {
        var ledger = ConversationActivityLedger()
        ledger.observe(observation("read", unread: true), baseline: true)
        ledger.markViewed(provider: "codex", id: "read", completion: "done-a")
        ledger.observe(observation("unread", unread: true), baseline: true)
        ledger.observe(observation("running", phase: .running, completion: nil), baseline: true)
        var restored = try JSONDecoder().decode(ConversationActivityLedger.self, from: JSONEncoder().encode(ledger))
        restored.observe(observation("read", unread: true), baseline: true)
        restored.observe(observation("running"), baseline: true)
        restored.observe(observation("historical", completion: "older"), baseline: true)
        XCTAssertNil(restored.entries["codex:read"]?.unread)
        XCTAssertNotNil(restored.entries["codex:unread"]?.unread)
        XCTAssertNotNil(restored.entries["codex:running"]?.unread)
        XCTAssertNil(restored.entries["codex:historical"]?.unread)
    }

    func testNativeReadOnlyClearsMatchingCompletionAndMissingIdentityIsNotRead() {
        var ledger = ConversationActivityLedger()
        var unread = observation(unread: true)
        unread.nativeRevision = "identity-host"
        ledger.observe(unread, baseline: true)
        ledger.observe(observation(), baseline: false)
        XCTAssertNotNil(ledger.entries["codex:a"]?.unread, "logout/missing account bucket is unknown")
        var read = unread
        read.nativeUnread = false
        ledger.observe(read, baseline: false)
        XCTAssertNil(ledger.entries["codex:a"]?.unread)
        var newer = observation(turn: "new", completion: "new", unread: true)
        newer.nativeRevision = "identity-host"
        ledger.observe(newer, baseline: false)
        read.completion = "new"
        read.nativeViewedCompletion = "done-a"
        ledger.observe(read, baseline: false)
        XCTAssertEqual(
            ledger.entries["codex:a"]?.unread, "new", "a read captured for the old turn cannot clear a newer one")
    }

    func testVisibleNativeCompletionCanStayReadWithoutPriorUnreadTrue() {
        var ledger = ConversationActivityLedger()
        ledger.observe(observation(phase: .running, completion: nil, unread: false), baseline: true)
        var completed = observation(unread: false)
        ledger.observe(completed, baseline: false)
        XCTAssertNil(ledger.entries["codex:a"]?.unread)
        XCTAssertNil(
            ledger.entries["codex:a"]?.viewed, "native false suppresses a dot without consuming a later true update")
        completed.nativeUnread = true
        ledger.observe(completed, baseline: false)
        XCTAssertEqual(ledger.entries["codex:a"]?.unread, "done-a")
    }

    func testOldUnreadWatermarkCanClearAfterNewNativeReadCompletionWithoutConsumingLaterUnread() {
        var ledger = ConversationActivityLedger()
        ledger.observe(observation(turn: "A", completion: "done-A", unread: true), baseline: true)
        ledger.observe(observation(turn: "B", completion: "done-B", unread: false), baseline: false)
        let entry = ledger.entries["codex:a"]
        let displayedWatermark = entry?.unread ?? entry?.completion
        XCTAssertEqual(displayedWatermark, "done-A")
        ledger.markViewed(provider: "codex", id: "a", completion: displayedWatermark)
        XCTAssertNil(ledger.entries["codex:a"]?.unread)
        XCTAssertNotEqual(ledger.entries["codex:a"]?.viewed, "done-B")
        ledger.observe(observation(turn: "B", completion: "done-B", unread: true), baseline: false)
        XCTAssertEqual(
            ledger.entries["codex:a"]?.unread, "done-B", "native true for B can arrive after the old A dot was cleared")
    }

    func testClaudeBusyReturningToOldAnswerIsNotSuccessfulCompletion() {
        var ledger = ConversationActivityLedger()
        ledger.observe(observation(provider: "claude", phase: .running, completion: "old-answer"), baseline: true)
        ledger.observe(observation(provider: "claude", turn: nil, completion: "old-answer"), baseline: false)
        XCTAssertNil(ledger.entries["claude:a"]?.unread)
        ledger.observe(
            observation(provider: "claude", phase: .running, turn: "second", completion: "old-answer"), baseline: false)
        ledger.observe(observation(provider: "claude", turn: nil, completion: "fresh-answer"), baseline: false)
        XCTAssertEqual(ledger.entries["claude:a"]?.unread, "fresh-answer")
    }

    func testLifecycleParserIgnoresToolMentionsAndKeepsAbortSeparate() throws {
        func line(_ payload: [String: Any], type: String = "event_msg") throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
            data.append(10)
            return data
        }
        var input = try line(["type": "task_started", "turn_id": "turn-1", "started_at": 1000])
        input.append(
            try line(["type": "task_complete", "turn_id": "fake", "completed_at": 2000], type: "response_item"))
        let running = ConversationActivityTail.codex(input)
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.run, "turn-1")
        XCTAssertEqual(running.startedAt, 1000)
        let done = ConversationActivityTail.codex(
            try line(["type": "task_complete", "turn_id": "turn-1", "completed_at": 2000]), previous: running)
        XCTAssertEqual(done.phase, .completed)
        XCTAssertEqual(done.completion, "turn-1:2000")
        let aborted = ConversationActivityTail.codex(
            try line(["type": "turn_aborted", "turn_id": "turn-1"]), previous: running)
        XCTAssertEqual(aborted.phase, .failed)
        XCTAssertNil(aborted.completion)
        let failed = ConversationActivityTail.codex(
            try line(["type": "task_complete", "turn_id": "turn-1", "error": "fixture"]), previous: running)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertNil(failed.completion)
        let nullError = ConversationActivityTail.codex(
            try line(["type": "task_complete", "turn_id": "turn-1", "completed_at": 2000, "error": NSNull()]),
            previous: running)
        XCTAssertEqual(nullError.phase, .completed)
        let cancelled = ConversationActivityTail.codex(
            try line(["type": "task_complete", "turn_id": "turn-1", "status": "cancelled"]), previous: running)
        XCTAssertEqual(cancelled.phase, .failed)
        XCTAssertNil(cancelled.completion)
    }

    func testNativeUnreadDoesNotFlattenAccountsOrExecutionHosts() throws {
        let host = "local:" + String(repeating: "a", count: 64)
        let context = try XCTUnwrap(
            NativeConversationActivitySource.readContext([
                "identity": ["kind": "chatgpt", "accountId": "account", "userId": "user"], "executionHostKey": host,
            ]))
        let data = try JSONSerialization.data(withJSONObject: [
            "electron-thread-read-state-v1": [
                "version": 1,
                "unreadByIdentity": [
                    context.identity: [host: ["current"], "remote:other": ["remote"], "local:other": ["other-local"]],
                    "other-account": [host: ["wrong-account"]],
                ],
            ]
        ])
        XCTAssertEqual(NativeConversationActivitySource.unreadIDs(data, context: context), ["current"])
        let unknown = NativeConversationActivitySource.ReadContext(identity: "logged-out", host: host)
        XCTAssertNil(NativeConversationActivitySource.unreadIDs(data, context: unknown))
        let source = NativeConversationActivitySource(home: temporary())
        source.acceptCodexReadState([
            "hostId": "local", "conversationId": UUID().uuidString, "hasUnreadTurn": false,
            "context": [
                "identity": ["kind": "chatgpt", "accountId": "account", "userId": "user"], "executionHostKey": host,
            ],
        ])
        XCTAssertFalse(
            source.acceptsCodexContext([
                "hostId": "local",
                "context": [
                    "identity": ["kind": "chatgpt", "accountId": "other", "userId": "user"], "executionHostKey": host,
                ],
            ]))
    }

    func testBootstrapUsesNativeAccessTokenUserFieldAndNeverSubject() throws {
        let claims: [String: Any] = [
            "exp": 1, "sub": "different-subject",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account", "user_id": "native-user", "chatgpt_user_id": "fallback-user",
            ],
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(
            of: "=", with: ""
        ).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let auth = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt", "tokens": ["access_token": "header." + payload + ".signature"],
        ])
        let context = try XCTUnwrap(NativeConversationActivitySource.bootstrapContext(auth))
        XCTAssertEqual(
            context.identity, NativeConversationActivitySource.digest(["chatgpt", "account", "native-user"]))
        XCTAssertNotEqual(
            context.identity, NativeConversationActivitySource.digest(["chatgpt", "account", "different-subject"]))
    }

    private func temporary() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "activity-fixture-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private final class FixtureSource: ConversationActivitySource, @unchecked Sendable {
        private let lock = NSLock()
        private var result: ConversationActivityScan
        init(_ value: ConversationActivityObservation) {
            result = .init(observations: [value], visibleIDs: [value.provider: [value.id]])
        }
        func scan(tracked: [String: ConversationActivityLedger.Entry]) -> ConversationActivityScan {
            lock.withLock { result }
        }
        func contains(provider: String, id: String) -> Bool {
            lock.withLock { result.visibleIDs[provider]?.contains(id) == true }
        }
        func acceptsCodexContext(_ params: [String: Any]) -> Bool { false }
        func acceptCodexReadState(_ params: [String: Any]) {}
    }

    private func database(_ path: URL, _ sql: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else { throw CLIError("fixture DB unavailable") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CLIError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func testNativeCodexMetadataFiltersSubagents() throws {
        let home = temporary()
        let path = home.appendingPathComponent("rollout.jsonl")
        let id = UUID().uuidString
        var line = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "turn", "completed_at": 5],
        ])
        line.append(10)
        try line.write(to: path)
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
        let codex = home.appendingPathComponent(".codex/state_5.sqlite")
        try database(
            codex,
            """
            CREATE TABLE threads(id TEXT,name TEXT,title TEXT,rollout_path TEXT,updated_at_ms INTEGER,archived INTEGER,agent_path TEXT,source TEXT,originator TEXT);
            INSERT INTO threads VALUES(\(quote(id)),NULL,'Original Codex',\(quote(path.path)),\(Int64(Date().timeIntervalSince1970 * 1000)),0,NULL,'vscode','vibepier');
            INSERT INTO threads VALUES('child',NULL,'Subagent',\(quote(path.path)),0,0,'child','vscode','Codex Desktop');
            """)
        let source = NativeConversationActivitySource(home: home)
        let first = source.scan(tracked: [:])
        var ledger = ConversationActivityLedger()
        for observation in first.observations { ledger.observe(observation, baseline: true) }
        XCTAssertEqual(first.visibleIDs["codex"], [id])
    }

    func testClaudeNativeRouteUsesExactHostAndArchivesRemoveTrackedActivity() throws {
        let home = temporary()
        let id = UUID().uuidString
        let host = "local_" + UUID().uuidString
        let transcript = home.appendingPathComponent(".claude/projects/project/" + id + ".jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "uuid": "answer", "message": ["stop_reason": "end_turn", "content": []],
        ])
        text.append(10)
        try text.write(to: transcript)
        let metadata = home.appendingPathComponent(
            "Library/Application Support/Claude-3p/claude-code-sessions/account/project/" + host + ".json")
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        var native: [String: Any] = [
            "sessionId": host, "cliSessionId": id, "title": "Native Claude title", "isArchived": false,
            "lastFocusedAt": 999999,
        ]
        try JSONSerialization.data(withJSONObject: native).write(to: metadata)
        let wrong = NativeConversationActivitySource(home: home, visibleClaudeHost: { host + "-different" })
        var ledger = ConversationActivityLedger()
        ledger.observe(
            observation(id, provider: "claude", turn: nil, completion: "answer", unread: true), baseline: true)
        for observation in wrong.scan(tracked: ledger.entries).observations {
            ledger.observe(observation, baseline: false)
        }
        XCTAssertNotNil(ledger.entries["claude:" + id]?.unread, "lastFocusedAt alone or a similar host is not a read")
        let exact = NativeConversationActivitySource(home: home, visibleClaudeHost: { host })
        for observation in exact.scan(tracked: ledger.entries).observations {
            ledger.observe(observation, baseline: false)
        }
        XCTAssertNil(ledger.entries["claude:" + id]?.unread)
        XCTAssertEqual(ledger.entries["claude:" + id]?.title, "Native Claude title")
        native["isArchived"] = true
        try JSONSerialization.data(withJSONObject: native).write(to: metadata, options: .atomic)
        XCTAssertEqual(exact.scan(tracked: ledger.entries).visibleIDs["claude"], [])
    }

    func testDelayedCodexFalseDoesNotApproveNewDiskCompletionOrLaterTrue() throws {
        let home = temporary()
        let id = UUID().uuidString
        let path = home.appendingPathComponent("rollout.jsonl")
        func completion(_ turn: String) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: [
                "type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn, "completed_at": turn],
            ])
            data.append(10)
            return data
        }
        try completion("A").write(to: path)
        try database(
            home.appendingPathComponent(".codex/state_5.sqlite"),
            """
            CREATE TABLE threads(id TEXT,name TEXT,title TEXT,rollout_path TEXT,updated_at_ms INTEGER,archived INTEGER,agent_path TEXT,source TEXT,originator TEXT);
            INSERT INTO threads VALUES('\(id)',NULL,'Original','\(path.path)',\(Int64(Date().timeIntervalSince1970 * 1000)),0,NULL,'vscode','Codex Desktop');
            """)
        let source = NativeConversationActivitySource(home: home)
        let host = "local:" + String(repeating: "a", count: 64)
        let context: [String: Any] = [
            "identity": ["kind": "chatgpt", "accountId": "account", "userId": "user"], "executionHostKey": host,
        ]
        var packet: [String: Any] = [
            "hostId": "local", "conversationId": id, "hasUnreadTurn": true, "context": context,
        ]
        source.acceptCodexReadState(packet)
        var ledger = ConversationActivityLedger()
        for observation in source.scan(tracked: [:]).observations { ledger.observe(observation, baseline: true) }
        XCTAssertEqual(ledger.entries["codex:" + id]?.unread, "A:A")
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: completion("B"))
        try handle.close()
        packet["hasUnreadTurn"] = false
        source.acceptCodexReadState(packet)
        packet["hasUnreadTurn"] = true
        source.acceptCodexReadState(packet)
        for observation in source.scan(tracked: ledger.entries).observations {
            ledger.observe(observation, baseline: false)
        }
        XCTAssertEqual(ledger.entries["codex:" + id]?.unread, "B:B", "delayed false(A) must not clear true(B)")
        XCTAssertNotEqual(ledger.entries["codex:" + id]?.viewed, "B:B")
    }

    func testOpenFailureDoesNotClearAndSuccessfulExactOpenPersists() async throws {
        let file = temporary().appendingPathComponent("ledger.json")
        let source = FixtureSource(observation(unread: true))
        let activity = ConversationActivity(file: file, source: source)
        activity.start()
        // A synchronous mark waits for the initial scan on the monitor queue.
        activity.markViewed(provider: "unrelated", id: "unrelated")
        XCTAssertEqual(activity.snapshot["unreadCount"] as? Int, 1)
        activity.setOpener { _, _ in throw CLIError("fixture could not verify the native route") }
        do {
            try await activity.open(provider: "codex", id: "a")
            XCTFail("failure must propagate")
        } catch {}
        XCTAssertEqual(activity.snapshot["unreadCount"] as? Int, 1)
        activity.setOpener { provider, id in
            XCTAssertEqual(provider, "codex")
            XCTAssertEqual(id, "a")
        }
        try await activity.open(provider: "codex", id: "a")
        XCTAssertEqual(activity.snapshot["unreadCount"] as? Int, 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        activity.stop()
        let restarted = ConversationActivity(file: file, source: source)
        restarted.start()
        restarted.markViewed(provider: "unrelated", id: "unrelated")
        XCTAssertEqual(restarted.snapshot["unreadCount"] as? Int, 0)
        restarted.stop()
    }

    func testMarkAllViewedPersistsAcrossRestart() throws {
        let file = temporary().appendingPathComponent("ledger.json")
        let source = FixtureSource(observation(unread: true))
        let activity = ConversationActivity(file: file, source: source)
        activity.start()
        activity.markViewed(provider: "unrelated", id: "unrelated")
        XCTAssertEqual(activity.snapshot["unreadCount"] as? Int, 1)
        XCTAssertEqual(activity.markAllViewed(keys: ["codex:a"]), 1)
        XCTAssertEqual(activity.snapshot["unreadCount"] as? Int, 0)
        activity.stop()
        let restarted = ConversationActivity(file: file, source: source)
        restarted.start()
        restarted.markViewed(provider: "unrelated", id: "unrelated")
        XCTAssertEqual(restarted.snapshot["unreadCount"] as? Int, 0)
        restarted.stop()
    }
}
