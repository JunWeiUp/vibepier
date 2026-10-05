import Foundation
import XCTest

@testable import VibePierCore

final class CodexBridgeCreationRecoveryTests: XCTestCase {
    private final class Readback: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var request: [String: Any] = [:]
        var client = ""
        var input: [[String: Any]] = []
        var result: [String: Any]?
        func read(_ request: [String: Any], _ client: String, _ input: [[String: Any]]) -> [String: Any]? {
            lock.withLock {
                calls += 1
                self.request = request
                self.client = client
                self.input = input
                return result
            }
        }
    }

    private var original: [String: Any] {
        [
            "op": "new", "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "provider": "codex",
            "cwd": "/synthetic", "draftId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            "text": "  synthetic\r\nprompt  ", "attachments": [String](), "model": "native-model",
            "effort": "medium", "mode": "auto", "executionMode": "default", "serviceTier": "standard",
        ]
    }
    private func lookup(_ value: [String: Any]) -> [String: Any] {
        SessionRemote.creationReceiptLookup(value, operation: value["id"] as! String, thread: "")
    }
    private func bridge(_ readback: Readback, receipts: ProviderOperationReceipts = ProviderOperationReceipts())
        -> CodexBridge
    {
        CodexBridge(
            attachments: nil, creationReceipts: receipts, backgroundCreationReceipt: readback.read,
            executionModeCatalog: { [] }, desktopBuild: { nil }, openNativeThread: { _ in XCTFail("Unexpected UI") })
    }
    private func perform(_ bridge: CodexBridge, _ request: [String: Any]) throws -> [String: Any] {
        let completed = expectation(description: "read-only creation receipt")
        let output = Readback()
        bridge.perform(try JSONSerialization.data(withJSONObject: request), client: "trusted-phone") { bytes in
            output.lock.withLock {
                output.result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        return try XCTUnwrap(output.lock.withLock { output.result })
    }

    func testRestartedCreationReadsExactOriginalInputWithoutAttachmentStorageOrDesktop() throws {
        let readback = Readback()
        readback.result = [
            "ok": true, "accepted": true, "threadId": "native-thread", "cwd": "/synthetic",
            "nativeMessageId": "native-message", "nativeTurnId": "native-turn",
            "executionModeVerified": true, "effectiveExecutionMode": "default",
        ]
        let result = try perform(bridge(readback), lookup(original))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(readback.calls, 1)
        XCTAssertEqual(readback.client, "trusted-phone")
        XCTAssertEqual(readback.request["operation"] as? String, original["id"] as? String)
        for key in ["cwd", "draftId", "model", "effort", "mode", "executionMode", "serviceTier"] {
            XCTAssertEqual(readback.request[key] as? String, original[key] as? String, key)
        }
        XCTAssertEqual(readback.input.count, 1)
        XCTAssertEqual(readback.input[0]["type"] as? String, "text")
        XCTAssertEqual(readback.input[0]["text"] as? String, "synthetic\nprompt")
        XCTAssertEqual((readback.input[0]["text_elements"] as? [Any])?.count, 0)
    }

    func testRecoveredPartialIdentityStaysUnknownAndIsReadAgain() throws {
        let readback = Readback()
        readback.result = [
            "ok": false, "unknown": true, "threadId": "native-thread", "cwd": "/synthetic",
            "nativeMessageId": "native-message", "nativeTurnId": "native-turn",
        ]
        let value = bridge(readback)
        for _ in 0..<2 {
            let result = try perform(value, lookup(original))
            XCTAssertEqual(result["unknown"] as? Bool, true)
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(result["threadId"] as? String, "native-thread")
            XCTAssertEqual(result["nativeTurnId"] as? String, "native-turn")
        }
        XCTAssertEqual(readback.calls, 2)
    }

    func testMissingCandidateOrAttachmentsCannotBecomeAResolvedFailure() throws {
        let readback = Readback()
        let value = bridge(readback)
        let absent = try perform(value, lookup(original))
        XCTAssertEqual(absent["unknown"] as? Bool, true)
        XCTAssertEqual(readback.calls, 1)
        var attached = original
        attached["attachments"] = ["CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"]
        let unavailable = try perform(value, lookup(attached))
        XCTAssertEqual(unavailable["unknown"] as? Bool, true)
        XCTAssertEqual(unavailable["accepted"] as? Bool, false)
        XCTAssertEqual(readback.calls, 1, "Missing attachment proof cannot invoke native recovery")
    }

    func testConfirmedProcessReceiptTakesPriorityOverRecovery() throws {
        let receipts = ProviderOperationReceipts()
        guard case .fresh(let ticket) = try receipts.begin(original, client: "trusted-phone") else {
            return XCTFail("Expected a synthetic reservation")
        }
        let saved = receipts.finish(
            ticket,
            result: [
                "ok": true, "accepted": true, "threadId": "saved-thread", "cwd": "/synthetic",
                "executionModeVerified": true, "effectiveExecutionMode": "default",
            ])
        XCTAssertEqual(saved["ok"] as? Bool, true)
        let readback = Readback()
        let result = try perform(bridge(readback, receipts: receipts), lookup(original))
        XCTAssertEqual(result["threadId"] as? String, "saved-thread")
        XCTAssertEqual(readback.calls, 0)
    }

    func testUnknownMutationReplayNeverEntersRecoveryOrCreation() throws {
        let receipts = ProviderOperationReceipts()
        guard case .fresh(let ticket) = try receipts.begin(original, client: "trusted-phone") else {
            return XCTFail("Expected a synthetic reservation")
        }
        _ = receipts.finish(ticket, result: ["ok": false, "unknown": true])
        let readback = Readback()
        let result = try perform(bridge(readback, receipts: receipts), original)
        XCTAssertEqual(result["unknown"] as? Bool, true)
        XCTAssertEqual(readback.calls, 0)
    }

    func testLegacyLookupPreservesImmutableInputAndConfiguration() throws {
        let request = original
        let before = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let result = lookup(request)
        XCTAssertEqual(result["op"] as? String, "newReceiptCheck")
        XCTAssertEqual(result["operation"] as? String, request["id"] as? String)
        XCTAssertEqual(result["threadId"] as? String, "")
        for key in request.keys where key != "op" {
            XCTAssertTrue(NSDictionary(dictionary: ["value": result[key]!]).isEqual(to: ["value": request[key]!]), key)
        }
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), before)
    }
}
