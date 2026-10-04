import Foundation
import XCTest

@testable import VibePierCore

final class APKPreparationTests: XCTestCase {
    func testBlockedPreparationDoesNotBlockStateQueueAndCancellationDoesNotFreeWorker() async {
        let workers = APKPreparationWorkers(capacity: 1)
        let started = expectation(description: "Preparation running")
        let finished = expectation(description: "Preparation exited")
        let gate = DispatchSemaphore(value: 0)
        let job = APKPreparationJob()
        XCTAssertTrue(
            workers.submit {
                started.fulfill()
                _ = gate.wait(timeout: .now() + 5)
                do {
                    try job.check()
                    XCTFail("Cancelled work must not commit")
                } catch {}
                finished.fulfill()
            })
        await fulfillment(of: [started], timeout: 2)
        job.cancel()
        XCTAssertFalse(workers.submit {})
        let state = DispatchQueue(label: "test.apk-state")
        XCTAssertEqual(state.sync { 7 }, 7)  // File work never occupies the state queue.
        gate.signal()
        await fulfillment(of: [finished], timeout: 2)
    }
    func testRevocationCancellationAndKeyRotationCannotCommitOldPreparation() throws {
        var reservations = APKStageReservations()
        let key = Data(repeating: 1, count: 32)
        let old = try XCTUnwrap(reservations.begin(device: "one", key: key, name: "one.apk", digest: "digest"))
        XCTAssertNil(reservations.begin(device: "one", key: key, name: "other.apk", digest: nil))
        XCTAssertEqual(reservations.status("one")?.phase, .preparing)
        reservations.cancel("one")
        let new = try XCTUnwrap(reservations.begin(device: "one", key: key, name: "new.apk", digest: nil))
        XCTAssertFalse(reservations.claim(device: "one", reservation: old, currentKey: key))
        XCTAssertEqual(reservations.reservation("one")?.id, new.id)
        XCTAssertFalse(reservations.claim(device: "one", reservation: new, currentKey: Data(repeating: 2, count: 32)))
        let revoked = try XCTUnwrap(reservations.begin(device: "one", key: key, name: "one.apk", digest: nil))
        XCTAssertFalse(reservations.claim(device: "one", reservation: revoked, currentKey: nil))
        XCTAssertNil(reservations.status("one"))
    }
    func testCancelledPreparationProducesNoSnapshotAndSuccessfulSnapshotIsPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.apk")
        try Data(repeating: 42, count: 4096).write(to: source)
        let job = APKPreparationJob()
        job.cancel()
        let snapshots = root.appendingPathComponent("snapshots")
        XCTAssertThrowsError(try PreparedAPK.prepare(source, root: snapshots, job: job))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshots.path))
        let prepared = try PreparedAPK.prepare(source, root: snapshots, job: APKPreparationJob())
        XCTAssertEqual(prepared.size, 4096)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: prepared.file.path)[.posixPermissions] as? NSNumber)?
                .intValue, 0o600)
        prepared.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.file.path))
    }
}
