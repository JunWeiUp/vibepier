import Foundation
import XCTest

@testable import VibePierCore

final class CodexBackgroundSessionsTests: XCTestCase {
    private final class Native: CodexRuntimeConnection, @unchecked Sendable {
        var runtimeVersion = CodexHeadlessRuntimeContract.version
        let instanceID = "synthetic-private-server"
        var isConnected = true
        var connected: Bool { isConnected }
        var onNotification: (@Sendable (String, Data) -> Void)?
        var onServerRequest: (@Sendable (Data, String, Data) -> Bool)?
        let thread = UUID().uuidString
        let turn = UUID().uuidString
        var project = ""
        var cwd = ""
        var settings: [String: Any] = [:]
        var turns: [[String: Any]] = []
        var status = "notLoaded"
        var calls: [String] = []
        var submissions: [[String: Any]] = []
        var omitClientID = false
        var changeText = false
        var changeAttachment = false
        var summaryItems = false
        var loseSendReply = false
        var emitSettings = true
        var initialMode: String?
        var emitResolution = true
        var changedCwd = false
        var onSubmit: (() throws -> Void)?
        var onResumeReturn: (() throws -> Void)?
        var publishUserAfter: TimeInterval = 0
        var userVisibleAt: TimeInterval = 0
        var onDelayedRead: (() throws -> Void)?

