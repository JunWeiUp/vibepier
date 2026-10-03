import XCTest

@testable import VibePierCore

final class CodexQuestionsTests: XCTestCase {
    private let operation = "A7C92703-5989-48E2-976A-93F2F7987314"
    private func state(status: String = "inProgress", extra: [[String: Any]] = []) -> [String: Any] {
        [
            "id": "thread",
            "turns": [
                [
                    "turnId": "turn", "status": status,
                    "items": [
                        [
                            "type": "agentMessage", "id": "call/1",
                            "questions": [["title": "选哪一种？", "options": ["方案 A", "方案 B"]], ["title": "补充说明"]],
                        ]
                    ] + extra,
                ]
            ],
        ]
    }
    private func native(freeform: Bool = true) -> [String: Any] {
        [
            "id": 42, "method": CodexQuestions.nativeMethod,
            "params": [
                "turnId": "turn",
                "questions": [
                    [
                        "id": "choice", "question": "选哪一种？", "isOther": freeform,
                        "options": [["label": "A", "description": "说明"]],
                    ],
                    ["id": "note", "question": "说明原因"],
                ],
            ],
        ]
    }
    func testAsyncProjectionAndExactDesktopQuestionIDs() throws {
        let page = CodexConversation.page(state())
        let card = try XCTUnwrap((page["approvals"] as? [[String: Any]])?.first)
        XCTAssertEqual(card["kind"] as? String, "questions")
        XCTAssertNil(card["questions"])  // Loaded on demand, including long options.
        let full = try XCTUnwrap(CodexQuestions.asynchronous(state()).first)
        let questions = try XCTUnwrap(full["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0]["id"] as? String, "[\"request_user_input_async\",\"call/1\",0]")
        XCTAssertTrue(CodexQuestions.asynchronous(state(status: "completed")).isEmpty)
    }
    func testAsyncReplyUsesImmediateSteerAndPreservesQuestionText() throws {
        let card = try XCTUnwrap(CodexQuestions.asynchronous(state()).first)
        let id = ((card["questions"] as? [[String: Any]])?.first?["id"] as? String)!
        let result = try CodexQuestions.submission(
            ["id": operation, "answers": [id: "自己填写的答案"]], projected: card, thread: "thread", cwd: "/tmp")
        XCTAssertEqual(result.method, "thread-follower-steer-turn")
        XCTAssertEqual(result.params["clientUserMessageId"] as? String, operation)
        let input = try XCTUnwrap(result.params["input"] as? [[String: Any]])
        let text = try XCTUnwrap(input.first?["text"] as? String)
        let rows = CodexQuestions.parseReply(text)
        XCTAssertEqual(rows, [["questionItemId": id, "question": "选哪一种？", "answer": "自己填写的答案"]])
        let accepted: [String: Any] = ["type": "steeringUserMessage", "status": "accepted", "input": input]
        let remaining = CodexQuestions.asynchronous(state(extra: [accepted]))
        XCTAssertEqual((remaining.first?["questions"] as? [[String: Any]])?.count, 1)
        XCTAssertNotEqual(card["fingerprint"] as? String, remaining.first?["fingerprint"] as? String)
        let rejected: [String: Any] = ["type": "steeringUserMessage", "status": "rejected", "input": input]
        XCTAssertEqual(
            (CodexQuestions.asynchronous(state(extra: [rejected])).first?["questions"] as? [[String: Any]])?.count, 2)
    }
    func testNativeAnswerMatchesProtocolAndValidatesSelections() throws {
        let card = try XCTUnwrap(CodexQuestions.native(native(freeform: false)))
        let result = try CodexQuestions.submission(
            ["id": operation, "answers": ["choice": "A", "note": "原因"]], projected: card, thread: "thread", cwd: "/tmp")
        XCTAssertEqual(result.method, "thread-follower-submit-user-input")
        XCTAssertEqual(result.params["requestId"] as? Int, 42)
        let response = try XCTUnwrap(result.params["response"] as? [String: Any])
        let answers = try XCTUnwrap(response["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["note"]?["answers"], ["原因"])
        for value in [
            ["choice": "invalid", "note": "原因"], ["choice": "A"], ["other": "x"], ["choice": " ", "note": " "],
        ] {
            XCTAssertThrowsError(
                try CodexQuestions.submission(
                    ["id": operation, "answers": value], projected: card, thread: "thread", cwd: "/tmp"))
        }
    }
    func testChangedNativeQuestionInvalidatesFingerprintAndUnknownShapeIsReadOnly() throws {
        let card = try XCTUnwrap(CodexQuestions.native(native()))
        var changed = native()
        var params = changed["params"] as! [String: Any]
        params["questions"] = [["id": "choice", "question": "修改的问题"]]
        changed["params"] = params
        XCTAssertNotEqual(card["fingerprint"] as? String, CodexQuestions.native(changed)?["fingerprint"] as? String)
        params["questions"] = [["id": "choice"]]
        changed["params"] = params
        let projected = CodexConversation.approvals(["requests": [changed]])
        XCTAssertEqual(projected.first?["canDecide"] as? Bool, false)
    }
    func testReceiptRequiresAcceptedOwnerMessage() {
        for status in ["pending", "rejected", "failed", "accepted"] {
            let value = state(extra: [
                ["type": "steeringUserMessage", "status": status, "clientUserMessageId": operation]
            ])
            XCTAssertEqual(CodexQuestions.acceptedMessage(value, operation: operation), status == "accepted")
        }
        XCTAssertTrue(
            CodexQuestions.acceptedMessage(
                state(extra: [["type": "userMessage", "clientId": operation]]), operation: operation))
        XCTAssertFalse(CodexQuestions.acceptedMessage(state(), operation: operation))
    }
    func testNativeQuestionsAppearWithoutAnyLoadedHistory() {
        let cards = CodexConversation.approvals(["requests": [native()]])
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?["canDecide"] as? Bool, true)
    }
}
