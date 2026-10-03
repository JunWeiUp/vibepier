import XCTest

@testable import VibePierCore

final class BluetoothNotificationQueueTests: XCTestCase {
    func testReplyOvertakesIconsOnlyAfterCurrentLineEnds() {
        let peer = UUID()
        var queue = BluetoothNotificationQueue()
        queue.append(Data("icon-one".utf8), peer: peer, size: 3)
        queue.append(Data("icon-two".utf8), peer: peer, size: 3)
        var wire = Data()
        wire.append(queue.first(allowPriority: true)!.data)
        queue.removeFirst()
        queue.append(Data("session-list".utf8), peer: peer, size: 3, urgent: true)
        while let frame = queue.first(allowPriority: true) {
            wire.append(frame.data)
            queue.removeFirst()
        }
        XCTAssertEqual(String(decoding: wire, as: UTF8.self), "icon-one\nsession-list\nicon-two\n")
    }
    func testBackpressureRetainsSameFrameAndAudioDefersUnstartedReply() {
        let peer = UUID()
        var queue = BluetoothNotificationQueue()
        queue.append(Data("list".utf8), peer: peer, size: 3, urgent: true)
        XCTAssertNil(queue.first(allowPriority: false))
        let first = queue.first(allowPriority: true)!
        XCTAssertEqual(queue.first(allowPriority: true)?.data, first.data, "failed notification write must not advance")
        queue.removeFirst()
        XCTAssertNotNil(queue.first(allowPriority: false), "an already-started line must finish even if audio starts")
        queue.removeFirst()
        XCTAssertTrue(queue.isEmpty)
        queue.append(Data("old peer".utf8), peer: peer, size: 3)
        _ = queue.first(allowPriority: true)
        queue.remove(peer)
        XCTAssertTrue(queue.betweenLines)
        XCTAssertTrue(queue.isEmpty)
    }
}
