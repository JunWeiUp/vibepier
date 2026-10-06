import XCTest

@testable import VibePierCore

final class ClaudeApprovalTests: XCTestCase {
    private func entries(_ ids: [String]) -> [[String: Any]] {
        ids.map { id in
            [
                "message": [
                    "content": [
                        [
                            "type": "tool_use", "id": id, "name": "Bash",
                            "input": ["command": "echo \(id)"],
                        ]
                    ]
                ]
            ]
        }
    }

    func testAmbiguousSameToolNeverAdvertisesDecision() {
        for requests in [["new-request"], ["old-request", "new-request"]] {
            let cards = ClaudePermissions.approvals(
                entries(["old", "new"]),
                requests: requests.map {
                    .init(id: $0, tool: "Bash", host: "local_test")
                }, host: "local_test", cwd: "/synthetic")
            XCTAssertEqual(cards.count, requests.count)
            for card in cards { assertMacOnly(card) }
        }
    }

    func testUniqueToolCannotBeAssignedToTwoRequests() {
        let cards = ClaudePermissions.approvals(
            entries(["one"]),
            requests: ["a", "b"].map {
                .init(id: $0, tool: "Bash", host: "local_test")
            }, host: "local_test", cwd: "/synthetic")
        XCTAssertEqual(cards.count, 2)
        for card in cards { assertMacOnly(card) }
    }

