import VibePierCore
import XCTest

@testable import VibePierApp

@MainActor
final class TaskActivityTests: XCTestCase {
    private func session(_ id: String, provider: String = "codex", running: Bool = false, unread: Bool = true)
        -> TaskActivityJSON.Session
    {
        .init(id: id, provider: provider, title: "任务 \(id)", isRunning: running, isUnread: unread)
    }
    private func status(_ activity: TaskActivityJSON) -> String {
        let entries = activity.sessions.map { session in
            [
                "id": session.id, "provider": session.provider, "title": session.title, "isRunning": session.isRunning,
                "isUnread": session.isUnread,
            ] as [String: Any]
        }
        let snapshot: [String: Any] = [
            "runningCount": activity.runningCount, "unreadCount": activity.unreadCount, "sessions": entries,
        ]
        let value: [String: Any] = ["ok": true, "dongleConnected": false, "micLinked": false, "taskActivity": snapshot]
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }

    func testActivityOrderingSeparatesProviderIdentitiesAndSkipsViewedCompletedSessions() {
        let unread = session("same", provider: "claude")
        let running = session("same", running: true, unread: false)
        let viewed = session("viewed", provider: "zcode", unread: false)
        let activity = TaskActivityJSON(runningCount: 1, unreadCount: 1, sessions: [unread, viewed, running])
        XCTAssertEqual(activity.orderedSessions.map(\.key), [running.key, unread.key])
        XCTAssertNotEqual(running.key, unread.key)
        XCTAssertEqual(unread.providerLabel, "Claude")
        XCTAssertEqual(viewed.providerLabel, "ZCode")
        XCTAssertEqual(session("both", running: true).statusLabel, L10n.text("mac.running_with_an_unviewed_completion"))
        XCTAssertEqual(
            TaskActivityJSON.Session(id: "blank", provider: "codex", title: "  \n", isRunning: false, isUnread: true)
                .displayTitle, L10n.text("mac.untitled_session"))
    }

    func testIndicatorKeepsTemplateCanvasAndOneRunningRingWithEveryUnreadDot() {
        let empty = TaskIndicatorLayout(runningCount: 0, unreadCount: 0)
        XCTAssertEqual(empty.width, 18)
        XCTAssertEqual(empty.markerCount, 0)
        XCTAssertEqual(empty.rowCount, 0)
        XCTAssertEqual(empty.columnCount, 0)
        let onlyRunning = TaskIndicatorLayout(runningCount: 3, unreadCount: 0)
        XCTAssertEqual(onlyRunning.markerCount, 1)
        XCTAssertEqual(onlyRunning.width, 26)
        XCTAssertEqual(onlyRunning.markerSize(0), 5)
        XCTAssertEqual(onlyRunning.position(0).y, 9)
        XCTAssertEqual(onlyRunning.columnCount, 0)
        let small = TaskIndicatorLayout(runningCount: 3, unreadCount: 2)
        XCTAssertEqual(small.markerCount, 3)  // One ring represents any number of running tasks.
        XCTAssertEqual(small.rowCount, 2)
        XCTAssertEqual(small.columnCount, 1)
        XCTAssertTrue(small.isRunningMarker(0))
        XCTAssertFalse(small.isRunningMarker(1))
        XCTAssertEqual(small.markerSize(0), 5)
        XCTAssertEqual(small.markerSize(1), 3.5)
        let threshold = TaskIndicatorLayout(runningCount: 1, unreadCount: 24)
        XCTAssertFalse(threshold.isDense)
        XCTAssertEqual(threshold.rowCount, 3)
        XCTAssertEqual(threshold.columnCount, 8)
        XCTAssertEqual(threshold.markerSize(1), 3.5)
        let dense = TaskIndicatorLayout(runningCount: 1, unreadCount: 25)
        XCTAssertTrue(dense.isDense)
        XCTAssertEqual(dense.rowCount, 6)
        XCTAssertEqual(dense.columnCount, 5)
        XCTAssertEqual(dense.markerSize(0), 5)
        XCTAssertEqual(dense.markerSize(1), 2)
        let large = TaskIndicatorLayout(runningCount: 1, unreadCount: 257)
        XCTAssertEqual(large.markerCount, 258)
        XCTAssertEqual(large.rowCount, 6)
        XCTAssertEqual(large.columnCount, 43)
        XCTAssertEqual(large.width, 157)
        XCTAssertGreaterThan(large.width, small.width)
        let unreadOnly = TaskIndicatorLayout(runningCount: 0, unreadCount: 257)
        XCTAssertEqual(unreadOnly.markerCount, 257)
        XCTAssertEqual(unreadOnly.width, 149)
        XCTAssertEqual(unreadOnly.markerSize(0), 2)
        for layout in [empty, onlyRunning, small, threshold, dense, large, unreadOnly] {
            let bounds = (0..<layout.markerCount).map { index -> CGRect in
                let point = layout.position(index)
                let size = layout.markerSize(index)
                return CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            }
            XCTAssertEqual(Set(bounds.map { "\($0.midX):\($0.midY)" }).count, layout.markerCount)
            XCTAssertTrue(
                bounds.allSatisfy { $0.minX >= 18 && $0.maxX <= layout.width && $0.minY >= 0 && $0.maxY <= 18 })
            for index in bounds.indices {
                XCTAssertTrue(
                    bounds.dropFirst(index + 1).allSatisfy { !bounds[index].intersects($0) },
                    "Markers overlap for unread count \(layout.unreadCount)")
            }
        }
        let negative = TaskIndicatorLayout(runningCount: -1, unreadCount: -3)
        XCTAssertEqual(negative.markerCount, 0)
        XCTAssertEqual(negative.width, 18)
    }

