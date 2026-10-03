import Foundation

/// Desktop build 12553: native requestUserInput and agentMessage.questions use different reply routes.
enum CodexQuestions {
    static let nativeMethod = "item/tool/requestUserInput"
    static let asyncMethod = "vibepier/asyncQuestions"

    static func native(_ request: [String: Any]) -> [String: Any]? {
        guard request["method"] as? String == nativeMethod, request["completed"] as? Bool != true,
            let params = request["params"] as? [String: Any], let id = request["id"],
            let raw = params["questions"] as? [[String: Any]], !raw.isEmpty
        else { return nil }
        let questions = raw.compactMap { question -> [String: Any]? in
            guard let id = question["id"] as? String, !id.isEmpty,
                let text = question["question"] as? String, !text.isEmpty
            else { return nil }
            let options = question["options"] as? [[String: Any]] ?? []
            guard options.allSatisfy({ $0["label"] is String }) else { return nil }
            return [
                "id": id, "question": text, "header": question["header"] as? String ?? "",
                "options": options, "freeform": options.isEmpty || question["isOther"] as? Bool == true,
                "secret": question["isSecret"] as? Bool == true,
            ]
        }
        guard questions.count == raw.count, Set(questions.compactMap { $0["id"] as? String }).count == questions.count
        else { return nil }
        return project(
            id: id, method: nativeMethod, turn: params["turnId"] as? String ?? "", questions: questions, source: request
        )
    }

    static func asynchronous(_ state: [String: Any]) -> [[String: Any]] {
        CodexConversation.turns(state).compactMap { turn in
            guard turn["status"] as? String == "inProgress", let turnID = turn["turnId"] as? String else { return nil }
            let items = turn["items"] as? [[String: Any]] ?? []
            let answered = Set(
                items.flatMap { item -> [String] in
                    let type = item["type"] as? String
                    guard
                        type == "userMessage"
                            || (type == "steeringUserMessage" && item["status"] as? String == "accepted")
                    else { return [] }
                    let input = item[type == "userMessage" ? "content" : "input"] as? [[String: Any]] ?? []
                    guard input.count == 1, let text = input.first?["text"] as? String else { return [] }
                    return parseReply(text).filter {
                        !($0["answer"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }.compactMap { $0["questionItemId"] }
                })
            let questions = items.flatMap { item -> [[String: Any]] in
                guard item["type"] as? String == "agentMessage", let itemID = item["id"] as? String,
                    let raw = item["questions"] as? [[String: Any]]
                else { return [] }
                return raw.enumerated().compactMap { index, question in
                    guard let text = question["title"] as? String, !text.isEmpty,
                        let bytes = try? JSONSerialization.data(
                            withJSONObject: ["request_user_input_async", itemID, index],
                            options: [.withoutEscapingSlashes]),
                        let id = String(data: bytes, encoding: .utf8), !answered.contains(id)
                    else { return nil }
                    let options = question["options"] as? [String] ?? []
                    return [
                        "id": id, "question": text, "options": options.map { ["label": $0, "description": ""] },
                        "freeform": true, "secret": false,
                    ]
                }
            }
            guard !questions.isEmpty else { return nil }
            return project(
                id: "async:" + turnID, method: asyncMethod, turn: turnID, questions: questions,
                source: ["turnId": turnID, "questions": questions])
        }
    }

    private static func project(
        id: Any, method: String, turn: String, questions: [[String: Any]], source: [String: Any]
    ) -> [String: Any] {
        let size = (try? JSONSerialization.data(withJSONObject: questions).count) ?? Int.max
        let supported = size <= 60_000 && questions.count <= 32 && !questions.contains { $0["secret"] as? Bool == true }
        return [
            "id": id, "fingerprint": CodexConversation.fingerprint(["source": source]),
            "title": L10n.text("session.answer_codex_s_questions"),
            "method": method, "kind": "questions", "turnId": turn, "questions": supported ? questions : [],
            "details": supported
                ? L10n.text("session.choose_an_option_or_enter_an_answer_then_submit")
                : L10n.text("session.answer_these_questions_on_the_mac"),
            "canDecide": supported,
        ]
    }

    /// A pending/rejected steering bubble is not evidence that the owner received an answer.
    static func acceptedMessage(_ state: [String: Any], operation: String) -> Bool {
        CodexConversation.turns(state).flatMap { $0["items"] as? [[String: Any]] ?? [] }.contains { item in
            let type = item["type"] as? String
            return (type == "userMessage" || (type == "steeringUserMessage" && item["status"] as? String == "accepted"))
                && (item["clientId"] as? String ?? item["clientUserMessageId"] as? String) == operation
        }
    }

    static func parseReply(_ text: String) -> [[String: String]] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = "<send_user_message_question_reply>"
        let end = "</send_user_message_question_reply>"
        guard text.hasPrefix(start), text.hasSuffix(end),
            let bytes = String(text.dropFirst(start.count).dropLast(end.count)).data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: bytes)
        else { return [] }
        return value as? [[String: String]] ?? (value as? [String: String]).map { [$0] } ?? []
    }

