import Darwin
import Foundation
import XCTest

@testable import VibePierCore

final class SessionFileAccessTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(Bool, Bool)] = []
        func record(_ event: Notification) {
            lock.withLock { events.append((event.object == nil, event.userInfo == nil)) }
        }
        var snapshot: [(Bool, Bool)] { lock.withLock { events } }
    }

    func testOnlyPermissionErrnoProducesStructuredFailureAndPayloadFreeNotification() {
        let notifications = NotificationCenter()
        let monitor = FileAccessMonitor(notifications: notifications)
        let events = Events()
        let observer = notifications.addObserver(
            forName: SessionFileAccess.permissionDenied, object: nil, queue: nil
        ) { events.record($0) }
        defer { notifications.removeObserver(observer) }
        for code in [EPERM, EACCES] {
            let error = SessionFileAccess.failure(
                errno: code, fallback: "/synthetic/private-path", notifications: notifications, monitor: monitor)
            XCTAssertTrue(error is SessionFileAccess.PermissionDenied)
            XCTAssertEqual(String(describing: error), L10n.text("mac.file_access_denied"))
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, L10n.text("mac.file_access_denied"))
            XCTAssertEqual(monitor.status, .permissionRequired)
        }
        for code in [ENOENT, EIO, ELOOP, ENOTDIR] {
            let error = SessionFileAccess.failure(
                errno: code, fallback: "Original failure", notifications: notifications, monitor: monitor)
            XCTAssertFalse(error is SessionFileAccess.PermissionDenied)
            XCTAssertEqual(String(describing: error), "Original failure")
        }
        XCTAssertEqual(events.snapshot.count, 2)
        XCTAssertTrue(events.snapshot.allSatisfy { $0.0 && $0.1 })
    }

    func testNoRecentFileRemainsUnknownWithoutRunningAProbe() {
        let monitor = FileAccessMonitor(notifications: NotificationCenter())
        XCTAssertFalse(monitor.check())
        XCTAssertEqual(monitor.status, .unknown)
        XCTAssertFalse(monitor.checkInFlight)
    }

    func testRecheckUsesInjectedRecentProbeAndDistinguishesPermissionFromMissingFile() {
        for expected in [FileAccessStatus.accessConfirmed, .permissionRequired, .unknown] {
            let notifications = NotificationCenter()
            let monitor = FileAccessMonitor(notifications: notifications)
            let completed = expectation(description: "probe result")
            monitor.recordProbe {
                switch expected {
                case .permissionRequired: throw SessionFileAccess.PermissionDenied()
                case .unknown: throw POSIXError(.ENOENT)
                default: break
                }
            }
            let observer = notifications.addObserver(
                forName: FileAccessMonitor.statusChanged, object: nil, queue: nil
            ) { _ in if !monitor.checkInFlight { completed.fulfill() } }
            XCTAssertTrue(monitor.check())
            wait(for: [completed], timeout: 1)
            XCTAssertEqual(monitor.status, expected)
            notifications.removeObserver(observer)
        }
    }

    func testTimedOutProbeRetainsItsWorkerSlotUntilItActuallyFinishes() {
        let notifications = NotificationCenter()
        let monitor = FileAccessMonitor(notifications: notifications, timeout: 0.02)
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "started")
        let timedOut = expectation(description: "bounded UI timeout")
        let completed = expectation(description: "worker exited")
        monitor.recordProbe {
            started.fulfill()
            gate.wait()
        }
        let observer = notifications.addObserver(
            forName: FileAccessMonitor.statusChanged, object: nil, queue: nil
        ) { _ in
            if monitor.status == .unknown && monitor.checkInFlight { timedOut.fulfill() }
            if monitor.status == .accessConfirmed && !monitor.checkInFlight { completed.fulfill() }
        }
        defer { notifications.removeObserver(observer) }
        XCTAssertTrue(monitor.check())
        wait(for: [started, timedOut], timeout: 1)
        XCTAssertTrue(monitor.checkInFlight)
        XCTAssertFalse(monitor.check(), "an expired UI deadline must not admit another blocked worker")
        gate.signal()
        wait(for: [completed], timeout: 1)
        XCTAssertFalse(monitor.checkInFlight)
    }

    func testOldCheckCannotReplaceANewerActualFileResult() {
        let notifications = NotificationCenter()
        let monitor = FileAccessMonitor(notifications: notifications)
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "old read started")
        let finished = expectation(description: "old read finished")
        monitor.recordProbe {
            started.fulfill()
            gate.wait()
        }
        let observer = notifications.addObserver(
            forName: FileAccessMonitor.statusChanged, object: nil, queue: nil
        ) { _ in if !monitor.checkInFlight { finished.fulfill() } }
        defer { notifications.removeObserver(observer) }
        XCTAssertTrue(monitor.check())
        wait(for: [started], timeout: 1)
        monitor.recordProbe { throw POSIXError(.ENOENT) }
        monitor.recordPermissionRequired()
        gate.signal()
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(monitor.status, .permissionRequired)
    }

    func testNewRefusalWithoutANewProbeInvalidatesTheOlderCheck() {
        let notifications = NotificationCenter()
        let monitor = FileAccessMonitor(notifications: notifications)
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "old check started")
        let finished = expectation(description: "old check exited")
        monitor.recordProbe {
            started.fulfill()
            gate.wait()
        }
        let observer = notifications.addObserver(
            forName: FileAccessMonitor.statusChanged, object: nil, queue: nil
        ) { _ in if !monitor.checkInFlight { finished.fulfill() } }
        defer { notifications.removeObserver(observer) }
        XCTAssertTrue(monitor.check())
        wait(for: [started], timeout: 1)
        _ = SessionFileAccess.failure(
            errno: EPERM, fallback: "unavailable", notifications: notifications, monitor: monitor)
        gate.signal()
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(monitor.status, .permissionRequired)
    }

    func testPureStaleProbeFailureDoesNotPublishOrOverwriteNewSuccess() {
        let notifications = NotificationCenter()
        let monitor = FileAccessMonitor(notifications: notifications)
        let events = Events()
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "old check started")
        let finished = expectation(description: "old check exited")
        monitor.recordProbe {
            started.fulfill()
            gate.wait()
            throw SessionFileAccess.failure(
                errno: EACCES, fallback: "unavailable", notifications: notifications, monitor: monitor, report: false)
        }
        let denialObserver = notifications.addObserver(
            forName: SessionFileAccess.permissionDenied, object: nil, queue: nil
        ) { events.record($0) }
        let statusObserver = notifications.addObserver(
            forName: FileAccessMonitor.statusChanged, object: nil, queue: nil
        ) { _ in if !monitor.checkInFlight { finished.fulfill() } }
        defer {
            notifications.removeObserver(denialObserver)
            notifications.removeObserver(statusObserver)
        }
        XCTAssertTrue(monitor.check())
        wait(for: [started], timeout: 1)
        let newer = monitor.recordProbe {}
        monitor.record(.accessConfirmed, for: newer)
        gate.signal()
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(monitor.status, .accessConfirmed)
        XCTAssertTrue(events.snapshot.isEmpty)
    }

    func testOlderNormalReadCannotCommitPermissionOrSuccessAfterANewerRead() {
        let notifications = NotificationCenter()
        let monitor = FileAccessMonitor(notifications: notifications)
        let events = Events()
        let observer = notifications.addObserver(
            forName: SessionFileAccess.permissionDenied, object: nil, queue: nil
        ) { events.record($0) }
        defer { notifications.removeObserver(observer) }
        let older = monitor.recordProbe {}
        let newer = monitor.recordProbe {}
        XCTAssertTrue(monitor.record(.accessConfirmed, for: newer))
        XCTAssertFalse(monitor.record(.permissionRequired, for: older))
        XCTAssertFalse(monitor.record(.accessConfirmed, for: older))
        XCTAssertEqual(monitor.status, .accessConfirmed)
        XCTAssertTrue(events.snapshot.isEmpty)
    }
}
