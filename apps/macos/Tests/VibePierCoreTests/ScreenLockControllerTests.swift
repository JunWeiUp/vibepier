import XCTest

@testable import VibePierCore

final class ScreenLockControllerTests: XCTestCase {
    private final class Screen: @unchecked Sendable {
        var locked = true
        var configured = true
        var failUnlock = false
        var unlocks = 0
        var locks = 0
        lazy var controller = ScreenLockController(
            isLocked: { self.locked },
            unlock: {
                guard self.configured else { throw CLIError("not configured") }
                self.unlocks += 1
                if self.failUnlock { throw ScreenUnlockAttemptFailed() }
                self.locked = false
            },
            lock: {
                self.locks += 1
                self.locked = true
            })
    }
    func testManualUnlockStaysUnlockedAndRepeatedTapIsIdempotent() throws {
        let screen = Screen()
        try screen.controller.unlockNow()
        try screen.controller.unlockNow()
        screen.controller.release()
        XCTAssertFalse(screen.locked)
        XCTAssertEqual(screen.unlocks, 1)
        XCTAssertEqual(screen.locks, 0)
    }
    func testManualUnlockOverridesTemporaryRelockWithoutLosingLeases() throws {
        let screen = Screen()
        try screen.controller.acquire()
        try screen.controller.acquire()
        try screen.controller.unlockNow()
        XCTAssertThrowsError(try screen.controller.lockNow(), "cannot lock during desktop input")
        screen.controller.release()
        screen.controller.release()
        XCTAssertFalse(screen.locked)
        try screen.controller.lockNow()
        try screen.controller.lockNow()
        XCTAssertTrue(screen.locked)
        XCTAssertEqual(screen.locks, 1)
    }
    func testTemporaryUnlockRelocksOnlyAfterLastLease() throws {
        let screen = Screen()
        try screen.controller.acquire()
        try screen.controller.acquire()
        screen.controller.release()
        XCTAssertFalse(screen.locked)
        screen.controller.release()
        XCTAssertTrue(screen.locked)
        XCTAssertEqual(screen.unlocks, 1)
        XCTAssertEqual(screen.locks, 1)
    }
    func testAlreadyUnlockedDesktopIsNeverRelockedByLease() throws {
        let screen = Screen()
        screen.locked = false
        try screen.controller.acquire()
        screen.controller.release()
        XCTAssertFalse(screen.locked)
        XCTAssertEqual(screen.unlocks, 0)
        XCTAssertEqual(screen.locks, 0)
    }
    func testMissingCredentialDoesNotTypeOrPermanentlyBlockFutureConfiguration() throws {
        let screen = Screen()
        screen.configured = false
        XCTAssertThrowsError(try screen.controller.unlockNow())
        XCTAssertFalse(screen.controller.failed)
        XCTAssertEqual(screen.unlocks, 0)
        screen.configured = true
        try screen.controller.unlockNow()
        XCTAssertFalse(screen.locked)
    }
    func testFailedUnlockNeverRetriesUntilCredentialIsReset() throws {
        let screen = Screen()
        screen.failUnlock = true
        XCTAssertThrowsError(try screen.controller.unlockNow())
        XCTAssertTrue(screen.controller.failed)
        XCTAssertThrowsError(try screen.controller.unlockNow())
        XCTAssertThrowsError(try screen.controller.acquire())
        XCTAssertEqual(screen.unlocks, 1)
        screen.failUnlock = false
        screen.controller.resetFailure()
        try screen.controller.unlockNow()
        XCTAssertEqual(screen.unlocks, 2)
        XCTAssertFalse(screen.locked)
    }

    func testConfirmedManualUnlockClearsFailureWithoutSavingPassword() throws {
        let screen = Screen()
        screen.failUnlock = true
        XCTAssertThrowsError(try screen.controller.unlockNow())
        screen.locked = false
        XCTAssertFalse(screen.controller.failed)
        screen.failUnlock = false
        screen.locked = true
        try screen.controller.acquire()
        screen.controller.release()
        XCTAssertEqual(screen.unlocks, 2)
        XCTAssertEqual(screen.locks, 1)
    }

    func testUnlockedActionClearsFailureWithoutTakingRelockOwnership() throws {
        let screen = Screen()
        screen.failUnlock = true
        XCTAssertThrowsError(try screen.controller.acquire())
        screen.locked = false
        try screen.controller.acquire()
        screen.controller.release()
        XCTAssertFalse(screen.controller.failed)
        XCTAssertEqual(screen.unlocks, 1)
        XCTAssertEqual(screen.locks, 0)
    }

    func testExplicitRelockAfterManualUnlockClearsOldFailure() throws {
        let screen = Screen()
        screen.failUnlock = true
        XCTAssertThrowsError(try screen.controller.unlockNow())
        screen.locked = false
        try screen.controller.lockNow()
        screen.failUnlock = false
        try screen.controller.unlockNow()
        XCTAssertEqual(screen.unlocks, 2)
    }

    private final class GraceScreen: @unchecked Sendable {
        var locked = true
        var unlocks = 0
        var locks = 0
        var idle: Double = 1_000
        var pending: [@Sendable () -> Void] = []
        lazy var controller = ScreenLockController(
            isLocked: { self.locked },
            unlock: {
                self.unlocks += 1
                self.locked = false
            },
            lock: {
                self.locks += 1
                self.locked = true
            }, relockGrace: 120, schedule: { _, work in self.pending.append(work) },
            localIdleSeconds: { self.idle })
        func fire() {
            let work = pending
            pending.removeAll()
            for item in work { item() }
        }
    }

    func testGraceKeepsPhoneUnlockOpenAcrossConsecutiveActionsThenRelocksOnce() throws {
        let screen = GraceScreen()
        try screen.controller.acquire()
        screen.controller.release()
        XCTAssertFalse(screen.locked, "Relock waits for the grace period")
        try screen.controller.acquire()
        screen.controller.release()
        XCTAssertEqual(screen.unlocks, 1, "A second action inside the grace period does not unlock again")
        screen.fire()
        XCTAssertTrue(screen.locked)
        XCTAssertEqual(screen.locks, 1, "Only the latest release may relock")
    }

    func testLocalUseOrExplicitUnlockDuringGraceCancelsRelock() throws {
        let screen = GraceScreen()
        try screen.controller.acquire()
        screen.controller.release()
        screen.idle = 5
        screen.fire()
        XCTAssertFalse(screen.locked, "Someone is using the Mac; leave it unlocked")
        screen.locked = true
        screen.idle = 1_000
        try screen.controller.acquire()
        screen.controller.release()
        try screen.controller.unlockNow()
        screen.fire()
        XCTAssertFalse(screen.locked, "An explicit phone unlock stays unlocked")
        XCTAssertEqual(screen.locks, 0)
    }
}
