import Foundation
import XCTest

@testable import VibePierCore

final class AgentSessionProfileTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/" + name))) as? [String: Any])
    }
    func testGeneratedCurrentContractMatchesSharedFixture() throws {
        let data = try fixture("session-v1.json")
        XCTAssertEqual(
            SessionV1Contract.operations.filter(\.durableMutation).map(\.name).sorted(),
            data["durableMutations"] as? [String])
        XCTAssertEqual(
            SessionV1Contract.operations.filter { $0.uncertainOnTimeout && !$0.durableMutation }.map(\.name).sorted(),
            data["timeoutUnknownOnly"] as? [String])
        XCTAssertEqual(
            SessionV1Contract.operations.filter(\.providerPolicyExempt).map(\.name).sorted(),
            data["providerPolicyExempt"] as? [String])
        XCTAssertNil(SessionV1Contract.descriptor("screenLockPassword"))
        XCTAssertEqual(SessionV1Contract.descriptor("unlockPassword")?.durableMutation, false)
        XCTAssertEqual(SessionV1Contract.descriptor("unlockPassword")?.uncertainOnTimeout, true)
    }
    func testSharedCanonicalFingerprintsAndStrictDecoder() throws {
        let data = try fixture("agent-session-v2.json")
        for vector in try XCTUnwrap(data["vectors"] as? [[String: Any]]) {
            let body = try XCTUnwrap(vector["request"] as? [String: Any])
            let decoded = try AgentSessionProfile.decode(["id": body["requestId"]!, "body": body])
            XCTAssertEqual(decoded.fingerprint, vector["fingerprint"] as? String)
            let semantic = body.filter { !["requestId", "controlLease"].contains($0.key) }
            XCTAssertEqual(
                String(decoding: try AgentSessionProfile.canonical(semantic), as: UTF8.self),
                vector["canonical"] as? String)
            var invalid = body
            invalid["agentProtocol"] = true
            XCTAssertThrowsError(try AgentSessionProfile.decode(["id": body["requestId"]!, "body": invalid]))
            invalid = body
            invalid["params"] = ["arbitraryNativeMethod": "command/exec"]
            XCTAssertThrowsError(try AgentSessionProfile.decode(["id": body["requestId"]!, "body": invalid]))
        }
    }
    func testEmptyDiscoverySearchPreservesStrictSearchTypesAndIdentityBounds() throws {
        for method in ["workspace.list", "session.list"] {
            let id = UUID().uuidString
            var body: [String: Any] = [
                "agentProtocol": 2, "requestId": id, "method": method,
                "target": ["adapterId": "codex.currentV1"], "params": ["search": ""],
            ]
            XCTAssertEqual(try AgentSessionProfile.decode(["id": id, "body": body]).params["search"] as? String, "")
            for invalid: Any in [42, NSNull(), "\0", String(repeating: "s", count: 201)] {
                body["params"] = ["search": invalid]
                XCTAssertThrowsError(try AgentSessionProfile.decode(["id": id, "body": body]))
            }
            body["params"] = ["search": ""]
            body["target"] = ["adapterId": ""]
            XCTAssertThrowsError(try AgentSessionProfile.decode(["id": id, "body": body]))
        }
    }

    func testSafeIntegerAndDepthBounds() throws {
        XCTAssertThrowsError(try AgentSessionProfile.canonical(["value": Double.infinity]))
        XCTAssertThrowsError(try AgentSessionProfile.canonical(["value": 1.25]))
        XCTAssertThrowsError(try AgentSessionProfile.canonical(["value": 9_007_199_254_740_992 as Int64]))
        XCTAssertEqual(
            String(decoding: try AgentSessionProfile.canonical(["boolean": true, "integer": 1]), as: UTF8.self),
            "{\"boolean\":true,\"integer\":1}")
        var nested: Any = "leaf"
        for _ in 0..<18 { nested = [nested] }
        XCTAssertThrowsError(try AgentSessionProfile.canonical(nested))
    }
    func testRequestAttemptAndLeaseDoNotChangeLogicalFingerprint() throws {
        let vector = try XCTUnwrap((fixture("agent-session-v2.json")["vectors"] as? [[String: Any]])?.last)
        var body = try XCTUnwrap(vector["request"] as? [String: Any])
        let original = try AgentSessionProfile.decode(["id": body["requestId"]!, "body": body]).fingerprint
        body["requestId"] = UUID().uuidString
        body["controlLease"] = UUID().uuidString
        XCTAssertEqual(try AgentSessionProfile.decode(["id": body["requestId"]!, "body": body]).fingerprint, original)
        var target = body["target"] as! [String: Any]
        target["sessionRef"] = "another-native-target"
        body["target"] = target
        XCTAssertNotEqual(
            try AgentSessionProfile.decode(["id": body["requestId"]!, "body": body]).fingerprint, original)
    }
    func testPersistentDirectoryPreservesReferencesAndRejectsCorruptStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("directory.json")
        let directory = try AgentSessionDirectory(file: file)
        let ref = try directory.registerSession(
            adapter: "codex.currentV1", provider: "codex", native: UUID().uuidString, cwd: "/synthetic/project")
        let restored = try AgentSessionDirectory(file: file)
        XCTAssertEqual(restored.session(ref.ref)?.nativeID, ref.nativeID)
        XCTAssertEqual(restored.hostRef, directory.hostRef)
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try AgentSessionDirectory(file: file))
    }
    func testReplayWindowRejectsWrongEpochGapsAndFutureCursor() throws {
        var stream = AgentObservationStream()
        for _ in 0..<300 { XCTAssertNotNil(stream.append(["event": "session.stateChanged", "data": ["dirty": true]])) }
        XCTAssertEqual(stream.events.count, 256)
        XCTAssertNil(stream.replay(epoch: stream.epoch, after: 0))
        XCTAssertNil(stream.replay(epoch: "old", after: 300))
        XCTAssertNil(stream.replay(epoch: stream.epoch, after: 301))
        XCTAssertEqual(stream.replay(epoch: stream.epoch, after: 299)?.count, 1)
    }
    func testExplicitSubmissionIntentDoesNotChangeAtNativeRace() {
        XCTAssertTrue(AgentSubmissionPolicy.allows("start", active: false, queued: false))
        XCTAssertFalse(AgentSubmissionPolicy.allows("start", active: true, queued: false))
        XCTAssertFalse(AgentSubmissionPolicy.allows("start", active: false, queued: true))
        XCTAssertTrue(AgentSubmissionPolicy.allows("queue", active: true, queued: false))
        XCTAssertFalse(AgentSubmissionPolicy.allows("queue", active: false, queued: false))
        XCTAssertFalse(AgentSubmissionPolicy.allows("steer", active: true, queued: false))
    }
    func testJournalPartialEvidenceAndLegacyIDCaseSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("journal.json")
        let device = UUID().uuidString
        let operation = UUID().uuidString
        let key = device + ":" + operation
        let journal = try SessionReceiptJournal(file: file)
        if case .fresh = try journal.reserve(key, hash: "hash", thread: "native", intent: Data("intent".utf8)) {
        } else {
            XCTFail()
        }
        try journal.recordEvidence(key, evidence: Data("verified-partial-identity".utf8))
        let restored = try SessionReceiptJournal(file: file)
        XCTAssertEqual(restored.receipt(key)?.evidence, Data("verified-partial-identity".utf8))
        XCTAssertNil(restored.receipt(key)?.result)
        XCTAssertEqual(restored.existingKey(device: device, operation: operation.lowercased()), key)
        if case .unknown = try restored.reserve(key, hash: "hash", thread: "native") {
        } else {
            XCTFail("Partial evidence must never enable execution")
        }
    }
}
