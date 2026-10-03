import XCTest

@testable import VibePierCore

final class CodexFollowUpsTests: XCTestCase {
    func testReadsDesktopQueueAndRefreshesAfterAtomicReplacement() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = CodexFollowUps(file: file)
        let message = CodexFollowUps.message(id: "original", text: "补充要求", cwd: "/project", files: [], images: [])
        try JSONSerialization.data(withJSONObject: ["queued-follow-ups": ["thread": [message]]]).write(
            to: file, options: .atomic)
        XCTAssertEqual(try cache.messages("thread").first?["id"] as? String, "original")
        XCTAssertEqual(try cache.messages("other").count, 0)
        try JSONSerialization.data(withJSONObject: ["queued-follow-ups": [:]]).write(to: file, options: .atomic)
        XCTAssertTrue(try cache.messages("thread").isEmpty)
        try Data("invalid".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try cache.messages("thread"), "Never replace an unreadable queue with an empty one")
    }
    func testSteerUsesOriginalMessageAndNativeCoordinatorWithoutDroppingAttachments() throws {
        var message = CodexFollowUps.message(
            id: "original", text: "补充要求", cwd: "/project", files: [["fsPath": "/project/a.txt", "label": "a.txt"]],
            images: [["fsPath": "/project/image.png", "label": "image.png"]])
        message["pausedReason"] = "interrupted"
        let steer = try CodexFollowUps.steer(message)
        XCTAssertEqual(steer["id"] as? String, "original")
        XCTAssertTrue(
            NSDictionary(dictionary: steer["context"] as! [String: Any]).isEqual(
                NSDictionary(dictionary: message["context"] as! [String: Any])))
        XCTAssertNil(steer["pausedReason"])
        let submission = try XCTUnwrap(steer["submission"] as? [String: Any])
        XCTAssertEqual(submission["hostId"] as? String, "local")
        XCTAssertEqual(submission["status"] as? String, "pending")
        XCTAssertEqual(submission["queueModeOverride"] as? String, "send-now")
        for status in ["pending", "sending", "outcome-unknown"] {
            message["submission"] = ["status": status]
            XCTAssertThrowsError(
                try CodexFollowUps.steer(message), "Do not submit uncertain or in-flight messages twice")
        }
        let view = CodexFollowUps.project([steer]).first!
        XCTAssertEqual(view["attachments"] as? [String], ["a.txt", "image.png"])
        XCTAssertEqual(view["canSteer"] as? Bool, false)
        XCTAssertEqual(view["canDelete"] as? Bool, false)
    }
    /// A paused message is reversible fixture data: this probe never asks the model to run it.
    func testRealDesktopPausedQueueRoundTripWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["VIBEPIER_CODEX_QUEUE_PROBE"] == "1",
            let thread = ProcessInfo.processInfo.environment["VIBEPIER_CODEX_READ_THREAD"]
        else { throw XCTSkip("Desktop queue round trip is opt-in") }
        let ipc = CodexIPC()
        try ipc.connect()
        defer { ipc.close() }
        let reply = try ipc.request(
            "thread-owner-discovery", ["hostId": "local", "conversationId": thread], version: 1)
        let owner = try XCTUnwrap(reply["handledByClientId"] as? String)
        let queue = CodexFollowUps()
        let original = try queue.messages(thread)
        let id = UUID().uuidString
        var message = CodexFollowUps.message(
            id: id, text: "VibePier queue integration fixture", cwd: "/tmp", files: [], images: [])
        message["pausedReason"] = "Integration fixture — do not send"
        defer {
            _ = try? ipc.request(
                "thread-follower-remove-queued-message", ["conversationId": thread, "messageId": id], version: 1,
                target: owner)
        }
        let result = try ipc.request(
            "thread-follower-set-queued-follow-ups-state",
            ["conversationId": thread, "state": [thread: original + [message]]], version: 1, target: owner)
        XCTAssertEqual((result["result"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertTrue(try queue.messages(thread).contains { $0["id"] as? String == id })
        _ = try ipc.request(
            "thread-follower-remove-queued-message", ["conversationId": thread, "messageId": id], version: 1,
            target: owner)
        let remaining = try queue.messages(thread)
        XCTAssertFalse(remaining.contains { $0["id"] as? String == id })
        for old in original { XCTAssertTrue(remaining.contains { $0["id"] as? String == old["id"] as? String }) }
    }
}
