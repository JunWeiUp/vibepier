import XCTest

@testable import VibePierCore

final class SessionProviderReplyTests: XCTestCase {
    func testLateCreationLookupPreservesNewNativeIdentityAndRequiresOriginalDirectory() throws {
        let receipt: [String: Any] = [
            "ok": true, "threadId": "new-native", "cwd": "/demo", "nativeMessageId": "message",
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt)
        let resolved = try XCTUnwrap(
            SessionProviderReply.resolvedLookup(data, thread: "", operation: "new", cwd: "/demo"))
        XCTAssertEqual(resolved["threadId"] as? String, "new-native")
        XCTAssertEqual(resolved["nativeMessageId"] as? String, "message")
        XCTAssertNil(SessionProviderReply.resolvedLookup(data, thread: "", operation: "new", cwd: "/other"))
        XCTAssertNil(SessionProviderReply.resolvedLookup(data, thread: "", operation: "new"))
        XCTAssertNil(SessionProviderReply.resolvedLookup(data, thread: "", operation: "send", cwd: "/demo"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("receipts.json")
        let journal = try SessionReceiptJournal(file: url)
        _ = try journal.reserve("phone:operation", hash: "hash", thread: "")
        let saved = SessionProviderReply(
            try JSONSerialization.data(withJSONObject: resolved),
            request: .init(["id": "operation", "op": "new", "threadId": "", "cwd": "/demo"]), mutable: true
        )
        .saving { try journal.complete("phone:operation", result: $0) }
        XCTAssertTrue(saved.definitive)
        let reloaded = try XCTUnwrap(SessionReceiptJournal(file: url).receipt("phone:operation")?.result)
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: reloaded) as? [String: Any])?["threadId"] as? String, "new-native")
    }

    func testApprovalLookupCannotManufactureConfirmationFromAcceptedBoolean() throws {
        func lookup(_ body: [String: Any]) throws -> [String: Any]? {
            SessionProviderReply.resolvedLookup(
                try JSONSerialization.data(withJSONObject: body), thread: "thread", operation: "approve",
                fingerprint: "original")
        }
        XCTAssertNil(try lookup(["ok": true, "accepted": true, "threadId": "thread"]))
        XCTAssertNil(try lookup(["ok": true, "submitted": true, "threadId": "thread", "fingerprint": "different"]))
        XCTAssertNotNil(try lookup(["ok": true, "submitted": true, "threadId": "thread", "fingerprint": "original"]))
    }
    private func reply(_ value: [String: Any], op: String = "send", extra: [String: Any] = [:], mutable: Bool = true)
        throws -> SessionProviderReply
    {
        var request: [String: Any] = [
            "id": "operation", "op": op, "threadId": "thread", "cwd": "/demo", "fingerprint": "approval",
        ]
        request.merge(extra) { _, new in new }
        return SessionProviderReply(
            try JSONSerialization.data(withJSONObject: value), request: .init(request), mutable: mutable)
    }

    func testInvalidMutationRepliesRemainDurablyUnknownAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("receipts.json")
        let bad = [
            Data(), Data("not json".utf8), Data("[]".utf8), Data("{}".utf8), Data("{\"ok\":1}".utf8),
            Data("{\"ok\":true,\"unknown\":\"true\"}".utf8),
        ]
        for (index, bytes) in bad.enumerated() {
            let key = "phone:\(index)"
            let journal = try SessionReceiptJournal(file: file)
            guard case .fresh = try journal.reserve(key, hash: "hash", thread: "thread") else {
                return XCTFail("fresh")
            }
            let result = SessionProviderReply(
                bytes, request: .init(["id": "operation", "op": "send", "threadId": "thread"]), mutable: true)
            if result.definitive { try journal.complete(key, result: result.data) }
            XCTAssertFalse(result.definitive)
            XCTAssertEqual(result.object["ok"] as? Bool, false)
            XCTAssertEqual(result.object["id"] as? String, "operation")
            let reopened = try SessionReceiptJournal(file: file)
            guard case .unknown = try reopened.reserve(key, hash: "hash", thread: "thread") else {
                return XCTFail("Malformed reply must not complete the reservation")
            }
        }
    }

    func testExecutionSettingsRequireMatchingNativeModeEvidenceButCreationTreatsItAsWarning() throws {
        for operation in ["settings", "new"] {
            for (mode, verified, settingsConfirmed) in [
                ("default", true, false), ("plan", false, false), ("plan", true, true),
            ] {
                // A created thread is proved by its native identity; its mode readback only adds a warning.
                let confirmed = operation == "new" || settingsConfirmed
                let value: [String: Any] = [
                    "ok": true, "accepted": true, "threadId": "thread", "cwd": "/demo",
                    "effectiveExecutionMode": mode, "executionModeVerified": verified,
                ]
                let normalized = try reply(value, op: operation, extra: ["executionMode": "plan"])
                XCTAssertEqual(normalized.definitive, confirmed)
                let lookup = SessionProviderReply.resolvedLookup(
                    try JSONSerialization.data(withJSONObject: value),
                    thread: "thread", operation: operation, cwd: "/demo", executionMode: "plan")
                XCTAssertEqual(lookup != nil, confirmed)
            }
        }
    }

    func testDefinitiveFailureSettlesALookupButAnUnqualifiedFailureDoesNot() throws {
        let definitive: [String: Any] = ["ok": false, "definitive": true, "error": "Nothing was sent"]
        XCTAssertNotNil(
            SessionProviderReply.resolvedLookup(
                try JSONSerialization.data(withJSONObject: definitive), thread: "", operation: "new", cwd: "/demo"))
        let unqualified: [String: Any] = ["ok": false, "error": "Nothing was sent"]
        XCTAssertNil(
            SessionProviderReply.resolvedLookup(
                try JSONSerialization.data(withJSONObject: unqualified), thread: "", operation: "new", cwd: "/demo"))
    }

    func testPersistenceFailureCannotBecomeAConfirmedResponse() throws {
        let success = try reply(["ok": true, "accepted": true, "threadId": "thread"])
        let unsaved = success.saving { _ in throw POSIXError(.ENOSPC) }
        XCTAssertFalse(unsaved.definitive)
        XCTAssertEqual(unsaved.object["ok"] as? Bool, false)
        XCTAssertEqual(unsaved.object["unknown"] as? Bool, true)
        XCTAssertEqual(unsaved.object["id"] as? String, "operation")
        var writes = 0
        let saved = success.saving { _ in writes += 1 }
        XCTAssertTrue(saved.definitive)
        let unknown = try reply(["ok": false, "unknown": true])
        XCTAssertFalse(unknown.saving { _ in writes += 1 }.definitive)
        XCTAssertEqual(writes, 1)
    }

    func testOperationSpecificSuccessRequiresMatchingIdentityAndAcknowledgment() throws {
        for op in ["send", "settings", "interrupt", "queueSteer", "queueDelete"] {
            XCTAssertTrue(try reply(["ok": true, "accepted": true, "threadId": "thread"], op: op).definitive)
            XCTAssertFalse(try reply(["ok": true, "accepted": true, "threadId": "other"], op: op).definitive)
            XCTAssertFalse(try reply(["ok": true, "threadId": "thread"], op: op).definitive)
            XCTAssertFalse(try reply(["ok": true, "accepted": 1, "threadId": "thread"], op: op).definitive)
        }
        XCTAssertTrue(
            try reply(["ok": true, "submitted": true, "threadId": "thread", "fingerprint": "approval"], op: "approve")
                .definitive)
        XCTAssertFalse(
            try reply(["ok": true, "submitted": true, "threadId": "thread", "fingerprint": "later"], op: "approve")
                .definitive)
        XCTAssertTrue(try reply(["ok": true, "threadId": "new-native-session", "cwd": "/demo"], op: "new").definitive)
        XCTAssertFalse(try reply(["ok": true, "threadId": "", "cwd": "/demo"], op: "new").definitive)
        XCTAssertFalse(
            try reply(["ok": true, "threadId": "new-native-session", "cwd": "/other"], op: "new").definitive)
        XCTAssertFalse(try reply(["ok": true], op: "new").definitive)
    }

    func testScreenControlsRequireExplicitResultingLockState() throws {
        XCTAssertTrue(try reply(["ok": true, "locked": true], op: "lockScreen").definitive)
        XCTAssertTrue(try reply(["ok": true, "locked": false], op: "unlockScreen").definitive)
        XCTAssertFalse(try reply(["ok": true, "locked": false], op: "lockScreen").definitive)
        XCTAssertFalse(try reply(["ok": true, "locked": true], op: "unlockScreen").definitive)
        for op in ["lockScreen", "unlockScreen"] {
            XCTAssertFalse(try reply(["ok": true], op: op).definitive)
            XCTAssertFalse(try reply(["ok": true, "locked": 1], op: op).definitive)
        }
    }

    func testUnknownOverridesConflictingSuccessAndKnownRejectionStaysDefinitive() throws {
        let unknown = try reply(["ok": true, "accepted": true, "threadId": "thread", "unknown": true])
        XCTAssertFalse(unknown.definitive)
        XCTAssertEqual(unknown.object["ok"] as? Bool, false)
        let rejected = try reply(["ok": false, "error": "Not authorized"])
        XCTAssertTrue(rejected.definitive)
        XCTAssertEqual(rejected.object["error"] as? String, "Not authorized")
        let read = try reply([:], op: "list", mutable: false)
        XCTAssertTrue(read.definitive)
        XCTAssertEqual(read.object["ok"] as? Bool, false)
        XCTAssertNil(read.object["unknown"])
    }

    func testOversizedSuccessCannotBeJournaledBeforeTransportRejectsIt() throws {
        let result = try reply([
            "ok": true, "accepted": true, "threadId": "thread", "detail": String(repeating: "x", count: 300_000),
        ])
        XCTAssertFalse(result.definitive)
        XCTAssertLessThan(result.data.count, 1000)
    }

    func testReceiptLookupRejectsUnknownWrongThreadAndContradictoryAcknowledgments() throws {
        func resolved(_ body: [String: Any], op: String = "send") throws -> [String: Any]? {
            SessionProviderReply.resolvedLookup(
                try JSONSerialization.data(withJSONObject: body), thread: "thread", operation: op)
        }
        XCTAssertNotNil(try resolved(["ok": true, "accepted": true, "threadId": "thread"]))
        for body: [String: Any] in [
            ["ok": true, "accepted": true, "threadId": "other"],
            ["ok": false, "accepted": true, "threadId": "thread"],
            ["ok": true, "accepted": true, "threadId": "thread", "unknown": true],
            ["ok": true, "accepted": true, "threadId": "thread", "unknown": "false"],
            ["ok": true, "accepted": 1, "threadId": "thread"],
            ["accepted": true, "threadId": "thread"],
        ] { XCTAssertNil(try resolved(body)) }
        let lostRace: [String: Any] = [
            "ok": false, "accepted": false, "resolved": true, "threadId": "thread", "error": "Already sent",
        ]
        XCTAssertNotNil(try resolved(lostRace, op: "queueDelete"))
        XCTAssertNil(try resolved(lostRace, op: "send"))
        XCTAssertNil(SessionProviderReply.resolvedLookup(Data(), thread: "thread", operation: "send"))
    }
}
