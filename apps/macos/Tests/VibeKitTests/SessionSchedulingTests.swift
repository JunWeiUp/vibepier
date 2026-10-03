import XCTest

@testable import VibeKit

private final class TestTransport: SessionTransport, @unchecked Sendable {
    var onConnect: (@Sendable (HIDDeviceDescription) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?
    var onReport: (@Sendable ([UInt8]) -> Void)?
    private let lock = NSLock()
    private var sent: [Frame] = []
    private var versionReplyAt: Int?
    var versionReplyAfter: Int? {
        get { lock.withLock { versionReplyAt } }
        set { lock.withLock { versionReplyAt = newValue } }
    }
    var connectOnStart = true
    var echoHeartbeat = false

    var frames: [Frame] { lock.withLock { sent } }

    func start() {
        guard connectOnStart else { return }
        onConnect?(
            HIDDeviceDescription(
                vendorID: 0, productID: 0, product: "test", manufacturer: "test",
                serialNumber: "test", locationID: 0, maxInputReportSize: 64, maxOutputReportSize: 64))
    }
    func stop() {}
    func send(report: [UInt8]) throws {
        let frame = Frame(FrameCodec.decodeInputReport(report))
        let versionReply = lock.withLock {
            sent.append(frame)
            return frame.group == 2 && frame.command == 3
                && versionReplyAt == sent.filter { $0.group == 2 && $0.command == 3 }.count
        }
        if versionReply { receive([6, 2, 3, 0x11]) }
        if echoHeartbeat && frame.group == 1 && frame.command == 0x23 { receive([6, 1, 0x23, 0, 1]) }
        if frame.group == 2 && frame.command == 5 {
            let code = frame.u32(5) ^ authPrivateKeys[0]
            receive([6, 2, 5, 0x11, 0] + (0..<4).map { UInt8(truncatingIfNeeded: code >> ($0 * 8)) })
        }
    }
    func receive(_ bytes: [UInt8]) {
        onReport?(FrameCodec.outputReport(for: bytes))
    }
}

final class SessionSchedulingTests: XCTestCase {
    func testVoiceWakeSendsImmediatelyAndWaitsForEcho() async throws {
        let transport = TestTransport()
        transport.echoHeartbeat = true
        let session = VibeSession(transport: transport)
        session.setHeartbeatEnabled(false)
        session.start()
        defer { session.stop() }
        try await session.waitUntilReady()
        session.configureHeartbeat(interval: 1)
        try await session.wakeHeartbeat(timeout: 0.1)
        XCTAssertTrue(transport.frames.contains { $0.command == 0x23 })
        session.configureHeartbeat(interval: nil)
        let before = session.timerWakeupCount
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(session.timerWakeupCount, before)
    }

    func testMissingWakeEchoTimesOut() async throws {
        let session = VibeSession(transport: TestTransport())
        session.start()
        defer { session.stop() }
        try await session.waitUntilReady()
        do {
            try await session.wakeHeartbeat(timeout: 0.03)
            XCTFail("missing echo must not be treated as readiness")
        } catch {}
    }

    func testNoTimerPollingWithoutDongle() async throws {
        let transport = TestTransport()
        transport.connectOnStart = false
        let session = VibeSession(transport: transport)
        session.start()
        defer { session.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.timerWakeupCount, 0)
        XCTAssertTrue(transport.frames.isEmpty)
    }

    func testIdleOnlyWakesForHeartbeatAndPausesWithoutPolling() async throws {
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(condition(), "Expected heartbeat progress before the scheduling deadline")
        }
        let transport = TestTransport()
        let session = VibeSession(transport: transport)
        session.heartbeatInterval = 0.05
        session.start()
        defer { session.stop() }
        try await session.waitUntilReady()
        try await waitUntil { transport.frames.filter { $0.command == 0x23 }.count >= 3 }
        let beats = transport.frames.filter { $0.command == 0x23 }.count
        XCTAssertGreaterThanOrEqual(beats, 3)
        XCTAssertLessThanOrEqual(session.timerWakeupCount, beats + 1)
        session.setHeartbeatEnabled(false)
        let paused = session.timerWakeupCount  // queue barrier
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.timerWakeupCount, paused)
        session.setHeartbeatEnabled(true)
        try await waitUntil { session.timerWakeupCount > paused }
        XCTAssertGreaterThan(session.timerWakeupCount, paused)
        transport.onDisconnect?()
        let disconnected = session.timerWakeupCount
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.timerWakeupCount, disconnected)
    }

    func testRequestsRetryAndTimeOutWhileHeartbeatPaused() async throws {
        let transport = TestTransport()
        transport.versionReplyAfter = 2
        let session = VibeSession(transport: transport)
        session.retryInterval = 0.025
        session.setHeartbeatEnabled(false)
        session.start()
        defer { session.stop() }
        try await session.waitUntilReady()
        // Observe an actual retry before the fixture replies. A short wall-clock timeout
        // cannot require a minimum number of timer deliveries on a loaded hosted runner.
        let reply = try await session.send(DongleRequest.version, timeout: 2)
        XCTAssertEqual(reply.command, 3)
        XCTAssertEqual(transport.frames.filter { $0.command == 3 }.count, 2)
        transport.versionReplyAfter = nil
        do {
            _ = try await session.send(DongleRequest.version, timeout: 0.05)
            XCTFail("expected timeout")
        } catch let error as SessionError {
            guard case .timeout = error else { return XCTFail("unexpected error: \(error)") }
        }
        let timedOutRequests = transport.frames.filter { $0.command == 3 }.count - 2
        XCTAssertGreaterThanOrEqual(timedOutRequests, 1)
        XCTAssertLessThanOrEqual(timedOutRequests, 2)
        let settled = session.timerWakeupCount
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(session.timerWakeupCount, settled)
    }

    func testNoResendStillExpiresAndReplyStopsRetryTimer() async throws {
        let transport = TestTransport()
        let session = VibeSession(transport: transport)
        session.setHeartbeatEnabled(false)
        session.start()
        defer { session.stop() }
        try await session.waitUntilReady()
        do {
            _ = try await session.send(DongleRequest.version, timeout: 0.05, resend: false)
            XCTFail("expected timeout")
        } catch {}
        XCTAssertEqual(transport.frames.filter { $0.command == 3 }.count, 1)
        let reply = Task { try await session.send(DongleRequest.version, timeout: 0.5) }
        try await Task.sleep(nanoseconds: 20_000_000)
        transport.receive([6, 2, 3, 0x11])
        let frame = try await reply.value
        XCTAssertEqual(frame.command, 3)
        let settled = session.timerWakeupCount
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(session.timerWakeupCount, settled)
    }

    func testIncomingKeysDoNotWaitForATimer() async throws {
        let transport = TestTransport()
        let session = VibeSession(transport: transport)
        session.setHeartbeatEnabled(false)
        let keyEvent = expectation(description: "key received with timer disabled")
        session.addListener { event in
            if case .message(.keyEvent, _) = event { keyEvent.fulfill() }
        }
        session.start()
        defer { session.stop() }
        try await session.waitUntilReady()
        transport.receive([MessageType.notice.rawValue, 0x10, 1, 1, 1])
        await fulfillment(of: [keyEvent], timeout: 0.5)
        XCTAssertEqual(session.timerWakeupCount, 0)
    }
}
