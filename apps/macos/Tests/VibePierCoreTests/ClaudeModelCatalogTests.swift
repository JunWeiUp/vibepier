import XCTest

@testable import VibePierCore

final class ClaudeModelCatalogTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
    private let env = [
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:12580/tingly/claude_desktop",
        "ANTHROPIC_API_KEY": "synthetic-secret",
        "ANTHROPIC_MODEL": "claude-opus-5-5",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5-5",
    ]

    func testActualIDsLabelsAliasesAndDefaultAreDistinctFromEffort() throws {
        let entries = try ClaudeModelCatalog.parse(
            [["id": "claude-opus-5-5", "display_name": "claude-opus-5-5"], ["id": "claude-haiku-4-5"]],
            settings: [:], environment: env)
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue((entries[0]["name"] as? String ?? "").contains("Opus 5.5"))
        XCTAssertEqual(entries[1]["id"] as? String, "claude-opus-5-5")
        XCTAssertEqual(entries[1]["name"] as? String, "Opus 5.5")
        let result = try ClaudeSessionConfiguration.resolve(
            ["model": "claude-opus-5-5", "effort": "high"], current: [:], models: entries)
        XCTAssertEqual(result["model"], "claude-opus-5-5")
        XCTAssertEqual(result["effort"], "high")
        XCTAssertEqual(
            try ClaudeSessionConfiguration.resolve(["model": "opus"], current: [:], models: entries)["model"],
            "claude-opus-5-5")
        XCTAssertThrowsError(
            try ClaudeSessionConfiguration.resolve(["model": "claude-opus-99"], current: [:], models: entries))
        XCTAssertThrowsError(try ClaudeSessionConfiguration.resolve(["model": "high"], current: [:], models: entries))
        XCTAssertThrowsError(
            try ClaudeSessionConfiguration.resolve(
                ["model": "claude-haiku-4-5", "effort": "high"], current: [:], models: entries))
    }

    func testPaginationRefreshAndFailedRefreshDoNotResurrectRemovedModels() throws {
        var calls = 0
        var fail = false
        var changed = false
        let catalog = ClaudeModelCatalog(
            directory: try directory(), environment: env,
            helper: { _ in
                XCTFail()
                return ""
            },
            fetch: { request in
                calls += 1
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "synthetic-secret")
                XCTAssertEqual(request.url?.path, "/tingly/claude_desktop/v1/models")
                if fail { throw CLIError("secret should not escape") }
                if changed { return try self.data(["data": [["id": "claude-sonnet-5"]], "has_more": false]) }
                if request.url?.query?.contains("after_id") == true {
                    return try self.data(["data": [["id": "claude-sonnet-5"]], "has_more": false])
                }
                return try self.data([
                    "data": [["id": "claude-opus-5-5"]], "has_more": true, "last_id": "claude-opus-5-5",
                ])
            })
        XCTAssertEqual(try catalog.entries(cwd: "").count, 3)
        XCTAssertEqual(try catalog.entries(cwd: "").count, 3)
        XCTAssertEqual(calls, 2)
        fail = true
        XCTAssertThrowsError(try catalog.entries(cwd: "", refresh: true)) { error in
            XCTAssertFalse(String(describing: error).contains("secret should not escape"))
        }
        fail = false
        changed = true
        let refreshed = try catalog.entries(cwd: "")
        XCTAssertEqual(refreshed.count, 2)
        XCTAssertEqual(calls, 4)
        XCTAssertThrowsError(
            try ClaudeSessionConfiguration.resolve(["model": "claude-opus-5-5"], current: [:], models: refreshed))
    }

    func testSettingsChangeInvalidatesCacheAndOnlyUserHelperRuns() throws {
        let root = try directory()
        let project = try directory()
        var helpers: [String] = []
        var calls = 0
        let settings = root.appendingPathComponent("settings.json")
        try data(["apiKeyHelper": "user-helper", "env": ["ANTHROPIC_BASE_URL": "https://gateway.invalid/claude"]])
            .write(to: settings)
        let catalog = ClaudeModelCatalog(
            directory: root, environment: [:],
            helper: { command in
                helpers.append(command)
                return "synthetic-token"
            },
            fetch: { request in
                calls += 1
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "synthetic-token")
                return try self.data(["data": [["id": "claude-opus-5-5"]]])
            })
        _ = try catalog.entries(cwd: project.path)
        _ = try catalog.entries(cwd: project.path)
        XCTAssertEqual(calls, 1)
        try data(["apiKeyHelper": "new-user-helper", "env": ["ANTHROPIC_BASE_URL": "https://gateway.invalid/claude"]])
            .write(to: settings)
        _ = try catalog.entries(cwd: project.path)
        XCTAssertEqual(helpers, ["user-helper", "new-user-helper"])
        let local = project.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try data(["apiKeyHelper": "untrusted-project-helper"]).write(
            to: local.appendingPathComponent("settings.local.json"))
        XCTAssertThrowsError(try catalog.entries(cwd: project.path))
        XCTAssertEqual(helpers.count, 2)
    }

    func testMalformedEmptyDuplicateAndOversizedCatalogsFailClosed() throws {
        for rows: [[String: Any]] in [
            [], [["id": "high\nsecret"]], [["id": "a"], ["id": "a"]], [["id": "default"]],
            [["id": "a", "display_name": "bad\nlabel"]],
        ] {
            XCTAssertThrowsError(try ClaudeModelCatalog.parse(rows, settings: [:], environment: [:]))
        }
        let catalog = ClaudeModelCatalog(
            directory: try directory(), environment: env, fetch: { _ in Data(repeating: 32, count: 1024 * 1024 + 1) })
        XCTAssertThrowsError(try catalog.entries(cwd: ""))
    }

    func testRemotePlaintextAndMissingCredentialsNeverFetch() throws {
        for env in [["ANTHROPIC_BASE_URL": "http://remote.invalid", "ANTHROPIC_API_KEY": "synthetic"], [:]] {
            let catalog = ClaudeModelCatalog(
                directory: try directory(), environment: env,
                fetch: { _ in
                    XCTFail()
                    return Data()
                })
            XCTAssertThrowsError(try catalog.entries(cwd: ""))
        }
    }

    func testLiveCatalogReadOnlyWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["VIBEPIER_CLAUDE_CATALOG_PROBE"] == "1" else {
            throw XCTSkip("Explicit opt-in only: queries configured model metadata without inference")
        }
        let entries = try ClaudeModelCatalog().entries(cwd: "", refresh: true)
        XCTAssertGreaterThan(entries.count, 1)
        print("LIVE_CLAUDE_MODELS " + entries.compactMap { $0["id"] as? String }.joined(separator: ","))
    }
}