        func request(_ method: String, params: Data) throws -> Data {
            calls.append(method)
            let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: Any])
            switch method {
            case "thread/start":
                cwd = parameters["cwd"] as? String ?? ""
                project = parameters["projectId"] as? String ?? ""
                settings = [
                    "model": parameters["model"] ?? "fixture-model",
                    "effort": (parameters["config"] as? [String: Any])?["model_reasoning_effort"] ?? "high",
                    "approvalPolicy": parameters["approvalPolicy"] ?? "on-request",
                    "permissions": parameters["permissions"] ?? ":workspace", "approvalsReviewer": "user",
                    "serviceTier": parameters["serviceTier"] as? String ?? "default",
                ]
                if let initialMode {
                    settings["collaborationMode"] = Self.expanded(
                        try CodexExecutionMode.preset(
                            mode: initialMode, model: "fixture-model", effort: "high",
                            catalog: [["id": "default"], ["id": "plan"]]))
                }
                return try json(metadata())
            case "thread/name/set", "thread/archive": return try json([:])
            case "thread/unsubscribe":
                XCTAssertEqual(parameters["threadId"] as? String, thread)
                return try json(["status": "unsubscribed"])
            case "thread/unarchive": return try json(metadata())
            case "thread/resume":
                XCTAssertEqual(parameters["threadId"] as? String, thread)
                XCTAssertTrue(
                    Set(parameters.keys).isSubset(of: [
                        "threadId", "cwd", "model", "permissions", "approvalPolicy", "approvalsReviewer", "serviceTier",
                        "config",
                    ]))
                status = turns.contains { $0["status"] as? String == "inProgress" } ? "active" : "idle"
                let snapshot = try json(metadata())
                try onResumeReturn?()
                return snapshot
            case "thread/read":
                XCTAssertEqual(parameters["threadId"] as? String, thread)
                if !submissions.isEmpty, ProcessInfo.processInfo.systemUptime < userVisibleAt {
                    try onDelayedRead?()
                    var reply = metadata()
                    var nativeThread = reply["thread"] as! [String: Any]
                    nativeThread["turns"] = turns.map { turn in
                        var value = turn
                        value["items"] = []
                        value["itemsView"] = "notLoaded"
                        return value
                    }
                    reply["thread"] = nativeThread
                    return try json(["thread": reply["thread"]!])
                }
                return try json(["thread": metadata()["thread"]!])
            case "turn/start", "turn/steer":
                try onSubmit?()
                submissions.append(parameters)
                userVisibleAt = ProcessInfo.processInfo.systemUptime + publishUserAfter
                var content = parameters["input"] as? [[String: Any]] ?? []
                for index in content.indices where content[index]["type"] as? String == "localImage" {
                    content[index]["detail"] = NSNull()
                }
                if changeText { content[0]["text"] = "different" }
                if changeAttachment { content[1]["path"] = "/synthetic/foreign.png" }
                var item: [String: Any] = [
                    "id": "native-item-distinct-from-client-id", "type": "userMessage", "content": content,
                ]
                if !omitClientID { item["clientId"] = parameters["clientUserMessageId"] }
                turns = [["id": turn, "status": "inProgress", "items": [item]]]
                status = "active"
                if let collaboration = parameters["collaborationMode"] as? [String: Any] {
                    settings["collaborationMode"] = Self.expanded(collaboration)
                }
                if parameters["serviceTier"] != nil {
                    settings["serviceTier"] = parameters["serviceTier"] as? String ?? "default"
                }
                if emitSettings { try notifySettings() }
                if loseSendReply { throw RuntimeDriverError.timeout }
                return try json(["turn": ["id": turn, "items": [], "itemsView": "notLoaded", "status": "inProgress"]])
            case "thread/settings/update":
                settings.merge(parameters.filter { $0.key != "threadId" }) { $1 }
                if parameters["serviceTier"] is NSNull { settings["serviceTier"] = "default" }
                if let collaboration = parameters["collaborationMode"] as? [String: Any] {
                    settings["collaborationMode"] = Self.expanded(collaboration)
                }
                if emitSettings { try notifySettings() }
                return try json([:])
            case "turn/interrupt":
                turns[0]["status"] = "interrupted"
                status = "idle"
                return try json([:])
            default: throw RuntimeDriverError.invalidRequest
            }
        }
        static func expanded(_ preset: [String: Any]) -> [String: Any] {
            var result = preset
            var options = preset["settings"] as? [String: Any] ?? [:]
            if options["developer_instructions"] is NSNull {
                options["developer_instructions"] =
                    "Synthetic native built-in instructions for " + (preset["mode"] as? String ?? "")
            }
            result["settings"] = options
            return result
        }
        func metadata() -> [String: Any] {
            var result = settings
            result["cwd"] = cwd
            result["reasoningEffort"] = settings["effort"]
            result["activePermissionProfile"] = ["id": settings["permissions"] ?? ":workspace"]
            result["thread"] = [
                "id": thread, "cwd": changedCwd ? "/foreign" : cwd, "projectId": project,
                "ephemeral": false,
                "turns": turns.map { turn in
                    var value = turn
                    value["itemsView"] = summaryItems ? "summary" : "full"
                    return value
                }, "status": ["type": status],
            ]
            return result
        }
        func notifySettings() throws {
            var actual = settings
            actual["cwd"] = cwd
            onNotification?("thread/settings/updated", try json(["threadId": thread, "threadSettings": actual]))
        }
        func approval(id: Int = 42, turnID: String? = nil, threadID: String? = nil) throws -> Bool {
            onServerRequest?(
                try json(id), "item/commandExecution/requestApproval",
                try json([
                    "threadId": threadID ?? thread, "turnId": turnID ?? turn,
                    "itemId": "command-1", "command": "synthetic command", "startedAtMs": 1,
                ])) ?? false
        }
        func respond(requestID: Data, result: Data) throws {
            calls.append("respond")
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
            XCTAssertEqual(response["decision"] as? String, "accept")
            if emitResolution {
                let id = try JSONSerialization.jsonObject(with: requestID, options: [.fragmentsAllowed])
                onNotification?("serverRequest/resolved", try json(["threadId": thread, "requestId": id]))
            }
        }
        func disconnect() { isConnected = false }
        func json(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        }
    }
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(
            "background-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: value, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    private func input(mode: String? = nil, speedOff: Bool = false) throws -> CodexConfiguredCreation.Input {
        var settings: [String: Any] = [
            "model": "fixture-model", "effort": "high",
            "permissions": ":workspace", "approvalPolicy": "on-request", "approvalsReviewer": "user",
        ]
        if let mode {
            settings["collaborationMode"] = try CodexExecutionMode.preset(
                mode: mode, model: "fixture-model", effort: "high", catalog: [["id": "default"], ["id": "plan"]])
        }
        if speedOff { settings["serviceTier"] = NSNull() }
        return
            .init(
                project: .init(id: UUID().uuidString, name: "Fixture", cwd: "/fixture"),
                settings: try JSONSerialization.data(withJSONObject: settings),
                attachments: try JSONSerialization.data(withJSONObject: [
                    "input": [
                        ["type": "localImage", "path": "/synthetic/a.png"],
                        ["type": "localImage", "path": "/synthetic/b.png"],
                    ], "files": [],
                ]), text: "Full synthetic first message", client: "authorized-phone", operation: UUID().uuidString)
    }
    private func create(_ background: CodexBackgroundSessions) throws -> [String: Any] {
        let result = try background.perform(input: input(), observation: .init(), arm: {})
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
    }

    func testDesktopCreationPersistsOnlyTheEmptyThreadAndReleasesItWithoutOwnership() throws {
        let native = Native()
        let background = CodexBackgroundSessions(directory: try directory()) { native }
        let input = try input()
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: input.settings) as? [String: Any])
        let started = try background.startForDesktop(
            try CodexThreadBootstrap.parameters(project: input.project, settings: settings), project: input.project,
            settings: settings, title: input.text)
        XCTAssertEqual((started["thread"] as? [String: Any])?["id"] as? String, native.thread)
        XCTAssertEqual(native.calls.last, "thread/unsubscribe", "The proxy must not stay a second writer")
        XCTAssertFalse(native.calls.contains("turn/start"), "The first turn belongs to the desktop owner")
        XCTAssertFalse(try background.owns(thread: native.thread))
    }

    func testReleaseToDesktopWaitsForTheBackgroundTurnThenDropsOwnership() throws {
        let native = Native()
        let background = CodexBackgroundSessions(directory: try directory()) { native }
        _ = try create(background)
        XCTAssertThrowsError(try background.releaseToDesktop(thread: native.thread))
        XCTAssertTrue(try background.owns(thread: native.thread))
        native.turns[0]["status"] = "completed"
        native.status = "idle"
        try background.releaseToDesktop(thread: native.thread)
        XCTAssertFalse(try background.owns(thread: native.thread))
        XCTAssertTrue(native.calls.contains("thread/unsubscribe"))
        XCTAssertEqual(native.submissions.count, 1, "Handing over never resubmits")
    }

    func testLazyOwnershipDoesNotStartOrResumeUnknownThreadsAndCorruptionFailsClosed() throws {
        let root = try directory()
        var connections = 0
        let background = CodexBackgroundSessions(directory: root) {
            connections += 1
            return Native()
        }
        XCTAssertFalse(try background.owns(thread: UUID().uuidString))
        XCTAssertThrowsError(try background.view(thread: UUID().uuidString))
        XCTAssertEqual(connections, 0)
        let registry = root.appendingPathComponent("threads.json")
        try RuntimePrivateStorage.write(Data("corrupt".utf8), to: registry)
        let corrupt = CodexBackgroundSessions(directory: root) {
            connections += 1
            return Native()
        }
        XCTAssertThrowsError(try corrupt.owns(thread: UUID().uuidString))
        XCTAssertEqual(connections, 0)
    }

    func testCreatePersistsOwnershipBeforeFirstSendWithoutStoringPromptAndConfirmsClientIDAndFullInputs() throws {
        let root = try directory()
        let native = Native()
        let background = CodexBackgroundSessions(directory: root) { native }
        native.onSubmit = {
            let reopened = CodexBackgroundSessions(directory: root) {
                XCTFail("Registry probe launched a process")
                return Native()
            }
            XCTAssertTrue(try reopened.owns(thread: native.thread))
        }
        let reply = try create(background)
        XCTAssertEqual(reply["accepted"] as? Bool, true)
        XCTAssertEqual(reply["threadId"] as? String, native.thread)
        XCTAssertEqual(native.submissions.count, 1)
        XCTAssertEqual((native.submissions[0]["input"] as? [[String: Any]])?.count, 3)
        let stored = try Data(contentsOf: root.appendingPathComponent("threads.json"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("Full synthetic first message"))
        XCTAssertEqual(native.calls.filter { $0 == "thread/resume" }.count, 1)
        let view = try background.view(thread: native.thread)
        XCTAssertEqual(CodexConversation.turns(view.state).first?["turnId"] as? String, native.turn)
        XCTAssertEqual(CodexComposer.selection(view.state)["model"] as? String, "fixture-model")
    }

    func testAckWithoutExactIdentityOrBodyRemainsUnknownAndNeverResends() throws {
        for failure in ["identity", "body", "attachment", "reply"] {
            let native = Native()
            native.omitClientID = failure == "identity"
            native.changeText = failure == "body"
            native.changeAttachment = failure == "attachment"
            native.loseSendReply = failure == "reply"
            let background = CodexBackgroundSessions(directory: try directory(), confirmationTimeout: 0.05) { native }
            XCTAssertThrowsError(try create(background)) { XCTAssertTrue($0 is UnconfirmedDesktopMutation) }
            XCTAssertTrue(try background.owns(thread: native.thread))
            XCTAssertEqual(native.submissions.count, 1)
            let marker = try XCTUnwrap(native.submissions[0]["clientUserMessageId"] as? String)
            XCTAssertEqual(
                try background.receipt(thread: native.thread, marker: marker)["accepted"] as? Bool, failure == "reply")
            XCTAssertEqual(
                try background.receipt(thread: native.thread, marker: "unreserved")["accepted"] as? Bool, false)
        }
    }

    func testDelayedNativeUserPublicationRetainsAckAndEventuallyConfirmsWithoutResend() throws {
        let root = try directory()
        let native = Native()
        native.publishUserAfter = 1.2
        let background = CodexBackgroundSessions(directory: root, confirmationTimeout: 2) { native }
        native.onDelayedRead = {
            let registry = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: root.appendingPathComponent("threads.json"))) as? [String: Any])
            let threads = try XCTUnwrap(registry["threads"] as? [String: [String: Any]])
            let proofs = try XCTUnwrap(threads[native.thread]?["submissions"] as? [String: [String: Any]])
            XCTAssertEqual(proofs.values.first?["turnID"] as? String, native.turn)
        }
        let bytes = try background.perform(input: input(mode: "default", speedOff: true), observation: .init(), arm: {})
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(reply["accepted"] as? Bool, true)
        XCTAssertEqual(reply["executionModeVerified"] as? Bool, true)
        XCTAssertEqual(native.submissions.count, 1)
        let marker = try XCTUnwrap(native.submissions.first?["clientUserMessageId"] as? String)
        XCTAssertEqual(try background.receipt(thread: native.thread, marker: marker)["accepted"] as? Bool, true)
    }

    func testRestartRecoversDelayedCreationOnlyWithOriginalInputAndHistoricalTurnSettings() throws {
        for hasEvidence in [true, false] {
            let root = try directory()
            let native = Native()
            native.publishUserAfter = 2
            let original = try input(mode: "default", speedOff: true)
            let first = CodexBackgroundSessions(directory: root, confirmationTimeout: 0.02, connectNative: { native })
            XCTAssertThrowsError(try first.perform(input: original, observation: .init(), arm: {})) {
                XCTAssertTrue($0 is UnconfirmedDesktopMutation)
            }
            let historical = try XCTUnwrap(native.settings["collaborationMode"] as? [String: Any])
            native.userVisibleAt = 0
            native.settings["collaborationMode"] = Native.expanded(
                try CodexExecutionMode.preset(
                    mode: "plan", model: "fixture-model", effort: "high", catalog: [["id": "plan"]]))
            native.settings["serviceTier"] = "priority"
            let restored = CodexBackgroundSessions(
                directory: root,
                turnEvidence: { thread, cwd, project, turn, marker, digest in
                    XCTAssertEqual(thread, native.thread)
                    XCTAssertEqual(cwd, native.cwd)
                    XCTAssertEqual(project, native.project)
                    XCTAssertEqual(turn, native.turn)
                    XCTAssertFalse(marker.isEmpty)
                    XCTAssertEqual(digest.count, 64)
                    return hasEvidence ? .init(mode: historical, serviceTier: "standard") : nil
                }, connectNative: { native })
            let attached = try XCTUnwrap(JSONSerialization.jsonObject(with: original.attachments) as? [String: Any])
            let expected = [["type": "text", "text": original.text]] + (attached["input"] as? [[String: Any]] ?? [])
            let request: [String: Any] = [
                "operation": original.operation, "cwd": native.cwd, "provider": "codex",
                "text": original.text, "model": "fixture-model", "effort": "high", "mode": "auto",
                "executionMode": "default", "serviceTier": "standard",
            ]
            let receipt = try XCTUnwrap(
                restored.creationReceipt(request: request, client: original.client, expectedInput: expected))
            XCTAssertEqual(receipt["threadId"] as? String, native.thread)
            XCTAssertEqual(receipt["nativeTurnId"] as? String, native.turn)
            XCTAssertEqual(receipt["accepted"] as? Bool, hasEvidence)
            XCTAssertEqual(receipt["unknown"] as? Bool, hasEvidence ? nil : true)
            if hasEvidence {
                XCTAssertEqual((receipt["composer"] as? [String: Any])?["serviceTier"] as? String, "standard")
                XCTAssertEqual(receipt["effectiveExecutionMode"] as? String, "default")
            }
            XCTAssertNil(try restored.creationReceipt(request: request, client: "other-phone", expectedInput: expected))
            XCTAssertNil(
                try restored.creationReceipt(
                    request: request, client: original.client,
                    expectedInput: [["type": "text", "text": "different"]]))
            XCTAssertEqual(native.submissions.count, 1)
        }
    }

    func testIndependentAdaptersPreserveOtherThreadsAndSubmissionProofs() throws {
        let root = try directory()
        let firstNative = Native()
        let secondNative = Native()
        let first = CodexBackgroundSessions(directory: root) { firstNative }
        let second = CodexBackgroundSessions(directory: root) { secondNative }
        _ = try create(first)
        _ = try create(second)
        XCTAssertTrue(try first.owns(thread: secondNative.thread))
        _ = try first.mutate(
            op: "interrupt", request: ["threadId": firstNative.thread, "expectedTurnId": firstNative.turn],
            client: "phone")
        let reply = try first.mutate(
            op: "send", request: ["threadId": firstNative.thread, "id": UUID().uuidString, "text": "Next message"],
            client: "phone")
        XCTAssertEqual(reply["accepted"] as? Bool, true)
        XCTAssertTrue(try second.owns(thread: firstNative.thread))
        let stored = try Data(contentsOf: root.appendingPathComponent("threads.json"))
        let registry = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let threads = try XCTUnwrap(registry["threads"] as? [String: [String: Any]])
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual((threads[firstNative.thread]?["submissions"] as? [String: Any])?.count, 2)
        XCTAssertEqual((threads[secondNative.thread]?["submissions"] as? [String: Any])?.count, 1)
        let marker = try XCTUnwrap(secondNative.submissions.first?["clientUserMessageId"] as? String)
        XCTAssertEqual(try second.receipt(thread: secondNative.thread, marker: marker)["accepted"] as? Bool, true)
    }

    func testParallelAdaptersRetainEveryOwnershipAndReservedSubmission() throws {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var errors: [Error] = []
            func record(_ error: Error) { lock.withLock { errors.append(error) } }
        }
        let root = try directory()
        let natives = (0..<8).map { _ in Native() }
        let backgrounds = natives.map { native in CodexBackgroundSessions(directory: root, connectNative: { native }) }
        let inputs = try backgrounds.map { _ in try input() }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: backgrounds.count) { index in
            do {
                _ = try backgrounds[index].perform(input: inputs[index], observation: .init(), arm: {})
            } catch { results.record(error) }
        }
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        let stored = try Data(contentsOf: root.appendingPathComponent("threads.json"))
        let registry = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let threads = try XCTUnwrap(registry["threads"] as? [String: [String: Any]])
        XCTAssertEqual(threads.count, natives.count)
        for native in natives {
            XCTAssertEqual((threads[native.thread]?["submissions"] as? [String: Any])?.count, 1)
            XCTAssertEqual(native.submissions.count, 1)
        }
    }

    func testResumeSnapshotCannotOverwriteNewerNativeSettingsNotification() throws {
        let root = try directory()
        let native = Native()
        let original = CodexBackgroundSessions(directory: root) { native }
        _ = try create(original)
        _ = try original.mutate(
            op: "interrupt", request: ["threadId": native.thread, "expectedTurnId": native.turn], client: "phone")
        let restored = CodexBackgroundSessions(directory: root) { native }
        native.onResumeReturn = {
            native.settings["model"] = "second-model"
            try native.notifySettings()
        }
        XCTAssertEqual(
            CodexComposer.selection(try restored.view(thread: native.thread).state)["model"] as? String,
            "second-model")
        native.onResumeReturn = {
            native.settings["model"] = "third-model"
            try native.notifySettings()
        }
        let reply = try restored.mutate(
            op: "settings",
            request: ["threadId": native.thread, "model": "third-model", "settings": ["model": "third-model"]],
            client: "phone")
        XCTAssertEqual(reply["accepted"] as? Bool, true)
        XCTAssertFalse(native.calls.contains("thread/settings/update"))
        XCTAssertEqual(
            CodexComposer.selection(try restored.view(thread: native.thread).state)["model"] as? String,
            "third-model")
    }

    func testSettingsRequiresNewNativeNotificationRatherThanSetterAck() throws {
        for confirmation in [true, false] {
            let native = Native()
            let background = CodexBackgroundSessions(directory: try directory()) { native }
            _ = try create(background)
            _ = try background.mutate(
                op: "interrupt", request: ["threadId": native.thread, "expectedTurnId": native.turn], client: "phone")
            native.emitSettings = confirmation
            let request: [String: Any] = [
                "threadId": native.thread, "model": "second-model", "settings": ["model": "second-model"],
            ]
            if confirmation {
                let reply = try background.mutate(op: "settings", request: request, client: "phone")
                XCTAssertEqual(reply["accepted"] as? Bool, true)
            } else {
                XCTAssertThrowsError(try background.mutate(op: "settings", request: request, client: "phone")) {
                    XCTAssertTrue($0 is UnconfirmedDesktopMutation)
                }
            }
            XCTAssertEqual(native.calls.filter { $0 == "thread/settings/update" }.count, 1)
        }
    }

    func testApprovalBindsFingerprintAndActiveTurnAndRequiresResolutionEvent() throws {
        for confirmation in [true, false] {
            let native = Native()
            let background = CodexBackgroundSessions(directory: try directory()) { native }
            _ = try create(background)
            XCTAssertFalse(try native.approval(threadID: UUID().uuidString))
            XCTAssertTrue(try native.approval())
            let state = try background.view(thread: native.thread).state
            let fingerprint = try XCTUnwrap(CodexConversation.approvals(state).first?["fingerprint"] as? String)
            XCTAssertThrowsError(
                try background.mutate(
                    op: "approve",
                    request: [
                        "threadId": native.thread,
                        "fingerprint": "foreign", "allow": true,
                    ], client: "phone"))
            XCTAssertFalse(native.calls.contains("respond"))
            native.emitResolution = confirmation
            let request: [String: Any] = ["threadId": native.thread, "fingerprint": fingerprint, "allow": true]
            XCTAssertThrowsError(try background.mutate(op: "approve", request: request, client: "phone")) {
                XCTAssertTrue($0 is UnconfirmedDesktopMutation)
            }
            XCTAssertThrowsError(try background.mutate(op: "approve", request: request, client: "phone"))
            XCTAssertEqual(native.calls.filter { $0 == "respond" }.count, 1)
        }
    }

    func testRegistryReloadSubscribesRunningOwnThreadWithoutNewTurnAndRejectsMovedThread() throws {
        let root = try directory()
        let native = Native()
        let original = CodexBackgroundSessions(directory: root) { native }
        _ = try create(original)
        let before = native.calls.filter { $0 == "thread/resume" }.count
        let restored = CodexBackgroundSessions(directory: root) { native }
        XCTAssertTrue(try restored.owns(thread: native.thread))
        _ = try restored.view(thread: native.thread)
        XCTAssertEqual(native.calls.filter { $0 == "thread/resume" }.count, before + 1)
        XCTAssertEqual(native.submissions.count, 1)
        native.changedCwd = true
        XCTAssertThrowsError(try restored.view(thread: native.thread))
    }

    func testExistingNativeModeDoesNotRequireAChangeNotification() throws {
        let native = Native()
        native.initialMode = "default"
        native.emitSettings = false
        let background = CodexBackgroundSessions(directory: try directory()) { native }
        let bytes = try background.perform(
            input: input(mode: "default", speedOff: true), observation: .init(), arm: {})
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(result["accepted"] as? Bool, true)
        XCTAssertEqual(result["executionModeVerified"] as? Bool, true)
        XCTAssertEqual((result["composer"] as? [String: Any])?["serviceTier"] as? String, "standard")
        XCTAssertEqual(
            CodexExecutionMode.turnSelection(
                try background.view(thread: native.thread).state, turnID: native.turn), "default")
        XCTAssertEqual(native.submissions.count, 1)
    }

    func testExecuteAndSpeedOffConfirmExpandedNativePresetAndPreserveTheFullTuple() throws {
        let native = Native()
        let background = CodexBackgroundSessions(directory: try directory()) { native }
        let bytes = try background.perform(input: input(mode: "default", speedOff: true), observation: .init(), arm: {})
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(result["accepted"] as? Bool, true)
        XCTAssertEqual(result["executionModeVerified"] as? Bool, true)
        XCTAssertEqual((result["composer"] as? [String: Any])?["serviceTier"] as? String, "standard")
        let requestPreset = try XCTUnwrap(native.submissions.first?["collaborationMode"] as? [String: Any])
        XCTAssertTrue((requestPreset["settings"] as? [String: Any])?["developer_instructions"] is NSNull)
        let state = try background.view(thread: native.thread).state
        let turn = try XCTUnwrap(CodexConversation.turns(state).first)
        let proof = try XCTUnwrap((turn["params"] as? [String: Any])?["collaborationMode"] as? [String: Any])
        XCTAssertEqual(
            (proof["settings"] as? [String: Any])?["developer_instructions"] as? String,
            "Synthetic native built-in instructions for default")
        XCTAssertTrue(
            NSDictionary(dictionary: proof).isEqual(
                to: try XCTUnwrap(native.settings["collaborationMode"] as? [String: Any])))
        XCTAssertEqual(native.submissions.count, 1)
    }

    func testNativePresetMatchingOnlyAllowsReviewedNullExpansion() throws {
        let preset = try CodexExecutionMode.preset(
            mode: "default", model: "fixture-model", effort: "high", catalog: [["id": "default"]])
        let expanded = Native.expanded(preset)
        let expected: [String: Any] = ["collaborationMode": preset, "serviceTier": NSNull()]
        let actual: [String: Any] = ["collaborationMode": expanded, "serviceTier": "default"]
        XCTAssertTrue(CodexBackgroundSessions.matches(expected, actual, runtimeVersion: "0.160.0"))
        XCTAssertTrue(
            CodexBackgroundSessions.matches(
                ["serviceTier": NSNull()], ["serviceTier": NSNull()], runtimeVersion: "0.160.0"))
        XCTAssertTrue(
            CodexBackgroundSessions.matches(
                ["serviceTier": NSNull()], ["serviceTier": "default"], runtimeVersion: "0.160.0"))
        for incorrect in ["priority", "unknown", "standard", ""] {
            XCTAssertFalse(
                CodexBackgroundSessions.matches(
                    ["serviceTier": NSNull()], ["serviceTier": incorrect], runtimeVersion: "0.160.0"))
        }
        XCTAssertFalse(CodexBackgroundSessions.matches(["serviceTier": NSNull()], [:], runtimeVersion: "0.160.0"))
        XCTAssertFalse(CodexBackgroundSessions.matches(expected, actual, runtimeVersion: "0.159.0"))
        XCTAssertFalse(CodexBackgroundSessions.matches(expected, actual, runtimeVersion: "unknown"))
        XCTAssertFalse(
            CodexBackgroundSessions.matches(
                expected, ["collaborationMode": expanded, "serviceTier": "priority"], runtimeVersion: "0.160.0"))
        for key in ["model", "reasoning_effort", "developer_instructions", "foreign"] {
            var altered = expanded
            var settings = try XCTUnwrap(expanded["settings"] as? [String: Any])
            settings[key] = key == "developer_instructions" ? "" : "different"
            altered["settings"] = settings
            XCTAssertFalse(
                CodexBackgroundSessions.matches(
                    ["collaborationMode": preset], ["collaborationMode": altered], runtimeVersion: "0.160.0"), key)
        }
        var differentMode = expanded
        differentMode["mode"] = "plan"
        XCTAssertFalse(
            CodexBackgroundSessions.matches(
                ["collaborationMode": preset], ["collaborationMode": differentMode], runtimeVersion: "0.160.0"))
        var unknown = expanded
        unknown["foreign"] = true
        XCTAssertFalse(
            CodexBackgroundSessions.matches(
                ["collaborationMode": preset], ["collaborationMode": unknown], runtimeVersion: "0.160.0"))
        var requested = preset
        var instructions = try XCTUnwrap(preset["settings"] as? [String: Any])
        instructions["developer_instructions"] = "Explicit instructions"
        requested["settings"] = instructions
        XCTAssertFalse(
            CodexBackgroundSessions.matches(
                ["collaborationMode": requested], ["collaborationMode": expanded], runtimeVersion: "0.160.0"))
        XCTAssertTrue(
            CodexBackgroundSessions.matches(
                ["collaborationMode": requested], ["collaborationMode": requested], runtimeVersion: "0.160.0"))
    }

    func testModeProofIsNativeAndImmutableAndPartialHistoryIsPreserved() throws {
        for confirmation in [true, false] {
            let native = Native()
            native.emitSettings = confirmation
            let background = CodexBackgroundSessions(directory: try directory()) { native }
            if confirmation {
                let result = try background.perform(input: input(mode: "plan"), observation: .init(), arm: {})
                XCTAssertEqual(
                    (try JSONSerialization.jsonObject(with: result) as? [String: Any])?["executionModeVerified"]
                        as? Bool, true)
                XCTAssertEqual(
                    CodexExecutionMode.turnSelection(
                        try background.view(thread: native.thread).state, turnID: native.turn), "plan")
                native.settings["collaborationMode"] = try CodexExecutionMode.preset(
                    mode: "default", model: "fixture-model", effort: "high", catalog: [["id": "default"]])
                try native.notifySettings()
                let changed = try background.view(thread: native.thread).state
                XCTAssertEqual(CodexExecutionMode.selected(changed), "default")
                XCTAssertEqual(CodexExecutionMode.turnSelection(changed, turnID: native.turn), "plan")
                XCTAssertTrue(CodexHistoryReadback.complete(changed))
                native.summaryItems = true
                XCTAssertFalse(CodexHistoryReadback.complete(try background.view(thread: native.thread).state))
            } else {
                XCTAssertThrowsError(try background.perform(input: input(mode: "plan"), observation: .init(), arm: {}))
                {
                    XCTAssertTrue($0 is UnconfirmedDesktopMutation)
                }
                XCTAssertEqual(native.submissions.count, 1)
                XCTAssertNil(
                    CodexExecutionMode.turnSelection(
                        try background.view(thread: native.thread).state, turnID: native.turn))
            }
        }
    }

    func testProxyReconnectDoesNotResendOrRestorePendingDecisions() throws {
        let native = Native()
        var connects = 0
        let background = CodexBackgroundSessions(directory: try directory()) {
            connects += 1
            native.isConnected = true
            return native
        }
        _ = try create(background)
        XCTAssertTrue(try native.approval())
        XCTAssertEqual(CodexConversation.approvals(try background.view(thread: native.thread).state).count, 1)
        let oldNotification = try XCTUnwrap(native.onNotification)
        let oldRequest = try XCTUnwrap(native.onServerRequest)
        native.isConnected = false
        let resumed = try background.view(thread: native.thread)
        XCTAssertEqual(connects, 2)
        XCTAssertTrue(CodexConversation.approvals(resumed.state).isEmpty)
        XCTAssertEqual(native.submissions.count, 1)
        XCTAssertEqual(native.calls.filter { $0 == "thread/resume" }.count, 2)
        oldNotification(
            "thread/settings/updated",
            try native.json(["threadId": native.thread, "threadSettings": ["cwd": native.cwd, "model": "stale-model"]]))
        XCTAssertFalse(
            oldRequest(
                try native.json(43), "item/commandExecution/requestApproval",
                try native.json(["threadId": native.thread, "turnId": native.turn, "itemId": "old-command"])))
        let current = try background.view(thread: native.thread).state
        XCTAssertTrue(CodexConversation.approvals(current).isEmpty)
        XCTAssertEqual(CodexComposer.selection(current)["model"] as? String, "fixture-model")
    }
}
