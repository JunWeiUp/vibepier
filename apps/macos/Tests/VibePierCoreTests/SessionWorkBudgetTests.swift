import Foundation
import XCTest

@testable import VibePierCore

final class SessionWorkBudgetTests: XCTestCase {
    func testStuckProviderCannotConsumeOtherProvidersOrReceiptCapacity() throws {
        let budget = SessionWorkBudget(lanes: SessionRequestLane.limits)
        var blocked: [UUID] = []
        for phone in 0..<4 {
            for index in 0..<3 {
                blocked.append(
                    try token(
                        budget.begin(device: "phone-\(phone)", id: "codex-\(index)", bytes: 128 * 1024, lane: "codex")))
            }
        }
        full(budget.begin(device: "phone-0", id: "extra", bytes: 1, lane: "codex"))
        full(budget.begin(device: "phone-5", id: "extra", bytes: 1, lane: "codex"))
        for lane in SessionRequestLane.allCases where lane != .codex {
            _ = try token(budget.begin(device: "phone-0", id: lane.rawValue, bytes: 100, lane: lane.rawValue))
        }
        full(budget.begin(device: "phone-0", id: "another-receipt", bytes: 1, lane: "codexReceipt"))
        // Consuming the reply does not release capacity until the underlying request finishes.
        XCTAssertTrue(budget.claimCompletion(blocked[0]))
        full(budget.begin(device: "phone-0", id: "extra", bytes: 1, lane: "codex"))
        XCTAssertTrue(budget.finish(blocked[0]))
        _ = try token(budget.begin(device: "phone-0", id: "recovered", bytes: 128 * 1024, lane: "codex"))
    }

    func testPartitionByteQuotasCannotStarveOtherLanesAndKeepOriginalGlobalBounds() throws {
        let rules = SessionRequestLane.limits
        XCTAssertLessThanOrEqual(rules.values.reduce(0) { $0 + $1.perDevice }, 16)
        XCTAssertLessThanOrEqual(rules.values.reduce(0) { $0 + $1.total }, 64)
        XCTAssertLessThanOrEqual(rules.values.reduce(0) { $0 + $1.bytesPerDevice }, 2 * 1024 * 1024)
        XCTAssertLessThanOrEqual(rules.values.reduce(0) { $0 + $1.bytesTotal }, 8 * 1024 * 1024)
        let budget = SessionWorkBudget(lanes: rules)
        for lane in SessionRequestLane.allCases {
            let bytes = try XCTUnwrap(rules[lane.rawValue]?.bytesPerDevice)
            _ = try token(budget.begin(device: "phone", id: lane.rawValue, bytes: bytes, lane: lane.rawValue))
            full(budget.begin(device: "phone", id: lane.rawValue + "-overflow", bytes: 1, lane: lane.rawValue))
        }
        full(budget.begin(device: "other", id: "spoofed", bytes: 1, lane: "phone-chosen-lane"))
    }

    func testLaneComesFromKnownOperationAndProviderNeverCallerPriority() {
        XCTAssertEqual(SessionRequestLane.resolve(["op": "send", "provider": "claude", "lane": "controls"]), "claude")
        XCTAssertEqual(
            SessionRequestLane.resolve(["op": "receiptCheck", "provider": "claude"], receipt: true), "claudeReceipt")
        XCTAssertEqual(SessionRequestLane.resolve(["op": "codexUsage", "provider": "claude"]), "account")
        XCTAssertEqual(SessionRequestLane.resolve(["op": "codexUsageResetReceipt"], receipt: true), "accountReceipt")
        XCTAssertEqual(SessionRequestLane.resolve(["op": "appUsage"]), "controls")
        XCTAssertEqual(SessionRequestLane.resolve(["op": "open"]), "codex")
    }