    func testStatusUpdatesTaskStateAndMissingOrOfflineSnapshotsClearStaleIndicators() async {
        let activity = TaskActivityJSON(
            runningCount: 1, unreadCount: 2,
            sessions: [session("running", running: true, unread: false), session("a"), session("b")])
        var calls: [[String]] = []
        var response = AppCommands.Result(exitCode: 0, stdout: status(activity), stderr: "")
        let model = DeviceModel(runCommand: { args in
            calls.append(args)
            return response
        })
        await model.refreshStatus()
        XCTAssertEqual(model.taskActivity, activity)
        XCTAssertTrue(model.menuIconDescription.contains(L10n.text("mac.running_tasks_0", 1)))
        XCTAssertTrue(model.menuIconDescription.contains(L10n.text("mac.completed_tasks_not_yet_viewed_0", 2)))
        response = .init(exitCode: 0, stdout: "{\"ok\":true,\"dongleConnected\":false,\"micLinked\":false}", stderr: "")
        await model.refreshStatus()
        XCTAssertEqual(model.taskActivity, .empty)
        response = .init(exitCode: 0, stdout: status(activity), stderr: "")
        await model.refreshStatus()
        response = .init(exitCode: 1, stdout: "", stderr: "offline")
        await model.refreshStatus()
        XCTAssertEqual(model.taskActivity, .empty)
        XCTAssertFalse(model.daemonRunning)
        XCTAssertTrue(calls.allSatisfy { $0 == ["status"] })
    }

    func testOpeningUsesExactProviderAndIDAndOnlyAcknowledgesThatTask() async {
        let codex = session("same")
        let claude = session("same", provider: "claude")
        var activity = TaskActivityJSON(runningCount: 0, unreadCount: 2, sessions: [codex, claude])
        var calls: [[String]] = []
        let model = DeviceModel(runCommand: { args in
            calls.append(args)
            if args.first == "task-open" {
                XCTAssertEqual(args, ["task-open", "claude", "same"])
                activity = .init(
                    runningCount: 0, unreadCount: 1,
                    sessions: [codex, self.session("same", provider: "claude", unread: false)])
                return .init(exitCode: 0, stdout: "{\"ok\":true}", stderr: "")
            }
            return .init(exitCode: 0, stdout: self.status(activity), stderr: "")
        })
        await model.refreshStatus()
        calls = []
        await model.openTaskSession(claude)
        XCTAssertEqual(calls, [["task-open", "claude", "same"], ["status"]])
        XCTAssertEqual(model.taskActivity.unreadCount, 1)
        XCTAssertTrue(model.taskActivity.sessions.first { $0.key == codex.key }!.isUnread)
        XCTAssertFalse(model.taskActivity.sessions.first { $0.key == claude.key }!.isUnread)
        XCTAssertNil(model.openingTask)
        XCTAssertTrue(model.taskActivityError.isEmpty)
    }

