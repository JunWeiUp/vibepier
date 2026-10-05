import XCTest

@testable import VibePierApp

@MainActor
final class SessionProviderModelTests: XCTestCase {
    func testFailedSettingRetainsConfirmedStateAndSuccessRefreshesIt() async {
        var enabled = true
        var fail = true
        var changes = 0
        let model = DeviceModel(runCommand: { args in
            if args.first == "session-provider-set" {
                changes += 1
                if fail { return .init(exitCode: 1, stdout: "", stderr: "synthetic save failure") }
                enabled = args.last == "on"
                return .init(exitCode: 0, stdout: "{}", stderr: "")
            }
            return .init(
                exitCode: 0,
                stdout: """
                    {"ok":true,"dongleConnected":false,"micLinked":false,
                     "providerAccess":{"revision":1,"enabled":{"codex":\(enabled),"claude":true,"zcode":false}}}
                    """, stderr: "")
        })
        await model.refreshStatus()
        await model.setSessionProvider("codex", enabled: false)
        XCTAssertEqual(model.sessionProviders["codex"], true)
        XCTAssertEqual(model.sessionProviderError, "synthetic save failure")
        fail = false
        await model.setSessionProvider("codex", enabled: false)
        XCTAssertEqual(model.sessionProviders["codex"], false)
        XCTAssertEqual(model.sessionProviders["claude"], true)
        XCTAssertEqual(model.sessionProviderError, "")
        await model.setSessionProvider("unknown", enabled: true)
        XCTAssertEqual(changes, 2)
    }
}
