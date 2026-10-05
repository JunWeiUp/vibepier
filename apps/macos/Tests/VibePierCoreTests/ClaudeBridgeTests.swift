import ImageIO
import XCTest

@testable import VibePierCore

final class ClaudeBridgeTests: XCTestCase {
    func testCurrentBlockerClearsOnProgressInterruptAndNewPrompt() {
        let error: [String: Any] = ["type": "system", "subtype": "api_error", "error": ["status": 429]]
        XCTAssertEqual(ClaudeTranscript.blocker([error])?["code"] as? String, "rateLimit")
        XCTAssertNil(ClaudeTranscript.blocker([error, ["type": "assistant", "message": ["content": []]]]))
        XCTAssertNil(ClaudeTranscript.blocker([error, ["type": "user", "message": ["content": "Next"]]]))
        XCTAssertNil(
            ClaudeTranscript.blocker([error, ["type": "user", "message": ["content": ClaudeTranscript.interrupted]]]))
        XCTAssertNil(ClaudeTranscript.blocker([error.merging(["isSidechain": true]) { _, new in new }]))
    }

    func testAPIRetriesShowOneSafeNoticePerTurn() throws {
        let failure: [String: Any] = [
            "type": "system", "subtype": "api_error", "uuid": "error-1",
            "error": ["status": 429, "message": "SECRET https://private.invalid/token"],
        ]
        let entries: [[String: Any]] = [
            ["type": "user", "uuid": "u1", "message": ["content": "Hello"]],
            failure, failure.merging(["uuid": "error-2"]) { _, new in new },
            failure.merging(["isSidechain": true]) { _, new in new },
            ["type": "assistant", "uuid": "a1", "message": ["content": [["type": "text", "text": "Recovered"]]]],
            ["type": "user", "uuid": "u2", "message": ["content": "Next"]],
            failure.merging(["uuid": "error-3", "error": ["status": 503]]) { _, new in new },
        ]
        let turns = ClaudeTranscript.turns(entries)
        XCTAssertEqual(turns.count, 2)
        let first = try XCTUnwrap(turns[0].last?["parts"] as? [[String: Any]])
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0]["text"] as? String, L10n.text("provider.claude_rate_limited"))
        XCTAssertEqual(first[1]["text"] as? String, "Recovered")
        let second = try XCTUnwrap(turns[1].last?["parts"] as? [[String: Any]])
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0]["text"] as? String, L10n.text("provider.claude_api_unavailable"))
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: turns), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SECRET"))
        XCTAssertFalse(encoded.contains("private.invalid"))
    }

    func testMissingToolNamesDoNotTurnTranslatedLabelsIntoGroupIdentifiers() {
        let claude = ClaudeTranscript.toolPart(["id": "missing-tool", "input": [:]], cwd: nil)
        let zcode = ZCodeConversation.part(["id": "missing-tool", "type": "tool", "state": [:]])
        for part in [claude, zcode] {
            XCTAssertEqual(part.title, L10n.text("session.tool"))
            XCTAssertNil(part.extra["toolName"])
            XCTAssertNil(part.extra["groupType"])
        }
        let nativeName = "用户工具 {0} %s"
        let named = ClaudeTranscript.toolPart(["id": "native-tool", "name": nativeName, "input": [:]], cwd: nil)
        XCTAssertEqual(named.title, nativeName)
        XCTAssertEqual(named.extra["toolName"] as? String, nativeName)
        XCTAssertEqual(
            named.extra["groupType"] as? String, ConversationReply.toolGrouping(nativeName)["groupType"] as? String)
    }

    func testLightSummaryKeepsLatestTitlesAndSkipsToolOnlyUserRecords() throws {
        let entries: [[String: Any]] = [
            ["type": "user", "cwd": "/wrong", "message": ["content": [["type": "tool_result", "content": "output"]]]],
            ["type": "user", "cwd": "/project", "message": ["content": "First real question"]],
            ["type": "ai-title", "aiTitle": "Generated"],
            ["type": "custom-title", "customTitle": "Older name"],
            ["type": "custom-title", "customTitle": "Current name"],
            ["type": "assistant", "message": ["content": String(repeating: "output", count: 100000)]],
        ]
        let data = try entries.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(into: Data()) {
            $0.append($1)
            $0.append(10)
        }
        let summary = try XCTUnwrap(ClaudeSessionSummary.read(data))
        XCTAssertEqual(summary.title, "Current name")
        XCTAssertEqual(summary.cwd, "/project")
        XCTAssertEqual(ClaudeSessionSummary.read(data, customTitle: "Sidecar name")?.title, "Sidecar name")
        let spaced = String(decoding: try JSONSerialization.data(withJSONObject: entries[1]), as: UTF8.self)
            .replacingOccurrences(of: "\"type\":", with: "\"type\" : ")
        XCTAssertEqual(ClaudeSessionSummary.read(Data(spaced.utf8))?.title, "First real question")
    }
    func testTranscriptGroupsEachTurnIntoOneReplyWithToolSteps() throws {
        let entries: [[String: Any]] = [
            [
                "type": "user", "uuid": "u0",
                "message": ["content": "<local-command-caveat>ignore</local-command-caveat>"],
            ],
            ["type": "user", "uuid": "u1", "message": ["content": "修复登录"]],
            [
                "type": "assistant", "uuid": "a1",
                "message": ["id": "m1", "content": [["type": "thinking", "thinking": "先读文件"]]],
            ],
            [
                "type": "assistant", "uuid": "a2",
                "message": [
                    "id": "m1",
                    "content": [
                        ["type": "text", "text": "先看代码"],
                        [
                            "type": "tool_use", "id": "t1", "name": "Bash",
                            "input": ["command": "swift test", "description": "跑测试"],
                        ],
                    ],
                ],
            ],
            [
                "type": "user", "uuid": "r1",
                "message": [
                    "content": [["type": "tool_result", "tool_use_id": "t1", "content": "1 failure", "is_error": true]]
                ],
            ],
            [
                "type": "assistant", "uuid": "a3",
                "message": [
                    "id": "m2",
                    "content": [
                        [
                            "type": "tool_use", "id": "t2", "name": "Edit",
                            "input": ["file_path": "/r/a.swift", "old_string": "a", "new_string": "b\nc"],
                        ]
                    ],
                ],
            ],
            [
                "type": "user", "uuid": "r2",
                "message": [
                    "content": [
                        ["type": "tool_result", "tool_use_id": "t2", "content": [["type": "text", "text": "ok"]]]
                    ]
                ],
            ],
            [
                "type": "assistant", "uuid": "a4",
                "message": [
                    "id": "m3",
                    "content": [["type": "tool_use", "id": "t3", "name": "mcp__docs__search", "input": ["q": "x"]]],
                ],
            ],
            [
                "type": "user", "uuid": "r3",
                "message": ["content": [["type": "tool_result", "tool_use_id": "t3", "content": "found"]]],
            ],
            [
                "type": "assistant", "uuid": "a5",
                "message": ["id": "m4", "content": [["type": "text", "text": "已修复"]]],
            ],
            ["type": "user", "uuid": "s1", "isSidechain": true, "message": ["content": "subagent prompt"]],
            ["type": "user", "uuid": "c1", "isCompactSummary": true, "message": ["content": "summary"]],
            ["type": "user", "uuid": "u2", "message": ["content": [["type": "text", "text": "再跑测试"]]]],
            [
                "type": "assistant", "uuid": "a6",
                "message": [
                    "id": "m5",
                    "content": [["type": "tool_use", "id": "t4", "name": "Bash", "input": ["command": "sleep 9"]]],
                ],
            ],
            [
                "type": "user", "uuid": "i1",
                "message": ["content": [["type": "text", "text": "[Request interrupted by user]"]]],
            ],
            ["type": "ai-title", "aiTitle": "登录修复"],
        ]
        let turns = ClaudeTranscript.turns(entries)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].map { $0["role"] as? String }, ["user", "assistant"])
        XCTAssertEqual(turns[0].map { $0["text"] as? String }, ["修复登录", "先看代码\n\n已修复"])
        let parts = try XCTUnwrap(turns[0][1]["parts"] as? [[String: Any]])
        XCTAssertEqual(
            parts.compactMap { $0["kind"] as? String }, ["thinking", "text", "command", "file", "tool", "text"])
        XCTAssertEqual(parts[2]["title"] as? String, "swift test")
        XCTAssertEqual(parts[2]["text"] as? String, "1 failure")
        XCTAssertEqual(parts[2]["status"] as? String, "failed")
        XCTAssertEqual(parts[2]["description"] as? String, "跑测试")
        XCTAssertEqual(parts[3]["text"] as? String, "*** update /r/a.swift\n-a\n+b\n+c")
        XCTAssertEqual(parts[3]["status"] as? String, "completed")
        XCTAssertEqual(parts[4]["title"] as? String, "docs · search")
        XCTAssertTrue((parts[4]["text"] as? String ?? "").hasSuffix(L10n.text("provider.result") + "found"))
        XCTAssertEqual(turns[1].first?["text"] as? String, "再跑测试")
        let second = try XCTUnwrap(turns[1].last?["parts"] as? [[String: Any]])
        XCTAssertEqual(
            second.compactMap { $0["status"] as? String }, ["declined", "declined"],
            "interrupt stops the running command")
        XCTAssertEqual(ClaudeTranscript.title(entries), "登录修复")
        XCTAssertEqual(ClaudeTranscript.title(entries + [["type": "custom-title", "customTitle": "手动标题"]]), "手动标题")
        let page = ClaudeTranscript.page(entries)
        XCTAssertEqual((page["messages"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(page["hasOlder"] as? Bool, true)
        let earlier = try XCTUnwrap(
            ConversationReply.older(turns, before: try XCTUnwrap(turns[1].first?["id"] as? String)))
        XCTAssertEqual(earlier.rows.compactMap { $0["text"] as? String }.first, "修复登录")
        XCTAssertEqual(earlier.start, 0)
        XCTAssertNil(ConversationReply.older(turns, before: "gone"))
        XCTAssertEqual(ConversationReply.fullText(ClaudeTranscript.messages(entries), id: "t1"), "1 failure")
    }

    func testImagesStayOnMacAndAreServedByIDAsJPEG() throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image: [String: Any] = [
            "type": "image",
            "source": ["type": "base64", "media_type": "image/png", "data": (png as Data).base64EncodedString()],
        ]
        let entries: [[String: Any]] = [
            ["type": "user", "uuid": "u1", "message": ["content": [image]]],
            [
                "type": "assistant", "uuid": "a1",
                "message": [
                    "content": [["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/r/a.png"]]]
                ],
            ],
            [
                "type": "user", "uuid": "r1",
                "message": [
                    "content": [
                        [
                            "type": "tool_result", "tool_use_id": "t1",
                            "content": [image, ["type": "text", "text": "ok"]],
                        ]
                    ]
                ],
            ],
        ]
        let rows = ClaudeTranscript.messages(entries)
        let page = ConversationReply.bounded(rows)
        XCTAssertEqual(page[0]["text"] as? String, "", "an image-only message is still the person's message")
        XCTAssertEqual((page[0]["images"] as? [[String: Any]])?.first?["id"] as? String, "u1#0")
        let part = try XCTUnwrap((page[1]["parts"] as? [[String: Any]])?.first)
        XCTAssertEqual(part["text"] as? String, L10n.text("provider.result") + "ok")
        XCTAssertEqual((part["images"] as? [[String: Any]])?.first?["id"] as? String, "t1#0")
        XCTAssertNil(part[ConversationReply.imageKey], "sources never leave the Mac in a page")
        XCTAssertNil(ConversationReply.image(rows, id: "t1#1"))
        let jpeg = try ConversationReply.jpeg(try XCTUnwrap(ConversationReply.image(rows, id: "t1#0")), maxPixel: 480)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertThrowsError(try ConversationReply.jpeg("/nonexistent/x.png", maxPixel: 480))
    }

    func testModelNamesMatchClaudeCodeLabels() {
        XCTAssertEqual(ClaudeBridge.modelName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ClaudeBridge.modelName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ClaudeBridge.modelName("claude-sonnet-5"), "Sonnet 5")
    }

    func testDesktopControlsPreserveModeAndUsageWhenUpdatingModelCatalog() {
        var controls = ClaudeDesktop.Controls(model: "Opus 4.7", effort: "medium", models: [])
        controls.mode = "auto"
        controls.contextUsage = "Context 84.7k / 200k (42%)"
        let updated = controls.withModels(["Opus 4.7", "Sonnet 5"])
        XCTAssertEqual(updated.mode, "auto")
        XCTAssertEqual(updated.contextUsage, controls.contextUsage)
        XCTAssertEqual(updated.models.count, 2)
        XCTAssertEqual(ClaudeDesktop.modeID("Manual"), "default")
        XCTAssertEqual(ClaudeDesktop.modeID("Accept edits"), "acceptEdits")
        XCTAssertEqual(ClaudeDesktop.modeID("Bypass permissions"), "bypassPermissions")
        XCTAssertNil(ClaudeDesktop.modeID("Unknown"))
    }

    func testDesktopEffortSliderMappingAndModelSupport() {
        XCTAssertEqual(ClaudeDesktop.effortValue("low"), 0)
        XCTAssertEqual(ClaudeDesktop.effortValue("medium"), 1)
        XCTAssertEqual(ClaudeDesktop.effortValue("high"), 2)
        XCTAssertNil(ClaudeDesktop.effortValue("xhigh"))
        XCTAssertNil(ClaudeDesktop.effortValue("default"))
        XCTAssertEqual(ClaudeDesktop.efforts(for: "Opus 4.7"), ["low", "medium", "high"])
        XCTAssertEqual(ClaudeDesktop.efforts(for: "Sonnet 5"), ["low", "medium", "high"])
        XCTAssertEqual(ClaudeDesktop.efforts(for: "Haiku 4.5"), ["default"])
    }

    func testDesktopGatewayMenuLabelsKeepFullModelVersion() {
        XCTAssertEqual(ClaudeDesktop.modelLabel("Sonnet 5 Most efficient for everyday tasks"), "Sonnet 5")
        XCTAssertEqual(ClaudeDesktop.modelLabel("Opus 5.5 Most capable for ambitious work"), "Opus 5.5")
        XCTAssertEqual(ClaudeDesktop.modelLabel("Haiku 4.5 Fastest for quick answers"), "Haiku 4.5")
        XCTAssertNil(ClaudeDesktop.modelLabel("Unsupported model"))
        XCTAssertNil(ClaudeDesktop.modelLabel("sonnet"))
    }

    func testLocalCommandResultIsFound() {
        let entries: [[String: Any]] = [
            [
                "type": "system", "subtype": "local_command", "commandRun": ["command": "model", "args": "sonnet"],
                "content": "<local-command-stdout>Set model to `Sonnet 5` for this session only</local-command-stdout>",
            ],
            ["type": "user", "uuid": "u1", "message": ["content": "hi"]],
        ]
        XCTAssertEqual(
            ClaudeTranscript.command("model", in: entries)?.output, "Set model to `Sonnet 5` for this session only")
        XCTAssertNil(ClaudeTranscript.command("model", in: entries, after: 1))
        XCTAssertNil(ClaudeTranscript.command("effort", in: entries))
    }

    func testPermissionLogTracksOpenDesktopRequests() {
        var log = ClaudePermissionLog()
        log.consume(
            """
            2026-10-02 08:09:06 [info] Emitted tool permission request aaa for Bash in session local_one
            2026-10-02 08:09:07 [info] Emitted tool permission request bbb for Read in session local_two
            2026-10-02 08:09:08 [info] Emitted tool permission request ccc for Edit in session local_one
            2026-10-02 08:09:09 [info] Emitted tool permission request ddd for Write in session cowork_x
            2026-10-02 08:09:11 [info] LocalSessions.respondToToolPermission: requestId=bbb, decision=once, hasUpdatedInput=true
            2026-10-02 08:09:12 [info] Received permission response for aaa: deny (tool: Bash)
            """)
        XCTAssertEqual(log.pending, [.init(id: "ccc", tool: "Edit", host: "local_one")])
        log.consume(line: "2026-10-02 08:09:13 [info] Permission request ccc for Edit aborted")
        XCTAssertTrue(log.pending.isEmpty)
    }

    func testPermissionTailReadsOnlyAppendedLinesAndSurvivesTruncation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(
            "x Emitted tool permission request one for Bash in session local_a\nx Emitted tool permission request two for Re"
                .utf8
        ).write(to: file)
        let tail = ClaudePermissionTail(files: [file])
        tail.update()
        XCTAssertEqual(tail.log.pending.map(\.id), ["one"])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data("ad in session local_a\nx Received permission response for one: once (tool: Bash)\n".utf8))
        try handle.close()
        tail.update()
        XCTAssertEqual(tail.log.pending, [.init(id: "two", tool: "Read", host: "local_a")])
        try Data("x Emitted tool permission request three for Bash in session local_b\n".utf8).write(to: file)
        tail.update()
        XCTAssertEqual(tail.log.pending.map(\.id), ["three"], "a shorter file is a new log")
        XCTAssertFalse(tail.waitAnswered("missing", decision: "once", seconds: 0))
    }

    func testPermissionApprovalsPairPendingToolCallsAndChangeFingerprintWithInput() throws {
        func entries(_ command: String) -> [[String: Any]] {
            [
                [
                    "type": "assistant",
                    "message": [
                        "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]]
                    ],
                ],
                [
                    "type": "user",
                    "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]],
                ],
                [
                    "type": "assistant", "isSidechain": true,
                    "message": ["content": [["type": "tool_use", "id": "s1", "name": "Bash", "input": [:]]]],
                ],
                [
                    "type": "assistant",
                    "message": [
                        "content": [
                            [
                                "type": "tool_use", "id": "t2", "name": "Bash",
                                "input": ["command": command, "description": "清理"],
                            ],
                            ["type": "tool_use", "id": "t3", "name": "AskUserQuestion", "input": ["questions": []]],
                        ]
                    ],
                ],
            ]
        }
        let requests: [ClaudePermissionLog.Request] = [
            .init(id: "r1", tool: "Bash", host: "local_a"), .init(id: "r2", tool: "AskUserQuestion", host: "local_a"),
            .init(id: "r3", tool: "Read", host: "local_a"), .init(id: "r4", tool: "Bash", host: "local_b"),
        ]
        let approvals = ClaudePermissions.approvals(
            entries("rm -rf build"), requests: requests, host: "local_a", cwd: "/repo")
        XCTAssertEqual(
            approvals.compactMap { $0["requestId"] as? String }, ["r1", "r2"],
            "no tool call, no card; other sessions excluded")
        XCTAssertEqual(approvals[0]["toolUseId"] as? String, "t2")
        XCTAssertEqual(approvals[0]["canDecide"] as? Bool, true)
        XCTAssertEqual(approvals[1]["canDecide"] as? Bool, false)
        let details = try XCTUnwrap(approvals[0]["details"] as? String)
        XCTAssertTrue(details.contains("rm -rf build") && details.contains("/repo") && details.contains("清理"))
        let other = ClaudePermissions.approvals(
            entries("rm -rf dist"), requests: requests, host: "local_a", cwd: "/repo")
        XCTAssertNotEqual(approvals[0]["fingerprint"] as? String, other[0]["fingerprint"] as? String)
        let plan = ClaudePermissions.approvals(
            [
                [
                    "type": "assistant",
                    "message": [
                        "content": [
                            [
                                "type": "tool_use", "id": "p1", "name": "ExitPlanMode",
                                "input": ["plan": "## 步骤\n1. 改按钮"],
                            ]
                        ]
                    ],
                ]
            ],
            requests: [.init(id: "r5", tool: "ExitPlanMode", host: "local_a")], host: "local_a", cwd: "/repo")
        XCTAssertEqual(plan.first?["canDecide"] as? Bool, true)
        XCTAssertEqual(plan.first?["plan"] as? Bool, true)
        XCTAssertEqual(plan.first?["planApprovalScope"] as? String, "once")
        XCTAssertEqual(plan.first?["allowLabel"] as? String, L10n.text("provider.approve_plan"))
        XCTAssertTrue((plan.first?["details"] as? String ?? "").contains("1. 改按钮"))
    }

    func testPermissionButtonsMatchDesktopLabels() {
        XCTAssertTrue(ClaudeDesktop.permissionButton("Allow once ⌘↵", allow: true))
        XCTAssertFalse(ClaudeDesktop.permissionButton("Always allow", allow: true))
        XCTAssertFalse(ClaudeDesktop.permissionButton("Allow for all tasks", allow: true))
        XCTAssertTrue(ClaudeDesktop.permissionButton("Deny esc", allow: false))
        XCTAssertTrue(ClaudeDesktop.permissionButton("Decline", allow: false))
        XCTAssertFalse(ClaudeDesktop.permissionButton("Allow once", allow: false))
        XCTAssertTrue(ClaudeDesktop.permissionButton("Accept ⇧ ⌘ ↵", allow: true, plan: true))
        XCTAssertFalse(ClaudeDesktop.permissionButton("Accept and auto mode ⌘ ↵", allow: true, plan: true))
        XCTAssertFalse(ClaudeDesktop.permissionButton("Accept all", allow: true, plan: true))
        XCTAssertFalse(ClaudeDesktop.permissionButton("Accepted", allow: true, plan: true))
        XCTAssertFalse(ClaudeDesktop.permissionButton("Accept & bypass permissions", allow: true, plan: true))
        XCTAssertFalse(ClaudeDesktop.permissionButton("Reject all", allow: false, plan: true))
        XCTAssertTrue(ClaudeDesktop.permissionButton("Reject", allow: false, plan: true))
        XCTAssertFalse(ClaudeDesktop.permissionButton("Revise… Esc", allow: false, plan: true))
    }

    func testOnlyCompletePlanWithoutPermissionExpansionIsOnceDecidable() throws {
        let requests: [ClaudePermissionLog.Request] = [
            .init(id: "native-request", tool: "ExitPlanMode", host: "local_fixture")
        ]
        func approval(_ input: [String: Any], tool: String = "ExitPlanMode") -> [String: Any]? {
            ClaudePermissions.approvals(
                [
                    [
                        "type": "assistant",
                        "message": [
                            "content": [["type": "tool_use", "id": "native-tool-use", "name": tool, "input": input]]
                        ],
                    ]
                ], requests: requests, host: "local_fixture", cwd: "/fixture"
            ).first
        }
        for input: [String: Any] in [
            ["plan": "A complete native plan"], ["plan": "A complete native plan", "allowedPrompts": []],
        ] {
            XCTAssertEqual(approval(input)?["canDecide"] as? Bool, true)
            XCTAssertEqual(approval(input)?["planApprovalScope"] as? String, "once")
        }
        for input: [String: Any] in [
            [:], ["plan": ""], ["plan": "  \n"], ["plan": 1],
            ["plan": String(repeating: "字", count: 20_001)],
            ["plan": "Native plan", "allowedPrompts": [["tool": "Bash", "prompt": "run arbitrary commands"]]],
            ["plan": "Native plan", "allowedPrompts": NSNull()],
            ["plan": "Native plan", "permissions": [:]],
            ["plan": "Native plan", "rules": []], ["plan": "Native plan", "futurePermissionScope": "session"],
        ] {
            XCTAssertEqual(approval(input)?["canDecide"] as? Bool, false)
            XCTAssertNil(approval(input)?["planApprovalScope"])
        }
        let first = approval(["plan": "Native plan A"])
        let changed = approval(["plan": "Native plan B"])
        XCTAssertEqual(first?["toolUseId"] as? String, "native-tool-use")
        XCTAssertEqual(first?["requestId"] as? String, "native-request")
        XCTAssertNotEqual(first?["fingerprint"] as? String, changed?["fingerprint"] as? String)
        XCTAssertNil(
            ClaudePermissions.planApprovalScope(
                .init(id: "native-tool-use", name: "OtherPlanTool", input: ["plan": "Native plan"]), cwd: "/fixture"))
    }
}
