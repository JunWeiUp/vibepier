import Foundation
import XCTest

@testable import VibePierCore

final class SessionReceiptJournalTests: XCTestCase {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("receipts.json")
    }
    private func smallLimits() -> SessionReceiptJournal.Limits {
        .init(fileBytes: 4000, deviceBytes: 1000, payloadBytes: 300, activeRecords: 20, totalRecords: 40)
    }

    func testCompletedPayloadRetiresWithoutMakingIDFreshAgain() throws {
        let file = try file()
        var now = 1000.0
        let journal = try SessionReceiptJournal(file: file, clock: { now })
        _ = try journal.reserve("phone:done", hash: "original", thread: "thread", intent: Data("private prompt".utf8))
        try journal.complete("phone:done", result: Data("accepted".utf8))
        XCTAssertNil(journal.receipt("phone:done")?.intent)
        _ = try journal.reserve(
            "phone:unknown", hash: "unknown", thread: "thread", intent: Data("uncertain prompt".utf8))
        now += 8 * 86400
        _ = try journal.reserve("other:new", hash: "next", thread: "other")
        let restored = try SessionReceiptJournal(file: file, clock: { now })
        XCTAssertEqual(restored.receipt("phone:done")?.retired, true)
        XCTAssertNil(restored.receipt("phone:done")?.result)
        guard case .unknown = try restored.reserve("phone:done", hash: "original", thread: "thread") else {
            return XCTFail("Retired ID executed again")
        }
        guard case .conflict = try restored.reserve("phone:done", hash: "changed", thread: "thread") else {
            return XCTFail("Retired fingerprint lost")
        }
        guard case .unknown = try restored.reserve("phone:unknown", hash: "unknown", thread: "thread") else {
            return XCTFail("Unknown dropped")
        }
        // Aged unknown records release their prompt and quota but stay a never-executable tombstone.
        XCTAssertEqual(restored.receipt("phone:unknown")?.retired, true)
        XCTAssertNil(restored.receipt("phone:unknown")?.intent)
        guard case .conflict = try restored.reserve("phone:unknown", hash: "changed", thread: "thread") else {
            return XCTFail("Retired unknown fingerprint lost")
        }
        XCTAssertThrowsError(try restored.complete("phone:done", result: Data("different".utf8)))
    }

    func testRecentUnknownKeepsIntentForReconciliation() throws {
        let file = try file()
        var now = 1000.0
        let journal = try SessionReceiptJournal(file: file, clock: { now })
        _ = try journal.reserve("phone:unknown", hash: "unknown", thread: "thread", intent: Data("prompt".utf8))
        now += 24 * 3600
        _ = try journal.reserve("other:new", hash: "next", thread: "other")
        XCTAssertNil(journal.receipt("phone:unknown")?.retired)
        XCTAssertEqual(journal.receipt("phone:unknown")?.intent, Data("prompt".utf8))
    }

    func testManyUnresolvedOperationsDoNotExhaustDeviceQuota() throws {
        // Previously each unresolved record reserved ~400 KB, so about nine unknowns blocked every new mutation.
        let file = try file()
        let journal = try SessionReceiptJournal(file: file)
        for index in 0..<40 {
            guard
                case .fresh = try journal.reserve(
                    "phone:\(index)", hash: "hash\(index)", thread: "thread", intent: Data(repeating: 7, count: 2048))
            else { return XCTFail("Reservation \(index) was not fresh") }
        }
        try journal.complete("phone:0", result: Data(repeating: 65, count: 200_000))
        XCTAssertNotNil(journal.receipt("phone:0")?.result)
    }

    func testPendingPerDeviceCapDoesNotAffectOtherDevices() throws {
        let file = try file()
        var limits = SessionReceiptJournal.Limits()
        limits.pendingPerDevice = 2
        let journal = try SessionReceiptJournal(file: file, limits: limits)
        _ = try journal.reserve("a:1", hash: "1", thread: "t")
        _ = try journal.reserve("a:2", hash: "2", thread: "t")
        XCTAssertThrowsError(try journal.reserve("a:3", hash: "3", thread: "t")) {
            XCTAssertEqual($0 as? SessionReceiptJournal.Failure, .full)
        }
        guard case .fresh = try journal.reserve("b:1", hash: "1", thread: "t") else {
            return XCTFail("Device isolated")
        }
        try journal.complete("a:1", result: Data("{}".utf8))
        guard case .fresh = try journal.reserve("a:3", hash: "3", thread: "t") else { return XCTFail("Slot released") }
    }

    func testOversizedFinalResultIsCompactedInsteadOfLost() throws {
        let file = try file()
        var limits = SessionReceiptJournal.Limits()
        limits.deviceBytes = 64 * 1024
        let journal = try SessionReceiptJournal(file: file, limits: limits)
        _ = try journal.reserve("a:1", hash: "1", thread: "t")
        let large: [String: Any] = [
            "ok": true, "accepted": true, "threadId": "thread", "nativeTurnId": "turn",
            "snapshot": String(repeating: "x", count: 120_000),
        ]
        try journal.complete("a:1", result: try JSONSerialization.data(withJSONObject: large))
        let stored = try XCTUnwrap(journal.receipt("a:1")?.result)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertEqual(object["threadId"] as? String, "thread")
        XCTAssertEqual(object["nativeTurnId"] as? String, "turn")
        XCTAssertEqual(object["compacted"] as? Bool, true)
        XCTAssertNil(object["snapshot"])
    }

    func testPendingResultSpaceIsReservedAndPerDeviceQuotaIsFair() throws {
        let file = try file()
        let journal = try SessionReceiptJournal(file: file, limits: smallLimits())
        _ = try journal.reserve("a:1", hash: "hash", thread: "thread", intent: Data(repeating: 1, count: 100))
        XCTAssertThrowsError(
            try journal.reserve("a:2", hash: "hash", thread: "thread", intent: Data(repeating: 1, count: 100)))
        XCTAssertNil(journal.receipt("a:2"))
        _ = try journal.reserve("b:1", hash: "hash", thread: "thread", intent: Data(repeating: 1, count: 100))
        let maximum = Data(repeating: 255, count: 300)
        try journal.complete("a:1", result: maximum)
        let restored = try SessionReceiptJournal(file: file, limits: smallLimits())
        XCTAssertEqual(restored.receipt("a:1")?.result, maximum)
        XCTAssertNil(restored.receipt("a:1")?.intent)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertLessThan(try Data(contentsOf: file).count, 4000)
    }

    func testGlobalQuotaAndRecordCapsDoNotEvictUncertainRecords() throws {
        let file = try file()
        var limits = smallLimits()
        limits.fileBytes = 1200
        limits.deviceBytes = 1200
        let journal = try SessionReceiptJournal(file: file, limits: limits)
        _ = try journal.reserve("a:1", hash: "hash", thread: "thread")
        _ = try journal.reserve("b:1", hash: "hash", thread: "thread")
        XCTAssertThrowsError(try journal.reserve("c:1", hash: "hash", thread: "thread"))
        XCTAssertNotNil(journal.receipt("a:1"))
        XCTAssertNotNil(journal.receipt("b:1"))
        let otherFile = try self.file()
        limits = smallLimits()
        limits.activeRecords = 1
        let capped = try SessionReceiptJournal(file: otherFile, limits: limits)
        _ = try capped.reserve("a:1", hash: "hash", thread: "thread")
        XCTAssertThrowsError(try capped.reserve("b:1", hash: "hash", thread: "thread"))
    }

    func testRetiredMarkersCountTowardHardLimitWithoutBeingEvicted() throws {
        let file = try file()
        var now = 1000.0
        var limits = smallLimits()
        limits.activeRecords = 1
        limits.totalRecords = 2
        let journal = try SessionReceiptJournal(file: file, limits: limits, clock: { now })
        _ = try journal.reserve("a:1", hash: "first", thread: "thread")
        try journal.complete("a:1", result: Data("ok".utf8))
        now += 8 * 86400
        _ = try journal.reserve("b:1", hash: "second", thread: "thread")
        try journal.complete("b:1", result: Data("ok".utf8))
        now += 8 * 86400
        XCTAssertThrowsError(try journal.reserve("c:1", hash: "third", thread: "thread")) {
            XCTAssertEqual($0 as? SessionReceiptJournal.Failure, .full)
        }
        let restored = try SessionReceiptJournal(file: file, limits: limits, clock: { now })
        XCTAssertEqual(restored.receipt("a:1")?.retired, true)
        XCTAssertNotNil(restored.receipt("b:1"))
        XCTAssertNil(restored.receipt("c:1"))
    }

    func testLockSymlinkCannotRedirectPersistence() throws {
        let file = try file()
        let target = file.deletingLastPathComponent().appendingPathComponent("keep")
        try Data("original".utf8).write(to: target)
        XCTAssertEqual(symlink(target.path, file.path + ".lock"), 0)
        let journal = try SessionReceiptJournal(file: file)
        XCTAssertThrowsError(try journal.reserve("phone:1", hash: "hash", thread: "thread"))
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testStaleJournalCannotOverwriteAnotherWritersReservation() throws {
        let file = try file()
        let first = try SessionReceiptJournal(file: file)
        let stale = try SessionReceiptJournal(file: file)
        _ = try first.reserve("a:1", hash: "hash", thread: "thread")
        XCTAssertThrowsError(try stale.reserve("b:1", hash: "hash", thread: "thread"))
        XCTAssertNil(stale.receipt("b:1"))
        XCTAssertThrowsError(try stale.reserve("c:1", hash: "hash", thread: "thread"))
        let restored = try SessionReceiptJournal(file: file)
        XCTAssertNotNil(restored.receipt("a:1"))
        XCTAssertNil(restored.receipt("b:1"))
    }

    func testPostPublicationFailurePoisonsWriterAndLeavesDurableUnknown() throws {
        let file = try file()
        let journal = try SessionReceiptJournal(
            file: file,
            commit: { bytes, _ in
                try bytes.write(to: file, options: .atomic)
                throw POSIXError(.EIO)  // Simulate failure after rename, before directory durability is known.
            })
        XCTAssertThrowsError(try journal.reserve("phone:operation", hash: "hash", thread: "thread"))
        XCTAssertNil(journal.receipt("phone:operation"))
        XCTAssertFalse(journal.isReliable)
        XCTAssertThrowsError(try journal.reserve("phone:operation", hash: "hash", thread: "thread"))
        let restored = try SessionReceiptJournal(file: file)
        guard case .unknown = try restored.reserve("phone:operation", hash: "hash", thread: "thread") else {
            return XCTFail("Ambiguous commit was retried")
        }
    }

    func testFailedCompletionPreservesReservationAndFirstFinalResultIsImmutable() throws {
        let file = try file()
        let first = try SessionReceiptJournal(file: file)
        _ = try first.reserve("phone:operation", hash: "hash", thread: "thread", intent: Data("original".utf8))
        let failure = try SessionReceiptJournal(file: file, commit: { _, _ in throw POSIXError(.ENOSPC) })
        XCTAssertThrowsError(try failure.complete("phone:operation", result: Data("accepted".utf8)))
        XCTAssertNil(failure.receipt("phone:operation")?.result)
        XCTAssertFalse(failure.isReliable)
        let restored = try SessionReceiptJournal(file: file)
        guard case .unknown = try restored.reserve("phone:operation", hash: "hash", thread: "thread") else {
            return XCTFail("Lost unknown")
        }
        try restored.complete("phone:operation", result: Data("accepted".utf8))
        try restored.complete("phone:operation", result: Data("accepted".utf8))
        XCTAssertThrowsError(try restored.complete("phone:operation", result: Data("contradictory".utf8)))
        XCTAssertEqual(restored.receipt("phone:operation")?.result, Data("accepted".utf8))
    }

    func testOversizedCorruptSymlinkAndNonRegularStoresFailClosed() throws {
        let file = try file()
        let bytes = Data(repeating: 120, count: 4001)
        try bytes.write(to: file)
        XCTAssertThrowsError(try SessionReceiptJournal(file: file, limits: smallLimits()))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try SessionReceiptJournal(file: file))
        try FileManager.default.removeItem(at: file)
        let target = file.deletingLastPathComponent().appendingPathComponent("target")
        try Data("{}".utf8).write(to: target)
        XCTAssertEqual(symlink(target.path, file.path), 0)
        XCTAssertThrowsError(try SessionReceiptJournal(file: file))
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
        XCTAssertEqual(unlink(file.path), 0)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try SessionReceiptJournal(file: file))
    }

    func testInvalidPayloadAndRecordMetadataCannotChangeStore() throws {
        let file = try file()
        let journal = try SessionReceiptJournal(file: file, limits: smallLimits())
        XCTAssertThrowsError(try journal.reserve("", hash: "hash", thread: "thread"))
        XCTAssertThrowsError(
            try journal.reserve("phone:1", hash: "hash", thread: "thread", intent: Data(repeating: 1, count: 301)))
        XCTAssertNil(journal.receipt("phone:1"))
        _ = try journal.reserve("phone:1", hash: "hash", thread: "thread")
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try journal.complete("phone:1", result: Data(repeating: 2, count: 301)))
        XCTAssertEqual(try Data(contentsOf: file), before)
        let invalid: [String: SessionReceiptJournal.Receipt] = [
            "phone:1": .init(hash: "", thread: "thread", created: 1000)
        ]
        try JSONEncoder().encode(invalid).write(to: file)
        XCTAssertThrowsError(try SessionReceiptJournal(file: file))
    }
}
