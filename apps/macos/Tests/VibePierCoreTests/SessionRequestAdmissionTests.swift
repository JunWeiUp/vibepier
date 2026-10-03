import Foundation
import XCTest

@testable import VibePierCore

final class SessionRequestAdmissionTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    func testExpiredQueuedMutationNeverExecutesAndOtherProviderRemainsUsable() {
        let first = SessionRequestAdmission(waitTimeout: 0.04, runningTimeout: 1)
        let second = SessionRequestAdmission(waitTimeout: 1)
        let blocked = DispatchQueue(label: "test.blocked-provider")
        let gate = DispatchSemaphore(value: 0)
        blocked.async { gate.wait() }  // Represents a stuck provider event or filesystem call.
        let executed = Counter()
        let expired = expectation(description: "Queued send expires")
        first.submit(on: blocked) {
            expired.fulfill()
        } work: {
            executed.add()
        }
        wait(for: [expired], timeout: 2)
        let other = expectation(description: "Other provider opens a session")
        second.submit(on: DispatchQueue(label: "test.healthy-provider")) {
            XCTFail("Other provider rejected")
        } work: {
            other.fulfill()
        }
        wait(for: [other], timeout: 2)

        // Expiry must not free the retained queue entry and allow unbounded retries behind it.
        let rejected = Counter()
        for _ in 0..<100 {
            first.submit(on: blocked) {
                rejected.add()
            } work: {
                executed.add()
            }
        }
        XCTAssertEqual(rejected.value, 100)
        gate.signal()
        blocked.sync {}
        XCTAssertEqual(executed.value, 0, "Cancelled sends must not execute after the provider recovers")
        let recovered = expectation(description: "Admission resumes after queue drains")
        first.submit(on: blocked) {
            XCTFail("Provider did not recover")
        } work: {
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 2)
    }

    func testRunningMutationKeepsItsOnlyCompletionAndCannotBeReplayedByTimeout() {
        // Delay timer delivery deliberately: admission must honor the clock, not callback scheduling.
        let timers = DispatchQueue(label: "test.delayed-admission-timers")
        let timerGate = DispatchSemaphore(value: 0)
        timers.async { timerGate.wait() }
        defer { timerGate.signal() }
        let admission = SessionRequestAdmission(waitTimeout: 5, runningTimeout: 0.03, timers: timers)
        let queue = DispatchQueue(label: "test.running-mutation")
        let started = expectation(description: "Original send starts")
        let completed = expectation(description: "Original completion is retained")
        let gate = DispatchSemaphore(value: 0)
        let rejections = Counter()
        admission.submit(on: queue) {
            XCTFail("Running work must not get a synthetic failure")
        } work: {
            started.fulfill()
            gate.wait()
            completed.fulfill()
        }
        wait(for: [started], timeout: 2)
        // Leave the fake call running past its deadline. No timeout callback may replace its result.
        Thread.sleep(forTimeInterval: 0.08)
        admission.submit(on: queue) {
            rejections.add()
        } work: {
            XCTFail("A retry ran while stalled")
        }
        XCTAssertEqual(rejections.value, 1)
        gate.signal()
        wait(for: [completed], timeout: 2)
        queue.sync {}
        let recovered = expectation(description: "Recovers after actual work finishes")
        admission.submit(on: queue) {
            XCTFail("Still blocked")
        } work: {
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 2)
    }

    func testAdmissionCapacityIsBoundedBeforeTimersFire() {
        let admission = SessionRequestAdmission(limit: 2, waitTimeout: 10)
        let queue = DispatchQueue(label: "test.capacity")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let rejects = Counter()
        let calls = Counter()
        for _ in 0..<100 {
            admission.submit(on: queue) {
                rejects.add()
            } work: {
                calls.add()
            }
        }
        XCTAssertEqual(rejects.value, 98)
        gate.signal()
        queue.sync {}
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(rejects.value, 98)
    }

    func testOneDesktopOwnerCannotHoldOtherProvidersIndefinitely() throws {
        let mutex = NSRecursiveLock()  // Never touch real desktop focus or the production lock.
        let queue = DispatchQueue(label: "test.desktop-owner")
        let started = expectation(description: "Fake desktop owner acquires lock")
        let gate = DispatchSemaphore(value: 0)
        queue.async {
            mutex.lock()
            started.fulfill()
            gate.wait()
            mutex.unlock()
        }
        wait(for: [started], timeout: 2)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try DesktopInteractions.acquire(mutex, timeout: 0.03))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        gate.signal()
        queue.sync {}
        try DesktopInteractions.acquire(mutex, timeout: 0.1)
        defer { mutex.unlock() }
        // Nested helpers in the owning thread still work.
        try DesktopInteractions.acquire(mutex, timeout: 0.1)
        mutex.unlock()
    }
}
