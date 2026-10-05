import XCTest

@testable import VibePierCore

final class ClaudeCreationReceiptTests: XCTestCase {
    private func entry(_ text: String, extra: [String: Any] = [:]) -> [String: Any] {
        [
            "type": "user", "uuid": "native-message", "sessionId": "native-session", "cwd": "/demo",
            "message": ["content": text],
        ].merging(extra) { _, new in new }
    }
    private func read(_ rows: [[String: Any]], newline: Bool = true) throws -> [String: Any]? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claude-creation-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data()
        for (index, row) in rows.enumerated() {
            data.append(try JSONSerialization.data(withJSONObject: row))
            if newline || index != rows.count - 1 { data.append(10) }
        }
        try data.write(to: url)
        return ClaudeCreationReceipt.read(url, session: "native-session", cwd: "/demo", text: "full body")
    }

    func testCreationRequiresFullFirstHumanBodyWithNativeSessionAndDirectory() throws {
        let value = try XCTUnwrap(read([entry("full body")]))
        XCTAssertEqual(value["threadId"] as? String, "native-session")
        XCTAssertEqual(value["nativeMessageId"] as? String, "native-message")
        XCTAssertEqual(value["turnId"] as? String, "transcript:native-session:native-message")
        XCTAssertEqual(value["turnIdentityKind"] as? String, "nativeMessageAnchor")
        for extra: [String: Any] in [["sessionId": "other"], ["cwd": "/other"], ["uuid": ""], ["uuid": "bad\0message"]]
        {
            XCTAssertNil(try read([entry("full body", extra: extra)]))
        }
        XCTAssertNil(try read([entry("full")]))
        XCTAssertNil(try read([entry("earlier different input"), entry("full body")]))
    }

    func testTranscriptTurnAnchorIsStableAndBoundToOriginalNativeHuman() throws {
        let initial = try XCTUnwrap(read([entry("full body")]))
        let late = try XCTUnwrap(read([entry("full body"), entry("later prompt", extra: ["uuid": "later-message"])]))
        XCTAssertEqual(initial["turnId"] as? String, late["turnId"] as? String)
        let other = try XCTUnwrap(read([entry("full body", extra: ["uuid": "other-first-message"])]))
        XCTAssertNotEqual(initial["turnId"] as? String, other["turnId"] as? String)
        XCTAssertEqual(other["turnId"] as? String, "transcript:native-session:other-first-message")
        XCTAssertNil(
            try read([entry("earlier unrelated human", extra: ["uuid": "other-first-message"]), entry("full body")]))
    }

    func testMetadataOrIncompleteFileCannotConfirmNewSubmission() throws {
        let metadata = entry("injected context", extra: ["isMeta": true])
        XCTAssertNil(try read([entry("full body", extra: ["isMeta": true])]))
        XCTAssertNotNil(try read([metadata, entry("full body")]))
        XCTAssertNil(try read([entry("full body")], newline: false))
        XCTAssertNil(try read([]))
    }
}
