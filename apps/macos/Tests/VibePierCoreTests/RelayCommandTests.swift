import XCTest

@testable import VibePierCore

final class RelayCommandTests: XCTestCase {
    func testConfigureReadsSecretFromFileWithoutRequiringACommandLineSecret() throws {
        let args = [
            "configure", "--url", "wss://relay.example.com/vibepier/relay", "--room", "my-mac", "--secret-file",
            "/private/secret",
        ]
        let result = try RelayCommand.payload(args) { path in
            XCTAssertEqual(path, "/private/secret")
            return Data((String(repeating: "a", count: 64) + "\n").utf8)
        }
        XCTAssertEqual(result["cmd"], "relay-config")
        XCTAssertEqual(result["secret"], String(repeating: "a", count: 64))
        XCTAssertEqual(result["room"], "my-mac")
    }
    func testInvalidOrDuplicateOptionsNeverReadSecret() {
        for args in [
            [], ["configure"], ["disable", "extra"], ["configure", "--url", "x", "--url", "y", "--secret-file", "z"],
        ] {
            XCTAssertThrowsError(
                try RelayCommand.payload(args) { _ in
                    XCTFail("must reject before reading")
                    return Data()
                })
        }
    }
    func testStatusAndDisableDoNotReadSecrets() throws {
        for action in ["status", "disable"] {
            let result = try RelayCommand.payload([action]) { _ in
                XCTFail("unexpected read")
                return Data()
            }
            XCTAssertEqual(result["cmd"], action == "status" ? "status" : "relay-config")
        }
    }
    func testRejectsMalformedAndOversizedCredentials() {
        let args = [
            "configure", "--url", "wss://relay.example.com/vibepier/relay", "--room", "my-mac", "--secret-file", "test",
        ]
        for data in [Data("short".utf8), Data(repeating: 0x61, count: 1025), Data([0xFF])] {
            XCTAssertThrowsError(try RelayCommand.payload(args) { _ in data })
        }
    }
}
