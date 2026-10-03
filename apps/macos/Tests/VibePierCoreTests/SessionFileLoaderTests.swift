import Foundation
import XCTest

@testable import VibePierCore

final class SessionFileLoaderTests: XCTestCase {
    func testBlockedFileTimesOutWithoutBlockingProviderQueueOrReleasingLiveWorker() throws {
        let loader = SessionFileLoader(limit: 1, timeout: 0.05)
        let queue = DispatchQueue(label: "fixture.provider")
        let entered = expectation(description: "file read entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let timedOut = expectation(description: "one file timeout")
        timedOut.assertForOverFulfill = true
        let returned = expectation(description: "worker actually returned")
        let file = SessionFileRequest(thread: "original-session") {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            returned.fulfill()
            return ["entries": []]
        }
        queue.async {
            loader.perform(file, provider: "codex") { bytes in
                let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                XCTAssertEqual(value?["ok"] as? Bool, false)
                XCTAssertEqual(value?["provider"] as? String, "codex")
                XCTAssertEqual(value?["threadId"] as? String, "original-session")
                timedOut.fulfill()
            }
        }
        wait(for: [entered], timeout: 1)
        let next = expectation(description: "provider remains responsive")
        queue.async { next.fulfill() }
        wait(for: [next, timedOut], timeout: 1)
        let full = expectation(description: "a timeout does not free a blocked worker")
        loader.perform(
            SessionFileRequest(thread: "other") {
                XCTFail("must not admit another blocked file read")
                return [:]
            }, provider: "claude"
        ) { bytes in
            let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            XCTAssertEqual(value?["ok"] as? Bool, false)
            full.fulfill()
        }
        wait(for: [full], timeout: 1)
        release.signal()
        wait(for: [returned], timeout: 1)
        let drained = expectation(description: "late result cannot produce a second callback")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        let recovered = expectation(description: "capacity returns after real completion")
        loader.perform(SessionFileRequest(thread: "new") { ["entries": []] }, provider: "claude") { bytes in
            let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            XCTAssertEqual(value?["ok"] as? Bool, true)
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 1)
    }

    func testIndependentFileRequestCanFinishWhileAnotherIsBlocked() {
        let loader = SessionFileLoader(limit: 2, timeout: 1)
        let entered = expectation(description: "blocked")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let slow = expectation(description: "slow file completed")
        loader.perform(
            SessionFileRequest(thread: "slow") {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return [:]
            }, provider: "codex"
        ) { _ in slow.fulfill() }
        wait(for: [entered], timeout: 1)
        let fast = expectation(description: "other provider file completed")
        loader.perform(SessionFileRequest(thread: "fast") { ["text": "fixture"] }, provider: "claude") { bytes in
            let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            XCTAssertEqual(value?["text"] as? String, "fixture")
            XCTAssertEqual(value?["threadId"] as? String, "fast")
            XCTAssertEqual(value?["provider"] as? String, "claude")
            fast.fulfill()
        }
        wait(for: [fast], timeout: 1)
        release.signal()
        wait(for: [slow], timeout: 1)
    }
}
