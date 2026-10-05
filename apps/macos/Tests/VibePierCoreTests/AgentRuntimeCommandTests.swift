import XCTest

@testable import VibePierCore

final class AgentRuntimeCommandTests: XCTestCase {
    func testOnlyExplicitLocalSetupCommandsParse() throws {
        let status = try AgentRuntimeCommand.payload(["status"])
        XCTAssertEqual(status["cmd"] as? String, "agent-runtime")
        let enable = try AgentRuntimeCommand.payload([
            "codex", "enable", "--executable", "/tools/codex", "--workspace", "/tmp/work",
        ])
        let request = try XCTUnwrap(enable["request"] as? [String: String])
        XCTAssertEqual(request["action"], "enable")
        XCTAssertEqual(request["workspace"], "/tmp/work")
        for input in [
            ["codex", "bind"], ["codex", "disable", "--workspace", "/tmp/work"],
            ["codex", "enable", "--executable", "codex", "--workspace", "/tmp/work"],
            ["claude-mods", "enable", "--reviewed-version", "2.1.287", "--reviewed-version", "2.1.288"],
            ["status", "--token", "secret"], ["codex", "enable"],
        ] {
            XCTAssertThrowsError(try AgentRuntimeCommand.payload(input))
        }
    }
}
