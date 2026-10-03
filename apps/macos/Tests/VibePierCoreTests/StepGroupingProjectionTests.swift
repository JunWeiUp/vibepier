import XCTest

@testable import VibePierCore

final class StepGroupingProjectionTests: XCTestCase {
    func testBuiltinGroupsIgnoreParametersButKeepSemanticBoundaries() throws {
        let calls: [(String, [String: Any], String)] = [
            ("Read", ["file_path": "/a.swift"], "file-read"),
            ("Read", ["file_path": "/b.swift"], "file-read"),
            ("Grep", ["pattern": "one", "path": "/a"], "file-search"),
            ("Glob", ["pattern": "*.swift"], "file-search"),
            ("WebFetch", ["url": "https://example.com/first"], "web-fetch"),
            ("WebFetch", ["url": "https://example.com/second"], "web-fetch"),
            ("WebSearch", ["query": "different query"], "web-search"),
            ("Task", ["description": "one task"], "agent"),
            ("Agent", ["description": "another task"], "agent"),
        ]
        for (index, call) in calls.enumerated() {
            let part = ClaudeTranscript.toolPart(["id": "tool-\(index)", "name": call.0, "input": call.1], cwd: nil)
            XCTAssertEqual(part.extra["groupType"] as? String, call.2)
            XCTAssertEqual(part.extra["toolName"] as? String, call.0)
            let native: [String: Any] = [
                "id": "tool-\(index)", "type": "tool", "tool": call.0,
                "state": ["status": "completed", "input": call.1, "output": "BODY_KEEP_LOCAL"],
            ]
            XCTAssertEqual(ZCodeConversation.part(native).extra["groupType"] as? String, call.2)
            let sequence = try XCTUnwrap(ZCodeConversation.sequence([native], offset: index).first)
            XCTAssertEqual(sequence["groupType"] as? String, call.2)
            XCTAssertEqual(sequence["index"] as? Int, index)
            XCTAssertNil(sequence["output"])
            XCTAssertEqual(sequence["bodyDeferred"] as? Bool, true)
        }
        let first = ClaudeTranscript.toolPart(["id": "a", "name": "Read", "input": ["file_path": "/a"]], cwd: nil)
        let second = ClaudeTranscript.toolPart(["id": "b", "name": "Read", "input": ["file_path": "/b"]], cwd: nil)
        XCTAssertNotEqual(first.title, second.title)
        XCTAssertEqual(first.extra["groupType"] as? String, second.extra["groupType"] as? String)
    }

    func testMCPIdentityIsStableAcrossProvidersAndDifferentMethodsStaySeparate() throws {
        let first = try XCTUnwrap(
            CodexConversation.part(
                ["type": "mcpToolCall", "server": "cua_repl", "tool": "js", "arguments": ["code": "first()"]], id: "c1")
        )
        let second = try XCTUnwrap(
            CodexConversation.part(
                ["type": "mcpToolCall", "server": "cua_repl", "tool": "js", "arguments": ["code": "second()"]], id: "c2"
            ))
        let other = try XCTUnwrap(
            CodexConversation.part(["type": "mcpToolCall", "server": "cua_repl", "tool": "getState"], id: "c3"))
        let claude = ClaudeTranscript.toolPart(
            ["id": "l1", "name": "mcp__cua_repl__js", "input": ["code": "third()"]], cwd: nil)
        let zcode = ZCodeConversation.part([
            "id": "z1", "type": "tool", "tool": "mcp__cua_repl__js", "state": ["input": ["code": "fourth()"]],
        ])
        XCTAssertEqual(first.extra["groupType"] as? String, second.extra["groupType"] as? String)
        XCTAssertEqual(first.extra["groupType"] as? String, claude.extra["groupType"] as? String)
        XCTAssertEqual(first.extra["groupType"] as? String, zcode.extra["groupType"] as? String)
        XCTAssertEqual(first.extra["toolName"] as? String, "cua_repl · js")
        XCTAssertNotEqual(first.extra["groupType"] as? String, other.extra["groupType"] as? String)
        let dynamic = try XCTUnwrap(
            CodexConversation.part(["type": "dynamicToolCall", "tool": "Read"], id: "custom-read"))
        XCTAssertTrue((dynamic.extra["groupType"] as? String ?? "").hasPrefix("tool:"))
        XCTAssertNotEqual(
            dynamic.extra["groupType"] as? String, ConversationReply.toolGrouping("Read")["groupType"] as? String)
        let function = try XCTUnwrap(
            CodexConversation.part(
                ["type": "functionCallOutput", "namespace": "cua_repl", "name": "js", "output": "result"], id: "f1"))
        XCTAssertEqual(first.extra["groupType"] as? String, function.extra["groupType"] as? String)
    }

    func testHeadersOldPartPagesAndOnDemandDetailsKeepTheSameGroupingMetadata() throws {
        let a = ClaudeTranscript.toolPart(["id": "a", "name": "Read", "input": ["file_path": "/a.swift"]], cwd: nil)
        let b = ClaudeTranscript.toolPart(["id": "b", "name": "Read", "input": ["file_path": "/b.swift"]], cwd: nil)
        let rows: [[String: Any]] = [["id": "reply", "role": "assistant", "text": "", "parts": [a.value, b.value]]]
        let preview = try XCTUnwrap(ConversationReply.preview(rows).first?["sequence"] as? [[String: Any]])
        let headers = try XCTUnwrap(
            ConversationReply.partPage(rows, id: "reply", offset: 0, headersOnly: true)?["parts"] as? [[String: Any]])
        let legacy = try XCTUnwrap(
            ConversationReply.partPage(rows, id: "reply", offset: 0)?["parts"] as? [[String: Any]])
        for projected in [preview, headers, legacy] {
            XCTAssertEqual(projected.compactMap { $0["groupType"] as? String }, ["file-read", "file-read"])
            XCTAssertEqual(projected.compactMap { $0["toolName"] as? String }, ["Read", "Read"])
        }
        XCTAssertEqual(ConversationReply.partDetails(rows, id: "a")?["groupType"] as? String, "file-read")
        var modified = a.value
        modified["groupType"] = "web-fetch"
        let changed: [[String: Any]] = [
            ["id": "reply", "role": "assistant", "text": "", "parts": [modified, b.value]]
        ]
        XCTAssertNotEqual(
            ConversationReply.preview(rows).first?["partsVersion"] as? String,
            ConversationReply.preview(changed).first?["partsVersion"] as? String)
    }

