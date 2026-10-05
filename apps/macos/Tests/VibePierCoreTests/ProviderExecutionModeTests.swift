import Foundation
import XCTest

@testable import VibePierCore

final class ProviderExecutionModeTests: XCTestCase {
    private var nativeModes: [String: Any] {
        ["data": [["name": "Default", "mode": "default"], ["name": "Plan", "mode": "plan"]]]
    }

    func testCodexCatalogRequiresInspectedBuildAndExactNativeChoices() throws {
        for build in ["12553", "12947"] {
            XCTAssertEqual(try CodexExecutionMode.catalog(nativeModes, build: build).count, 2)
        }
        for build: String? in [nil, "12948", "11645"] {
            XCTAssertThrowsError(try CodexExecutionMode.catalog(nativeModes, build: build))
        }
        XCTAssertThrowsError(
            try CodexExecutionMode.catalog(["data": [["name": "Plan", "mode": "plan"]]], build: "12947"))
        XCTAssertThrowsError(
            try CodexExecutionMode.catalog(
                [
                    "data": [
                        ["name": "Default", "mode": "default"], ["name": "Plan", "mode": "plan"],
                        ["name": "Duplicate", "mode": "plan"],
                    ]
                ], build: "12947"))
        XCTAssertTrue(CodexStdioRPC.Purpose.catalog.allows("collaborationMode/list", mutable: false))
        for method in ["thread/start", "thread/settings/update", "turn/start", "account/rateLimits/read"] {
            XCTAssertFalse(CodexStdioRPC.Purpose.catalog.allows(method, mutable: false))
            XCTAssertFalse(CodexStdioRPC.Purpose.catalog.allows(method, mutable: true))
        }
        XCTAssertFalse(CodexStdioRPC.Purpose.catalog.allows("collaborationMode/list", mutable: true))
    }

