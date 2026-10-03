import XCTest

@testable import VibePierCore

final class PhoneInputLeaseTests: XCTestCase {
    func testIdleNeverChangesInputAndGestureRestoresMac() throws {
        let harness = Harness()
        let lease = harness.make()
        XCTAssertTrue(lease.recover())
        XCTAssertEqual(harness.changes, [])
        try lease.begin(target: harness.phone)
        XCTAssertEqual(harness.current.uid, "phone")
        XCTAssertTrue(lease.restore())
        XCTAssertEqual(harness.current.uid, "mac")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url.path))
    }
    func testCrashRecoveryAndExistingPhoneInputReturnToMac() throws {
        let harness = Harness()
        try harness.make().begin(target: harness.phone)
        XCTAssertTrue(harness.make().recover())
        XCTAssertEqual(harness.current.uid, "mac")
        harness.current = harness.phone
        let lease = harness.make()
        try lease.begin(target: harness.phone)
        XCTAssertTrue(lease.restore())
        XCTAssertEqual(harness.current.uid, "mac")
    }
    func testManualInputSelectionIsPreserved() throws {
        let harness = Harness()
        let lease = harness.make()
        try lease.begin(target: harness.phone)
        harness.current = harness.external
        XCTAssertTrue(lease.restore())
        XCTAssertEqual(harness.current.uid, "external")
    }
    func testFailedRestoreRetainsRecoveryRecord() throws {
        let harness = Harness()
        let lease = harness.make()
        try lease.begin(target: harness.phone)
        harness.canSelect = false
        XCTAssertFalse(lease.restore())
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.url.path))
        harness.canSelect = true
        XCTAssertTrue(lease.restore())
        XCTAssertEqual(harness.current.uid, "mac")
    }
    func testUnreadableRecoveryRecordBlocksNewGestureWithoutOverwritingEvidence() throws {
        for data in [
            Data("{damaged".utf8), Data(repeating: 0x61, count: 4097),
            Data(#"{"originalUID":"phone","phoneUID":"phone"}"#.utf8),
        ] {
            let harness = Harness()
            try data.write(to: harness.url)
            let lease = harness.make()
            XCTAssertFalse(lease.recover())
            XCTAssertThrowsError(try lease.begin(target: harness.phone))
            XCTAssertEqual(try Data(contentsOf: harness.url), data)
            XCTAssertEqual(harness.changes, [])
        }
    }
    func testNewGestureRecoversEarlierCrashBeforeSavingItsOwnLease() throws {
        let harness = Harness()
        try harness.make().begin(target: harness.phone)
        let next = harness.make()
        // begin must be safe even when the caller did not explicitly recover first.
        try next.begin(target: harness.phone)
        XCTAssertEqual(harness.changes, ["phone", "mac", "phone"])
        let permissions = try FileManager.default.attributesOfItem(atPath: harness.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertTrue(next.restore())
        XCTAssertEqual(harness.current.uid, "mac")
    }
    func testSuccessfulSetWithoutReadbackCannotDiscardRecoveryRecord() throws {
        let harness = Harness()
        let lease = harness.make()
        try lease.begin(target: harness.phone)
        let record = try Data(contentsOf: harness.url)
        harness.appliesSelection = false
        XCTAssertFalse(lease.restore())
        XCTAssertThrowsError(try lease.begin(target: harness.phone))
        XCTAssertEqual(try Data(contentsOf: harness.url), record)
        harness.appliesSelection = true
        XCTAssertTrue(lease.restore())
    }

    func testNoOpInputSwitchCannotBeginPhoneRecording() throws {
        let harness = Harness()
        harness.appliesSelection = false
        XCTAssertThrowsError(try harness.make().begin(target: harness.phone))
        XCTAssertEqual(harness.current.uid, "mac")
    }
    private final class Harness {
        let mac = AudioManager.InputDevice(id: 1, name: "MacBook Pro麦克风", uid: "mac")
        let phone = AudioManager.InputDevice(id: 2, name: "BlackHole 2ch", uid: "phone")
        let external = AudioManager.InputDevice(id: 3, name: "Headset", uid: "external")
        var current: AudioManager.InputDevice
        var changes: [String] = []
        var canSelect = true
        var appliesSelection = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "phone-input-test-\(UUID().uuidString).json")
        init() { current = mac }
        deinit { try? FileManager.default.removeItem(at: url) }
        func make() -> PhoneInputLease {
            PhoneInputLease(
                file: url, devices: { [unowned self] in [mac, phone, external] },
                current: { [unowned self] in current },
                select: { [unowned self] device in
                    guard canSelect else { return false }
                    changes.append(device.uid)
                    if appliesSelection { current = device }
                    return true
                })
        }
    }
}