    private func assertMacOnly(_ card: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(card["canDecide"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(
            card["details"] as? String,
            L10n.text("provider.this_request_must_be_handled_on_the_mac"), file: file, line: line)
        XCTAssertEqual(card["allowedDecisions"] as? [String], [], file: file, line: line)
        for key in ["toolUseId", "options", "questions", "plan", "optionDescriptions"] {
            XCTAssertNil(card[key], file: file, line: line)
        }
    }

    func testUnverifiedCardFingerprintIsStableScopedAndChangesWhenBindingResolves() throws {
        func card(_ ids: [String], host: String = "local_test", request: String = "request") throws -> [String: Any] {
            try XCTUnwrap(
                ClaudePermissions.approvals(
                    entries(ids),
                    requests: [
                        .init(id: request, tool: "Bash", host: host)
                    ], host: host, cwd: "/synthetic"
                ).first)
        }
        let ambiguous = try card(["old", "new"])
        assertMacOnly(ambiguous)
        let fingerprint = try XCTUnwrap(ambiguous["fingerprint"] as? String)
        XCTAssertEqual(fingerprint, try card(["new", "old"])["fingerprint"] as? String)
        XCTAssertNotEqual(fingerprint, try card(["old", "new"], host: "local_other")["fingerprint"] as? String)
        XCTAssertNotEqual(fingerprint, try card(["old", "new"], request: "other")["fingerprint"] as? String)
        XCTAssertNotEqual(fingerprint, try card(["old", "third"])["fingerprint"] as? String)
        XCTAssertNotEqual(fingerprint, try card(["new"])["fingerprint"] as? String)
        let missing = try card([])
        assertMacOnly(missing)
        XCTAssertNotEqual(fingerprint, missing["fingerprint"] as? String)
    }

    func testCompletedOldToolLeavesUniqueMapping() {
        var transcript = entries(["old", "new"])
        transcript.append(["message": ["content": [["type": "tool_result", "tool_use_id": "old"]]]])
        let cards = ClaudePermissions.approvals(
            transcript,
            requests: [
                .init(id: "request", tool: "Bash", host: "local_test")
            ], host: "local_test", cwd: "/synthetic")
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?["toolUseId"] as? String, "new")
        XCTAssertEqual(cards.first?["canDecide"] as? Bool, true)
    }

    private final class Log: @unchecked Sendable {
        // Test and receipt lookup run synchronously on the same thread.
        var value = ClaudePermissionLog()
        init() { value.consume(line: "Emitted tool permission request request for Bash in session local_test") }
        func confirm(_ id: String, _ decision: String, _ seconds: Double) -> Bool {
            value.answers[id] == decision
        }
    }

    func testLateApprovalReceiptConfirmsOnlyOriginalRequestAndDecisionWithoutAnotherClick() throws {
        for decision in ["once", "deny"] {
            for evidence in ["matching", "other-request", "opposite", "disappeared"] {
                let receipts = ProviderOperationReceipts()
                let request: [String: Any] = [
                    "id": "operation", "op": "approve", "threadId": "thread",
                    "fingerprint": "fingerprint", "allow": decision == "once",
                ]
                guard case .fresh(let ticket) = try receipts.begin(request, client: "phone") else {
                    return XCTFail("fresh operation required")
                }
                let log = Log()
                var clicks = 0
                XCTAssertThrowsError(
                    try ClaudeBridge.submitApproval(
                        receipts: receipts, ticket: ticket, session: "thread", fingerprint: "fingerprint",
                        requestID: "request", decision: decision, confirmation: log.confirm
                    ) { confirmed in
                        clicks += 1
                        if !confirmed(0) { throw UnconfirmedDesktopMutation(reason: "synthetic timeout") }
                    })
                receipts.finish(ticket, result: ["ok": false, "unknown": true])
                switch evidence {
                case "matching":
                    log.value.consume(line: Substring("Received permission response for request: \(decision)"))
                case "other-request":
                    log.value.consume(line: "Emitted tool permission request other for Bash in session local_test")
                    log.value.consume(line: Substring("Received permission response for other: \(decision)"))
                case "opposite":
                    log.value.consume(
                        line: Substring(
                            "Received permission response for request: \(decision == "once" ? "deny" : "once")"))
                default: log.value.consume(line: "Permission request request aborted")
                }
                for _ in 0..<2 {
                    let reply = receipts.lookup(
                        client: "phone", operation: "operation", thread: "thread", kind: "approve")
                    if evidence == "matching" {
                        XCTAssertEqual(reply["submitted"] as? Bool, true)
                        XCTAssertEqual(reply["fingerprint"] as? String, "fingerprint")
                    } else {
                        XCTAssertEqual(reply["unknown"] as? Bool, true)
                    }
                }
                for (client, thread, kind) in [
                    ("other-phone", "thread", "approve"),
                    ("phone", "other-thread", "approve"), ("phone", "thread", "send"),
                ] {
                    XCTAssertEqual(
                        receipts.lookup(
                            client: client, operation: "operation", thread: thread,
                            kind: kind)["unknown"] as? Bool, true)
                }
                guard case .cached = try receipts.begin(request, client: "phone") else {
                    return XCTFail("receipt query must never admit another click")
                }
                XCTAssertEqual(clicks, 1)
                XCTAssertEqual(
                    ProviderOperationReceipts().lookup(
                        client: "phone", operation: "operation",
                        thread: "thread", kind: "approve")["unknown"] as? Bool, true)
            }
        }
    }

    func testFailureBeforeClickCannotArmApprovalObserver() throws {
        let receipts = ProviderOperationReceipts()
        guard
            case .fresh(let ticket) = try receipts.begin(
                [
                    "id": "operation", "op": "approve", "threadId": "thread", "fingerprint": "fingerprint",
                ], client: "phone")
        else { return XCTFail("fresh operation required") }
        let log = Log()
        XCTAssertThrowsError(
            try ClaudeBridge.submitApproval(
                receipts: receipts, ticket: ticket, session: "thread", fingerprint: "fingerprint",
                requestID: "request", decision: "once", confirmation: log.confirm
            ) { _ in throw CLIError("synthetic preparation failure") })
        receipts.finish(ticket, result: ["ok": false, "unknown": true])
        log.value.consume(line: "Received permission response for request: once")
        XCTAssertEqual(
            receipts.lookup(
                client: "phone", operation: "operation", thread: "thread",
                kind: "approve")["unknown"] as? Bool, true)
    }
}
