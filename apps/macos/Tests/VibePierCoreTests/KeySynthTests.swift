import CoreGraphics
import XCTest

@testable import VibePierCore

final class KeySynthTests: XCTestCase {
    func testUnsupportedCodeCannotLeaveModifiersOrMouseHeld() {
        for codes: [UInt16] in [[0xE3, 0xFFFF], [0x100, 0x04, 0xFFFF], [0x105, 0xFFFF]] {
            var emitted: [KeySynth.InputEvent] = []
            XCTAssertThrowsError(try KeySynth.press(codes, isTrusted: { true }, send: { emitted.append($0) }))
            XCTAssertEqual(emitted, [], "The whole shortcut must validate before any native effect")
        }
    }

    func testValidShortcutEmitsModifiersBeforeKeyWithTheirFlags() throws {
        var emitted: [KeySynth.InputEvent] = []
        try KeySynth.press([0x04, 0xE3, 0xE1], isTrusted: { true }, send: { emitted.append($0) })
        XCTAssertEqual(
            emitted,
            [
                .key(0x37, true, .maskCommand),
                .key(0x38, true, [.maskCommand, .maskShift]),
                .key(0x00, true, [.maskCommand, .maskShift]),
            ])
    }

    func testPermissionRefusalHasNoNativeEffects() {
        var emitted: [KeySynth.InputEvent] = []
        XCTAssertThrowsError(try KeySynth.press([0xE3, 0x04], isTrusted: { false }, send: { emitted.append($0) }))
        XCTAssertTrue(emitted.isEmpty)
    }
}