    func testClearAllSendsEveryVisibleUnreadKeyAndSkipsRunningOnly() async {
        let running = session("busy", running: true, unread: false)
        var activity = TaskActivityJSON(
            runningCount: 1, unreadCount: 2, sessions: [running, session("a"), session("a", provider: "claude")])
        var calls: [[String]] = []
        let model = DeviceModel(runCommand: { args in
            calls.append(args)
            if args.first == "task-clear-unread" {
                activity = .init(runningCount: 1, unreadCount: 0, sessions: [running])
                return .init(exitCode: 0, stdout: "{\"ok\":true,\"cleared\":2}", stderr: "")
            }
            return .init(exitCode: 0, stdout: self.status(activity), stderr: "")
        })
        await model.refreshStatus()
        calls = []
        await model.clearUnreadTasks()
        XCTAssertEqual(calls, [["task-clear-unread", "codex:a", "claude:a"], ["status"]])
        XCTAssertEqual(model.taskActivity.unreadCount, 0)
        XCTAssertEqual(model.taskActivity.runningCount, 1)
        XCTAssertFalse(model.clearingUnread)
        calls = []
        await model.clearUnreadTasks()
        XCTAssertTrue(calls.isEmpty, "nothing to clear sends no command")
    }

    func testFailedClearKeepsDotsAndShowsAnError() async {
        let activity = TaskActivityJSON(runningCount: 0, unreadCount: 1, sessions: [session("a")])
        let model = DeviceModel(runCommand: { args in
            args.first == "status"
                ? .init(exitCode: 0, stdout: self.status(activity), stderr: "")
                : .init(exitCode: 1, stdout: "", stderr: "内置按键服务未启动")
        })
        await model.refreshStatus()
        await model.clearUnreadTasks()
        XCTAssertEqual(model.taskActivity, activity)
        XCTAssertEqual(model.taskActivityError, "内置按键服务未启动")
        XCTAssertFalse(model.clearingUnread)
    }

    func testFailedOpenRetainsUnreadMarksAndShowsAnError() async {
        let entry = session("closed", provider: "zcode")
        let activity = TaskActivityJSON(runningCount: 0, unreadCount: 1, sessions: [entry])
        var calls: [[String]] = []
        let model = DeviceModel(runCommand: { args in
            calls.append(args)
            return args.first == "status"
                ? .init(exitCode: 0, stdout: self.status(activity), stderr: "")
                : .init(exitCode: 1, stdout: "", stderr: "原生会话无法打开")
        })
        await model.refreshStatus()
        calls = []
        await model.openTaskSession(entry)
        XCTAssertEqual(calls, [["task-open", "zcode", "closed"]])
        XCTAssertEqual(model.taskActivity, activity)
        XCTAssertEqual(model.taskActivityError, "原生会话无法打开")
        XCTAssertNil(model.openingTask)
    }

    func testDriverNotificationUpdatesTasksWhilePanelMonitoringIsStopped() async {
        let received = expectation(description: "local status notification")
        let activity = TaskActivityJSON(
            runningCount: 1, unreadCount: 0, sessions: [session("background", running: true, unread: false)])
        let model = DeviceModel(runCommand: { args in
            XCTAssertEqual(args, ["status"])
            received.fulfill()
            return .init(exitCode: 0, stdout: self.status(activity), stderr: "")
        })
        model.stopMonitoring()
        NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: nil)
        await fulfillment(of: [received], timeout: 2)
        // Allow the notification task to publish its decoded snapshot after the CLI callback.
        await Task.yield()
        XCTAssertEqual(model.taskActivity, activity)
    }

    func testNotificationDuringAnAwaitedStatusReadIsCoalescedRatherThanDropped() async {
        let firstStarted = expectation(description: "first status read")
        var releaseFirst: CheckedContinuation<Void, Never>?
        var calls = 0
        let updated = TaskActivityJSON(runningCount: 0, unreadCount: 1, sessions: [session("finished")])
        let model = DeviceModel(runCommand: { args in
            XCTAssertEqual(args, ["status"])
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                    firstStarted.fulfill()
                }
                return .init(exitCode: 0, stdout: self.status(.empty), stderr: "")
            }
            return .init(exitCode: 0, stdout: self.status(updated), stderr: "")
        })
        let first = Task { await model.refreshStatus() }
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertTrue(model.refreshing)
        // Same delivery path as the permanent Driver observer; sets a pending local refresh.
        await model.refreshStatus()
        releaseFirst?.resume()
        await first.value
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.taskActivity, updated)
    }
}
