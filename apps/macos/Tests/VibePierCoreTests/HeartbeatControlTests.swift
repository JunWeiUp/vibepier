import XCTest

@testable import VibePierCore

final class HeartbeatControlTests: XCTestCase {
    private func makeDriver(config: Config = Config()) -> Daemon {
        Daemon(config: config, verbose: false, readProviderAccess: { SessionProviderPolicy(config).object })
    }

    func testStatusUsesEffectiveProviderPolicyWithoutStartingRemoteSessions() async {
        let policy = SessionProviderPolicy(enabled: ["codex": false, "claude": true], revision: 7)
        let driver = Daemon(config: Config(), verbose: false, readProviderAccess: { policy.object })
        let status = await driver.handle(["cmd": "status"])
        let reported = status["providerAccess"] as? [String: Any]
        XCTAssertEqual(reported?["revision"] as? Int64, 7)
        XCTAssertEqual(reported?["enabled"] as? [String: Bool], ["codex": false, "claude": true])
    }

    func testAutomaticModeStartsIdleAndSupportsManualFallback() async {
        let driver = makeDriver(config: Config(heartbeatMode: "auto"))
        var status = await driver.handle(["cmd": "status"])
        XCTAssertEqual(status["heartbeatMode"] as? String, "auto")
        XCTAssertEqual(status["heartbeatEnabled"] as? Bool, false)
        _ = await driver.handle(["cmd": "heartbeat-mode", "mode": "on"])
        status = await driver.handle(["cmd": "status"])
        XCTAssertEqual(status["heartbeatEnabled"] as? Bool, true)
        _ = await driver.handle(["cmd": "heartbeat-mode", "mode": "auto"])
        status = await driver.handle(["cmd": "status"])
        XCTAssertEqual(status["heartbeatEnabled"] as? Bool, false)
    }
    func testProbeRestoresManualOffState() async throws {
        let driver = makeDriver()
        _ = await driver.handle(["cmd": "heartbeat", "enabled": false])
        _ = await driver.handle(["cmd": "heartbeat-probe", "interval": 2.0, "seconds": 1.0])
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let status = await driver.handle(["cmd": "status"])
        XCTAssertEqual(status["heartbeatEnabled"] as? Bool, false)
        XCTAssertEqual(status["heartbeatInterval"] as? Double, 0)
    }
    func testManualSwitchCancelsProbeAndItsDelayedRestore() async throws {
        let driver = makeDriver()
        _ = await driver.handle(["cmd": "heartbeat-probe", "interval": 5.0, "seconds": 1.0])
        _ = await driver.handle(["cmd": "heartbeat", "enabled": false])
        try await Task.sleep(nanoseconds: 1_100_000_000)
        var status = await driver.handle(["cmd": "status"])
        XCTAssertEqual(status["heartbeatEnabled"] as? Bool, false)
        _ = await driver.handle(["cmd": "heartbeat", "enabled": true])
        status = await driver.handle(["cmd": "status"])
        XCTAssertEqual(status["heartbeatEnabled"] as? Bool, true)
        XCTAssertEqual(status["heartbeatInterval"] as? Double, 1)
    }
}
