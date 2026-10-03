import XCTest

@testable import VibePierCore

private final class AudioFixture: @unchecked Sendable {
    let system = AudioManager.InputDevice(id: 1, name: "MacBook", uid: "system")
    let au05 = AudioManager.InputDevice(id: 2, name: "AU05", uid: "au05")
    var selected: AudioManager.InputDevice?
    var devices: [AudioManager.InputDevice] = []
    var enumerations = 0
    init() {
        selected = system
        devices = [system, au05]
    }
    func router() -> TalkInputRouter {
        TalkInputRouter(
            list: {
                self.enumerations += 1
                return self.devices
            }, current: { self.selected },
            select: {
                self.selected = $0
                return true
            })
    }
}
final class TalkInputRouterTests: XCTestCase {
    func testPressReleaseRestoresAndCachesDeviceList() throws {
        let audio = AudioFixture()
        let router = audio.router()
        for _ in 0..<3 {
            try router.press()
            try router.press()
            XCTAssertEqual(audio.selected?.uid, "au05")
            try router.release()
            XCTAssertEqual(audio.selected?.uid, "system")
        }
        XCTAssertEqual(audio.enumerations, 1)
    }
    func testManualChangeIsRespectedAndDeviceChangesInvalidateCache() throws {
        let audio = AudioFixture()
        let router = audio.router()
        try router.press()
        audio.selected = audio.system
        try router.release()
        XCTAssertEqual(audio.selected?.uid, "system")
        audio.devices = [audio.system]
        router.invalidateDevices()
        try router.press()
        XCTAssertEqual(audio.selected?.uid, "system", "without AU05 the current input stays")
        try router.release()
        XCTAssertEqual(audio.selected?.uid, "system")
    }
    func testOriginalAU05IsPreserved() throws {
        let audio = AudioFixture()
        audio.selected = audio.au05
        let router = audio.router()
        try router.press()
        try router.release()
        XCTAssertEqual(audio.selected?.uid, "au05")
    }
}
