import XCTest

@testable import VibePierCore

final class TaskViewIntentTests: XCTestCase {
    func testOnlyExplicitOpenCreatesAnIntent() {
        XCTAssertNil(TaskViewIntent(["op": "sync", "threadId": "a", "viewVersion": 3]))
        XCTAssertNil(TaskViewIntent(["op": "open", "threadId": "a", "viewVersion": -1]))
        XCTAssertNil(TaskViewIntent(["op": "open", "threadId": "a", "viewVersion": 1, "provider": "other"]))
        XCTAssertEqual(TaskViewIntent(["op": "open", "threadId": "a", "viewVersion": 3])?.provider, "codex")
    }

    func testOnlyAvailableMatchingPageClearsTheIntendedConversation() throws {
        let intent = try XCTUnwrap(
            TaskViewIntent(["op": "open", "threadId": "same-id", "viewVersion": 3, "provider": "claude"]))
        let page: [String: Any] = ["threadId": "same-id", "viewVersion": 3, "messages": [[String: Any]](), "ok": true]
        XCTAssertTrue(intent.isReady(page, provider: "claude"))
        XCTAssertFalse(intent.isReady(page, provider: "codex"))
        for change in [
            ["threadId": "other"], ["viewVersion": 2], ["opening": true], ["ok": false], ["error": "offline"],
            ["event": "delta"],
        ] as [[String: Any]] {
            XCTAssertFalse(intent.isReady(page.merging(change) { _, new in new }, provider: "claude"))
        }
        XCTAssertFalse(intent.isReady(["threadId": "same-id", "viewVersion": 3], provider: "claude"))
        let known = ConversationReply.versioned(page)["cacheVersion"] as? String
        let cached = ConversationReply.conditional(page, known: known)
        XCTAssertEqual(cached["unchanged"] as? Bool, true)
        XCTAssertTrue(intent.isReady(cached, provider: "claude"))
        XCTAssertTrue(intent.isReady(page.merging(["event": "snapshot"]) { _, new in new }, provider: "claude"))
    }

    func testOldReadyPageKeepsTheCapturedCompletionWhenANewTurnFinished() throws {
        var view = try XCTUnwrap(TaskViewIntent(["op": "open", "threadId": "a", "viewVersion": 3]))
        view.completion = "turn-a"
        var ledger = ConversationActivityLedger()
        ledger.observe(
            .init(provider: "codex", id: "a", title: "A", phase: .completed, completion: "turn-a", nativeUnread: true),
            baseline: true)
        ledger.observe(
            .init(provider: "codex", id: "a", title: "A", phase: .completed, completion: "turn-b", nativeUnread: true),
            baseline: false)
        let page: [String: Any] = ["threadId": "a", "viewVersion": 3, "messages": [[String: Any]]()]
        XCTAssertTrue(view.isReady(page, provider: "codex"))
        ledger.markViewed(provider: view.provider, id: view.id, completion: view.completion)
        XCTAssertEqual(ledger.entries["codex:a"]?.unread, "turn-b")
    }
}