    func testThinkingNoticesAndImagesCarryTypesWhilePlansAndQuestionsStayBoundaries() throws {
        for type in [
            "reasoning", "imageView", "imageGeneration", "contextCompaction", "enteredReviewMode", "exitedReviewMode",
        ] {
            let part = try XCTUnwrap(
                CodexConversation.part(
                    ["type": type, "text": "Plan", "summary": ["Reason"], "path": "/image.png"], id: type))
            XCTAssertNotNil(part.extra["groupType"])
        }
        let compaction = ZCodeConversation.part(["id": "z1", "type": "compaction", "timelineStatus": "completed"])
        let model = ZCodeConversation.part([
            "id": "z2", "type": "timeline", "timelineType": "model_change", "status": "completed",
        ])
        XCTAssertNotEqual(compaction.extra["groupType"] as? String, model.extra["groupType"] as? String)
        let image = ZCodeConversation.part([
            "id": "z3", "type": "file", "mime": "image/png", "filename": "different.png", "imageDeferred": true,
        ])
        XCTAssertEqual(image.extra["groupType"] as? String, "image-view")
        let plan = try XCTUnwrap(CodexConversation.part(["type": "plan", "text": "Keep this visible"], id: "plan"))
        XCTAssertNil(plan.extra["groupType"])
        let todo = ClaudeTranscript.toolPart(["id": "todo", "name": "TodoWrite", "input": ["todos": []]], cwd: nil)
        XCTAssertEqual(todo.kind, "plan")
        XCTAssertNil(todo.extra["groupType"])
        let zcodeTodo = ZCodeConversation.part([
            "id": "todo", "type": "tool", "tool": "TodoWrite", "state": ["input": ["todos": []]],
        ])
        XCTAssertEqual(
            zcodeTodo.extra["groupType"] as? String, "plan", "lazy tool-shaped checklist remains a grouping boundary")
        XCTAssertEqual(ConversationReply.toolGrouping("AskUserQuestion")["groupType"] as? String, "approval")
        XCTAssertEqual(ConversationReply.toolGrouping("ExitPlanMode")["groupType"] as? String, "approval")
        XCTAssertEqual(ConversationReply.toolGrouping("EnterPlanMode")["groupType"] as? String, "plan")
        let request = try XCTUnwrap(
            CodexConversation.part(["type": "dynamicToolCall", "tool": "request_user_input"], id: "question"))
        XCTAssertEqual(request.extra["groupType"] as? String, "approval")
    }

    func testEightLongUnicodeToolNamesKeepTheirFullIdentitiesInsidePreviewBudget() throws {
        let namespacePrefix = String(repeating: "长命名空间🐱", count: 200)
        let methodPrefix = String(repeating: "长方法🐶", count: 200)
        let parts = try (0..<8).map { index -> ConversationReply.Part in
            try XCTUnwrap(
                CodexConversation.part(
                    [
                        "type": "mcpToolCall", "server": namespacePrefix + "-\(index % 2)",
                        "tool": methodPrefix + "-\(index / 2)", "status": "completed",
                        "result": ["content": [["type": "text", "text": "BODY_STAYS_ON_MAC"]]],
                    ], id: "native-\(index)"))
        }
        let rows: [[String: Any]] = [["id": "reply", "role": "assistant", "text": "", "parts": parts.map(\.value)]]
        let preview = ConversationReply.preview(rows)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: preview).count, 12_000)
        let headers = try XCTUnwrap(preview.first?["sequence"] as? [[String: Any]])
        XCTAssertEqual(headers.count, 8)
        for (index, header) in headers.enumerated() {
            XCTAssertEqual(header["id"] as? String, "native-\(index)")
            XCTAssertEqual(header["groupType"] as? String, parts[index].extra["groupType"] as? String)
            XCTAssertEqual((header["groupType"] as? String)?.count, 69, "the complete tool identity hash is retained")
            let label = try XCTUnwrap(header["toolName"] as? String)
            XCTAssertLessThanOrEqual(label.count, 128)
            XCTAssertLessThanOrEqual(label.utf8.count, 512)
            XCTAssertEqual(header["bodyDeferred"] as? Bool, true)
            XCTAssertFalse((header["text"] as? String ?? "").contains("BODY_STAYS_ON_MAC"))
        }
        XCTAssertEqual(
            headers[0]["toolName"] as? String, headers[1]["toolName"] as? String,
            "display names may share a truncated prefix")
        XCTAssertNotEqual(
            headers[0]["groupType"] as? String, headers[1]["groupType"] as? String,
            "different long namespaces remain separate")
        XCTAssertNotEqual(
            headers[0]["groupType"] as? String, headers[2]["groupType"] as? String,
            "different long methods remain separate")
        XCTAssertEqual(Set(headers.compactMap { $0["groupType"] as? String }).count, 8)
    }
}
