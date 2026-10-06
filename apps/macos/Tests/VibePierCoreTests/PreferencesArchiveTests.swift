import XCTest

@testable import VibePierCore

final class PreferencesArchiveTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func source(_ root: URL) throws -> (Config, PhoneBindings) {
        var config = Config.defaults
        config.relayURL = "wss://private.example.test/relay"
        config.relayRoom = "private-room"
        config.herdrPointer = "/private/synthetic/path"
        config.actions?["talk"]?.run = "echo synthetic-command-secret"
        config.actions?["talk"]?.applescript = "synthetic-automation-secret"
        config.actions?["talk"]?.open = "/private/synthetic/attachment"
        config.applicationShortcuts = ["com.example.editor"]
        config.settings = Settings(standbyTime: 300, brightness: 8)
        let bindings = PhoneBindings(url: root.appendingPathComponent("source-bindings.json"))
        try bindings.set(key: "keys.confirm", value: "cmd+return", name: "")
        return (config, bindings)
    }

    func testAllowlistExcludesSecretsScriptsPathsAndSourceIdentity() throws {
        let root = try directory()
        let (config, bindings) = try source(root)
        let text = String(
            decoding: try PreferencesArchive(config: config, bindings: bindings.snapshot).encoded(), as: UTF8.self)
        for excluded in [
            "synthetic-secret", "synthetic-command-secret", "synthetic-automation-secret", "/private/", "private-room",
            "private.example", bindings.snapshot.server, bindings.snapshot.revision,
        ] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
        XCTAssertTrue(text.contains("rcmd"))
        XCTAssertTrue(text.contains("com.example.editor"))
        XCTAssertFalse(text.contains("relaySecret"))
        XCTAssertFalse(text.contains("operation"))
    }

    func testRoundTripMergesControlsButPreservesDestinationCredentialsAndLocalScripts() throws {
        let root = try directory()
        let (config, bindings) = try source(root)
        let archive = try PreferencesArchive.decode(
            PreferencesArchive(config: config, bindings: bindings.snapshot).encoded())
        var current = Config.defaults
        current.relayURL = "wss://destination.example.test/r"
        current.relayRoom = "destination"
        current.herdrPointer = "/private/destination"
        current.actions?["talk"]?.run = "destination-command"
        current.agentLightsEnabled = false
        let destination = PhoneBindings(url: root.appendingPathComponent("destination-bindings.json"))
        try destination.set(key: "keys.cancel", value: "escape")
        let server = destination.snapshot.server
        let oldCancel = destination.snapshot.entries["keys.cancel"]
        var saved: Config?
        let next = try archive.apply(to: current, bindings: destination) { saved = $0 }
        XCTAssertEqual(next, saved)
        XCTAssertEqual(next.relayURL, current.relayURL)
        XCTAssertEqual(next.herdrPointer, current.herdrPointer)
        XCTAssertEqual(next.actions?["talk"]?.run, "destination-command")
        XCTAssertEqual(next.agentLightsEnabled, false)
        XCTAssertEqual(next.settings?.brightness, 8)
        XCTAssertEqual(destination.snapshot.server, server)
        XCTAssertEqual(destination.snapshot.entries["keys.cancel"], oldCancel)
        XCTAssertEqual(destination.resolved("confirm"), "cmd+return")
        let revision = destination.snapshot.revision
        try destination.mergePortable(archive.phoneBindings)
        XCTAssertEqual(destination.snapshot.revision, revision, "Identical import must be idempotent")
    }

    func testInvalidArchiveOrBindingDoesNotWriteAnyDestination() throws {
        let root = try directory()
        let (config, bindings) = try source(root)
        var archive = PreferencesArchive(config: config, bindings: bindings.snapshot)
        let destination = PhoneBindings(url: root.appendingPathComponent("destination-bindings.json"))
        archive.phoneBindings["app.invalid.keys.unknown"] = .init(value: "return", name: "")
        XCTAssertThrowsError(
            try archive.apply(to: .defaults, bindings: destination) { _ in XCTFail("Must validate first") })
        XCTAssertTrue(destination.snapshot.entries.isEmpty)
        archive.phoneBindings = [:]
        archive.version = 2
        XCTAssertThrowsError(try archive.validate())
        archive.version = 1
        archive.mac.hardware?.brightness = 21
        XCTAssertThrowsError(try archive.validate())
        XCTAssertThrowsError(
            try PreferencesArchive.decode(Data(repeating: 32, count: PreferencesArchive.maximumBytes + 1)))
    }

    func testConfigWriteFailureLeavesPhoneBindingsUntouched() throws {
        let root = try directory()
        let (config, bindings) = try source(root)
        let archive = PreferencesArchive(config: config, bindings: bindings.snapshot)
        let destination = PhoneBindings(url: root.appendingPathComponent("destination-bindings.json"))
        XCTAssertThrowsError(
            try archive.apply(to: .defaults, bindings: destination) { _ in throw CLIError("synthetic disk failure") })
        XCTAssertTrue(destination.snapshot.entries.isEmpty)
    }

    func testPhoneWriteFailureRestoresPreviousConfig() throws {
        let root = try directory()
        let (config, bindings) = try source(root)
        let archive = PreferencesArchive(config: config, bindings: bindings.snapshot)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blocked)
        let destination = PhoneBindings(url: blocked.appendingPathComponent("bindings.json"))
        var writes: [Config] = []
        XCTAssertThrowsError(try archive.apply(to: .defaults, bindings: destination) { writes.append($0) })
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.last, .defaults)
        XCTAssertTrue(destination.snapshot.entries.isEmpty)
    }

    func testCLIExportUsesPrivateNewFileAndDryRunHasNoMutationCommand() throws {
        let root = try directory()
        let (config, bindings) = try source(root)
        let archive = PreferencesArchive(config: config, bindings: bindings.snapshot)
        let object = try JSONSerialization.jsonObject(with: archive.encoded())
        let file = root.appendingPathComponent("portable.json")
        try PreferencesCommand.run(["export", file.path]) { request in
            XCTAssertEqual(request["cmd"] as? String, "preferences-export")
            return ["ok": true, "archive": object]
        }
        let original = try Data(contentsOf: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(
            try PreferencesCommand.run(["export", file.path]) { _ in
                XCTFail("Must refuse overwrite")
                return nil
            })
        XCTAssertEqual(try Data(contentsOf: file), original)
        try PreferencesCommand.run(["import", file.path, "--dry-run"]) { request in
            XCTAssertEqual(request["cmd"] as? String, "preferences-preview")
            XCTAssertNotNil(request["archive"])
            return ["ok": true]
        }
    }
}
