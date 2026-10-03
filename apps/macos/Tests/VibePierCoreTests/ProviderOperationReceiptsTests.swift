import XCTest

@testable import VibePierCore

final class ProviderOperationReceiptsTests: XCTestCase {
    func testCachedReceiptBypassesBlockedProviderWithoutReadingUnknownEvidence() throws {
        let cache = ProviderOperationReceipts()
        let ticket = try begin(cache, request())
        try cache.observe(ticket, bytes: 100) {
            XCTFail("Fast receipt lookup must not run a native observer")
            return nil
        }
        cache.arm(ticket)
        let original = try JSONSerialization.data(withJSONObject: request())
        let replay = try XCTUnwrap(cache.cachedReply(original, client: "phone", provider: "claude"))
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: replay) as? [String: Any])?["unknown"] as? Bool, true)
        var changed = request()
        changed["text"] = "different"
        let conflict = try XCTUnwrap(
            cache.cachedReply(
                JSONSerialization.data(withJSONObject: changed), client: "phone", provider: "claude"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: conflict) as? [String: Any])?["ok"] as? Bool, false)
        func query(_ changes: [String: Any] = [:], client: String = "phone") throws -> Data? {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "op": "receiptCheck", "operation": "operation", "threadId": "thread",
                ].merging(changes) { _, new in new })
            return cache.cachedReply(data, client: client, provider: "claude")
        }
        XCTAssertNil(try query())
        cache.finish(ticket, result: ["ok": true, "accepted": true, "threadId": "thread"])
        let data = try XCTUnwrap(query())
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["accepted"] as? Bool, true)
        XCTAssertEqual(result["provider"] as? String, "claude")
        XCTAssertNil(try query(client: "other-phone"))
        XCTAssertNil(try query(["threadId": "other-thread"]))
        XCTAssertNil(try query(["originalOperation": "settings"]))
        XCTAssertNil(try query(["op": "send"]))
        XCTAssertNil(try query(["operation": "other-operation"]))
    }

    private func request(_ id: String = "operation", op: String = "send", thread: String = "thread") -> [String: Any] {
        ["id": id, "op": op, "threadId": thread, "cwd": "/demo", "text": "hello", "fingerprint": "approval"]
    }
    private func begin(_ cache: ProviderOperationReceipts, _ request: [String: Any], client: String = "phone") throws
        -> ProviderOperationReceipts.Ticket
    {
        guard case .fresh(let ticket) = try cache.begin(request, client: client) else {
            throw CLIError("Expected a fresh synthetic operation")
        }
        return ticket
    }
    private func known(_ cache: ProviderOperationReceipts, _ request: [String: Any], client: String = "phone") throws
        -> [String: Any]
    {
        guard case .cached(let cached) = try cache.begin(request, client: client) else {
            throw CLIError("An existing operation must never run again")
        }
        return cached
    }

    func testPendingReplayConflictAndTrustedClientIsolation() throws {
        let cache = ProviderOperationReceipts()
        let a = try begin(cache, request(), client: "phone-a")
        XCTAssertEqual(try known(cache, request(), client: "phone-a")["unknown"] as? Bool, true)
        let b = try begin(cache, request(), client: "phone-b")
        cache.finish(a, result: ["ok": true, "accepted": true, "threadId": "thread"])
        XCTAssertEqual(try known(cache, request(), client: "phone-a")["accepted"] as? Bool, true)
        XCTAssertEqual(try known(cache, request(), client: "phone-b")["unknown"] as? Bool, true)
        XCTAssertNotEqual(a.key, b.key)
        var changed = request()
        changed["text"] = "different"
        XCTAssertThrowsError(try cache.begin(changed, client: "phone-a"))
        XCTAssertThrowsError(try cache.begin(request(thread: "other"), client: "phone-a"))
        XCTAssertThrowsError(try cache.begin(request(op: "settings"), client: "phone-a"))
    }

    func testQueriesCannotBorrowAnotherSessionOrOperationKind() throws {
        let cache = ProviderOperationReceipts()
        let ticket = try begin(cache, request(op: "approve"))
        cache.finish(ticket, result: ["ok": true, "submitted": true, "threadId": "thread", "fingerprint": "approval"])
        for (client, operation, thread, kind) in [
            ("other", "operation", "thread", "approve"),
            ("phone", "other", "thread", "approve"), ("phone", "operation", "other", "approve"),
            ("phone", "operation", "thread", "send"),
        ] {
            XCTAssertEqual(
                cache.lookup(client: client, operation: operation, thread: thread, kind: kind)["unknown"] as? Bool, true
            )
        }
        XCTAssertEqual(
            cache.lookup(client: "phone", operation: "operation", thread: "thread", kind: "approve")["submitted"]
                as? Bool, true)
    }

    func testCapacityRefusesNewWorkWithoutEvictingUncertainIdentity() throws {
        let cache = ProviderOperationReceipts(
            limits: .init(records: 3, recordsPerClient: 2, bytes: 10_000, bytesPerClient: 8_000))
        _ = try begin(cache, request("one"))
        _ = try begin(cache, request("two"))
        XCTAssertThrowsError(try cache.begin(request("three"), client: "phone"))
        _ = try begin(cache, request("three"), client: "other")
        XCTAssertThrowsError(try cache.begin(request("four"), client: "third"))
        for id in ["one", "two"] { XCTAssertEqual(try known(cache, request(id))["unknown"] as? Bool, true) }
    }

    func testCompletedBodyRetirementKeepsFingerprintAndCannotRunOrOverwriteAgain() throws {
        let cache = ProviderOperationReceipts(
            limits: .init(records: 10, recordsPerClient: 10, bytes: 3000, bytesPerClient: 3000))
        let first = try begin(cache, request("one"))
        cache.finish(
            first,
            result: ["ok": true, "accepted": true, "threadId": "thread", "detail": String(repeating: "x", count: 1900)])
        _ = try begin(cache, request("two"))
        _ = try begin(cache, request("three"))
        let retired = try known(cache, request("one"))
        XCTAssertEqual(retired["retired"] as? Bool, true)
        XCTAssertEqual(retired["unknown"] as? Bool, true)
        XCTAssertEqual(cache.finish(first, result: ["ok": false, "error": "late failure"])["retired"] as? Bool, true)
        var collision = request("one")
        collision["text"] = "reused"
        XCTAssertThrowsError(try cache.begin(collision, client: "phone"))
    }

    func testMalformedRepliesStayUnknownAndFirstDefinitiveOutcomeIsImmutable() throws {
        let cache = ProviderOperationReceipts()
        let ticket = try begin(cache, request())
        XCTAssertEqual(
            cache.finish(ticket, result: ["ok": true, "accepted": true, "threadId": "other"])["unknown"] as? Bool, true)
        cache.finish(ticket, result: ["ok": true, "accepted": true, "threadId": "thread"])
        XCTAssertEqual(cache.finish(ticket, result: ["ok": false, "error": "later"])["ok"] as? Bool, true)
    }

    private final class Observer: @unchecked Sendable {
        private let lock = NSLock()
        private var available = false
        private var count = 0
        func ready() { lock.withLock { available = true } }
        var calls: Int { lock.withLock { count } }
        func read() -> [String: Any]? {
            lock.withLock {
                count += 1
                return available
                    ? [
                        "ok": true, "accepted": true, "threadId": "new-native", "cwd": "/demo",
                        "nativeMessageId": "message",
                    ] : nil
            }
        }
    }

    func testLateCreationObserverIsReadOnlyArmedAfterSubmitAndBoundToPhone() throws {
        let cache = ProviderOperationReceipts()
        let ticket = try begin(cache, request(op: "new", thread: ""))
        let observer = Observer()
        try cache.observe(ticket, bytes: 2000) { observer.read() }
        observer.ready()
        XCTAssertEqual(
            cache.lookup(client: "phone", operation: "operation", thread: "", kind: "new")["unknown"] as? Bool, true)
        XCTAssertEqual(observer.calls, 0)
        cache.arm(ticket)
        _ = cache.lookup(client: "other", operation: "operation", thread: "", kind: "new")
        XCTAssertEqual(observer.calls, 0)
        cache.finish(ticket, result: ["ok": false, "unknown": true])
        let receipt = cache.lookup(client: "phone", operation: "operation", thread: "", kind: "new")
        XCTAssertEqual(receipt["threadId"] as? String, "new-native")
        XCTAssertEqual(try known(cache, request(op: "new", thread: ""))["cwd"] as? String, "/demo")
        _ = cache.lookup(client: "phone", operation: "operation", thread: "", kind: "new")
        XCTAssertEqual(observer.calls, 1, "Completed receipts no longer retain or run an observer")
    }

    func testObserverMemoryIsReservedBeforeNativeActionAndReleasedOnConfirmation() throws {
        let cache = ProviderOperationReceipts(
            limits: .init(records: 10, recordsPerClient: 10, bytes: 4000, bytesPerClient: 4000))
        let ticket = try begin(cache, request(op: "new", thread: ""))
        XCTAssertThrowsError(
            try cache.observe(ticket, bytes: 5000) {
                XCTFail()
                return nil
            })
        try cache.observe(ticket, bytes: 3000) { nil }
        XCTAssertThrowsError(try cache.begin(request("large"), client: "phone"))
        cache.finish(ticket, result: ["ok": true, "threadId": "created", "cwd": "/demo"])
        _ = try begin(cache, request("after-confirmation"))
    }
}
