// SPDX-License-Identifier: MIT
//
// Vectors come from two sources: frames captured from a real AU05 dongle
// (firmware 4.4.0), and byte layouts recovered from the vendor library.

import XCTest

@testable import VibeKit

final class TEATests: XCTestCase {
    func hex(_ s: String) -> [UInt8] {
        let clean = s.replacingOccurrences(of: " ", with: "")
        return stride(from: 0, to: clean.count, by: 2).map {
            let a = clean.index(clean.startIndex, offsetBy: $0)
            return UInt8(clean[a..<clean.index(a, offsetBy: 2)], radix: 16)!
        }
    }

    func testKnownBlock() {
        // Verified against the dongle: it answers this encrypted version request.
        let plain = hex("0602030100000000")
        XCTAssertEqual(TEA.encrypt(plain), hex("45369cd8d0246f39"))
        XCTAssertEqual(TEA.decrypt(hex("45369cd8d0246f39")), plain)
    }

    func testZeroBlock() {
        // The last 7 bytes of every input report are this block, truncated.
        XCTAssertEqual(TEA.encrypt([UInt8](repeating: 0, count: 8)), hex("3890c499a360aaad"))
    }

    func testRoundTrip() {
        let data = (0..<64).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        XCTAssertEqual(TEA.decrypt(TEA.encrypt(data)), data)
    }

    func testOutputReportLayout() {
        let report = FrameCodec.outputReport(for: DongleRequest.version.bytes)
        XCTAssertEqual(report.count, 64)
        XCTAssertEqual(report[0], 0x55)
        XCTAssertEqual(Array(report[1..<9]), hex("45369cd8d0246f39"))
        // The vendor library drops the last encrypted byte.
        XCTAssertEqual(Array(report[57..<64]), hex("3890c499a360aa"))
    }

    func testInputReportDecode() {
        let plain = hex("060203114100001628000404002607231410") + [UInt8](repeating: 0, count: 46)
        let cipher = TEA.encrypt(plain)
        let report = [UInt8(0x55)] + cipher.prefix(63)
        let decoded = FrameCodec.decodeInputReport(report)
        XCTAssertEqual(decoded.count, 56)
        XCTAssertEqual(decoded, Array(plain.prefix(56)))
    }
}

final class RequestTests: XCTestCase {
    func prefix(_ r: Request, _ n: Int) -> [UInt8] { Array(r.bytes.prefix(n)) }

    func testAuth() {
        let r = DongleRequest.auth(code: 0x3F7A_4C9E)
        XCTAssertEqual(prefix(r, 9), [0x06, 0x02, 0x05, 0x01, 0x0E, 0x9E, 0x4C, 0x7A, 0x3F])
    }

    func testHeartbeat() {
        XCTAssertEqual(prefix(DongleRequest.heartbeat, 5), [0x06, 0x01, 0x23, 0x00, 0x01])
        XCTAssertNil(DongleRequest.heartbeat.reply)
    }

    func testReads() {
        XCTAssertEqual(prefix(DongleRequest.version, 4), [0x06, 0x02, 0x03, 0x01])
        XCTAssertEqual(prefix(DongleRequest.deviceActive, 4), [0x06, 0x03, 0x0A, 0x01])
        XCTAssertEqual(prefix(DeviceRequest.battery, 4), [0x01, 0x01, 0x02, 0x01])
        XCTAssertEqual(prefix(DeviceRequest.version, 4), [0x01, 0x04, 0x04, 0x01])
        XCTAssertEqual(prefix(DeviceRequest.indicatorLights, 4), [0x01, 0x0B, 0x88, 0x01])
        XCTAssertEqual(prefix(DeviceRequest.buttonShortcut(3), 5), [0x01, 0x06, 0x50, 0x01, 0x03])
        XCTAssertEqual(prefix(DeviceRequest.buttonFixedFunction(2), 6), [0x01, 0x06, 0x10, 0x01, 0x00, 0x02])
    }

