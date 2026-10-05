import SQLite3
import XCTest

@testable import VibePierCore

final class CodexBridgeTests: XCTestCase {
    func testConditionalContentOmitsUnchangedMessagesButReconfirmsLiveCapabilities() throws {
        let rows: [[String: Any]] = [
            [
                "id": "reply", "role": "assistant", "text": String(repeating: "文字", count: 1800),
                "parts": [["id": "c", "kind": "command", "status": "running", "title": "test", "text": "one output"]],
            ]
        ]
        let base: [String: Any] = [
            "threadId": "thread", "messages": ConversationReply.preview(rows),
            "approvals": [["fingerprint": "approval"]], "status": "active", "composer": ["model": "model"],
            "canSend": true, "revision": 1, "viewVersion": 1,
        ]
        let full = ConversationReply.versioned(base)
        var resumed = base
        resumed["viewVersion"] = 2
        resumed["revision"] = 100
        resumed["canSend"] = false
        let short = ConversationReply.conditional(resumed, known: full["cacheVersion"] as? String)
        XCTAssertEqual(short["unchanged"] as? Bool, true)
        XCTAssertNil(short["messages"])
        XCTAssertEqual(short["canSend"] as? Bool, false)
        XCTAssertNotNil(short["approvals"])
        XCTAssertEqual(short["viewVersion"] as? Int, 2)
        let fullSize = try JSONSerialization.data(withJSONObject: full).count
        let shortSize = try JSONSerialization.data(withJSONObject: short).count
        XCTAssertLessThan(shortSize * 4, fullSize)
        print("Conditional conversation: \(fullSize) → \(shortSize) bytes")
        var moreOutput = rows
        moreOutput[0]["parts"] = [
            ["id": "c", "kind": "command", "status": "running", "title": "test", "text": "much more output"]
        ]
        XCTAssertEqual(
            (ConversationReply.preview(moreOutput).first?["sequence"] as? [[String: Any]])?.first?["bodyVersion"]
                as? String, "running")
        XCTAssertEqual(
            CodexConversation.fingerprint(["messages": ConversationReply.preview(rows)]),
            CodexConversation.fingerprint(["messages": ConversationReply.preview(moreOutput)]),
            "hidden running output must not trigger repeated page pushes")
        var completed = moreOutput
        completed[0]["parts"] = [
            ["id": "c", "kind": "command", "status": "completed", "title": "test", "text": "much more output"]
        ]
        resumed["messages"] = ConversationReply.preview(completed)
        XCTAssertNotNil(ConversationReply.conditional(resumed, known: full["cacheVersion"] as? String)["messages"])
        resumed = base
        resumed["composer"] = ["model": "changed"]
        XCTAssertNotNil(ConversationReply.conditional(resumed, known: full["cacheVersion"] as? String)["messages"])
    }
    func testDesktopSequencePreviewsNewestPartsAndPrependsMixedContentInOriginalOrder() throws {
        let parts: [[String: Any]] = (0..<20).map { i in
            [
                "id": "part-\(i)", "kind": i % 2 == 0 ? "text" : "command", "title": "command \(i)",
                "status": "completed", "text": i % 2 == 0 ? "paragraph \(i)" : String(repeating: "输出", count: 40000),
            ]
        }
        let rows: [[String: Any]] = [
            ["id": "reply", "role": "assistant", "text": "aggregate legacy text", "parts": parts]
        ]
        let preview = ConversationReply.preview(rows).first!
        let tail = try XCTUnwrap(preview["sequence"] as? [[String: Any]])
        XCTAssertEqual(tail.compactMap { $0["index"] as? Int }, Array(12..<20))
        XCTAssertEqual(tail.first?["text"] as? String, "paragraph 12")
        XCTAssertTrue(
            tail.filter { $0["kind"] as? String == "command" }.allSatisfy {
                ($0["text"] as? String ?? "").isEmpty && $0["bodyDeferred"] as? Bool == true
            })
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: preview).count, 12_000)
        var result = tail
        var first = 12
        while first > 0 {
            let start = max(0, first - 8)
            let page = try XCTUnwrap(
                ConversationReply.partPage(rows, id: "reply", offset: start, sequence: true, before: first))
            let earlier = try XCTUnwrap(page["parts"] as? [[String: Any]])
            XCTAssertEqual(earlier.compactMap { $0["index"] as? Int }, Array(start..<first))
            XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: page).count, 12_000)
            result = earlier + result
            first = start
        }
        XCTAssertEqual(result.compactMap { $0["id"] as? String }, parts.compactMap { $0["id"] as? String })
        XCTAssertEqual(result.compactMap { $0["kind"] as? String }, parts.compactMap { $0["kind"] as? String })
        let changed = [
            ["id": "reply", "parts": [["id": "part-19", "kind": "command", "text": "different same length"]]]
        ]
        XCTAssertNotEqual(
            (ConversationReply.preview(changed).first?["sequence"] as? [[String: Any]])?.first?["bodyVersion"]
                as? String, tail.last?["bodyVersion"] as? String)
    }
    func testInlineProcessHeadersExcludeBodiesAndKeepOrderAcrossPages() throws {
        let parts: [[String: Any]] =
            [["id": "prose", "kind": "text", "text": "回答"]]
            + (0..<20).map {
                [
                    "id": "command-\($0)", "kind": "command", "title": "command \($0)", "status": "completed",
                    "text": String(repeating: "输出", count: 40000),
                ]
            }
        let rows: [[String: Any]] = [["id": "reply", "role": "assistant", "text": "回答", "parts": parts]]
        let preview = ConversationReply.preview(rows).first!
        XCTAssertEqual(preview["processCount"] as? Int, 20)
        XCTAssertNil(preview["parts"])
        var offset = 0
        var ids: [String] = []
        repeat {
            let page = try XCTUnwrap(ConversationReply.partPage(rows, id: "reply", offset: offset, headersOnly: true))
            XCTAssertLessThan(try JSONSerialization.data(withJSONObject: page).count, 6000)
            let headers = try XCTUnwrap(page["parts"] as? [[String: Any]])
            XCTAssertTrue(headers.allSatisfy { $0["text"] == nil && $0[ConversationReply.imageKey] == nil })
            ids += headers.compactMap { $0["id"] as? String }
            offset = page["nextOffset"] as? Int ?? -1
        } while offset >= 0
        XCTAssertEqual(ids, (0..<20).map { "command-\($0)" })
        XCTAssertEqual(ConversationReply.fullText(rows, id: "command-19"), parts.last?["text"] as? String)
        let longCommand = String(repeating: "command ", count: 1000)
        let detailRows: [[String: Any]] = [
            [
                "id": "reply",
                "parts": [["id": "long-command", "kind": "command", "title": longCommand, "text": "output"]],
            ]
        ]
        let header = try XCTUnwrap(
            (ConversationReply.partPage(detailRows, id: "reply", offset: 0, headersOnly: true)?["parts"]
                as? [[String: Any]])?.first)
        XCTAssertEqual((header["title"] as? String)?.count, 400)
        XCTAssertEqual(ConversationReply.partDetails(detailRows, id: "long-command")?["title"] as? String, longCommand)
        XCTAssertNil(ConversationReply.partDetails(detailRows, id: "long-command")?["text"])
        var changed = parts
        changed[0]["text"] = "新的回答"
        changed[1]["text"] = "新的输出"
        let sameHeaders = ConversationReply.preview([["id": "reply", "parts": changed]]).first!
        XCTAssertEqual(preview["partsVersion"] as? String, sameHeaders["partsVersion"] as? String)
        changed[1]["status"] = "failed"
        let changedHeaders = ConversationReply.preview([["id": "reply", "parts": changed]]).first!
        XCTAssertNotEqual(preview["partsVersion"] as? String, changedHeaders["partsVersion"] as? String)
        XCTAssertEqual(
            ConversationReply.preview([["id": "text", "parts": [parts[0]]]]).first?["processCount"] as? Int, 0)
    }
    func testContextUsageUsesLatestRequestAndRequiresKnownWindow() {
        let state: [String: Any] = [
            "latestTokenUsageInfo": [
                "total": ["totalTokens": 9_000_000],
                "last": ["totalTokens": 25000, "inputTokens": 24000, "cachedInputTokens": 20000, "outputTokens": 1000],
                "modelContextWindow": 100000,
            ]
        ]
        let usage = CodexConversation.contextUsage(state)
        XCTAssertEqual(usage?["usedTokens"] as? Int64, 25000)
        XCTAssertEqual(usage?["remainingTokens"] as? Int64, 75000)
        XCTAssertEqual(usage?["percent"] as? Double, 25)
        XCTAssertEqual(CodexConversation.composer(state)["contextUsage"] as? String, usage?["summary"] as? String)
        XCTAssertNil(CodexConversation.contextUsage([:]))
        XCTAssertNil(CodexConversation.contextUsage(["latestTokenUsageInfo": ["last": ["totalTokens": 3]]]))
        XCTAssertNil(
            CodexConversation.contextUsage([
                "latestTokenUsageInfo": ["last": ["totalTokens": -1], "modelContextWindow": 100]
            ]))
        let over = CodexConversation.contextUsage([
            "latestTokenUsageInfo": ["last": ["totalTokens": 200], "modelContextWindow": 100]
        ])
        XCTAssertEqual(over?["usedTokens"] as? Int64, 100)
        XCTAssertEqual(over?["percent"] as? Double, 100)
    }

    func testReceiptReservationSurvivesCrashAndRejectsChangedPayload() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("receipts.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var journal = try SessionReceiptJournal(file: file)
        guard case .fresh = try journal.reserve("device:operation", hash: "hash", thread: "thread") else {
            return XCTFail("first operation")
        }
        journal = try SessionReceiptJournal(file: file)
        guard case .unknown = try journal.reserve("device:operation", hash: "hash", thread: "thread") else {
            return XCTFail("must never repeat after crash")
        }
        guard case .conflict = try journal.reserve("device:operation", hash: "different", thread: "other") else {
            return XCTFail("must reject reused ID")
        }
        let result = Data("accepted".utf8)
        try journal.complete("device:operation", result: result)
        journal = try SessionReceiptJournal(file: file)
        guard case .complete(let replay) = try journal.reserve("device:operation", hash: "hash", thread: "thread")
        else { return XCTFail("must return same receipt") }
        XCTAssertEqual(replay, result)
        guard case .fresh = try journal.reserve("other-device:operation", hash: "hash", thread: "thread") else {
            return XCTFail("device scope")
        }
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try SessionReceiptJournal(file: file))
    }
    func testFailedReservationDoesNotPermitExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = try SessionReceiptJournal(file: directory.appendingPathComponent("receipts.json"))
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try journal.reserve("operation", hash: "hash", thread: "thread"))
        XCTAssertNil(journal.receipt("operation"))
    }
    func testLongPageKeepsAllMessageIdentitiesAndDefersApprovalDetails() throws {
        let turns: [[String: Any]] = (0..<20).map { turn in
            [
                "turnId": "t\(turn)",
                "items": [["id": "u\(turn)", "type": "userMessage", "text": "问题\(turn)"]]
                    + (0..<5).map {
                        [
                            "id": "message-\(turn)-\($0)", "type": "agentMessage",
                            "text": String(repeating: "长文本", count: 5000),
                        ]
                    },
            ]
        }
        let state: [String: Any] = [
            "turns": turns,
            "requests": [["id": 1, "method": "item/commandExecution/requestApproval", "params": ["command": "pwd"]]],
        ]
        let page = CodexConversation.page(state)
        let messages = try XCTUnwrap(page["messages"] as? [[String: Any]])
        XCTAssertEqual(
            messages.count, ConversationReply.recentTurns * 2, "the newest turns, one question and one reply each")
        XCTAssertEqual(messages.first?["id"] as? String, "u19")
        XCTAssertEqual(page["hasOlder"] as? Bool, true)
        XCTAssertTrue(
            messages.filter { $0["role"] as? String == "assistant" }.allSatisfy { $0["hasMore"] as? Bool == true })
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: page).count, 16_000)
        XCTAssertNil(messages.last?["parts"])
        XCTAssertEqual(messages.last?["partsDeferred"] as? Bool, true)
        // Scrolling up asks for the batch before the oldest message shown, then the rest.
        let all = CodexConversation.turns(state).map(CodexConversation.messages)
        let earlier = try XCTUnwrap(ConversationReply.older(all, before: "u19"))
        XCTAssertEqual(earlier.rows.first?["id"] as? String, "u16")
        XCTAssertEqual(earlier.rows.count, ConversationReply.olderTurns * 2)
        XCTAssertEqual(earlier.start, 16)
        let oldest = try XCTUnwrap(ConversationReply.older(all, before: "u3"))
        XCTAssertEqual(oldest.rows.first?["id"] as? String, "u0")
        XCTAssertEqual(oldest.start, 0)
        let approval = try XCTUnwrap((page["approvals"] as? [[String: Any]])?.first)
        XCTAssertNil(approval["details"])
        XCTAssertEqual(approval["detailsOnDemand"] as? Bool, true)
    }
    func testInitialPreviewDefersHundredsOfStepsAndPartPagesRetainEveryIdentity() throws {
        let steps: [[String: Any]] = (0..<200).map {
            ["id": "step-\($0)", "kind": "command", "title": "工具\($0)", "text": String(repeating: "输出", count: 3000)]
        }
        let rows: [[String: Any]] = [
            ["id": "question", "role": "user", "text": "最新问题"],
            ["id": "reply", "role": "assistant", "text": "最新回复", "parts": steps],
        ]
        let preview = ConversationReply.preview(rows)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: preview).count, 6000)
        XCTAssertEqual(preview.last?["text"] as? String, "最新回复")
        XCTAssertEqual(preview.last?["partCount"] as? Int, 200)
        var offset = 0
        var ids: [String] = []
        repeat {
            let page = try XCTUnwrap(ConversationReply.partPage(rows, id: "reply", offset: offset))
            XCTAssertLessThan(try JSONSerialization.data(withJSONObject: page).count, 13_000)
            let parts = try XCTUnwrap(page["parts"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(parts.count, 8)
            ids += parts.compactMap { $0["id"] as? String }
            offset = page["nextOffset"] as? Int ?? -1
        } while offset >= 0
        XCTAssertEqual(ids, steps.compactMap { $0["id"] as? String })
        XCTAssertEqual(ConversationReply.fullText(rows, id: "step-199"), steps.last?["text"] as? String)
    }
    func testListLatencyWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["VIBEPIER_LIST_PROBE"] == "1" else {
            throw XCTSkip("List latency probe is opt-in")
        }
        for projects in [false, true] {
            let start = ProcessInfo.processInfo.systemUptime
            let result =
                projects
                ? try CodexThreadStore().projects(search: "", limit: 8)
                : try CodexThreadStore().list(search: "", offset: 0, limit: 8)
            print(
                "Codex \(projects ? "projects" : "list"): \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))ms, \(try JSONSerialization.data(withJSONObject: result).count) bytes"
            )
        }
        let bridge = ClaudeBridge()
        for op in ["list", "projects"] {
            let done = expectation(description: "Claude list probe")
            let start = ProcessInfo.processInfo.systemUptime
            let request = try JSONSerialization.data(withJSONObject: ["op": op, "offset": 0, "limit": 8])
            bridge.perform(request, client: "list-probe") { result in
                print(
                    "Claude \(op): \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))ms, \(result.count) bytes"
                )
                done.fulfill()
            }
            wait(for: [done], timeout: 60)
        }
    }
    func testRealDesktopIndexIncludesCurrentThreadWhenExplicitlyRequested() throws {
        guard let thread = ProcessInfo.processInfo.environment["VIBEPIER_CODEX_READ_THREAD"] else {
            throw XCTSkip("Live index check is opt-in")
        }
        let store = CodexThreadStore()
        var offset = 0
        var ids = Set<String>()
        repeat {
            let page = try store.list(search: "", offset: offset)
            let rows = try XCTUnwrap(page["threads"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(rows.count, 20)
            for row in rows { XCTAssertTrue(ids.insert(try XCTUnwrap(row["id"] as? String)).inserted) }
            offset = page["nextOffset"] as? Int ?? -1
        } while offset >= 0
        XCTAssertTrue(
            ids.contains(thread), "Current real desktop conversation must be listed regardless of has_user_event")
    }
    func testRealBridgeOpensCurrentDesktopAndDeliversMessagesWhenExplicitlyRequested() throws {
        guard let thread = ProcessInfo.processInfo.environment["VIBEPIER_CODEX_READ_THREAD"] else {
            throw XCTSkip("Real bridge open is opt-in")
        }
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var received = false
            func take() -> Bool {
                lock.withLock {
                    if received { return false }
                    received = true
                    return true
                }
            }
        }
        let once = Once()
        let opened = expectation(description: "bridge open accepted")
        let snapshot = expectation(description: "real messages passed compatibility gate")
        let bridge = CodexBridge(executionModeCatalog: { [] })
        let client = "readonly-test-" + UUID().uuidString
        defer { bridge.stop(client) }
        bridge.event = { recipient, data in
            guard recipient == client, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                value["event"] as? String == "snapshot", value["threadId"] as? String == thread, once.take()
            else { return }
            XCTAssertEqual(value["viewVersion"] as? Int, 1)
            XCTAssertEqual(value["canSend"] as? Bool, true)
            XCTAssertFalse((value["messages"] as? [Any] ?? []).isEmpty)
            snapshot.fulfill()
        }
        let request = try JSONSerialization.data(withJSONObject: ["op": "open", "threadId": thread, "viewVersion": 1])
        bridge.perform(request, client: client) { data in
            let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(result?["ok"] as? Bool, true, "\(result?["error"] ?? "No result")")
            opened.fulfill()
        }
        wait(for: [opened, snapshot], timeout: 15)
        let retry = expectation(description: "opening retry returns already loaded page")
        let warm = expectation(
            description: "foreground reopen reuses current subscription and validates cached content")
        bridge.perform(request, client: client) { data in
            let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(result?["ok"] as? Bool, true)
            XCTAssertEqual(result?["viewVersion"] as? Int, 1)
            XCTAssertFalse(
                (result?["messages"] as? [Any] ?? []).isEmpty,
                "A lost first push must be recoverable from the opening retry")
            retry.fulfill()
            if ProcessInfo.processInfo.environment["VIBEPIER_CODEX_NOOP_MODEL_THREAD"] == thread {
                warm.fulfill()
                return
            }
            let known = result?["cacheVersion"] as? String ?? ""
            let next = try! JSONSerialization.data(withJSONObject: [
                "op": "open", "threadId": thread, "viewVersion": 2, "knownVersion": known, "updatesIntervalMs": 750,
            ])
            bridge.perform(next, client: client) { short in
                let value = (try? JSONSerialization.jsonObject(with: short) as? [String: Any]) ?? [:]
                XCTAssertEqual(value["ok"] as? Bool, true)
                XCTAssertEqual(value["viewVersion"] as? Int, 2)
                XCTAssertEqual(value["unchanged"] as? Bool, true)
                XCTAssertNil(value["messages"])
                XCTAssertEqual(value["canSend"] as? Bool, true)
                print("Real desktop warm reopen: \(data.count) → \(short.count) bytes, same owner subscription reused")
                warm.fulfill()
            }
        }
        wait(for: [retry, warm], timeout: 3)
        guard ProcessInfo.processInfo.environment["VIBEPIER_CODEX_NOOP_MODEL_THREAD"] == thread else { return }
        let settingsReady = expectation(description: "same-model bridge returns confirmed composer")
        bridge.perform(request, client: client) { data in
            let page = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let selection = page["composer"] as? [String: Any] ?? [:]
            print(
                "Initial page payload: \(data.count) bytes; model settings probe begins locked: \(ScreenLock.locked())")
            guard let model = selection["model"] as? String, let effort = selection["effort"] as? String,
                let change = try? JSONSerialization.data(withJSONObject: [
                    "op": "settings", "id": UUID().uuidString, "threadId": thread, "viewVersion": 1, "model": model,
                    "effort": effort,
                ])
            else {
                XCTFail("No current model to validate")
                settingsReady.fulfill()
                return
            }
            bridge.perform(change, client: client) { result in
                let receipt = (try? JSONSerialization.jsonObject(with: result) as? [String: Any]) ?? [:]
                XCTAssertEqual(receipt["accepted"] as? Bool, true, "\(receipt["error"] ?? "No receipt")")
                let composer = receipt["composer"] as? [String: Any]
                XCTAssertEqual(composer?["model"] as? String, model)
                XCTAssertEqual(composer?["effort"] as? String, effort)
                settingsReady.fulfill()
            }
        }
        wait(for: [settingsReady], timeout: 30)
    }
    func testUserFormReplyShowsAnswerInsteadOfTransportJSON() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            ["questionItemId": "private-id", "question": "消息显示了吗？", "answer": "已经显示消息"]
        ])
        let raw =
            "<send_user_message_question_reply>\n" + String(decoding: payload, as: UTF8.self)
            + "\n</send_user_message_question_reply>"
        XCTAssertEqual(CodexConversation.displayText(raw), "> 消息显示了吗？\n\n已经显示消息")
        XCTAssertEqual(
            CodexConversation.displayText(
                "<external_codex_apps_open_page>{\"page_id\":null}</external_codex_apps_open_page>\n正文"), "正文")
        XCTAssertEqual(
            CodexConversation.displayText(
                "<external_codex_apps_open_page>{\"page_id\":null}</external_codex_apps_open_page>"), "")
        XCTAssertEqual(CodexConversation.displayText("```xml\n" + raw + "\n```"), "```xml\n" + raw + "\n```")
        let messages = CodexConversation.messages([
            "items": [["id": "answer", "type": "userMessage", "content": [["type": "text", "text": raw]]]]
        ])
        XCTAssertEqual(messages.first?["text"] as? String, "> 消息显示了吗？\n\n已经显示消息")
    }
    func testDesktopReadOnlySubscriptionWhenExplicitlyRequested() throws {
        guard let thread = ProcessInfo.processInfo.environment["VIBEPIER_CODEX_READ_THREAD"] else {
            throw XCTSkip("Live desktop probe is opt-in")
        }
        final class Result: @unchecked Sendable {
            let lock = NSLock()
            var data: Data?
            func take(_ value: Data) -> Bool {
                lock.withLock {
                    if data != nil { return false }
                    data = value
                    return true
                }
            }
        }
        let result = Result()
        let ready = expectation(description: "desktop snapshot")
        let ipc = CodexIPC()
        try ipc.connect()
        defer { ipc.close() }
        let reply = try ipc.request(
            "thread-owner-discovery", ["hostId": "local", "conversationId": thread], version: 1)
        let owner = try XCTUnwrap(reply["handledByClientId"] as? String)
        ipc.broadcast = { data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["method"] as? String == "thread-stream-state-changed",
                let params = object["params"] as? [String: Any], params["conversationId"] as? String == thread,
                (params["change"] as? [String: Any])?["type"] as? String == "snapshot"
            else { return }
            if result.take(data) { ready.fulfill() }
        }
        try ipc.follow(thread, owner: owner, on: true)
        wait(for: [ready], timeout: 8)
        try ipc.follow(thread, owner: owner, on: false)
        let data = try XCTUnwrap(result.lock.withLock { result.data })
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let state =
            ((object["params"] as! [String: Any])["change"] as! [String: Any])["conversationState"] as! [String: Any]
        XCTAssertEqual(state["id"] as? String, thread)
        XCTAssertFalse((CodexConversation.page(state)["messages"] as! [Any]).isEmpty)
    }
    func testDesktopSameModelSettingsWhenExplicitlyRequested() throws {
        guard let thread = ProcessInfo.processInfo.environment["VIBEPIER_CODEX_NOOP_MODEL_THREAD"] else {
            throw XCTSkip("Desktop same-model update is opt-in")
        }
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var value: [String: Any]?
        }
        let state = State()
        let ready = expectation(description: "current settings")
        let ipc = CodexIPC()
        try ipc.connect()
        defer { ipc.close() }
        let discovery = try ipc.request(
            "thread-owner-discovery", ["hostId": "local", "conversationId": thread], version: 1)
        let owner = try XCTUnwrap(discovery["handledByClientId"] as? String)
        ipc.broadcast = { data in
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let params = value["params"] as? [String: Any], params["conversationId"] as? String == thread,
                let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
                let snapshot = change["conversationState"] as? [String: Any]
            else { return }
            state.lock.withLock {
                if state.value == nil {
                    state.value = snapshot
                    ready.fulfill()
                }
            }
        }
        try ipc.follow(thread, owner: owner, on: true)
        defer { try? ipc.follow(thread, owner: owner, on: false) }
        wait(for: [ready], timeout: 8)
        let current = try XCTUnwrap(state.lock.withLock { state.value })
        let selection = CodexComposer.selection(current)
        let settings = try CodexComposer().settings(
            ["model": try XCTUnwrap(selection["model"]), "effort": try XCTUnwrap(selection["effort"])], state: current)
        // No permission or model change: validate the installed owner's settings interface only.
        let response = try ipc.request(
            "thread-follower-update-thread-settings", ["conversationId": thread, "threadSettings": settings],
            version: 2, target: owner)
        XCTAssertEqual((response["result"] as? [String: Any])?["applied"] as? Bool, true)
    }
    func testAuthenticatedEnvelopeBindsDeviceDirectionAndPacket() throws {
        let key = Data(repeating: 7, count: 32)
        let text = Data("手机回复".utf8)
        let sealed = try SessionEnvelope.seal(text, key: key, device: "phone-a", packet: "packet-a", direction: "phone")
        XCTAssertEqual(
            try SessionEnvelope.open(sealed, key: key, device: "phone-a", packet: "packet-a", direction: "phone"), text)
        for (device, packet, direction) in [
            ("phone-b", "packet-a", "phone"), ("phone-a", "packet-b", "phone"), ("phone-a", "packet-a", "mac"),
        ] {
            XCTAssertThrowsError(
                try SessionEnvelope.open(sealed, key: key, device: device, packet: packet, direction: direction))
        }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(
            try SessionEnvelope.open(tampered, key: key, device: "phone-a", packet: "packet-a", direction: "phone"))
    }
    func testChunkFramesFitLegacyTransportAndReassemble() throws {
        let source = Data(repeating: 255, count: 28_000)
        let frames = SessionEnvelope.frames(source, device: "phone", packet: "packet", sender: "sender")
        let objects = try frames.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        XCTAssertTrue(frames.allSatisfy { $0.count < 1200 })
        XCTAssertEqual(objects.map { $0["part"] as! Int }, Array(0..<frames.count))
        XCTAssertEqual(Data(base64Encoded: objects.map { $0["data"] as! String }.joined()), source)
    }
    func testHistoryProjectionGroupsTurnIntoOneReplyWithEverySteps() throws {
        let state: [String: Any] = [
            "id": "thread",
            "turnHistory": [
                "history": [
                    "entitiesByKey": [
                        "turn-a": [
                            "turnId": "turn-a", "status": "completed",
                            "items": [
                                [
                                    "id": "u", "type": "userMessage", "clientId": "op",
                                    "content": [
                                        ["type": "text", "text": "hello"],
                                        ["type": "localImage", "path": "/tmp/shot.png"],
                                    ],
                                ],
                                ["id": "r", "type": "reasoning", "summary": [], "content": "看一下目录"],
                                ["id": "a1", "type": "agentMessage", "text": "先列文件"],
                                [
                                    "id": "c", "type": "commandExecution", "command": "ls", "cwd": "/repo",
                                    "status": "completed", "exitCode": 1, "durationMs": 20,
                                    "aggregatedOutput": "no such file",
                                ],
                                [
                                    "id": "f", "type": "fileChange", "status": "completed",
                                    "changes": [
                                        [
                                            "path": "a.swift", "kind": ["type": "update"],
                                            "diff": "@@\n-old\n+new\n+more",
                                        ]
                                    ],
                                ],
                                [
                                    "id": "m", "type": "mcpToolCall", "server": "docs", "tool": "search",
                                    "arguments": ["q": "x"], "status": "completed",
                                    "result": ["content": [["type": "text", "text": "found"]]],
                                ],
                                ["id": "h", "type": "hookPrompt", "fragments": []],
                                ["id": "v", "type": "imageView", "path": "/repo/ui.png"],
                                ["id": "a2", "type": "agentMessage", "text": "reply"],
                            ],
                        ]
                    ], "islands": [["entries": [["value": "turn-a"]]]],
                ]
            ],
        ]
        let page = CodexConversation.page(state)
        let messages = try XCTUnwrap(page["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant"], "one reply per message")
        XCTAssertEqual(messages.first?["clientId"] as? String, "op")
        XCTAssertEqual(messages.first?["text"] as? String, "hello")
        XCTAssertEqual((messages.first?["images"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["u#0"])
        let reply = messages[1]
        XCTAssertEqual(reply["id"] as? String, "reply-u")
        XCTAssertEqual(reply["text"] as? String, "先列文件\n\nreply")
        XCTAssertNil(reply["parts"])
        XCTAssertEqual(reply["partsDeferred"] as? Bool, true)
        let steps = try XCTUnwrap(
            ConversationReply.partPage(
                CodexConversation.turns(state).flatMap(CodexConversation.messages), id: "reply-u", offset: 0))
        let parts = try XCTUnwrap(steps["parts"] as? [[String: Any]])
        XCTAssertEqual(
            parts.compactMap { $0["kind"] as? String }, ["thinking", "text", "command", "file", "tool", "tool", "text"])
        XCTAssertEqual((parts[5]["images"] as? [[String: Any]])?.first?["id"] as? String, "v#0")
        XCTAssertEqual(parts[2]["title"] as? String, "ls")
        XCTAssertEqual(parts[2]["text"] as? String, "no such file")
        XCTAssertEqual(parts[2]["status"] as? String, "failed")
        XCTAssertEqual(parts[2]["exitCode"] as? Int, 1)
        XCTAssertEqual(parts[3]["added"] as? Int, 2)
        XCTAssertEqual(parts[3]["removed"] as? Int, 1)
        XCTAssertTrue((parts[3]["text"] as? String ?? "").hasPrefix("*** update a.swift\n"))
        XCTAssertEqual(parts[4]["title"] as? String, "docs · search")
        XCTAssertTrue((parts[4]["text"] as? String ?? "").contains("found"))
        let all = CodexConversation.turns(state).flatMap(CodexConversation.messages)
        XCTAssertEqual(ConversationReply.fullText(all, id: "c"), "no such file")
        XCTAssertEqual(ConversationReply.fullText(all, id: "reply-u"), "先列文件\n\nreply")
        XCTAssertEqual(ConversationReply.image(all, id: "u#0"), "/tmp/shot.png")
        XCTAssertEqual(ConversationReply.image(all, id: "v#0"), "/repo/ui.png")
    }
    func testBoundedPageTrimsToolOutputAndKeepsFullTextOnDemand() throws {
        // Long Chinese commands in a long run: titles and folders alone used to pass the 300 KB transport limit.
        let items: [[String: Any]] =
            [["id": "u", "type": "userMessage", "content": [["type": "text", "text": "跑测试"]]]]
            + (0..<600).map {
                [
                    "id": "c\($0)", "type": "commandExecution",
                    "command": "echo " + String(repeating: "中文命令", count: 200),
                    "cwd": "/Users/demo/Documents/code/一个很长的项目目录",
                    "status": "completed", "exitCode": 0, "aggregatedOutput": String(repeating: "输出", count: 20_000),
                ]
            }
        let state: [String: Any] = ["turns": [["turnId": "t", "status": "inProgress", "items": items]]]
        let page = CodexConversation.page(state)
        XCTAssertLessThan(
            try JSONSerialization.data(withJSONObject: page).count, 13_000,
            "only the newest eight headers, never their output, enter the first page")
        let reply = try XCTUnwrap((page["messages"] as? [[String: Any]])?.last)
        XCTAssertEqual(reply["status"] as? String, "running")
        XCTAssertNil(reply["parts"])
        XCTAssertEqual(reply["partCount"] as? Int, 600)
        let latest = try XCTUnwrap(reply["sequence"] as? [[String: Any]])
        XCTAssertEqual(latest.compactMap { $0["index"] as? Int }, Array(592..<600))
        XCTAssertTrue(latest.allSatisfy { ($0["text"] as? String ?? "").isEmpty })
        let steps = try XCTUnwrap(
            ConversationReply.partPage(
                CodexConversation.turns(state).flatMap(CodexConversation.messages), id: reply["id"] as? String ?? "",
                offset: 0))
        let parts = try XCTUnwrap(steps["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 8)
        XCTAssertEqual(steps["nextOffset"] as? Int, 8)
        XCTAssertTrue(parts.allSatisfy { $0["hasMore"] as? Bool == true })
        XCTAssertEqual(
            ConversationReply.fullText(CodexConversation.messages(["items": items]), id: "c7")?.count, 40_000)
    }
    func testPatchesAreAppliedWithoutMutatingOldState() throws {
        let old: [String: Any] = ["items": [["text": "a"], ["text": "b"]]]
        let updated =
            try CodexConversation.patch(old, path: ["items", 1, "text"][...], operation: "replace", value: "c")
            as! [String: Any]
        XCTAssertEqual((updated["items"] as? [[String: String]])?.last?["text"], "c")
        XCTAssertEqual((old["items"] as? [[String: String]])?.last?["text"], "b")
        XCTAssertThrowsError(
            try CodexConversation.patch(old, path: ["items", 9][...], operation: "remove", value: nil))
    }
    func testApprovalCannotAuthorizeUnknownOrIncompletePayloadAndChangesInvalidateFingerprint() throws {
        let request: [String: Any] = [
            "id": 1, "method": "item/fileChange/requestApproval", "params": ["itemId": "file", "reason": "edit"],
        ]
        let incomplete: [String: Any] = ["requests": [request]]
        XCTAssertEqual(CodexConversation.approvals(incomplete).first?["canDecide"] as? Bool, false)
        func state(_ change: String) -> [String: Any] {
            [
                "requests": [request],
                "turns": [
                    [
                        "items": [
                            [
                                "id": "file", "type": "fileChange",
                                "changes": [["path": change, "diff": "+line", "kind": "update"]],
                            ]
                        ]
                    ]
                ],
            ]
        }
        let a = CodexConversation.approvals(state("a.swift"))[0]
        let b = CodexConversation.approvals(state("b.swift"))[0]
        XCTAssertEqual(a["canDecide"] as? Bool, true)
        XCTAssertNotEqual(a["fingerprint"] as? String, b["fingerprint"] as? String)
        XCTAssertEqual(
            CodexConversation.approvals(["requests": [["id": 2, "method": "unknown", "params": [:]]]]).first?[
                "canDecide"] as? Bool, false)
    }
    func testReadOnlyThreadListSortSearchAndIsolation() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-index-\(UUID().uuidString).sqlite"
        ).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema =
            "CREATE TABLE threads (id TEXT, name TEXT, title TEXT, cwd TEXT, is_pinned INT, recency_at_ms INT, archived INT, has_user_event INT, agent_path TEXT, source TEXT, originator TEXT, rollout_path TEXT, updated_at_ms INT)"
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for (id, pinned, archived, source, originator) in [
            ("a", 0, 0, "vscode", "Codex Desktop"), ("b", 1, 0, "vscode", "Codex Desktop"),
            ("c", 0, 1, "vscode", "Codex Desktop"), ("d", 0, 0, "subagent", "Codex Desktop"),
            ("e", 0, 0, "vscode", "other_app"),
        ] {
            XCTAssertEqual(
                sqlite3_exec(
                    db,
                    "INSERT INTO threads VALUES ('\(id)', '\(id)', 'title', '/repo', \(pinned), 10, \(archived), 0, NULL, '\(source)', '\(originator)', '', 0)",
                    nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET name='' WHERE id='a'", nil, nil, nil), SQLITE_OK)
        let store = CodexThreadStore(path: path)
        let rows = try store.list(search: "", offset: 0)["threads"] as! [[String: Any]]
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["b", "a"])
        let first = try store.list(search: "", offset: 0, limit: 1)
        XCTAssertEqual(first["nextOffset"] as? Int, 1)
        XCTAssertEqual((first["threads"] as? [[String: Any]])?.first?["id"] as? String, "b")
        XCTAssertEqual(
            (try store.list(search: "", offset: 1, limit: 1)["threads"] as? [[String: Any]])?.first?["id"] as? String,
            "a")
        XCTAssertEqual((try store.list(search: "%", offset: 0)["threads"] as! [Any]).count, 0)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "INSERT INTO threads VALUES ('f', 'f', 'title', '/other/app', 0, 20, 0, 0, NULL, 'cli', NULL, '', 0)",
                nil, nil, nil), SQLITE_OK)
        let projects = try store.projects(search: "")["projects"] as! [[String: Any]]
        XCTAssertEqual(
            projects.compactMap { $0["cwd"] as? String }, ["/other/app", "/repo"], "hidden threads do not count")
        XCTAssertEqual(projects.compactMap { $0["count"] as? Int64 }, [1, 2])
        XCTAssertEqual(projects.first?["project"] as? String, "app")
        XCTAssertEqual(try store.projects(search: "", limit: 1)["nextOffset"] as? Int, 1)
        XCTAssertEqual(
            (try store.projects(search: "", offset: 1, limit: 1)["projects"] as? [[String: Any]])?.first?["cwd"]
                as? String, "/repo")
        let scoped = try store.list(search: "", offset: 0, cwd: "/repo")["threads"] as! [[String: Any]]
        XCTAssertEqual(scoped.compactMap { $0["id"] as? String }, ["b", "a"])
        XCTAssertEqual((try store.projects(search: "other")["projects"] as! [Any]).count, 1)
        XCTAssertEqual(
            (try store.list(search: "title", offset: 0)["threads"] as! [[String: Any]]).compactMap {
                $0["id"] as? String
            }, ["a"])
    }
    func testClosedWALIndexStillLists() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-wal-\(UUID().uuidString).sqlite"
        ).path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "PRAGMA journal_mode=WAL; CREATE TABLE threads (id TEXT, name TEXT, title TEXT, cwd TEXT, is_pinned INT, recency_at_ms INT, archived INT, agent_path TEXT, source TEXT, originator TEXT, rollout_path TEXT); INSERT INTO threads VALUES ('a', 'a', 't', '/repo', 0, 1, 0, NULL, 'cli', NULL, '')",
                nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        // Codex leaves a closed index without -wal/-shm; Apple's SQLite keeps them, so remove them by hand.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let rows = try CodexThreadStore(path: path).list(search: "", offset: 0)["threads"] as! [[String: Any]]
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["a"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "the fallback connection never writes")
    }
    func testRolloutTailTellsWhetherATurnIsRunning() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }
        func line(_ type: String) -> String { #"{"type":"event_msg","payload":{"type":"\#(type)"}}"# + "\n" }
        let filler = String(repeating: #"{"type":"response_item","payload":{"type":"reasoning"}}"# + "\n", count: 8000)
        try (line("task_started") + line("task_complete") + line("task_started") + filler).write(
            toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(
            CodexThreadStore.running(rollout: path, now: Date()), "a marker beyond the first tail window is still found"
        )
        XCTAssertFalse(
            CodexThreadStore.running(rollout: path, now: Date().addingTimeInterval(3600)),
            "an untouched rollout is a dead turn")
        try (line("task_started") + filler + line("turn_aborted")).write(
            toFile: path, atomically: true, encoding: .utf8)
        XCTAssertFalse(CodexThreadStore.running(rollout: path, now: Date()))
        XCTAssertFalse(CodexThreadStore.running(rollout: "", now: Date()))
    }
}
