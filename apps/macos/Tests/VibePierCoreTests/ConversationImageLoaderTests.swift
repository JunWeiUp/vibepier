import Foundation
import XCTest

@testable import VibePierCore

final class ConversationImageLoaderTests: XCTestCase {
    private static let offer: BinaryMediaFiles.Offer = { snapshot, device, thread, mime in
        defer { snapshot.discard() }
        XCTAssertEqual(device, "phone")
        XCTAssertFalse(thread.isEmpty)
        XCTAssertEqual(mime, "image/jpeg")
        let bytes = try Data(contentsOf: snapshot.file)
        XCTAssertTrue(bytes == Data([7]) || bytes == Data([1, 2, 3]))
        return ["id": UUID().uuidString, "size": bytes.count, "sha256": snapshot.digest, "mime": mime]
    }

    private let request = ConversationImageRequest(
        thread: "thread", id: "image", source: "synthetic", cwd: "/", maxPixel: 480, device: "phone")

    func testBlockedReadTimesOutOnceAndRetainsWorkerCapacity() {
        let entered = expectation(description: "worker entered")
        let returned = expectation(description: "worker returned")
        let release = DispatchSemaphore(value: 0)
        let loader = ConversationImageLoader(limit: 1, timeout: 0.05, queueLimit: 0, offer: Self.offer) { _ in
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

    func testLargeImageQueuesAheadOfThumbnailsWithoutExceedingWorkerLimit() {
        final class Order: @unchecked Sendable {
            let lock = NSLock()
            var ids: [String] = []
        }
        let order = Order()
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "occupied worker")
        let done = expectation(description: "all queued images")
        done.expectedFulfillmentCount = 3
        let loader = ConversationImageLoader(limit: 1, timeout: 2, queueLimit: 2, offer: Self.offer) { request in
            order.lock.withLock { order.ids.append(request.id) }
            if request.id == "first" {
                started.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
            return Data([7])
        }
        func submit(_ id: String, size: Int) {
            loader.perform(
                .init(thread: "thread", id: id, source: "synthetic", cwd: "/", maxPixel: size, device: "phone"),
                provider: "codex"
            ) { bytes in
                let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                XCTAssertEqual(value?["ok"] as? Bool, true)
                XCTAssertNil(value?["image"])
                XCTAssertNotNil(value?["binary"] as? [String: Any])
                done.fulfill()
            }
        }
        submit("first", size: 480)
        wait(for: [started], timeout: 1)
        submit("thumb", size: 480)
        submit("large", size: 1280)
        let rejected = expectation(description: "bounded queue")
        loader.perform(request, provider: "codex") { bytes in
            let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            XCTAssertEqual(value?["ok"] as? Bool, false)
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 1)
        release.signal()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(order.lock.withLock { order.ids }, ["first", "large", "thumb"])
    }

    func testSlowImageDoesNotBlockAnotherPreviewAndPreservesIdentity() {
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "slow image")
        let loader = ConversationImageLoader(limit: 2, timeout: 2, offer: Self.offer) { request in
            if request.id == "slow" {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
            return Data([7])
        }
        let slowDone = expectation(description: "slow result")
        loader.perform(
            .init(thread: "old", id: "slow", source: "", cwd: "/", maxPixel: 480, device: "phone"), provider: "codex"
        ) { _ in
            slowDone.fulfill()
        }
        wait(for: [entered], timeout: 1)
        let fastDone = expectation(description: "independent result")
        loader.perform(request, provider: "claude") { data in
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(value?["ok"] as? Bool, true)
            XCTAssertNil(value?["image"])
            XCTAssertNotNil(value?["binary"] as? [String: Any])
            XCTAssertEqual(value?["imageId"] as? String, "image")
            XCTAssertEqual(value?["threadId"] as? String, "thread")
            XCTAssertEqual(value?["provider"] as? String, "claude")
            fastDone.fulfill()
        }
        wait(for: [fastDone], timeout: 1)
        release.signal()
        wait(for: [slowDone], timeout: 1)
    }
}
