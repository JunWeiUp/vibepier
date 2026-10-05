import XCTest

@testable import VibePierCore

final class UnlockPreferencesTests: XCTestCase {
    private func withFile(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("preferences/unlock.json"))
    }

    private func store(_ file: URL, account: String = "synthetic-user") -> UnlockPreferences {
        UnlockPreferences(
            file: file, account: account,
            legacyRead: {
                XCTFail("Existing preferences must not read Keychain")
                return nil
            }, legacyRemove: {})
    }

    func testNewAppInstanceRetainsPasswordWithoutKeychainAccess() throws {
        try withFile { file in
            try store(file).save("synthetic-password")
            XCTAssertEqual(try store(file).read(), "synthetic-password")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let parent = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
            XCTAssertEqual((parent[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    func testLegacyMigrationCommitsBeforeRemovingAndOnlyRunsOnce() throws {
        try withFile { file in
            var reads = 0
            var removals = 0
            let value = UnlockPreferences(
                file: file, account: "synthetic-user",
                legacyRead: {
                    reads += 1
                    return "legacy-synthetic"
                },
                legacyRemove: {
                    removals += 1
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                })
            XCTAssertEqual(try value.read(), "legacy-synthetic")
            XCTAssertEqual(try value.read(), "legacy-synthetic")
            XCTAssertEqual(try store(file).read(), "legacy-synthetic")
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(removals, 1)
        }
    }

    func testClearPersistsTombstoneAndNeverResurrectsOldPassword() throws {
        try withFile { file in
            try store(file).save("synthetic-password")
            try store(file).save(nil)
            XCTAssertNil(try store(file).read())
        }
    }

    func testMigrationFailureDoesNotRemoveLegacyPassword() throws {
        try withFile { file in
            let parent = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("blocked".utf8).write(to: parent)
            let value = UnlockPreferences(
                file: file, account: "synthetic-user", legacyRead: { "legacy-synthetic" },
                legacyRemove: { XCTFail("Failed migration must preserve Keychain") })
            XCTAssertThrowsError(try value.read())
        }
    }

    func testUnavailableLegacyReaderDoesNotWriteEmptyPreferences() throws {
        try withFile { file in
            let value = UnlockPreferences(
                file: file, account: "synthetic-user", legacyRead: { throw CLIError("synthetic denied") },
                legacyRemove: { XCTFail("No migration occurred") })
            XCTAssertThrowsError(try value.read())
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            // Explicit configuration can recover without reading the inaccessible legacy item.
            try store(file).save("new-synthetic")
            XCTAssertEqual(try store(file).read(), "new-synthetic")
        }
    }

    func testMalformedOrOtherUserPreferencesDoNotFallBackToKeychain() throws {
        try withFile { file in
            try store(file).save("synthetic-password")
            XCTAssertThrowsError(try store(file, account: "other-user").read())
            try Data("malformed".utf8).write(to: file)
            XCTAssertThrowsError(try store(file).read())
        }
    }

    func testFailedSavePreservesPreviousPassword() throws {
        try withFile { file in
            try store(file).save("synthetic-password")
            XCTAssertThrowsError(try store(file).save(String(repeating: "x", count: 257)))
            XCTAssertEqual(try store(file).read(), "synthetic-password")
            try store(file).save("replacement-synthetic")
            XCTAssertEqual(try store(file).read(), "replacement-synthetic")
        }
    }

    func testEmptyFirstMigrationPersistsNoPassword() throws {
        try withFile { file in
            let value = UnlockPreferences(file: file, account: "synthetic-user", legacyRead: { nil }, legacyRemove: {})
            XCTAssertNil(try value.read())
            XCTAssertNil(try store(file).read())
        }
    }
}
