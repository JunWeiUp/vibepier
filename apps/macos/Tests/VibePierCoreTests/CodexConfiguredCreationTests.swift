import Foundation
import XCTest

@testable import VibePierCore

final class CodexConfiguredCreationTests: XCTestCase {
    func testConfiguredCreationOnlyAcceptsInspectedDesktopBuilds() {
        for build in ["12553", "12947"] {
            XCTAssertTrue(CodexBridge.supportsConfiguredCreation(build: build))
        }
        for build: String? in [nil, "", "11645", "12404", "12948", "unknown"] {
            XCTAssertFalse(CodexBridge.supportsConfiguredCreation(build: build))
        }
    }

    private let thread = UUID().uuidString
    private let project = CodexCreationProject(id: UUID().uuidString, name: "Fixture", cwd: "/fixture")
    private let settings: [String: Any] = [
        "model": "fixture-model", "effort": "high", "permissions": ":workspace",
        "approvalPolicy": "on-request", "approvalsReviewer": "user",
    ]
    private func input() throws -> CodexConfiguredCreation.Input {
        .init(
            project: project, settings: try JSONSerialization.data(withJSONObject: settings),
            attachments: try JSONSerialization.data(withJSONObject: [
                "input": [["type": "localImage", "path": "/synthetic/image.png"]],
                "files": [["path": "/synthetic/notes.md", "label": "notes.md"]],
            ]), text: "Inspect this fixture", client: "phone", operation: UUID().uuidString)
    }
    private func started() -> [String: Any] {
        [
            "thread": ["id": thread, "cwd": project.cwd, "projectId": project.id, "ephemeral": false, "turns": []],
            "cwd": project.cwd, "model": "fixture-model", "reasoningEffort": "high", "approvalPolicy": "on-request",
            "approvalsReviewer": "user", "activePermissionProfile": ["id": ":workspace"],
        ]
    }

    func testSelectedSettingsAndAttachmentsReachExactlyOneDesktopFirstTurn() throws {
        var events: [String] = []
        let input = try input()
        let nativeID = try CodexMessageIdentity(client: input.client, thread: thread, operation: input.operation)
            .nativeID
        let turn = UUID().uuidString
        let services = CodexConfiguredCreation.Services(
            start: { params in
                events.append("start")
                XCTAssertEqual(params["model"] as? String, "fixture-model")
                XCTAssertEqual(params["approvalPolicy"] as? String, "on-request")
                XCTAssertEqual(params["config"] as? [String: String], ["model_reasoning_effort": "high"])
                return self.started()
            },
            open: { id in
                events.append("open")
                XCTAssertEqual(id, self.thread)
            },
            view: { _ in
                events.append("view")
                return .init(owner: "native-owner", state: ["cwd": self.project.cwd, "turns": []])
            },
            send: { owner, params in
                events.append("send")
                XCTAssertEqual(owner, "native-owner")
                let start = try XCTUnwrap(params["turnStart"] as? [String: Any])
                let request = try XCTUnwrap(start["request"] as? [String: Any])
                for (key, expected) in self.settings { XCTAssertEqual(request[key] as? String, expected as? String) }
                XCTAssertEqual(request["clientUserMessageId"] as? String, nativeID)
                let content = try XCTUnwrap(request["input"] as? [[String: Any]])
                XCTAssertEqual(content.first?["text"] as? String, input.text)
                XCTAssertEqual(content.last?["type"] as? String, "localImage")
                XCTAssertEqual(content.last?["path"] as? String, "/synthetic/image.png")
                return ["result": ["result": ["turn": ["id": turn]]]]
            })
        let result = try CodexConfiguredCreation.run(input, services: services, observation: .init()) {
            events.append("arm")
        }
        let reply = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        XCTAssertEqual(reply?["threadId"] as? String, thread)
        XCTAssertEqual(reply?["nativeTurnId"] as? String, turn)
        XCTAssertEqual(events, ["start", "open", "view", "arm", "send"])
    }

    func testChangedProjectExistingTurnAndUnconfirmedSubmitNeverRetry() throws {
        for failure in ["settings", "project", "history", "send"] {
            var starts = 0
            var sends = 0
            let services = CodexConfiguredCreation.Services(
                start: { _ in
                    starts += 1
                    var value = self.started()
                    if failure == "settings" { value["model"] = "different" }
                    return value
                }, open: { _ in },
                view: { _ in
                    .init(
                        owner: "owner",
                        state: [
                            "cwd": failure == "project" ? "/different" : self.project.cwd,
                            "turns": failure == "history" ? [["items": [["type": "userMessage"]]]] : [],
                        ])
                },
                send: { _, _ in
                    sends += 1
                    throw CLIError("synthetic lost reply")
                })
            XCTAssertThrowsError(
                try CodexConfiguredCreation.run(input(), services: services, observation: .init(), arm: {})
            ) {
                XCTAssertTrue($0 is UnconfirmedDesktopMutation)
            }
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(sends, failure == "send" ? 1 : 0)
        }
        XCTAssertFalse(CodexConfiguredCreation.emptyHistory([:]))
        XCTAssertFalse(CodexConfiguredCreation.emptyHistory(["turnHistory": ["history": [:]]]))
    }

    func testLateObservationIsReadOnlyAndRequiresOriginalNativeMessageIdentity() throws {
        let observation = CodexConfiguredCreation.Observation()
        let id = UUID().uuidString
        observation.bind(.init(id: thread, cwd: project.cwd, projectID: project.id), nativeID: id)
        XCTAssertNil(
            try observation.receipt { _ in
                XCTFail("Not submitted")
                throw CLIError("not called")
            })
        observation.arm()
        func view(_ cwd: String, _ message: String) -> CodexConfiguredCreation.View {
            .init(
                owner: "owner",
                state: ["cwd": cwd, "turns": [["items": [["type": "userMessage", "clientId": message]]]]])
        }
        XCTAssertNil(try observation.receipt { _ in view(self.project.cwd, "different") })
        XCTAssertNil(try observation.receipt { _ in view("/different", id) })
        XCTAssertEqual(try observation.receipt { _ in view(self.project.cwd, id) }?["threadId"] as? String, thread)
    }

    func testSnapshotMustComeFromExactLocalOwnerAndSupportedFullSnapshot() throws {
        let good: [String: Any] = [
            "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "owner",
            "params": [
                "hostId": "local", "conversationId": thread,
                "change": ["type": "snapshot", "conversationState": ["cwd": project.cwd, "turns": []]],
            ],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: good)
        XCTAssertNotNil(CodexConfiguredCreation.snapshot(bytes, thread: thread, owner: "owner"))
        XCTAssertNil(CodexConfiguredCreation.snapshot(bytes, thread: "other", owner: "owner"))
        XCTAssertNil(CodexConfiguredCreation.snapshot(bytes, thread: thread, owner: "other"))
        var changed = good
        changed["version"] = 12
        XCTAssertNil(
            CodexConfiguredCreation.snapshot(
                try JSONSerialization.data(withJSONObject: changed), thread: thread, owner: "owner"))
    }
}
