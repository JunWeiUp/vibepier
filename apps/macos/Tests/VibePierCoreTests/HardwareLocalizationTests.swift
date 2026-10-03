import VibeKit
import XCTest

@testable import VibePierCore

final class HardwareLocalizationTests: XCTestCase {
    func testHardwareAndCoreErrorsShareLanguageWithoutChangingNativeValues() {
        let chinese = L10n.language == .simplifiedChinese
        XCTAssertEqual(HotkeyError.empty.description, chinese ? "快捷键为空" : "the hotkey is empty")
        XCTAssertEqual(
            SessionError.notReady.description,
            chinese ? "接收器未完成认证握手" : "the dongle did not complete the auth handshake")
        XCTAssertEqual(
            TransportError.openFailed(-1).description,
            chinese ? "IOHIDDeviceOpen 失败（0xFFFFFFFF）" : "IOHIDDeviceOpen failed (0xFFFFFFFF)")
        let raw = "native-{0}-%s-原始值"
        XCTAssertTrue(HotkeyError.unknownKey(raw).description.contains(raw))
        XCTAssertTrue(SessionError.timeout(raw).description.contains(raw))
        XCTAssertTrue(VibeKeyError.writeRejected(raw, Frame([1, 2])).description.contains(raw))
        XCTAssertTrue(FirmwareError.wrongTarget(255, .dongle).description.contains("255"))
        XCTAssertTrue(FirmwareError.wrongTarget(255, .dongle).description.contains("dongle"))
        XCTAssertEqual(
            KeySynth.SynthError.unmapped(255).description,
            chinese ? "HID 用法 0xFF 没有对应的 macOS 键码" : "HID usage 0xFF has no macOS key code")
    }
}
