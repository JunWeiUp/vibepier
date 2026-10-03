import VibeKit
import XCTest

@testable import VibePierCore

final class EmbeddedDriverTests: XCTestCase {
    func testLaunchAgentRunsOnlyTheApp() {
        let app = "/Applications/VibePier.app/Contents/MacOS/VibePier"
        XCTAssertEqual(Service.plist(binary: app)["ProgramArguments"] as? [String], [app])
        XCTAssertEqual(
            Service.plist(binary: "/tmp/vibepier")["ProgramArguments"] as? [String], ["/tmp/vibepier", "daemon"])
    }
    func testStoppedEmbeddedDriverReportsErrorWithoutLaunchingAProcess() async {
        let result = await EmbeddedDriver().run(["status"])
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.stderr.isEmpty)
    }
    func testInvalidSettingsThrowInsteadOfExitingTheApplication() async {
        let key = VibeKey(session: VibeSession())
        for args in [[], ["brightness"], ["brightness", "21"], ["unknown", "1"]] {
            do {
                try await setDeviceSetting(args, key: key)
                XCTFail("expected error for \(args)")
            } catch {}
        }
    }
}
