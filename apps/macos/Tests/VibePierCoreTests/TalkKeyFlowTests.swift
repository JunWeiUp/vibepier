import XCTest

@testable import VibePierCore

private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ value: String) { lock.withLock { items.append(value) } }
    var values: [String] { lock.withLock { items } }
}
final class TalkKeyFlowTests: XCTestCase {
    func testHeartbeatBracketsCompletedVoiceActions() async {
        let flow = TalkKeyFlow()
        let trace = Trace()
        let run: TalkKeyFlow.Run = { pressed, shouldRun in
            guard shouldRun() else { return false }
            trace.add(pressed ? "press" : "release")
            return true
        }
        flow.handle(
            pressed: true, prepare: { trace.add("heartbeat-on") }, run: run,
            finish: { trace.add("heartbeat-off") }, log: { _ in })
        await flow.waitUntilIdle()
        flow.handle(
            pressed: false, prepare: {}, run: run,
            finish: { trace.add("heartbeat-off") }, log: { _ in })
        await flow.waitUntilIdle()
        XCTAssertEqual(trace.values, ["heartbeat-on", "press", "release", "heartbeat-off"])
    }
    func testReleaseDuringWakeDoesNotStartLateDictation() async {
        let flow = TalkKeyFlow()
        let trace = Trace()
        let preparing = expectation(description: "waking")
        let run: TalkKeyFlow.Run = { pressed, shouldRun in
            guard shouldRun() else { return false }
            trace.add(pressed ? "press" : "release")
            return true
        }
        flow.handle(
            pressed: true,
            prepare: {
                trace.add("heartbeat-on")
                preparing.fulfill()
                try await Task.sleep(nanoseconds: 100_000_000)
            }, run: run, finish: { trace.add("heartbeat-off") }, log: { _ in })
        await fulfillment(of: [preparing], timeout: 1)
        flow.handle(
            pressed: false, prepare: {}, run: run,
            finish: { trace.add("heartbeat-off") }, log: { _ in })
        await flow.waitUntilIdle()
        XCTAssertFalse(trace.values.contains("press"))
        XCTAssertEqual(trace.values.last, "heartbeat-off")
    }
    func testFailedWakeTurnsHeartbeatBackOff() async {
        let flow = TalkKeyFlow()
        let trace = Trace()
        flow.handle(
            pressed: true, prepare: { throw NSError(domain: "test", code: 1) },
            run: { _, _ in
                trace.add("press")
                return true
            },
            finish: { trace.add("heartbeat-off") }, log: { _ in })
        await flow.waitUntilIdle()
        XCTAssertEqual(trace.values, ["heartbeat-off"])
    }
}
