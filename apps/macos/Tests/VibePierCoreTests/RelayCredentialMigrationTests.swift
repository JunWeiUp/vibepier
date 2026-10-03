import XCTest

@testable import VibePierCore

final class RelayCredentialMigrationTests: XCTestCase {
    private func legacy() -> Config {
        var config = Config.defaults
        config.relayURL = "wss://relay.example.test/vibepier/relay"
        config.relayRoom = "test-room"
        config.relaySecret = String(repeating: "a", count: 32)
        config.relayDNSRecovery = true
        return config
    }

    func testMigrationPersistsOnlyAfterSecureStorageSucceeds() throws {
        var calls: [String] = []
        let clean = try RelayCredentialMigration.migrate(
            legacy(),
            store: { value in
                calls.append("keychain")
                XCTAssertEqual(value.secret, String(repeating: "a", count: 32))
                XCTAssertTrue(value.dnsRecovery)
            },
            persist: { value in
                calls.append("config")
                XCTAssertNil(value.relaySecret)
            })
        XCTAssertEqual(calls, ["keychain", "config"])
        XCTAssertNil(clean.relaySecret)
        XCTAssertEqual(clean.relayURL, legacy().relayURL)
        XCTAssertEqual(clean.relayDNSRecovery, true)
    }

    func testKeychainFailureNeverErasesLegacySecret() {
        let config = legacy()
        XCTAssertThrowsError(
            try RelayCredentialMigration.migrate(
                config,
                store: { _ in
                    throw CLIError("synthetic keychain failure")
                }, persist: { _ in XCTFail("Must not erase a secret before storing it") }))
        XCTAssertNotNil(config.relaySecret)
    }

    func testCleanConfigNeverOpensKeychainOrRewritesFile() throws {
        let clean = try RelayCredentialMigration.migrate(
            Config.defaults,
            store: { _ in XCTFail("No keychain operation needed") },
            persist: { _ in XCTFail("No rewrite needed") })
        XCTAssertNil(clean.relaySecret)
    }

    func testPlaintextSaveIsRejectedAndInvalidMigrationDoesNotWrite() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try legacy().save(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        var invalid = legacy()
        invalid.relayURL = "https://relay.example.test/"
        XCTAssertThrowsError(
            try RelayCredentialMigration.migrate(
                invalid,
                store: { _ in XCTFail("Invalid credentials must not be stored") },
                persist: { _ in XCTFail("Invalid credentials must not be removed") }))
    }
}
