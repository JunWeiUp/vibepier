import XCTest

@testable import VibePierCore

final class CodexMessageIdentityTests: XCTestCase {
    private let thread = "A437FEE0-08D2-44BC-A5B6-8E288C558340"
    private let operation = "ECA5FFCB-4AC0-4D42-B935-7B83E0806C70"

    func testSameOperationFromDifferentPhonesCannotReuseNativeReceipt() throws {
        let first = try CodexMessageIdentity(client: "phone-a", thread: thread, operation: operation)
        let second = try CodexMessageIdentity(client: "phone-b", thread: thread, operation: operation)
        XCTAssertNotEqual(first.nativeID, second.nativeID)
        let state = state(id: first.nativeID)
        XCTAssertTrue(first.delivered(in: state))
        XCTAssertFalse(second.delivered(in: state))
        let queued = [CodexFollowUps.message(id: first.nativeID, text: "hello", cwd: "/demo", files: [], images: [])]
        XCTAssertTrue(first.queued(in: queued))
        XCTAssertFalse(second.queued(in: queued))
        // A copied visible native ID is still a new operation in the other device's namespace.
        let copied = try CodexMessageIdentity(client: "phone-b", thread: thread, operation: first.nativeID)
        XCTAssertFalse(copied.delivered(in: state))
        XCTAssertFalse(copied.queued(in: queued))
    }

    func testIdentitySurvivesReconstructionAndSeparatesThreadAndOperation() throws {
        let first = try CodexMessageIdentity(client: "phone", thread: thread, operation: operation)
        XCTAssertNotNil(UUID(uuidString: first.nativeID))
        XCTAssertNotEqual(first.nativeID, operation)
        XCTAssertEqual(
            first.nativeID, try CodexMessageIdentity(client: "phone", thread: thread, operation: operation).nativeID)
        XCTAssertNotEqual(
            first.nativeID, try CodexMessageIdentity(client: "phone", thread: operation, operation: operation).nativeID)
        XCTAssertNotEqual(
            first.nativeID, try CodexMessageIdentity(client: "phone", thread: thread, operation: thread).nativeID)
        XCTAssertNotEqual(
            first.nativeID,
            try CodexMessageIdentity(client: "phone", thread: thread, operation: operation.lowercased()).nativeID)
    }

    func testLegacyRawIDsAndUnacceptedSteeringNeverConfirmScopedSend() throws {
        let identity = try CodexMessageIdentity(client: "phone", thread: thread, operation: operation)
        XCTAssertFalse(identity.delivered(in: state(id: operation)))
        XCTAssertFalse(identity.queued(in: [["id": operation]]))
        for status in ["pending", "rejected", "failed", "accepted"] {
            let value: [String: Any] = [
                "turns": [
                    [
                        "items": [
                            [
                                "type": "steeringUserMessage", "clientUserMessageId": identity.nativeID,
                                "status": status,
                            ]
                        ]
                    ]
                ]
            ]
            XCTAssertEqual(identity.delivered(in: value), status == "accepted")
        }
    }

    func testInvalidIdentitiesAreRejectedBeforeNativeSubmission() throws {
        for client in ["", String(repeating: "a", count: 1025)] {
            XCTAssertThrowsError(try CodexMessageIdentity(client: client, thread: thread, operation: operation))
        }
        for invalid in ["", "not-a-uuid", String(repeating: "a", count: 1000)] {
            XCTAssertThrowsError(try CodexMessageIdentity(client: "phone", thread: invalid, operation: operation))
            XCTAssertThrowsError(try CodexMessageIdentity(client: "phone", thread: thread, operation: invalid))
        }
    }

    private func state(id: String) -> [String: Any] {
        ["turns": [["items": [["type": "userMessage", "clientId": id, "text": "hello"]]]]]
    }
}
