import XCTest

@testable import VibePierCore

final class TaskNativeRouteTests: XCTestCase {
    func testClaudeReadIdentityUsesTheWholePathComponent() {
        XCTAssertEqual(ClaudeDesktop.sessionHost(from: "https://claude.ai/code/local_abc-123"), "local_abc-123")
        XCTAssertEqual(
            ClaudeDesktop.sessionHost(from: "https://claude.ai/code/local_target?search=local_other"), "local_target")
        for address in [
            "https://claude.ai/code?search=local_target", "https://claude.ai/code/prefixlocal_target",
            "https://claude.ai/code/local_target/other", "https://claude.ai/code/local_target%2Fother",
        ] {
            XCTAssertNil(ClaudeDesktop.sessionHost(from: address), address)
        }
    }
}