    func testCodexPresetUsesBuiltInNativeInstructionsAndKeepsPermissionAxis() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: [
            "models": [
                [
                    "slug": "native-model", "visibility": "list", "default_reasoning_level": "medium",
                    "supported_reasoning_levels": [["effort": "medium"], ["effort": "high"]],
                ]
            ]
        ]).write(to: file)
        let composer = CodexComposer(catalogURL: file)
        let state: [String: Any] = [
            "latestThreadSettings": ["model": "native-model", "effort": "high", "permissions": ":workspace"]
        ]
        let catalog = try CodexExecutionMode.catalog(nativeModes, build: "12947")
        let settings = try composer.settings(
            ["executionMode": "plan", "mode": "auto"], state: state, executionModes: catalog)
        let preset = try XCTUnwrap(settings["collaborationMode"] as? [String: Any])
        XCTAssertEqual(preset["mode"] as? String, "plan")
        let native = try XCTUnwrap(preset["settings"] as? [String: Any])
        XCTAssertEqual(native["model"] as? String, "native-model")
        XCTAssertEqual(native["reasoning_effort"] as? String, "high")
        XCTAssertTrue(native["developer_instructions"] is NSNull)
        XCTAssertEqual(settings["permissions"] as? String, ":workspace")
        XCTAssertThrowsError(try composer.settings(["executionMode": "plan"], state: state))
        XCTAssertThrowsError(
            try composer.settings(["executionMode": "unsupported"], state: state, executionModes: catalog))
        XCTAssertThrowsError(try composer.settings(["executionMode": true], state: state, executionModes: catalog))
        var actual = state
        var selected = state["latestThreadSettings"] as? [String: Any] ?? [:]
        selected["collaborationMode"] = preset
        actual["latestThreadSettings"] = selected
        XCTAssertEqual(CodexComposer.selection(actual)["executionMode"] as? String, "plan")
        XCTAssertEqual(
            try CodexExecutionMode.verifiedComposer(actual, request: ["executionMode": "plan"])["executionMode"]
                as? String, "plan")
        XCTAssertThrowsError(try CodexExecutionMode.verifiedComposer(state, request: ["executionMode": "plan"]))
        XCTAssertThrowsError(try CodexExecutionMode.verifiedComposer(actual, request: ["executionMode": "default"]))
        XCTAssertNil(CodexExecutionMode.selected(["latestCollaborationMode": ["mode": "plan"]]))
    }

    func testClaudePlanMapsNativePermissionAndExitCannotRestoreFullAccessImplicitly() throws {
        let current = ["model": "default", "effort": "default", "mode": "bypassPermissions"]
        XCTAssertEqual(
            try ClaudeSessionConfiguration.resolve(["executionMode": "plan"], current: current)["mode"], "plan")
        XCTAssertEqual(
            try ClaudeSessionConfiguration.resolve(["executionMode": "default"], current: current)["mode"], "default")
        XCTAssertEqual(
            try ClaudeSessionConfiguration.resolve(
                ["executionMode": "default", "mode": "acceptEdits"], current: current)["mode"], "acceptEdits")
        XCTAssertThrowsError(
            try ClaudeSessionConfiguration.resolve(["executionMode": "plan", "mode": "auto"], current: current))
        XCTAssertThrowsError(
            try ClaudeSessionConfiguration.resolve(["executionMode": "default", "mode": "plan"], current: current))
        XCTAssertThrowsError(try ClaudeSessionConfiguration.resolve(["executionMode": "unsupported"], current: current))
        XCTAssertThrowsError(try ClaudeSessionConfiguration.resolve(["executionMode": false], current: current))
        XCTAssertThrowsError(
            try ClaudeSessionConfiguration.resolve(
                ["executionMode": "default", "mode": "bypassPermissions"], current: current))
        XCTAssertEqual(ClaudeSessionConfiguration.executionMode(permissionMode: "plan"), "plan")
        XCTAssertNil(ClaudeSessionConfiguration.executionMode(permissionMode: "future-unknown-mode"))
        XCTAssertEqual(ClaudeSessionConfiguration.executionModes.last?["permissionMode"] as? String, "plan")
    }

    func testClaudeCreationPlanRequiresFirstNativeMessagePermissionReadback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("native.jsonl")
        let proof = try ClaudePrompt(text: "synthetic plan").proof
        var entry: [String: Any] = [
            "type": "user", "uuid": "actual-message", "sessionId": "session", "cwd": "/fixture",
            "message": ["content": "synthetic plan"],
        ]
        func write() throws {
            var data = try JSONSerialization.data(withJSONObject: entry)
            data.append(10)
            try data.write(to: file)
        }
        func read() -> [String: Any]? {
            ClaudeCreationReceipt.read(
                file, session: "session", cwd: "/fixture", proof: proof, executionMode: "plan", permissionMode: "plan")
        }
        try write()
        XCTAssertEqual(read()?["unknown"] as? Bool, true)
        XCTAssertEqual(read()?["nativeMessageId"] as? String, "actual-message")
        XCTAssertEqual(read()?["turnId"] as? String, "transcript:session:actual-message")
        XCTAssertEqual(read()?["turnIdentityKind"] as? String, "nativeMessageAnchor")
        XCTAssertEqual(read()?["executionModeVerified"] as? Bool, false)
        entry["permissionMode"] = "default"
        try write()
        XCTAssertEqual(read()?["unknown"] as? Bool, true)
        XCTAssertEqual(read()?["turnId"] as? String, "transcript:session:actual-message")
        entry["permissionMode"] = "plan"
        try write()
        XCTAssertEqual(read()?["executionModeVerified"] as? Bool, true)
        XCTAssertEqual(read()?["effectiveExecutionMode"] as? String, "plan")
        XCTAssertEqual(read()?["turnId"] as? String, "transcript:session:actual-message")
        XCTAssertEqual((read()?["composer"] as? [String: Any])?["mode"] as? String, "plan")
    }
}
