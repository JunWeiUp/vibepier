import XCTest

@testable import VibePierCore

final class UnlockPreferencesTests: XCTestCase {
    private func withFile(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("preferences/unlock.json"))
    }

    private func store(_ file: URL, account: String = "synthetic-user") -> UnlockPreferences {
        UnlockPreferences(file: file, account: account)
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

    func testMissingStoreDoesNotWriteOnRead() throws {
        try withFile { file in
            XCTAssertNil(try store(file).read())
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testClearPersistsTombstoneAndNeverResurrectsOldPassword() throws {
        try withFile { file in
            try store(file).save("synthetic-password")
            try store(file).save(nil)
            XCTAssertNil(try store(file).read())
        }
    }

    func testInvalidDataCannotBeOverwrittenOrCleared() throws {
        for text in [
            "malformed", #"{"version":0,"account":"synthetic-user"}"#,
            #"{"account":"synthetic-user"}"#, #"{"version":1,"account":"other-user"}"#,
        ] {
            try withFile { file in
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let original = Data(text.utf8)
                try original.write(to: file)
                XCTAssertThrowsError(try store(file).read())
                XCTAssertThrowsError(try store(file).save(nil))
                XCTAssertThrowsError(try store(file).save("replacement"))
                XCTAssertEqual(try Data(contentsOf: file), original)
            }
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

}
