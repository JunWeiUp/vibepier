import Foundation
import XCTest

@testable import VibePierCore

final class ApplicationUsageTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_006_400)

    func testDisabledAndUnknownForegroundNeverInventTime() {
        var ledger = ApplicationUsageLedger()
        ledger.record(
            start: origin, now: origin.addingTimeInterval(60), elapsed: 60, appID: "a", name: "A", rest: false)
        XCTAssertTrue(ledger.segments.isEmpty)
        ledger.enabled = true
        ledger.record(start: origin, now: origin.addingTimeInterval(60), elapsed: 60, appID: "", name: "", rest: false)
        XCTAssertTrue(ledger.segments.isEmpty)
    }

    func testSwitchRestRestartAndMidnightAreDisjoint() {
        var ledger = ApplicationUsageLedger(enabled: true)
        let midnight = origin.addingTimeInterval(86400)
        ledger.record(
            start: midnight.addingTimeInterval(-30), now: midnight.addingTimeInterval(30), elapsed: 60, appID: "a",
            name: "A", rest: false)
        ledger.record(
            start: midnight.addingTimeInterval(30), now: midnight.addingTimeInterval(90), elapsed: 60, appID: "b",
            name: "B", rest: false)
        ledger.record(
            start: midnight.addingTimeInterval(90), now: midnight.addingTimeInterval(150), elapsed: 60, appID: "",
            name: "", rest: true)
        // A service restart begins a new observation; its 60s gap is never backfilled.
        ledger.record(
            start: midnight.addingTimeInterval(210), now: midnight.addingTimeInterval(240), elapsed: 30, appID: "b",
            name: "B", rest: false)
        let yesterday = ledger.totals(day: DateInterval(start: origin, duration: 86400), cutoff: midnight)
        let today = ledger.totals(
            day: DateInterval(start: midnight, duration: 86400), cutoff: midnight.addingTimeInterval(240))
        XCTAssertEqual(yesterday.apps["a"]?.seconds, 30)
        XCTAssertEqual(today.apps["a"]?.seconds, 30)
        XCTAssertEqual(today.apps["b"]?.seconds, 90)
        XCTAssertEqual(today.rest, 60)
        XCTAssertEqual(240 - today.rest - today.apps.values.reduce(0) { $0 + $1.seconds }, 60)
        XCTAssertEqual(ledger.segments.count, 4)
    }

    func testForwardClockCorrectionUsesElapsedTimeAndBackwardNeverDuplicates() {
        var ledger = ApplicationUsageLedger(enabled: true)
        ledger.record(
            start: origin, now: origin.addingTimeInterval(3600), elapsed: 60, appID: "a", name: "A", rest: false)
        XCTAssertEqual(ledger.segments[0].end.timeIntervalSince(origin), 60)
        ledger.record(
            start: origin.addingTimeInterval(20), now: origin.addingTimeInterval(50), elapsed: 60, appID: "a",
            name: "A", rest: false)
        XCTAssertEqual(ledger.segments.count, 1)
        ledger.record(
            start: origin.addingTimeInterval(50), now: origin.addingTimeInterval(90), elapsed: 40, appID: "a",
            name: "A", rest: false)
        XCTAssertEqual(ledger.segments[0].end.timeIntervalSince(origin), 90)
    }

    func testTimelineKeepsActualPositionsRestAndEveryVisitBeyond500() {
        var ledger = ApplicationUsageLedger(enabled: true)
        let day = DateInterval(start: origin, duration: 86400)
        ledger.record(
            start: origin.addingTimeInterval(-30), now: origin.addingTimeInterval(30), elapsed: 60, appID: "a",
            name: "A", rest: false)
        ledger.record(
            start: origin.addingTimeInterval(30), now: origin.addingTimeInterval(60), elapsed: 30, appID: "", name: "",
            rest: true)
        for index in 0..<600 {
            let start = origin.addingTimeInterval(Double(120 + index * 60))
            ledger.record(
                start: start, now: start.addingTimeInterval(60), elapsed: 60, appID: index % 2 == 0 ? "a" : "b",
                name: "App", rest: false)
        }
        let timeline = ledger.timeline(day: day, cutoff: origin.addingTimeInterval(36090))
        XCTAssertEqual(timeline.count, 602)
        XCTAssertEqual(timeline.first?.start, origin)
        XCTAssertEqual(timeline.first?.end, origin.addingTimeInterval(30))
        XCTAssertTrue(timeline[1].rest)
        XCTAssertEqual(timeline[2].start, origin.addingTimeInterval(120))
        XCTAssertEqual(timeline.last?.end, origin.addingTimeInterval(36090))
        XCTAssertEqual(timeline.filter { !$0.rest }.count, 601)
    }

    func testPauseAndPersistenceKeepColorAndTotalsStable() throws {
        var ledger = ApplicationUsageLedger(enabled: true)
        ledger.record(
            start: origin, now: origin.addingTimeInterval(30), elapsed: 30, appID: "org.editor", name: "Editor",
            rest: false)
        ledger.enabled = false
        ledger.record(
            start: origin.addingTimeInterval(30), now: origin.addingTimeInterval(300), elapsed: 270,
            appID: "org.editor", name: "Editor", rest: false)
        var restored = try JSONDecoder().decode(ApplicationUsageLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(restored.segments, ledger.segments)
        XCTAssertEqual(restored.color(for: "org.editor"), ledger.color(for: "org.editor"))
        let totals = restored.totals(
            day: DateInterval(start: origin, duration: 86400), cutoff: origin.addingTimeInterval(300))
        XCTAssertEqual(totals.apps["org.editor"]?.seconds, 30)
    }

    func testApplicationColorsRemainDistinctAndStableAfterRestore() throws {
        var ledger = ApplicationUsageLedger(enabled: true)
        let colors = (0..<32).map { ledger.color(for: "org.application.\($0)") }
        XCTAssertEqual(Set(colors).count, 32)
        var restored = try JSONDecoder().decode(ApplicationUsageLedger.self, from: JSONEncoder().encode(ledger))
        for index in 0..<32 { XCTAssertEqual(restored.color(for: "org.application.\(index)"), colors[index]) }
    }
    func testLateEnableRetryCannotOverrideNewerPauseEvenAfterRestore() throws {
        var ledger = ApplicationUsageLedger()
        XCTAssertTrue(ledger.setEnabled(true, sequence: 100, device: "phone"))
        XCTAssertTrue(ledger.setEnabled(false, sequence: 101, device: "phone"))
        var restored = try JSONDecoder().decode(ApplicationUsageLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertFalse(restored.setEnabled(true, sequence: 100, device: "phone"))
        XCTAssertFalse(restored.enabled)
        XCTAssertFalse(restored.setEnabled(true, sequence: 101, device: "phone"))
        XCTAssertTrue(restored.setEnabled(true, sequence: 102, device: "phone"))
        XCTAssertTrue(restored.enabled)
    }

    @MainActor func testTransientStorageFailureCanPauseAndRecover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent = root.appendingPathComponent("records")
        let file = parent.appendingPathComponent("usage.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = ApplicationUsage(file: file)
        defer { usage.stop() }
        let enabled = try usage.reply(
            ["op": "appUsageSet", "enabled": true, "mutationSequence": 1.0], device: "test-phone")
        XCTAssertEqual(enabled["enabled"] as? Bool, true)
        // Make subsequent atomic writes fail, without changing the test instance's in-memory state.
        try FileManager.default.removeItem(at: parent)
        try Data("obstruction".utf8).write(to: parent)
        XCTAssertThrowsError(
            try usage.reply(["op": "appUsageSet", "enabled": false, "mutationSequence": 2.0], device: "test-phone"))
        try FileManager.default.removeItem(at: parent)
        let recovered = try usage.reply(["op": "appUsage"])
        XCTAssertEqual(recovered["enabled"] as? Bool, false)
        let restored = try JSONDecoder().decode(ApplicationUsageLedger.self, from: Data(contentsOf: file))
        XCTAssertFalse(restored.enabled)
    }

    @MainActor func testCorruptFileIsNeverReplacedByPauseRequest() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("broken usage data".utf8)
        try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let usage = ApplicationUsage(file: file)
        defer { usage.stop() }
        XCTAssertThrowsError(
            try usage.reply(["op": "appUsageSet", "enabled": false, "mutationSequence": 1.0], device: "test-phone"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
