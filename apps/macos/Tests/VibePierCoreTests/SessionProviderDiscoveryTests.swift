import XCTest

@testable import VibePierCore

final class SessionProviderDiscoveryTests: XCTestCase {
    private func coordinator() throws -> AgentSessionCoordinator {
        AgentSessionCoordinator(registry: try AgentAdapterRegistry(["codex", "claude"].map { provider in
            CurrentV1AgentAdapter(provider: provider, backendKinds: ["desktopAttached"],
                execute: { _, _, _ in XCTFail("Discovery must not execute native operations") },
                stop: { _ in }, stopAll: {})
        }))
    }

    func testProductionBootstrapProvidesBothDefaultAdaptersActionsAndOnlyProfileTwo() throws {
        let coordinator = try coordinator()
        for client in ["phone-a", "phone-b"] {
            let response = SessionRemote.providerDiscoveryResponse(
                id: "request-" + client, client: client, policy: SessionProviderPolicy(), coordinator: coordinator,
                runtimeAdapters: [["id": "codex.runtime", "provider": "codex", "default": true]], serviceAvailable: true)
            XCTAssertEqual(response["id"] as? String, "request-" + client)
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertNotNil(response["providerAccess"])
            let profiles = try XCTUnwrap(response["agentProfiles"] as? [String: Any])
            XCTAssertEqual(profiles["versions"] as? [Int], [2])
            XCTAssertEqual(profiles["minimumClientVersion"] as? Int, 2)
            XCTAssertEqual(profiles["methods"] as? [String], AgentSessionProfile.methods)
            let caps = try XCTUnwrap(response["agentCapabilities"] as? [String: Any])
            XCTAssertEqual(caps["version"] as? Int, 1)
            XCTAssertFalse((caps["revision"] as? String ?? "").isEmpty)
            let adapters = try XCTUnwrap(caps["adapters"] as? [[String: Any]])
            for provider in ["codex", "claude"] {
                let adapter = try XCTUnwrap(adapters.first { $0["id"] as? String == provider + ".currentV1" })
                XCTAssertEqual(adapter["provider"] as? String, provider)
                XCTAssertEqual(adapter["default"] as? Bool, true)
                let actions = try XCTUnwrap(adapter["actions"] as? [String: [String: Any]])
                XCTAssertEqual(Set(actions.keys), Set(SessionV1Contract.capabilityKeys))
                XCTAssertEqual(actions["send"]?["supported"] as? Bool, true)
                XCTAssertEqual(actions["send"]?["available"] as? Bool, false)
            }
            XCTAssertEqual(adapters.last?["default"] as? Bool, false)
            // Discovery really negotiated this authenticated client, but issued no write scope/lease.
            let write: [String: Any] = ["op": "send", "provider": "codex", "agentCapabilityVersion": 1]
            XCTAssertEqual(coordinator.freshMutationFailure(write, client: client), "agent_capability_unavailable")
            XCTAssertEqual(coordinator.freshMutationFailure(write, client: "unnegotiated"), "agent_upgrade_required")
            XCTAssertNotNil(SessionRemote.rejectedPhoneSession(write, recorded: false, journalReliable: true))
        }
    }

    func testProductionBootstrapPreservesPolicyAndDoesNotInventAnAvailableService() throws {
        let response = SessionRemote.providerDiscoveryResponse(
            id: "request", client: "phone", policy: SessionProviderPolicy(enabled: ["codex": true, "claude": false]),
            coordinator: try coordinator(), runtimeAdapters: [], serviceAvailable: false)
        XCTAssertNil(response["agentProfiles"])
        let caps = try XCTUnwrap(response["agentCapabilities"] as? [String: Any])
        let adapters = try XCTUnwrap(caps["adapters"] as? [[String: Any]])
        let claude = try XCTUnwrap(adapters.first { $0["provider"] as? String == "claude" })
        let actions = try XCTUnwrap(claude["actions"] as? [String: [String: Any]])
        XCTAssertTrue(actions.values.allSatisfy { $0["available"] as? Bool == false && $0["reason"] as? String == "provider_disabled" })
    }
}