    func testWrites() {
        XCTAssertEqual(
            prefix(DeviceRequest.setSleepTime(seconds: 7200), 8), [0x01, 0x01, 0x42, 0x02, 0x20, 0x1C, 0x00, 0x00])
        XCTAssertEqual(prefix(DeviceRequest.setMotorStrength(255), 6), [0x01, 0x06, 0x40, 0x04, 0xFF, 0x00])
        XCTAssertEqual(
            prefix(DeviceRequest.setNoiseReduction(level: 1), 9),
            [0x01, 0x01, 0x90, 0x04, 0x01, 0x40, 0x06, 0xE8, 0x03])
        XCTAssertEqual(prefix(DeviceRequest.setHooksMode(true), 5), [0x01, 0x0B, 0x89, 0x04, 0x01])
        XCTAssertEqual(prefix(DeviceRequest.setIndicatorLightMode(2), 7), [0x01, 0x0B, 0x88, 0x04, 0x01, 0x00, 0x02])
        XCTAssertEqual(
            prefix(DeviceRequest.setIndicatorLightAllOnBrightness(7), 8),
            [0x01, 0x0B, 0x88, 0x04, 0x02, 0x00, 0x00, 0x07])
        XCTAssertEqual(
            prefix(DeviceRequest.setButtonFixedFunction(1, function: 0x70), 10),
            [0x01, 0x06, 0x10, 0x04, 0x00, 0x01, 0x70, 0x00, 0x00, 0x00])
        XCTAssertEqual(prefix(DeviceRequest.reboot(), 8), [0x01, 0x01, 0x0C, 0x00, 0xF4, 0x01, 0x00, 0x00])
        XCTAssertEqual(prefix(DongleRequest.reboot(), 8), [0x06, 0x01, 0x26, 0x00, 0xF4, 0x01, 0x00, 0x00])
    }

    func testLEDFieldWrite() {
        // setDeviceIndicatorLightWorkModeType:type: for LED 1, type 0.
        let r = DeviceRequest.setIndicatorLight(led: 1, field: .workType, value: 0)
        XCTAssertEqual(prefix(r, 6), [0x01, 0x0B, 0x88, 0x04, 0x04, 0x01])
        // LED 3 always-on brightness lands at 8 + 15 + 4 = 27.
        let b = DeviceRequest.setIndicatorLight(led: 3, field: .alwaysOnBrightness, value: 9)
        XCTAssertEqual(b.bytes[4], 0x40)
        XCTAssertEqual(b.bytes[27], 9)
    }

    func testShortcutWrite() throws {
        // Captured: confirm bound to cmd+return.
        let r = DeviceRequest.setButtonShortcut(1, keys: try Hotkey.parse("cmd+return"))
        XCTAssertEqual(prefix(r, 11), [0x01, 0x06, 0x50, 0x04, 0x01, 0x01, 0x02, 0x03, 0x08, 0x02, 0x28])
    }

    func testReplyMatch() {
        let m = DeviceRequest.buttonShortcut(1).reply!
        XCTAssertTrue(m.matches(Frame([0x81, 0x06, 0x50, 0x11, 0x01])))
        XCTAssertFalse(m.matches(Frame([0x81, 0x06, 0x50, 0x11, 0x02])))
        XCTAssertFalse(m.matches(Frame([0x81, 0x06, 0x50, 0x14, 0x01])))
        let w = DeviceRequest.setHooksMode(true).reply!
        XCTAssertTrue(w.matches(Frame([0x81, 0x0B, 0x89, 0x14, 0x01])))
        XCTAssertTrue(w.matches(Frame([0x81, 0x0B, 0x89, 0x10, 0x01])))
        XCTAssertFalse(w.matches(Frame([0x81, 0x0B, 0x89, 0x11, 0x00])))
    }

    func testUpgradeMessages() {
        let c = UpgradeRequest.connect(target: 0x1F, fileLength: 0x0001_2345, customCode: [0x41, 0x00, 0x00])
        XCTAssertEqual(Array(c.prefix(15)), [0x1F, 0x01, 0, 0, 0, 0, 0, 0, 0x45, 0x23, 0x01, 0x00, 0x41, 0x00, 0x00])
        let d = UpgradeRequest.data(target: 0x1E, packageIndex: 3, chunk: [0xAA, 0xBB])
        XCTAssertEqual(Array(d.prefix(7)), [0x1E, 0x02, 0x03, 0x00, 0x02, 0xAA, 0xBB])
        let r = UpgradeRequest.receivePackageNum(target: 0x1F, checksum: 0x0102_0304)
        XCTAssertEqual(Array(r.prefix(10)), [0x1F, 0x03, 0, 0, 0, 0, 0x04, 0x03, 0x02, 0x01])
        let e = UpgradeRequest.enableProgram(target: 0x1F, frameIndex: 0x0102, packageCount: 32)
        XCTAssertEqual(Array(e.prefix(6)), [0x1F, 0x04, 0x02, 0x01, 0x20, 0x01])
        XCTAssertEqual(Array(UpgradeRequest.checkAllSum(target: 0x1F).prefix(2)), [0x1F, 0x06])
        XCTAssertEqual(
            Array(UpgradeRequest.allPageCompleteResult(target: 0x1F, matched: true).prefix(3)), [0x1F, 0x07, 0x01])
    }
}

