import Foundation
import XCTest

@testable import VibePierCore

final class ConfigDefaultsTests: XCTestCase {
    func testMissingConfigUsesVerifiedHeartbeatAndDoesNotWriteHardwareSettings() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
        let config = try Config.load(missing)
        XCTAssertEqual(config.heartbeatMode, "on")
        XCTAssertEqual(config.agentLightsEnabled, false)
        XCTAssertEqual(config.agentMode, "off")
        XCTAssertNil(config.settings)
        XCTAssertNil(config.relayURL)
        XCTAssertEqual(config.actions?["talk"]?.keys, "rcmd")
        XCTAssertEqual(config.actions?["talk"]?.keysMode, "hold")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missing.path), "reading defaults must not perform installation")
    }

    func testExistingUserSettingsSurviveReadAndPrivateSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json")
        let original = Config(actions: ["talk": HostAction(keys: "fn")], heartbeatMode: "off", remotePort: 0)
        try original.save(path)
        XCTAssertEqual(try Config.load(path), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
