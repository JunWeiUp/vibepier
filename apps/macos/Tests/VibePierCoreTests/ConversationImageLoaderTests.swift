import Foundation
import XCTest

@testable import VibePierCore

final class ConversationImageLoaderTests: XCTestCase {
    private let request = ConversationImageRequest(
        thread: "thread", id: "image", source: "synthetic", cwd: "/", maxPixel: 480)

    func testBlockedReadTimesOutOnceAndRetainsWorkerCapacity() {
        let entered = expectation(description: "worker entered")
        let returned = expectation(description: "worker returned")
        let release = DispatchSemaphore(value: 0)
        let loader = ConversationImageLoader(limit: 1, timeout: 0.05) { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            returned.fulfill()
            return Data([1, 2, 3])
        }
        let expired = expectation(description: "one timeout response")
        expired.assertForOverFulfill = true
        loader.perform(request, provider: "codex") { data in
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(value?["ok"] as? Bool, false)
            XCTAssertEqual(value?["threadId"] as? String, "thread")
            XCTAssertNil(value?["image"])
            expired.fulfill()
        }
        wait(for: [entered, expired], timeout: 1)
        let full = expectation(description: "blocked capacity remains charged")
        loader.perform(request, provider: "claude") { data in
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(value?["ok"] as? Bool, false)
            full.fulfill()
        }
        wait(for: [full], timeout: 1)
        release.signal()
        wait(for: [returned], timeout: 1)
        let drained = expectation(description: "late completion has drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testSlowImageDoesNotBlockAnotherPreviewAndPreservesIdentity() {
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "slow image")
        let loader = ConversationImageLoader(limit: 2, timeout: 2) { request in
            if request.id == "slow" {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
            return Data([7])
        }
        let slowDone = expectation(description: "slow result")
        loader.perform(.init(thread: "old", id: "slow", source: "", cwd: "/", maxPixel: 480), provider: "codex") { _ in
            slowDone.fulfill()
        }
        wait(for: [entered], timeout: 1)
        let fastDone = expectation(description: "independent result")
        loader.perform(request, provider: "zcode") { data in
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(value?["ok"] as? Bool, true)
            XCTAssertEqual(value?["imageId"] as? String, "image")
            XCTAssertEqual(value?["threadId"] as? String, "thread")
            XCTAssertEqual(value?["provider"] as? String, "zcode")
            fastDone.fulfill()
        }
        wait(for: [fastDone], timeout: 1)
        release.signal()
        wait(for: [slowDone], timeout: 1)
    }
}
