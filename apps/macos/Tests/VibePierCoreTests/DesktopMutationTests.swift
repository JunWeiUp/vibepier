import XCTest

@testable import VibePierCore

final class DesktopMutationTests: XCTestCase {
    func testCreationPreparationFailureDoesNotClaimMessageSubmissionWhileSettingsStayUnknown() {
        let prepare = { () throws -> Void in
            try DesktopMutationScope.run { scope in
                try scope.attempt {}
                throw CLIError("Mode readback unavailable")
            }
        }
        XCTAssertThrowsError(try prepare()) { error in
            XCTAssertTrue(error is UnconfirmedDesktopMutation)
        }
        XCTAssertThrowsError(try DesktopMutationScope.beforeCreationSubmission(prepare)) { error in
            XCTAssertFalse(error is UnconfirmedDesktopMutation)
            XCTAssertNil(ProviderFailure.reply(error, provider: "zcode")["unknown"])
        }
        XCTAssertThrowsError(try UnconfirmedDesktopMutation.attempting { throw CLIError("Send acknowledgement lost") })
        { error in
            XCTAssertEqual(ProviderFailure.reply(error, provider: "zcode")["unknown"] as? Bool, true)
        }
    }

    func testClaudeLateNativeReceiptResolvesOriginalOperationWithoutResubmitting() throws {
        let receipts = ProviderOperationReceipts()
        let request: [String: Any] = ["op": "send", "id": "operation", "threadId": "thread", "text": "fixture"]
        guard case .fresh(let ticket) = try receipts.begin(request, client: "phone") else {
            return XCTFail("fresh request required")
        }
        let proof = ClaudeSendReceipt(entries: [user("anchor", "earlier")], text: "fixture")
        final class Transcript: @unchecked Sendable {
            let lock = NSLock()
            var entries: [[String: Any]] = []
        }
        let transcript = Transcript()
        transcript.entries = [user("anchor", "earlier")]
        try receipts.observe(ticket, bytes: proof.retainedBytes) {
            guard let id = transcript.lock.withLock({ proof.confirmedMessage(in: transcript.entries) }) else {
                return nil
            }
            return ["ok": true, "accepted": true, "threadId": "thread", "nativeMessageId": id]
        }
        receipts.arm(ticket)
        _ = receipts.finish(ticket, result: ["ok": false, "unknown": true])
        XCTAssertEqual(
            receipts.lookup(client: "phone", operation: "operation", thread: "thread", kind: "send")["unknown"]
                as? Bool, true)
        transcript.lock.withLock { transcript.entries.append(user("actual-native-message", "fixture")) }
        let result = receipts.lookup(client: "phone", operation: "operation", thread: "thread", kind: "send")
        XCTAssertEqual(result["accepted"] as? Bool, true)
        XCTAssertEqual(result["nativeMessageId"] as? String, "actual-native-message")
        guard case .cached(let cached) = try receipts.begin(request, client: "phone") else {
            return XCTFail("resolved send must not be admitted again")
        }
        XCTAssertEqual(cached["accepted"] as? Bool, true)
        XCTAssertEqual(
            receipts.lookup(client: "other", operation: "operation", thread: "thread", kind: "send")["unknown"]
                as? Bool, true)
    }

    func testDesktopSessionIdentityCannotMatchAPrefixOrQueryParameter() {
        XCTAssertTrue(ClaudeDesktop.matchesSession("local_a", address: "https://claude.ai/code/local_a"))
        XCTAssertFalse(ClaudeDesktop.matchesSession("local_a", address: "https://claude.ai/code/local_ab"))
        XCTAssertFalse(ClaudeDesktop.matchesSession("local_a", address: "https://claude.ai/code/local_b?other=local_a"))
    }

    func testChangedIdentityDuringPreparationDoesNotSubmit() {
        var current = true
        var submissions = 0
        XCTAssertThrowsError(
            try DesktopMutationScope.confirmedAction(
                isCurrent: { current },
                prepare: {
                    current = false
                    return { submissions += 1 }
                },
                confirmed: {
                    XCTFail("No confirmation before submission")
                    return false
                },
                unavailable: "changed", unconfirmed: "uncertain")
        ) {
            XCTAssertFalse($0 is UnconfirmedDesktopMutation)
        }
        XCTAssertEqual(submissions, 0)
    }

    func testDelayedOrFailedConfirmationNeverSubmitsTwiceAndKeepsUnknownReply() {
        for diagnostic in ["delayed", "延迟回执", "{0} %s"] {
            var submissions = 0
            XCTAssertThrowsError(
                try DesktopMutationScope.confirmedAction(
                    isCurrent: { true }, prepare: { { submissions += 1 } }, confirmed: { false },
                    unavailable: "unavailable", unconfirmed: diagnostic)
            ) { error in
                XCTAssertTrue(error is UnconfirmedDesktopMutation)
                for provider in ["claude", "zcode"] {
                    let result = ProviderFailure.reply(error, provider: provider)
                    XCTAssertEqual(result["unknown"] as? Bool, true)
                    XCTAssertEqual(result["ok"] as? Bool, false)
                    XCTAssertNil(result["accepted"])
                    XCTAssertTrue((result["error"] as? String ?? "").contains(diagnostic))
                }
            }
            XCTAssertEqual(submissions, 1)
        }
    }

    func testConfirmedActionSubmitsOnceAndWaitsForExplicitReceipt() throws {
        var events: [String] = []
        try DesktopMutationScope.confirmedAction(
            isCurrent: { true }, prepare: { { events.append("submit") } },
            confirmed: {
                events.append("native-receipt")
                return true
            },
            unavailable: "unavailable", unconfirmed: "uncertain")
        XCTAssertEqual(events, ["submit", "native-receipt"])
    }

