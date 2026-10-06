import XCTest

@testable import VibePierCore

final class SessionProviderPolicyTests: XCTestCase {
    func testUpgradePreservesKnownProvidersButUnknownNeverDefaultsToCodex() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        let policy = SessionProviderPolicy(config)
        for provider in SessionProviderPolicy.ids { XCTAssertTrue(policy.isEnabled(provider)) }
        XCTAssertFalse(policy.permits(["provider": "future-agent", "op": "list"]))
        XCTAssertTrue(policy.permits(["op": "list"]))
    }

    func testDisabledProviderRejectsDiscoveryAndMutationsButKeepsReceiptsAndControls() {
        let policy = SessionProviderPolicy(enabled: ["codex": false, "claude": true])
        for op in [
            "list", "projects", "open", "sync", "history", "readImageFile", "new", "send", "approve", "settings",
            "interrupt",
        ] {
            XCTAssertFalse(policy.permits(["provider": "codex", "op": op]), op)
            XCTAssertTrue(policy.permits(["provider": "claude", "op": op]), op)
        }
        for op in ["receipt", "newReceiptCheck", "receiptCheck", "close", "applications", "lockScreen", "providers"] {
            XCTAssertTrue(policy.permits(["provider": "codex", "op": op]), op)
        }
        XCTAssertTrue(policy.permits(["provider": "codex", "op": "send"], recordedMutation: true))
        XCTAssertFalse(policy.permits(["provider": "claude", "op": "codexUsage"]))
        XCTAssertEqual(SessionProviderPolicy.contentProvider(["provider": "claude", "op": "list"]), "claude")
        XCTAssertNil(SessionProviderPolicy.contentProvider(["provider": "codex", "op": "apkBinary"]))
        XCTAssertNil(SessionProviderPolicy.contentProvider(["provider": "codex", "op": "receipt"]))
    }

    func testSettingPersistsAllOffAndRetainsUnrelatedConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        var config = Config.defaults
        config.relayURL = "wss://example.test/relay"
        config.applicationShortcuts = ["com.example.editor"]
        for provider in SessionProviderPolicy.ids {
            config = try config.settingSessionProvider(provider, enabled: false)
        }
        try config.save(file)
        let restored = try Config.load(file)
        XCTAssertEqual(restored, config)
        XCTAssertEqual(restored.sessionProviderRevision, Int64(SessionProviderPolicy.ids.count))
        XCTAssertTrue(SessionProviderPolicy.ids.allSatisfy { !SessionProviderPolicy(restored).isEnabled($0) })
        XCTAssertEqual(try restored.settingSessionProvider("codex", enabled: false), restored)
        let enabled = try restored.settingSessionProvider("claude", enabled: true, minimumRevision: 10)
        XCTAssertEqual(enabled.sessionProviderRevision, 11)
        XCTAssertEqual(enabled.relayURL, config.relayURL)
        XCTAssertEqual(enabled.applicationShortcuts, config.applicationShortcuts)
        XCTAssertFalse(SessionProviderPolicy(enabled).isEnabled("codex"))
        XCTAssertTrue(SessionProviderPolicy(enabled).isEnabled("claude"))
    }

    func testInvalidProviderAndRevisionOverflowDoNotCreateSettings() {
        XCTAssertThrowsError(try Config.defaults.settingSessionProvider("future-agent", enabled: true))
        var config = Config.defaults
        config.sessionProviderRevision = Int64.max
        XCTAssertThrowsError(try config.settingSessionProvider("codex", enabled: false))
        XCTAssertNil(config.sessionProviders)
    }

    func testActualPasswordAndStatusWireNamesRemainIndependentOfProviders() {
        let policy = SessionProviderPolicy(enabled: ["codex": false, "claude": false])
        for op in ["unlockStatus", "unlockPassword"] {
            XCTAssertTrue(policy.permits(["provider": "codex", "op": op]), op)
            XCTAssertNil(SessionProviderPolicy.contentProvider(["provider": "codex", "op": op]), op)
            XCTAssertEqual(SessionRequestLane.resolve(["provider": "claude", "op": op]), "controls", op)
        }
        XCTAssertFalse(policy.permits(["provider": "codex", "op": "screenLockPassword"]))
        XCTAssertFalse(policy.permits(["provider": "codex", "op": "screenLockStatus"]))
    }
}
