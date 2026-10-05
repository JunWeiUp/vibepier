import Foundation
import XCTest

@testable import VibePierCore

final class AgentSessionCoordinatorTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var requests: [(Data, String)] = []
        var stops: [String] = []
        var stopAllCount = 0
        var reply = Data("{}".utf8)
        var callback: (@Sendable (Data) -> Void)?
        var delayed = false
        func adapter(_ provider: String, creationAvailable: Bool = true) -> CurrentV1AgentAdapter {
            CurrentV1AgentAdapter(
                provider: provider, backendKinds: ["desktopAttached"],
                execute: { [self] data, client, completion in
                    let output = lock.withLock { () -> Data? in
                        requests.append((data, client))
                        if delayed {
                            callback = completion
                            return nil
                        }
                        return reply
                    }
                    if let output { completion(output) }
                }, stop: { [self] client in lock.withLock { stops.append(client) } },
                stopAll: { [self] in lock.withLock { stopAllCount += 1 } },
                creationAvailable: { creationAvailable })
        }
    }
    private func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func object(_ value: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: value) as? [String: Any])
    }
    private func coordinator(_ adapter: CurrentV1AgentAdapter) throws -> AgentSessionCoordinator {
        let value = AgentSessionCoordinator(registry: try AgentAdapterRegistry([adapter]))
        XCTAssertNotNil(value.describe(client: "phone", requestedVersion: 1, policy: SessionProviderPolicy()))
        return value
    }
    private func perform(
        _ value: AgentSessionCoordinator, _ request: [String: Any], provider: String? = "codex",
        client: String = "phone"
    ) throws -> [String: Any] {
        let received = expectation(description: "reply")
        let result = Probe()
        value.performCurrentV1(try bytes(request), provider: provider, trustedClient: client) { data in
            result.lock.withLock { result.reply = data }
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
        return try object(result.reply)
    }
    private var page: [String: Any] {
        [
            "threadId": "session", "viewVersion": 7, "canSend": true, "status": "idle",
            "composer": ["model": "native-model"], "capabilities": ["projectFiles": true],
        ]
    }
    private func request(_ capabilities: [String: Any], op: String = "send") -> [String: Any] {
        [
            "op": op, "threadId": "session", "viewVersion": 7, "provider": "codex", "agentCapabilityVersion": 1,
            "agentAdapterId": capabilities["adapterId"] ?? "",
            "agentCapabilityRevision": capabilities["revision"] ?? "",
        ]
    }
    private func action(_ capabilities: [String: Any], _ name: String) throws -> [String: Any] {
        try XCTUnwrap((capabilities["actions"] as? [String: [String: Any]])?[name])
    }

    func testSameScopeSnapshotDoesNotRevokeCurrentCapabilitiesWhileItsReadIsPending() throws {
        let probe = Probe()
        probe.reply = try bytes(page)
        let value = try coordinator(probe.adapter("codex"))
        let opened = try perform(value, ["op": "open", "threadId": "session", "viewVersion": 7])
        let original = try XCTUnwrap(opened["agentCapabilities"] as? [String: Any])
        let write = request(original)
        let originalRevision = original["revision"] as? String
        probe.delayed = true
        let received = expectation(description: "same view snapshot")
        value.performCurrentV1(
            try bytes(["op": "open", "threadId": "session", "viewVersion": 7]), provider: "codex",
            trustedClient: "phone"
        ) { data in
            let next = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let caps = next?["agentCapabilities"] as? [String: Any]
            XCTAssertEqual(caps?["revision"] as? String, originalRevision)
            received.fulfill()
        }
        XCTAssertNil(value.freshMutationFailure(write, client: "phone"))
        try XCTUnwrap(probe.callback)(try bytes(page))
        wait(for: [received], timeout: 2)
        XCTAssertNil(value.freshMutationFailure(write, client: "phone"))
    }

    func testSameDraftOptionsReadPreservesCapabilitiesButChangedScopeRevokesImmediately() throws {
        let probe = Probe()
        let draft = UUID().uuidString.lowercased()
        probe.reply = try bytes(["creationVersion": 1, "draftId": draft, "capabilities": ["new": true]])
        let value = try coordinator(probe.adapter("codex"))
        let options: [String: Any] = ["op": "newOptions", "cwd": "/synthetic", "draftId": draft]
        let first = try perform(value, options)
        let caps = try XCTUnwrap(first["agentCapabilities"] as? [String: Any])
        let next = try perform(value, options)
        XCTAssertEqual(
            (next["agentCapabilities"] as? [String: Any])?["revision"] as? String, caps["revision"] as? String)
        var write = request(caps, op: "new")
        write["cwd"] = "/synthetic"
        write["draftId"] = draft
        XCTAssertNil(value.freshMutationFailure(write, client: "phone"))
        probe.delayed = true
        value.performCurrentV1(
            try bytes(["op": "newOptions", "cwd": "/another", "draftId": UUID().uuidString]), provider: "codex",
            trustedClient: "phone"
        ) { _ in }
        XCTAssertEqual(value.freshMutationFailure(write, client: "phone"), "agent_capability_unavailable")
    }

    func testRegistryRejectsDuplicateUnknownProviderAndOnlyMissingProviderDefaults() throws {
        let one = Probe().adapter("codex")
        XCTAssertThrowsError(try AgentAdapterRegistry([one, Probe().adapter("codex")]))
        XCTAssertThrowsError(try AgentAdapterRegistry([Probe().adapter("other")]))
        let registry = try AgentAdapterRegistry([one])
        XCTAssertTrue(registry.adapter(provider: nil) === one)
        XCTAssertTrue(registry.adapter(provider: "") === one)
        XCTAssertNil(registry.adapter(provider: "other"))
    }
    func testExecutionModeRequiresNativeCatalogAndIdleScope() throws {
        let probe = Probe()
        var native = page
        native["executionModes"] = [["id": "default"], ["id": "plan"]]
        probe.reply = try bytes(native)
        let value = try coordinator(probe.adapter("codex"))
        var opened = try perform(value, ["op": "open", "threadId": "session", "viewVersion": 7])
        var caps = try XCTUnwrap(opened["agentCapabilities"] as? [String: Any])
        var write = request(caps, op: "settings")
        write["executionMode"] = "plan"
        XCTAssertEqual(value.freshMutationFailure(write, client: "phone"), "agent_capability_unavailable")
        native["capabilities"] = ["executionMode": true]
        probe.reply = try bytes(native)
        opened = try perform(value, ["op": "sync", "threadId": "session", "viewVersion": 7])
        caps = try XCTUnwrap(opened["agentCapabilities"] as? [String: Any])
        write = request(caps, op: "settings")
        write["executionMode"] = "plan"
        XCTAssertNil(value.freshMutationFailure(write, client: "phone"))
        native["status"] = "active"
        native["activeTurnId"] = "native-turn"
        probe.reply = try bytes(native)
        opened = try perform(value, ["op": "sync", "threadId": "session", "viewVersion": 7])
        caps = try XCTUnwrap(opened["agentCapabilities"] as? [String: Any])
        XCTAssertEqual(try action(caps, "executionMode")["available"] as? Bool, false)
        write = request(caps, op: "settings")
        write["executionMode"] = "default"
        XCTAssertEqual(value.freshMutationFailure(write, client: "phone"), "agent_capability_unavailable")
    }

    func testWrapperPassesOriginalBytesAndTrustedClientWithoutRewriting() {
        let probe = Probe()
        let adapter = probe.adapter("claude")
        let input = Data("  { \"text\": \"literal\\nbody\", \"provider\": \"codex\" }  ".utf8)
        adapter.performCurrentV1(input, client: "trusted-phone") { _ in }
        XCTAssertEqual(probe.requests.first?.0, input)
        XCTAssertEqual(probe.requests.first?.1, "trusted-phone")
    }
    func testDiscoveryRequiresExactVersionAndDoesNotRunNativeAgent() throws {
        let probe = Probe()
        let value = AgentSessionCoordinator(registry: try AgentAdapterRegistry([probe.adapter("codex")]))
        for invalid: Any in [true, "1", 2, 1.0] {
            XCTAssertNil(value.describe(client: "phone", requestedVersion: invalid, policy: SessionProviderPolicy()))
        }
        let description = try XCTUnwrap(
            value.describe(client: "phone", requestedVersion: 1, policy: SessionProviderPolicy()))
        let adapters = try XCTUnwrap(description["adapters"] as? [[String: Any]])
        XCTAssertEqual(adapters.first?["id"] as? String, "codex.currentV1")
        let actions = try XCTUnwrap(adapters.first?["actions"] as? [String: [String: Any]])
        XCTAssertEqual(Set(actions.keys), Set(SessionV1Contract.capabilityKeys))
        XCTAssertTrue(actions.values.allSatisfy { $0["available"] as? Bool == false })
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertEqual(
            value.freshMutationFailure(["op": "send", "provider": "codex"], client: "phone"), "agent_upgrade_required")
    }
    func testCapabilityIsBoundToClientProviderThreadViewAndRevision() throws {
        let probe = Probe()
        probe.reply = try bytes(page)
        let value = try coordinator(probe.adapter("codex"))
        let body = try perform(value, ["op": "open", "threadId": "session", "viewVersion": 7])
        let caps = try XCTUnwrap(body["agentCapabilities"] as? [String: Any])
        XCTAssertEqual(try action(caps, "send")["available"] as? Bool, true)
        XCTAssertNil(value.freshMutationFailure(request(caps), client: "phone"))
        for (key, invalid): (String, Any) in [
            ("threadId", "other"), ("viewVersion", 8), ("provider", "claude"), ("agentAdapterId", "other"),
            ("agentCapabilityRevision", "stale"),
        ] {
            var changed = request(caps)
            changed[key] = invalid
            XCTAssertEqual(value.freshMutationFailure(changed, client: "phone"), "agent_capability_unavailable", key)
        }
        XCTAssertEqual(value.freshMutationFailure(request(caps), client: "other-phone"), "agent_upgrade_required")
        XCTAssertNil(value.freshMutationFailure(["op": "lockScreen"], client: "other-phone"))
        XCTAssertNil(value.freshMutationFailure(["op": "codexUsageReset"], client: "other-phone"))
        XCTAssertNil(value.freshMutationFailure(["op": "receipt"], client: "other-phone"))
    }
    func testMissingAndNumericNativeStateCannotAdvertiseAvailableAction() throws {
        let probe = Probe()
        probe.reply = try bytes(["threadId": "session", "viewVersion": 7, "canSend": 1, "status": "idle"])
        let value = try coordinator(probe.adapter("codex"))
        let body = try perform(value, ["op": "open", "threadId": "session", "viewVersion": 7])
        let caps = try XCTUnwrap(body["agentCapabilities"] as? [String: Any])
        for name in ["send", "settings", "interrupt", "approvals", "queue", "videoFiles"] {
            XCTAssertEqual(try action(caps, name)["available"] as? Bool, false, name)
        }
        probe.reply = try bytes(["threadId": "session", "viewVersion": 7, "canSend": true])
        let incomplete = try perform(value, ["op": "sync", "threadId": "session", "viewVersion": 7])
        let incompleteCaps = try XCTUnwrap(incomplete["agentCapabilities"] as? [String: Any])
        XCTAssertEqual(try action(incompleteCaps, "send")["available"] as? Bool, false)
    }
    func testInterruptAndApprovalRequireCurrentNativeTargetsAndRevisionChanges() throws {
        let probe = Probe()
        probe.reply = try bytes(page)
        let adapter = probe.adapter("codex")
        let value = try coordinator(adapter)
        let initial = try perform(value, ["op": "open", "threadId": "session", "viewVersion": 7])
        let before = try XCTUnwrap(initial["agentCapabilities"] as? [String: Any])
        XCTAssertEqual(try action(before, "interrupt")["available"] as? Bool, false)
        let captured = Probe()
        value.event = { client, provider, data in
            XCTAssertEqual(client, "phone")
            XCTAssertEqual(provider, "codex")
            captured.lock.withLock { captured.reply = data }
        }
        var active = page
        active["event"] = "snapshot"
        active["provider"] = "claude"
        active["status"] = "active"
        active["activeTurnId"] = "native-turn"
        active["approvals"] = [["fingerprint": "approval"]]
        adapter.emit(client: "phone", data: try bytes(active))
        let event = try object(captured.reply)
        XCTAssertEqual(event["provider"] as? String, "codex")
        let after = try XCTUnwrap(event["agentCapabilities"] as? [String: Any])
        XCTAssertEqual(try action(after, "interrupt")["available"] as? Bool, true)
        XCTAssertEqual(try action(after, "approvals")["available"] as? Bool, true)
        XCTAssertNotEqual(before["revision"] as? String, after["revision"] as? String)
        XCTAssertEqual(value.freshMutationFailure(request(before), client: "phone"), "agent_capability_unavailable")
        XCTAssertNil(value.freshMutationFailure(request(after, op: "interrupt"), client: "phone"))
    }
    func testClaudeExternalTerminalNeverClaimsDesktopControlOrQueue() throws {
        let probe = Probe()
        var terminal = page
        terminal["owner"] = "terminal"
        probe.reply = try bytes(terminal)
        let value = try coordinator(probe.adapter("claude"))
        let body = try perform(value, ["op": "open", "threadId": "session", "viewVersion": 7], provider: "claude")
        let caps = try XCTUnwrap(body["agentCapabilities"] as? [String: Any])
        for name in ["send", "settings", "queue", "queueSteer", "queueDelete"] {
            XCTAssertEqual(try action(caps, name)["available"] as? Bool, false, name)
        }
    }
    func testCreationCapabilityCannotBeReusedForAnotherDraftOrSession() throws {
        let draft = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let probe = Probe()
        probe.reply = try bytes([
            "creationVersion": 1, "draftId": draft.lowercased(), "capabilities": ["attachments": true],
        ])
        let value = try coordinator(probe.adapter("codex"))
        let body = try perform(value, ["op": "newOptions", "cwd": "/synthetic", "draftId": draft])
        let caps = try XCTUnwrap(body["agentCapabilities"] as? [String: Any])
        XCTAssertEqual(try action(caps, "new")["available"] as? Bool, true)
        XCTAssertEqual(try action(caps, "newAttachments")["available"] as? Bool, true)
        var create = request(caps, op: "new")
        create["cwd"] = "/synthetic"
        create["draftId"] = draft
        XCTAssertNil(value.freshMutationFailure(create, client: "phone"))
        create["cwd"] = "/other"
        XCTAssertEqual(value.freshMutationFailure(create, client: "phone"), "agent_capability_unavailable")
        XCTAssertEqual(value.freshMutationFailure(request(caps), client: "phone"), "agent_capability_unavailable")
    }
    func testMissingCreationRuntimeKeepsCreateUnavailable() throws {
        let draft = UUID().uuidString.lowercased()
        let probe = Probe()
        probe.reply = try bytes(["creationVersion": 1, "draftId": draft])
        let value = try coordinator(probe.adapter("claude", creationAvailable: false))
        let body = try perform(value, ["op": "newOptions", "cwd": "/synthetic", "draftId": draft], provider: "claude")
        let caps = try XCTUnwrap(body["agentCapabilities"] as? [String: Any])
        XCTAssertEqual(try action(caps, "new")["available"] as? Bool, false)
    }
    func testCloseAndLateEventsCannotRestoreCapabilityOrStopAnotherClient() throws {
        let probe = Probe()
        probe.reply = try bytes(page)
        let adapter = probe.adapter("codex")
        let value = try coordinator(adapter)
        let opened = try perform(value, ["op": "open", "threadId": "session", "viewVersion": 7])
        let caps = try XCTUnwrap(opened["agentCapabilities"] as? [String: Any])
        _ = try perform(value, ["op": "close", "viewVersion": 8])
        var late = page
        late["event"] = "snapshot"
        adapter.emit(client: "phone", data: try bytes(late))
        XCTAssertEqual(value.freshMutationFailure(request(caps), client: "phone"), "agent_capability_unavailable")
        value.stopObservation(client: "other-phone", providers: ["codex"], forgetNegotiation: true)
        XCTAssertEqual(probe.stops, ["other-phone"])
        XCTAssertEqual(probe.stopAllCount, 0)
        value.stopAllObservations()
        XCTAssertEqual(probe.stopAllCount, 1)
    }
    func testLateOpenReplyAfterDisconnectCannotIssueFreshCapabilities() throws {
        let probe = Probe()
        probe.delayed = true
        let value = try coordinator(probe.adapter("codex"))
        let received = expectation(description: "late reply")
        let result = Probe()
        value.performCurrentV1(
            try bytes(["op": "open", "threadId": "session", "viewVersion": 7]), provider: "codex",
            trustedClient: "phone"
        ) { data in
            result.reply = data
            received.fulfill()
        }
        value.stopObservation(client: "phone", forgetNegotiation: true)
        probe.callback?(try bytes(page))
        wait(for: [received], timeout: 2)
        XCTAssertNil(try object(result.reply)["agentCapabilities"])
    }
}