    private func token(_ value: SessionWorkBudget.Admission, file: StaticString = #filePath, line: UInt = #line) throws
        -> UUID
    {
        guard case .accepted(let token) = value else {
            XCTFail("Admission denied", file: file, line: line)
            throw POSIXError(.EBUSY)
        }
        return token
    }
    private func full(_ value: SessionWorkBudget.Admission, file: StaticString = #filePath, line: UInt = #line) {
        guard case .full = value else { return XCTFail("Capacity should be full", file: file, line: line) }
    }

    func testPerDeviceAndGlobalCapacityPreserveOtherPhones() throws {
        let budget = SessionWorkBudget(limits: .init(perDevice: 1, total: 2, bytesPerDevice: 10, bytesTotal: 20))
        let first = try token(budget.begin(device: "a", id: "1", bytes: 10))
        full(budget.begin(device: "a", id: "2", bytes: 1))
        let second = try token(budget.begin(device: "b", id: "1", bytes: 10))
        full(budget.begin(device: "c", id: "1", bytes: 1))
        XCTAssertTrue(budget.finish(first))
        _ = try token(budget.begin(device: "c", id: "1", bytes: 1))
        XCTAssertTrue(budget.finish(second))
    }

    func testByteBoundsDuplicateRequestAndFirstCompletionOwnTheLease() throws {
        let budget = SessionWorkBudget(limits: .init(perDevice: 4, total: 8, bytesPerDevice: 10, bytesTotal: 15))
        let first = try token(budget.begin(device: "a", id: "1", bytes: 8))
        full(budget.begin(device: "a", id: "2", bytes: 3))
        full(budget.begin(device: "b", id: "1", bytes: 8))
        full(budget.begin(device: "b", id: "1", bytes: -1))
        full(budget.begin(device: "b", id: "1", bytes: Int.max))
        guard case .duplicate = budget.begin(device: "a", id: "1", bytes: 1) else {
            return XCTFail("Duplicated work admitted")
        }
        XCTAssertTrue(budget.claimCompletion(first))
        XCTAssertFalse(budget.claimCompletion(first))
        full(budget.begin(device: "a", id: "2", bytes: 3))  // Completion is queued, not consumed.
        XCTAssertTrue(budget.finish(first))
        let replacement = try token(budget.begin(device: "a", id: "1", bytes: 10))
        XCTAssertFalse(budget.finish(first))
        full(budget.begin(device: "a", id: "3", bytes: 1))
        XCTAssertTrue(budget.finish(replacement))
    }

    func testPasswordVerificationIsExclusiveWithoutBlockingOtherWork() throws {
        let budget = SessionWorkBudget()
        let first = try token(budget.begin(device: "a", id: "password", bytes: 100, exclusive: "password"))
        full(budget.begin(device: "b", id: "password", bytes: 100, exclusive: "password"))
        _ = try token(budget.begin(device: "b", id: "read", bytes: 100))
        budget.finish(first)
        _ = try token(budget.begin(device: "b", id: "password", bytes: 100, exclusive: "password"))
    }

    func testConcurrentIngressAdmissionCannotExceedCapacity() {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var tokens: [UUID] = []
            func add(_ token: UUID) { lock.withLock { tokens.append(token) } }
        }
        let budget = SessionWorkBudget(limits: .init(perDevice: 4, total: 4, bytesPerDevice: 40, bytesTotal: 40))
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if case .accepted(let token) = budget.begin(device: "phone", id: String(index), bytes: 10) {
                results.add(token)
            }
        }
        XCTAssertEqual(results.tokens.count, 4)
        for token in results.tokens { XCTAssertTrue(budget.finish(token)) }
        XCTAssertNoThrow(try self.token(budget.begin(device: "phone", id: "new", bytes: 40)))
    }

    func testReplyCachePendingEntriesSurviveAgeAndSaturation() {
        var cache = SessionReadReplies(limits: .init(perDevice: 1, total: 2, bytesPerDevice: 10, bytesTotal: 20))
        XCTAssertTrue(cache.reserve("a:1", device: "a", hash: "first", now: 0))
        XCTAssertFalse(cache.reserve("a:2", device: "a", hash: "second", now: 1))
        guard case .pending = cache.lookup("a:1", hash: "first", now: 1000) else {
            return XCTFail("Pending entry expired")
        }
        guard case .conflict = cache.lookup("a:1", hash: "other", now: 1000) else { return XCTFail("Fingerprint lost") }
        XCTAssertTrue(cache.reserve("b:1", device: "b", hash: "first", now: 1))
    }

    func testCompletedCacheBudgetsEvictOwnOldReplyBeforeAnotherPhone() {
        var cache = SessionReadReplies(limits: .init(perDevice: 2, total: 3, bytesPerDevice: 6, bytesTotal: 10))
        XCTAssertTrue(cache.reserve("a:1", device: "a", hash: "hash", now: 0))
        cache.complete("a:1", hash: "hash", result: Data(repeating: 1, count: 4))
        XCTAssertTrue(cache.reserve("b:1", device: "b", hash: "hash", now: 1))
        cache.complete("b:1", hash: "hash", result: Data(repeating: 2, count: 4))
        XCTAssertTrue(cache.reserve("a:2", device: "a", hash: "hash", now: 2))
        cache.complete("a:2", hash: "hash", result: Data(repeating: 3, count: 4))
        guard case .missing = cache.lookup("a:1", hash: "hash", now: 3) else {
            return XCTFail("Own oversized cache retained")
        }
        guard case .complete(let other) = cache.lookup("b:1", hash: "hash", now: 3) else {
            return XCTFail("Other phone evicted")
        }
        XCTAssertEqual(other, Data(repeating: 2, count: 4))
        XCTAssertTrue(cache.reserve("c:1", device: "c", hash: "hash", now: 3))
        cache.complete("c:1", hash: "hash", result: Data(repeating: 4, count: 4))
        guard case .missing = cache.lookup("b:1", hash: "hash", now: 4) else {
            return XCTFail("Global byte cap exceeded")
        }
    }

    func testOversizedOrStaleCachedCompletionCannotCorruptReplacement() {
        var cache = SessionReadReplies(limits: .init(perDevice: 2, total: 4, bytesPerDevice: 5, bytesTotal: 10))
        XCTAssertTrue(cache.reserve("a:1", device: "a", hash: "old", now: 0))
        cache.remove(device: "a")
        XCTAssertTrue(cache.reserve("a:1", device: "a", hash: "new", now: 1))
        cache.abandon("a:1", hash: "old")
        cache.complete("a:1", hash: "old", result: Data("old".utf8))
        guard case .pending = cache.lookup("a:1", hash: "new", now: 2) else {
            return XCTFail("Stale completion replaced new request")
        }
        cache.complete("a:1", hash: "new", result: Data(repeating: 0, count: 6))
        guard case .missing = cache.lookup("a:1", hash: "new", now: 2) else {
            return XCTFail("Oversized reply retained")
        }
        XCTAssertTrue(cache.reserve("a:2", device: "a", hash: "hash", now: 0))
        cache.complete("a:2", hash: "hash", result: Data("ok".utf8))
        guard case .missing = cache.lookup("a:2", hash: "hash", now: 181) else {
            return XCTFail("Completed cache never expired")
        }
    }
    func testAbandonedAPKPreparationFreesOnlyMatchingPendingReply() {
        var cache = SessionReadReplies(limits: .init(perDevice: 1, total: 2, bytesPerDevice: 10, bytesTotal: 20))
        XCTAssertTrue(cache.reserve("phone:request", device: "phone", hash: "apk", now: 0))
        cache.abandon("phone:request", hash: "wrong")
        XCTAssertFalse(cache.reserve("phone:next", device: "phone", hash: "next", now: 1))
        cache.abandon("phone:request", hash: "apk")
        XCTAssertTrue(cache.reserve("phone:next", device: "phone", hash: "next", now: 1))
        cache.complete("phone:next", hash: "next", result: Data("ok".utf8))
        cache.abandon("phone:next", hash: "next")
        guard case .complete = cache.lookup("phone:next", hash: "next", now: 2) else {
            return XCTFail("Known result must remain idempotent")
        }
    }
}