    func testPartialSettingsChangeCannotBecomeKnownFailure() {
        var effects = 0
        XCTAssertThrowsError(
            try DesktopMutationScope.run { scope in
                try scope.attempt { effects += 1 }
                throw CLIError("A later menu changed before its click")
            }
        ) { XCTAssertTrue($0 is UnconfirmedDesktopMutation) }
        XCTAssertEqual(effects, 1)
        XCTAssertThrowsError(try DesktopMutationScope.run { _ in throw CLIError("preflight") }) {
            XCTAssertNil(ProviderFailure.reply($0, provider: "claude")["unknown"])
        }
    }

    private func user(_ id: String, _ text: String, extra: [String: Any] = [:]) -> [String: Any] {
        var entry: [String: Any] = ["uuid": id, "type": "user", "message": ["content": text]]
        entry.merge(extra) { _, new in new }
        return entry
    }

    func testSendReceiptRequiresUniqueNewNativeUserMessageWithFullBody() {
        let text = "<div>完整内容 {0} %s</div>\nsecond line"
        let baseline = [user("old", text)]
        let receipt = ClaudeSendReceipt(entries: baseline, text: text)
        XCTAssertNil(receipt.confirmedMessage(in: baseline))
        XCTAssertNil(receipt.confirmedMessage(in: baseline + [user("new", String(text.prefix(24)))]))
        XCTAssertNil(receipt.confirmedMessage(in: baseline + [user("old", text)]))
        XCTAssertEqual(receipt.confirmedMessage(in: baseline + [user("new", text)]), "new")
        XCTAssertNil(receipt.confirmedMessage(in: baseline + [user("new", text), user("other", text)]))
        XCTAssertNil(receipt.confirmedMessage(in: [user("new", text)]), "Replaced/truncated history loses the anchor")
    }

    func testSendReceiptToleratesDesktopParagraphRewrites() {
        let text = "看这张图\n\n用户附加文件：shot.jpg\nMac 本地路径：/tmp/a b/shot.jpg"
        let baseline = [user("old", "before")]
        let receipt = ClaudeSendReceipt(entries: baseline, text: text)
        let rewritten = "看这张图\n用户附加文件：shot.jpg\n\nMac 本地路径：/tmp/a b/shot.jpg\n"
        XCTAssertEqual(receipt.confirmedMessage(in: baseline + [user("new", rewritten)]), "new")
        XCTAssertNil(receipt.confirmedMessage(in: baseline + [user("new", "看这张图\n用户附加文件：shot.jpg")]))
    }

    func testInjectedMetadataAndToolResultsCannotConfirmSend() {
        let baseline = [user("old", "before")]
        let receipt = ClaudeSendReceipt(entries: baseline, text: "hello")
        for extra: [String: Any] in [
            ["isMeta": true], ["isCompactSummary": true], ["isSidechain": true], ["type": "assistant"], ["uuid": ""],
        ] {
            XCTAssertNil(receipt.confirmedMessage(in: baseline + [user("new", "hello", extra: extra)]))
        }
        let result = user(
            "tool", "hello", extra: ["message": ["content": [["type": "tool_result", "content": "hello"]]]])
        XCTAssertNil(receipt.confirmedMessage(in: baseline + [result]))
        let textBlocks = user("new", "", extra: ["message": ["content": [["type": "text", "text": "hello"]]]])
        XCTAssertEqual(receipt.confirmedMessage(in: baseline + [textBlocks]), "new")
        XCTAssertNotEqual(
            ClaudeSendReceipt.activeTurn(entries: baseline, host: "local_host"),
            ClaudeSendReceipt.activeTurn(entries: baseline + [user("new", "before")], host: "local_host"))
    }

    func testApprovalRequiresMatchingNativeAnswerNotDisappearanceOrAbort() {
        var log = ClaudePermissionLog()
        log.consume(line: "Emitted tool permission request first for Bash in session local_host")
        log.consume(line: "Permission request first for Bash aborted")
        XCTAssertNil(log.answers["first"])
        log.consume(line: "Received permission response for never-seen: once (tool: Bash)")
        XCTAssertNil(log.answers["never-seen"])
        log.consume(line: "Emitted tool permission request second for Bash in session local_host")
        log.consume(line: "Received permission response for second: deny (tool: Bash)")
        XCTAssertEqual(log.answers["second"], "deny")
        XCTAssertNotEqual(log.answers["second"], "once")
        log.consume(line: "Emitted tool permission request third for Read in session local_host")
        log.consume(line: "LocalSessions.respondToToolPermission: requestId=third, decision=once, hasUpdatedInput=true")
        XCTAssertEqual(log.answers["third"], "once")
        log.consume(line: "Emitted tool permission request third for Read in session local_host")
        XCTAssertNil(log.answers["third"], "Reusing a request ID cannot reuse an older answer")
    }

    func testStopConfirmationAllowsNativeInterruptMarkerButNotANewerPrompt() {
        let before = [user("original", "work")]
        let expected = "desktop:local_host:original"
        let marker = user("marker", "[Request interrupted by user]")
        XCTAssertTrue(ClaudeSendReceipt.stoppedTurn(entries: before, host: "local_host", expected: expected))
        XCTAssertTrue(ClaudeSendReceipt.stoppedTurn(entries: before + [marker], host: "local_host", expected: expected))
        XCTAssertFalse(
            ClaudeSendReceipt.stoppedTurn(
                entries: before + [user("later", "new work"), marker], host: "local_host", expected: expected))
        XCTAssertFalse(ClaudeSendReceipt.stoppedTurn(entries: before, host: "local_other", expected: expected))
    }
}