final class ParserTests: XCTestCase {
    func frame(_ s: String) -> Frame {
        Frame(s.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    func testAuthReply() {
        // Captured: code 0x3F7A4C9E answered with key index 1.
        let m = VibeMessage.parse(frame("06 02 05 11 01 f3 f3 42 fe"))
        XCTAssertEqual(m, .authReply(keyIndex: 1, code: 0x3F7A_4C9E))
    }

    func testDongleVersion() {
        guard
            case .dongleVersion(let v) = VibeMessage.parse(
                frame("06 02 03 11 41 00 00 16 28 00 04 04 00 26 07 23 14 10 00"))
        else {
            return XCTFail("not a version")
        }
        XCTAssertEqual(v.version, "4.4.0")
        XCTAssertEqual(v.customCode, "410000")
        XCTAssertEqual(v.buildStamp, "2026-07-23 14:10")
    }

    func testDongleSerial() {
        let f = frame("06 02 81 11 11 00 82 02 54 45 53 54 44 4f 4e 47 4c 45 30 30 30 30 30 30 31")
        XCTAssertEqual(VibeMessage.parse(f), .dongleSerial("TESTDONGLE0000001"))
    }

    func testDeviceBattery() {
        let m = VibeMessage.parse(frame("81 01 02 11 b8 0f 5a 00 fe 01 00 00"))
        XCTAssertEqual(
            m,
            .battery(
                BatteryStatus(
                    percent: 90, millivolts: 4024, charging: false, chargeFull: false,
                    lowBatteryLevel: 0, powerOff: false)))
    }

    func testBatteryNotice() {
        let m = VibeMessage.parse(frame("0b 7b f9 0f 08 5a"))
        XCTAssertEqual(
            m,
            .batteryNotice(
                BatteryStatus(
                    percent: 90, millivolts: 4089, charging: true, chargeFull: false,
                    lowBatteryLevel: 0, powerOff: false)))
    }

    func testSerialChunks() {
        XCTAssertEqual(
            VibeMessage.parse(frame("81 01 0b 11 0a 00 54 45 53 54 4d 49 43 30 30 30")),
            .deviceSerialChunk(offset: 0, bytes: Array("TESTMIC000".utf8)))
        XCTAssertEqual(
            VibeMessage.parse(frame("81 01 0b 11 07 01 30 30 30 30 30 30 31")),
            .deviceSerialChunk(offset: 1, bytes: Array("0000001".utf8)))
    }

    func testLights() {
        let f = frame("81 0b 88 11 00 00 02 02 02 0a 02 02 02 02 0a 02 02 02 02 0a 02 02 02 01 0a 02 02 02")
        guard case .indicatorLights(let l) = VibeMessage.parse(f) else { return XCTFail("not lights") }
        XCTAssertEqual(l.mode, 2)
        XCTAssertEqual(l.allOnBrightness, 2)
        XCTAssertEqual(l.leds.count, 4)
        XCTAssertEqual(
            l.leds[0], LEDState(workType: 2, workTime: 10, breatheLevel: 2, breatheBrightness: 2, alwaysOnBrightness: 2)
        )
        XCTAssertEqual(l.leds[3].workType, 1)
    }

    func testShortcutReply() {
        let m = VibeMessage.parse(frame("81 06 50 11 01 01 02 03 08 02 28"))
        XCTAssertEqual(
            m, .buttonShortcut(index: 1, keys: [ShortcutKey(page: 3, value: 8), ShortcutKey(page: 2, value: 0x28)]))
        XCTAssertEqual(VibeMessage.parse(frame("81 06 50 11 04")), .buttonShortcut(index: 4, keys: []))
    }

    func testFixedFunctionReply() {
        XCTAssertEqual(
            VibeMessage.parse(frame("81 06 10 11 00 03 6e")),
            .buttonFixedFunction(index: 3, macroConfig: 0, function: 0x6E))
    }

    func testNotices() {
        XCTAssertEqual(
            VibeMessage.parse(frame("0b 10 01 01 00")),
            .keyEvent(KeyEvent(index: 1, status: 1, physicalIndex: 0)))
        XCTAssertEqual(VibeMessage.parse(frame("0b 0b 01")), .linkActive(true))
        XCTAssertEqual(VibeMessage.parse(frame("0b f0")), .powerOn)
        XCTAssertEqual(
            VibeMessage.parse(frame("0b 83 00 64 00 64 00")),
            .noiseReductionNotice(level: 0, low: 100, high: 100))
    }

    func testKeyEventControlUsesPhysicalIndex() {
        XCTAssertEqual(KeyEvent(index: 9, status: 1, physicalIndex: 5).control, .knobLeft)
    }

    func testUpgradeReplies() {
        XCTAssertEqual(VibeMessage.parse(frame("1f 01")), .upgrade(target: 0x1F, .connected))
        XCTAssertEqual(
            VibeMessage.parse(frame("1f 03 ff ff ff ff 10 20 00 00")),
            .upgrade(target: 0x1F, .receivePackageNum(mask: 0xFFFF_FFFF, checksum: 0x2010)))
        XCTAssertEqual(
            VibeMessage.parse(frame("1e 05 01 ff 07 00")),
            .upgrade(target: 0x1E, .programComplete(result: 1, mask: 0xFF, index: 7)))
        XCTAssertEqual(VibeMessage.parse(frame("1f 06 78 56 34 12")), .upgrade(target: 0x1F, .checkAllSum(0x1234_5678)))
        XCTAssertEqual(VibeMessage.parse(frame("1f 08 01")), .upgrade(target: 0x1F, .result(1)))
    }
}

final class HotkeyTests: XCTestCase {
    func testModifiersFirst() throws {
        XCTAssertEqual(try Hotkey.parseHIDCodes("4+cmd+shift"), [0xE3, 0xE1, 0x21])
    }

    func testVendorContentString() throws {
        XCTAssertEqual(Hotkey.vendorContentString(try Hotkey.parseHIDCodes("cmd+d")), "E3|07")
        XCTAssertEqual(Hotkey.vendorContentString(try Hotkey.parseHIDCodes("wheel-up")), "0105")
    }

    func testFirmwareEncoding() throws {
        XCTAssertEqual(try Hotkey.parse("fn"), [ShortcutKey(page: 0x13, value: 2)])
        XCTAssertEqual(try Hotkey.parse("wheel-down"), [ShortcutKey(page: 7, value: 6)])
        XCTAssertEqual(try Hotkey.parse("left-click"), [ShortcutKey(page: 7, value: 0)])
        XCTAssertEqual(try Hotkey.parse("ralt"), [ShortcutKey(page: 3, value: 0x40)])
        XCTAssertEqual(try Hotkey.parse("escape"), [ShortcutKey(page: 2, value: 0x29)])
    }

    func testPlusKey() throws {
        XCTAssertEqual(try Hotkey.parseHIDCodes("cmd++"), [0xE3, 0x2E])
    }

    func testLimits() {
        XCTAssertThrowsError(try Hotkey.parse("ctrl+alt+shift+cmd+a"))
        XCTAssertThrowsError(try Hotkey.parse("cmd+nosuchkey"))
        XCTAssertThrowsError(try Hotkey.parse(""))
    }

    func testRender() throws {
        XCTAssertEqual(Hotkey.render(try Hotkey.parse("cmd+shift+4")), "cmd+shift+4")
        XCTAssertEqual(Hotkey.render([ShortcutKey(page: 3, value: 0x09)]), "ctrl+cmd")
    }

    func testRoundTripHIDCode() {
        for code: UInt16 in [0x02, 0x04, 0x28, 0xE0, 0xE7, 0x100, 0x105, 0x106] {
            XCTAssertEqual(ShortcutKey(hidCode: code).hidCode, code)
        }
    }
}

final class FirmwareTests: XCTestCase {
    func image(target: UInt8, payload: Int) -> Data {
        var header = [UInt8](repeating: 0, count: 32)
        header[4] = target
        header[5] = 0x41
        writeLE32(&header, 28, UInt32(payload))
        let body = (0..<payload).map { UInt8($0 & 0xFF) }
        return Data(header + body)
    }

    func testParse() throws {
        let img = try FirmwareImage(data: image(target: 1, payload: 12000), target: .device)
        XCTAssertEqual(img.frames.count, 12)
        XCTAssertEqual(img.frames[11].count, 12000 - 11 * 1024)
        XCTAssertEqual(img.customCode, [0x41, 0, 0])
        XCTAssertEqual(FirmwareImage.packages(of: img.frames[0]).count, 32)
        XCTAssertEqual(FirmwareImage.packages(of: img.frames[11]).count, 23)
        let expected = (0..<12000).reduce(UInt32(0)) { $0 + UInt32($1 & 0xFF) }
        XCTAssertEqual(img.totalChecksum, expected)
    }

    func testTargetChecks() {
        XCTAssertThrowsError(try FirmwareImage(data: image(target: 0, payload: 12000), target: .device))
        XCTAssertThrowsError(try FirmwareImage(data: image(target: 1, payload: 12000), target: .dongle))
        XCTAssertNoThrow(try FirmwareImage(data: image(target: 2, payload: 12000), target: .dongle))
        XCTAssertNoThrow(try FirmwareImage(data: image(target: 2, payload: 12000), target: .device))
    }

    func testSizeCheck() {
        // (length >> 11) < 5 is rejected, so 10239 bytes fails and 10240 passes.
        XCTAssertThrowsError(try FirmwareImage(data: image(target: 1, payload: 10239 - 32), target: .device))
        XCTAssertNoThrow(try FirmwareImage(data: image(target: 1, payload: 10240 - 32), target: .device))
    }
}
