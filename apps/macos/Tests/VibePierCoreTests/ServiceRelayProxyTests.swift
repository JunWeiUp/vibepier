import XCTest

@testable import VibePierCore

final class ServiceRelayProxyTests: XCTestCase {
    func testRebuiltJobKeepsOnlyDedicatedRelayProxy() {
        let app = "/Applications/VibePier.app/Contents/MacOS/VibePier"
        let job = Service.plist(binary: app, relayProxy: "  http://localhost:51837/  ")
        XCTAssertEqual(
            job["EnvironmentVariables"] as? [String: String], ["VIBEPIER_RELAY_PROXY": "http://localhost:51837/"])
        XCTAssertEqual(job["ProgramArguments"] as? [String], [app])
        XCTAssertEqual(job["Label"] as? String, Service.label)
    }

    func testInvalidOrMissingProxyDoesNotAddJobEnvironment() {
        for proxy in [nil, "", "http://user:password@localhost:51837", "socks5://localhost:51837"] as [String?] {
            XCTAssertNil(Service.plist(binary: "/tmp/vibepier", relayProxy: proxy)["EnvironmentVariables"])
        }
    }
}
