import XCTest

@testable import VibePierCore

final class ConfigStorageTests: XCTestCase {
    private func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("config.json")
    }

    func testCurrentConfigurationRoundTrip() throws {
        let url = try file()
        var config = Config.defaults
        config.relayURL = "wss://example.test/relay"
        config.relayRoom = "synthetic-room"
        try config.save(url)
        XCTAssertEqual(try Config.load(url), config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertFalse(object.keys.contains("relaySecret"))
    }

    func testOldOrCorruptConfigurationIsPreservedAndRejected() throws {
        for text in [#"{"relaySecret":"synthetic-secret"}"#, #"{"relaySecret":null}"#, "broken", "[]"] {
            let url = try file()
            let original = Data(text.utf8)
            try original.write(to: url)
            XCTAssertThrowsError(try Config.load(url))
            XCTAssertThrowsError(try Config.defaults.save(url))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
}
