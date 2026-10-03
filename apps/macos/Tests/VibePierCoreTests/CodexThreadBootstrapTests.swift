import Foundation
import XCTest

@testable import VibePierCore

final class CodexThreadBootstrapTests: XCTestCase {
    private let project = CodexCreationProject(id: UUID().uuidString, name: "Fixture", cwd: "/fixture/project")
    private let selection: [String: Any] = [
        "model": "fixture-model", "effort": "high", "permissions": ":workspace",
        "approvalPolicy": "on-request", "approvalsReviewer": "guardian_subagent",
    ]
    private func nativeReply() -> [String: Any] {
        [
            "thread": [
                "id": UUID().uuidString, "cwd": project.cwd, "projectId": project.id,
                "ephemeral": false, "turns": [], "status": ["type": "idle"],
            ],
            "cwd": project.cwd, "model": "fixture-model", "reasoningEffort": "high",
            "activePermissionProfile": ["id": ":workspace"], "approvalPolicy": "on-request",
            "approvalsReviewer": "auto_review",
        ]
    }

    func testStdioPurposeIsEnforcedBeforeWritingToSyntheticNativeProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-bootstrap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture-codex")
        let script = """
            #!/usr/bin/env python3
            import json, pathlib, sys
            log = pathlib.Path(__file__).with_name('calls.jsonl')
            for line in sys.stdin:
                value = json.loads(line)
                with log.open('a') as output:
                    output.write(json.dumps({'method':value['method']})+'\\n')
                if 'id' not in value: continue
                result = {'fixture': True} if value['method']=='thread/start' else {}
                print(json.dumps({'id':value['id'], 'result':result}), flush=True)
            """
        try script.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let account = try CodexAccountRPC(executable: executable)
        XCTAssertThrowsError(try account.request("thread/start", params: [:], mutable: true))
        account.close()
        let creation = try CodexStdioRPC(executable: executable, purpose: .creation)
        XCTAssertEqual(try creation.request("thread/start", params: [:], mutable: true)["fixture"] as? Bool, true)
        XCTAssertThrowsError(try creation.request("turn/start", params: [:], mutable: true))
        XCTAssertThrowsError(try creation.request("account/rateLimitResetCredit/consume", params: [:], mutable: true))
        creation.close()
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
        XCTAssertEqual(calls.filter { $0["method"] == "thread/start" }.count, 1)
        XCTAssertFalse(
            calls.contains { ["turn/start", "account/rateLimitResetCredit/consume"].contains($0["method"] ?? "") })
    }

    func testFirstThreadParametersContainOnlyValidatedSelectionAndExactProject() throws {
        var options = selection
        options["dynamicTools"] = [["name": "caller-defined"]]
        options["developerInstructions"] = "must not forward"
        options["config"] = ["arbitrary": "must not forward"]
        let value = try CodexThreadBootstrap.parameters(project: project, settings: options)
        XCTAssertEqual(value["projectId"] as? String, project.id)
        XCTAssertEqual(value["runtimeWorkspaceRoots"] as? [String], [project.cwd])
        XCTAssertEqual(value["allowProviderModelFallback"] as? Bool, false)
        XCTAssertEqual(value["config"] as? [String: String], ["model_reasoning_effort": "high"])
        XCTAssertNil(value["dynamicTools"])
        XCTAssertNil(value["developerInstructions"])
        XCTAssertThrowsError(
            try CodexThreadBootstrap.parameters(
                project: .init(id: project.id, name: "", cwd: "relative"), settings: selection))
    }

    func testBootstrapMaterializesOnlyTheVerifiedThreadBeforeReturning() throws {
        let native = nativeReply()
        let thread = try XCTUnwrap((native["thread"] as? [String: Any])?["id"] as? String)
        var calls: [String] = []
        _ = try CodexThreadBootstrap.startPersisted(
            parameters: [:], project: project, settings: selection, title: "Fixture title"
        ) { method, parameters in
            calls.append(method)
            if method == "thread/start" || method == "thread/unarchive" { return native }
            XCTAssertEqual(parameters["threadId"] as? String, thread)
            if method == "thread/name/set" { XCTAssertEqual(parameters["name"] as? String, "Fixture title") }
            return [:]
        }
        XCTAssertEqual(calls, ["thread/start", "thread/name/set", "thread/archive", "thread/unarchive"])
        calls.removeAll()
        var invalid = native
        invalid["model"] = "different"
        XCTAssertThrowsError(
            try CodexThreadBootstrap.startPersisted(
                parameters: [:], project: project, settings: selection, title: "Fixture"
            ) { method, _ in
                calls.append(method)
                return invalid
            })
        XCTAssertEqual(calls, ["thread/start"])
    }

    func testFailedMaterializationNeverRestartsOrReturnsAnUnpersistedThread() throws {
        var calls: [String] = []
        XCTAssertThrowsError(
            try CodexThreadBootstrap.startPersisted(
                parameters: [:], project: project, settings: selection, title: ""
            ) { method, parameters in
                calls.append(method)
                if method == "thread/start" { return self.nativeReply() }
                XCTAssertEqual(parameters["name"] as? String, self.project.name)
                throw CLIError("synthetic lost persistence reply")
            })
        XCTAssertEqual(calls, ["thread/start", "thread/name/set"])
    }

    func testArchiveRestoreFailuresAndMismatchedRestoredIdentityCannotProceed() throws {
        for failure in ["thread/archive", "thread/unarchive", "identity"] {
            var calls: [String] = []
            let native = nativeReply()
            XCTAssertThrowsError(
                try CodexThreadBootstrap.startPersisted(
                    parameters: [:], project: project, settings: selection, title: "Fixture"
                ) { method, _ in
                    calls.append(method)
                    if method == failure { throw CLIError("synthetic persistence failure") }
                    if method == "thread/start" { return native }
                    if method == "thread/unarchive" { return self.nativeReply() }
                    return [:]
                })
            XCTAssertEqual(calls.filter { $0 == "thread/start" }.count, 1)
            XCTAssertEqual(calls.filter { $0 == "thread/archive" }.count, 1)
            XCTAssertEqual(calls.filter { $0 == "thread/unarchive" }.count, failure == "thread/archive" ? 0 : 1)
        }
    }

    func testOnlyExactEmptyNativeThreadAndRequestedSettingsCanProceed() throws {
        let good = nativeReply()
        let created = try CodexThreadBootstrap.verified(good, project: project, settings: selection)
        XCTAssertEqual(created.projectID, project.id)
        XCTAssertEqual(created.cwd, project.cwd)
        for (key, value): (String, Any) in [
            ("cwd", "/other"), ("model", "fallback"), ("reasoningEffort", "low"),
            ("approvalPolicy", "never"), ("approvalsReviewer", "user"),
            ("activePermissionProfile", ["id": ":danger-full-access"]),
        ] {
            var reply = good
            reply[key] = value
            XCTAssertThrowsError(try CodexThreadBootstrap.verified(reply, project: project, settings: selection), key)
        }
        for (key, value): (String, Any) in [
            ("id", "not-a-native-thread"), ("cwd", "/other"), ("projectId", UUID().uuidString),
            ("ephemeral", true), ("ephemeral", 0), ("turns", [["id": "existing-turn"]]),
            ("status", ["type": "active"]),
        ] {
            var reply = good
            var thread = try XCTUnwrap(reply["thread"] as? [String: Any])
            thread[key] = value
            reply["thread"] = thread
            XCTAssertThrowsError(try CodexThreadBootstrap.verified(reply, project: project, settings: selection), key)
        }
    }

    func testAccountAndBootstrapChannelsCannotExecuteTurnsOrBorrowEachOthersAuthority() {
        XCTAssertTrue(CodexStdioRPC.Purpose.account.allows("account/rateLimits/read", mutable: false))
        XCTAssertTrue(CodexStdioRPC.Purpose.creation.allows("thread/start", mutable: true))
        XCTAssertTrue(CodexStdioRPC.Purpose.creation.allows("thread/name/set", mutable: true))
        XCTAssertFalse(CodexStdioRPC.Purpose.account.allows("thread/name/set", mutable: true))
        XCTAssertFalse(CodexStdioRPC.Purpose.creation.allows("thread/name/set", mutable: false))
        for scope in [CodexStdioRPC.Purpose.account, .creation] {
            for method in ["turn/start", "turn/steer", "command/exec", "thread/resume"] {
                XCTAssertFalse(scope.allows(method, mutable: true), method)
                XCTAssertFalse(scope.allows(method, mutable: false), method)
            }
        }
        XCTAssertFalse(CodexStdioRPC.Purpose.account.allows("thread/start", mutable: true))
        XCTAssertFalse(CodexStdioRPC.Purpose.creation.allows("account/rateLimitResetCredit/consume", mutable: true))
        XCTAssertFalse(CodexStdioRPC.Purpose.creation.allows("thread/start", mutable: false))
    }
}
