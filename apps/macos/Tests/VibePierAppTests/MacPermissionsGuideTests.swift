import XCTest

@testable import VibePierApp
@testable import VibePierCore

final class MacPermissionsGuideTests: XCTestCase {
    @MainActor
    func testOnlyInstalledAppShowsFirstLaunchGuide() {
        XCTAssertTrue(
            MacPermissionsGuide.shouldShowOnLaunch(
                bundleURL: URL(fileURLWithPath: "/Applications/VibePier.app"), setupVersion: 0))
        XCTAssertFalse(
            MacPermissionsGuide.shouldShowOnLaunch(
                bundleURL: URL(fileURLWithPath: "/Applications/VibePier.app"), setupVersion: 1))
        for path in ["/tmp/VibePier.app", "/project/dist/VibePier.app", "/ApplicationsOther/VibePier.app"] {
            XCTAssertFalse(
                MacPermissionsGuide.shouldShowOnLaunch(bundleURL: URL(fileURLWithPath: path), setupVersion: 0))
        }
    }

    @MainActor
    func testActualFileDenialBypassesShownGuideAndPresentsOnlyOncePerProcess() {
        let installed = URL(fileURLWithPath: "/Applications/VibePier.app")
        let guide = MacPermissionsGuide(fileAccessMonitor: FileAccessMonitor(notifications: NotificationCenter()))
        var presentations = 0
        XCTAssertFalse(MacPermissionsGuide.shouldShowOnLaunch(bundleURL: installed, setupVersion: 1))
        XCTAssertTrue(guide.handleFileAccessDenied(bundleURL: installed) { presentations += 1 })
        XCTAssertTrue(guide.fileAccessDenied)
        XCTAssertFalse(guide.handleFileAccessDenied(bundleURL: installed) { presentations += 1 })
        XCTAssertEqual(presentations, 1)
        let nextLaunch = MacPermissionsGuide(fileAccessMonitor: FileAccessMonitor(notifications: NotificationCenter()))
        XCTAssertTrue(nextLaunch.handleFileAccessDenied(bundleURL: installed) { presentations += 1 })
        XCTAssertEqual(presentations, 2)
    }

    @MainActor
    func testSourceBuildDenialDoesNotOpenInstalledAppGuide() {
        let guide = MacPermissionsGuide(fileAccessMonitor: FileAccessMonitor(notifications: NotificationCenter()))
        XCTAssertFalse(
            guide.handleFileAccessDenied(bundleURL: URL(fileURLWithPath: "/tmp/VibePier.app")) {
                XCTFail("source-build tests must not open windows or System Settings")
            })
        XCTAssertFalse(guide.fileAccessDenied)
    }

    @MainActor
    func testLocalDenialNotificationReachesMockPresentationAfterEarlierSetup() async {
        let notifications = NotificationCenter()
        let monitor = FileAccessMonitor(notifications: notifications)
        let guide = MacPermissionsGuide(fileAccessMonitor: monitor)
        let shown = expectation(description: "permission repair guidance")
        guide.startMonitoringFileAccess(
            notifications: notifications, bundleURL: { URL(fileURLWithPath: "/Applications/VibePier.app") },
            present: { shown.fulfill() })
        defer { guide.stopMonitoringFileAccess() }
        monitor.recordPermissionRequired()
        notifications.post(name: SessionFileAccess.permissionDenied, object: nil)
        await fulfillment(of: [shown], timeout: 1)
        XCTAssertTrue(guide.fileAccessDenied)
        notifications.post(name: SessionFileAccess.permissionDenied, object: nil)
        await Task.yield()
    }

    @MainActor
    func testNoRecentFileCheckRemainsUnverifiedWithoutOpeningSystemSettings() {
        let monitor = FileAccessMonitor(notifications: NotificationCenter())
        let guide = MacPermissionsGuide(fileAccessMonitor: monitor)
        guide.checkFileAccess()
        XCTAssertEqual(guide.fileAccessStatus, .unknown)
        XCTAssertFalse(guide.fileAccessCheckInFlight)
    }

    @MainActor
    func testCheckButtonUpdatesActualReadStatusAndClearsThePreviousWarning() async {
        let notifications = NotificationCenter()
        let monitor = FileAccessMonitor(notifications: notifications)
        let guide = MacPermissionsGuide(fileAccessMonitor: monitor)
        guide.startMonitoringFileAccess(
            notifications: notifications, bundleURL: { URL(fileURLWithPath: "/Applications/VibePier.app") },
            present: { XCTFail("successful synthetic reads must not show permission guidance") })
        defer { guide.stopMonitoringFileAccess() }
        guide.handleFileAccessDenied(bundleURL: URL(fileURLWithPath: "/Applications/VibePier.app"), present: {})
        monitor.recordProbe {}  // No real file or authorization is accessed.
        guide.checkFileAccess()
        for _ in 0..<100 {
            if guide.fileAccessStatus == .accessConfirmed && !guide.fileAccessCheckInFlight { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(guide.fileAccessStatus, .accessConfirmed)
        XCTAssertFalse(guide.fileAccessDenied)
        XCTAssertFalse(guide.fileAccessCheckInFlight)
    }

    @MainActor
    func testSyntheticDeniedRecheckShowsRequiredStatusAndOnlyOneRepairPrompt() async {
        let notifications = NotificationCenter()
        let monitor = FileAccessMonitor(notifications: notifications)
        let guide = MacPermissionsGuide(fileAccessMonitor: monitor)
        var presentations = 0
        guide.startMonitoringFileAccess(
            notifications: notifications, bundleURL: { URL(fileURLWithPath: "/Applications/VibePier.app") },
            present: { presentations += 1 })
        defer { guide.stopMonitoringFileAccess() }
        monitor.recordProbe { throw SessionFileAccess.PermissionDenied() }
        for _ in 0..<2 {
            guide.checkFileAccess()
            for _ in 0..<100 {
                if guide.fileAccessStatus == .permissionRequired && !guide.fileAccessCheckInFlight && presentations == 1
                {
                    break
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        XCTAssertEqual(guide.fileAccessStatus, .permissionRequired)
        XCTAssertTrue(guide.fileAccessDenied)
        XCTAssertEqual(presentations, 1)
    }

    @MainActor
    func testQueuedDenialDoesNotShowRepairAfterANewerSuccessfulRead() async {
        let notifications = NotificationCenter()
        let monitor = FileAccessMonitor(notifications: notifications)
        let guide = MacPermissionsGuide(fileAccessMonitor: monitor)
        guide.startMonitoringFileAccess(
            notifications: notifications, bundleURL: { URL(fileURLWithPath: "/Applications/VibePier.app") },
            present: { XCTFail("an obsolete refusal must not overwrite recovered access") })
        defer { guide.stopMonitoringFileAccess() }
        monitor.recordPermissionRequired()
        notifications.post(name: SessionFileAccess.permissionDenied, object: nil)
        monitor.recordAccessConfirmed()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(guide.fileAccessStatus, .accessConfirmed)
        XCTAssertFalse(guide.fileAccessDenied)
    }
}