    static func submission(_ request: [String: Any], projected: [String: Any], thread: String, cwd: String) throws -> (
        method: String, params: [String: Any]
    ) {
        guard projected["canDecide"] as? Bool == true,
            let questions = projected["questions"] as? [[String: Any]], !questions.isEmpty,
            let answers = request["answers"] as? [String: String], !answers.isEmpty,
            let operation = request["id"] as? String, UUID(uuidString: operation) != nil,
            (try JSONSerialization.data(withJSONObject: answers)).count <= 32_000
        else { throw CLIError(L10n.text("session.enter_an_answer_up_to_32_kb")) }
        let ids = Set(questions.compactMap { $0["id"] as? String })
        guard Set(answers.keys).isSubset(of: ids) else {
            throw CLIError(L10n.text("session.the_questions_changed_review_them_again"))
        }
        var rows: [[String: String]] = []
        for question in questions {
            let id = question["id"] as? String ?? ""
            let answer = (answers[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty { continue }
            let options = question["options"] as? [[String: Any]] ?? []
            guard question["freeform"] as? Bool == true || options.contains(where: { $0["label"] as? String == answer })
            else { throw CLIError(L10n.text("session.choose_one_of_the_provided_options")) }
            rows.append(["questionItemId": id, "question": question["question"] as? String ?? "", "answer": answer])
        }
        guard !rows.isEmpty else { throw CLIError(L10n.text("session.answer_at_least_one_question")) }
        if projected["method"] as? String == nativeMethod {
            guard rows.count == questions.count else {
                throw CLIError(L10n.text("session.answer_all_questions_before_submitting"))
            }
            let values = Dictionary(
                uniqueKeysWithValues: rows.map { ($0["questionItemId"]!, ["answers": [$0["answer"]!]]) })
            return (
                "thread-follower-submit-user-input",
                ["conversationId": thread, "requestId": projected["id"]!, "response": ["answers": values]]
            )
        }
        guard projected["method"] as? String == asyncMethod else {
            throw CLIError(L10n.text("session.unsupported_question_type"))
        }
        let text =
            "<send_user_message_question_reply>\n"
            + String(
                decoding: try JSONSerialization.data(
                    withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            + "\n</send_user_message_question_reply>"
        var restore = CodexFollowUps.message(id: operation, text: text, cwd: cwd, files: [], images: [])
        var context = restore["context"] as? [String: Any] ?? [:]
        context["turnTrigger"] = "send_user_message_async_question"
        restore["context"] = context
        return (
            "thread-follower-steer-turn",
            [
                "conversationId": thread, "input": [["type": "text", "text": text, "text_elements": []]],
                "restoreMessage": restore, "attachments": [], "clientUserMessageId": operation,
            ]
        )
    }
}
