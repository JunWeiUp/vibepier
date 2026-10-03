import VibePierCore
import XCTest

@testable import VibePierApp

@MainActor
final class DeviceModelTests: XCTestCase {
    private final class CLI {
        var calls: [[String]] = []
        var linked = true
        var running = true
        var agentLightsEnabled = true
        var brightness = 2
        var heartbeatEnabled = true

        var settings: String {
            """
            {"lights":{"mode":0,"allOnBrightness":\(brightness)},"noiseReductionLevel":0,
            "sleepTimeSeconds":0,"standbyTimeSeconds":3600,"microphoneEnabled":false}
            """
        }

        func run(_ args: [String]) async -> AppCommands.Result {
            calls.append(args)
            let body: String
            switch args.first {
            case "status":
                if !running { return .init(exitCode: 1, stdout: "", stderr: "not running") }
                body = """
                    {"ok":true,"dongleConnected":true,"micLinked":\(linked),"agentLightsEnabled":\(agentLightsEnabled),
                    "heartbeatEnabled":\(heartbeatEnabled),"heartbeatInterval":\(heartbeatEnabled ? 1 : 0),
                    "battery":{"percent":70,"millivolts":3870,"charging":false}}
                    """
            case "info":
                body = """
                    {"dongle":{"micLinked":true,"serialNumber":"test","version":{"version":"4.4.2"}},
                    "device":{"serialNumber":"test","version":{"version":"4.4.2"},
                    "battery":{"percent":70,"millivolts":3870,"charging":false,"chargeFull":false}},
                    "settings":\(settings)}
                    """
            case "settings": body = settings
            case "buttons": body = "talk        rcmd\nconfirm     return\ncancel      escape\n"
            case "hooks": body = "Codex: installed"
            case "set":
                brightness = 9
                body = "ok"
            case "heartbeat":
                heartbeatEnabled = args.last == "on"
                body = "ok"
            default: body = "ok"
            }
            return .init(exitCode: 0, stdout: body, stderr: "")
        }
    }

    func testHardwareSettingFailureRetainsConfigurationAndNextSuccessClearsError() async {
        let cli = CLI()
        var fail = false
        let model = DeviceModel(runCommand: { args in
            if fail && args.first == "set" {
                return .init(exitCode: 1, stdout: "", stderr: "设备未响应")
            }
            return await cli.run(args)
        })
        await model.preparePanel()
        fail = true
        await model.applySetting(["set", "brightness", "9"])
        XCTAssertEqual(model.deviceSettingError, "设备未响应")
        XCTAssertEqual(model.settings?.lights.allOnBrightness, 2)
        XCTAssertFalse(model.refreshing)
        fail = false
        await model.applySetting(["set", "brightness", "9"])
        XCTAssertEqual(model.deviceSettingError, "")
        XCTAssertEqual(model.settings?.lights.allOnBrightness, 9)
    }

    func testPhoneConnectionCanShowWithoutAU05() async {
        let model = DeviceModel(runCommand: { _ in
            .init(
                exitCode: 0,
                stdout: """
                    {"ok":true,"dongleConnected":false,"micLinked":false,
                     "remoteConnectedAddresses":["192.168.0.204"],"remoteListening":true,"remotePort":47800}
                    """, stderr: "")
        })
        await model.refreshStatus()
        XCTAssertEqual(model.linkState, .noDongle)
        XCTAssertEqual(model.remoteConnectedAddresses.count, 1)
        XCTAssertEqual(model.menuStatusText, L10n.text("mac.phone_connected"))
        XCTAssertEqual(model.statusText, L10n.text("mac.no_receiver_detected"))
        model.remoteConnectedAddresses = []
        XCTAssertEqual(model.menuStatusText, L10n.text("mac.no_phone_connected"))
    }

    func testPeriodicRefreshNeverQueriesHardwareEvenAcrossReconnect() async {
        let cli = CLI()
        let model = DeviceModel(runCommand: cli.run)
        await model.preparePanel()
        XCTAssertNotNil(model.settings)
        cli.calls = []
        for _ in 0..<5 { await model.refreshStatus() }
        XCTAssertEqual(model.batteryPercent, 70)
        cli.linked = false
        await model.refreshStatus()
        XCTAssertNil(model.batteryPercent)
        XCTAssertNil(model.settings)
        cli.linked = true
        await model.refreshStatus()
        XCTAssertEqual(model.linkState, .linked)
        XCTAssertNil(model.settings)  // Reconnect waits for an explicit panel read.
        XCTAssertTrue(cli.calls.allSatisfy { $0 == ["status"] })
        await model.preparePanel()
        XCTAssertEqual(cli.calls.last, ["info", "--json"])
        XCTAssertNotNil(model.settings)
    }

    func testRepeatedPanelOpenReusesDetailsAndDoesNotReadBindings() async {
        let cli = CLI()
        let model = DeviceModel(runCommand: cli.run)
        await model.preparePanel()
        XCTAssertEqual(cli.calls, [["status"], ["info", "--json"], ["hooks", "status"]])
        XCTAssertEqual(model.settings?.lights.allOnBrightness, 2)
        cli.calls = []
        await model.preparePanel()
        XCTAssertEqual(cli.calls, [["status"]])
        await model.refreshBindings()
        XCTAssertEqual(cli.calls.last, ["buttons"])
        XCTAssertEqual(model.bindings.first?.keys, "rcmd")
    }

    func testEditsReadOnlyTheAffectedSection() async {
        let cli = CLI()
        let model = DeviceModel(runCommand: cli.run)
        await model.applySetting(["set", "brightness", "9"])
        XCTAssertEqual(cli.calls, [["set", "brightness", "9"], ["settings", "--json"]])
        XCTAssertEqual(model.settings?.lights.allOnBrightness, 9)
        cli.calls = []
        let success = await model.setBinding(control: "talk", keys: "rcmd")
        XCTAssertTrue(success)
        XCTAssertEqual(cli.calls, [["bind", "talk", "rcmd"], ["buttons"]])
    }

    func testOfflineDaemonDoesNotCauseAutomaticHardwarePolling() async {
        let cli = CLI()
        cli.running = false
        let model = DeviceModel(runCommand: cli.run)
        await model.preparePanel()
        await model.refreshStatus()
        XCTAssertFalse(model.daemonRunning)
        XCTAssertFalse(cli.calls.contains { ["info", "settings", "buttons"].contains($0.first ?? "") })
        cli.calls = []
        await model.refresh()  // User explicitly requests a hardware read.
        XCTAssertTrue(cli.calls.contains(["info", "--json"]))
        XCTAssertNotNil(model.settings)
    }

    func testDisabledAgentLightsSkipHooksAndClearTheirDisplay() async {
        let cli = CLI()
        let model = DeviceModel(runCommand: cli.run)
        await model.preparePanel()
        XCTAssertFalse(model.hooksLines.isEmpty)
        cli.agentLightsEnabled = false
        cli.calls = []
        await model.preparePanel()
        await model.refresh()
        XCTAssertFalse(model.agentLightsEnabled)
        XCTAssertTrue(model.hooksLines.isEmpty)
        XCTAssertFalse(cli.calls.contains { $0.first == "hooks" })
    }

    func testHeartbeatSwitchOnlyUpdatesLocalStatus() async {
        let cli = CLI()
        let model = DeviceModel(runCommand: cli.run)
        await model.setHeartbeatEnabled(false)
        XCTAssertFalse(model.heartbeatEnabled)
        XCTAssertEqual(model.heartbeatInterval, 0)
        XCTAssertEqual(cli.calls, [["heartbeat", "off"], ["status"]])
        await model.setHeartbeatEnabled(true)
        XCTAssertTrue(model.heartbeatEnabled)
        XCTAssertEqual(model.heartbeatInterval, 1)
    }

    func testApplicationListEditsRefreshAllSlotsAndClearRecoveredErrors() async {
        var calls: [[String]] = []
        var fail = true
        let entries = (0..<7).map {
            "{\"slot\":\($0),\"bundleID\":\"test.application\($0)\",\"name\":\"App \($0)\",\"iconPNG\":\"\",\"available\":false}"
        }.joined(separator: ",")
        let model = DeviceModel(runCommand: { args in
            calls.append(args)
            if args.first != "status", fail {
                return .init(exitCode: 1, stdout: "", stderr: "无法保存配置")
            }
            return .init(
                exitCode: 0,
                stdout: """
                    {"ok":true,"dongleConnected":false,"micLinked":false,"applicationShortcuts":[\(entries)]}
                    """, stderr: "")
        })
        await model.addApplicationShortcut(bundleID: "test.application6")
        XCTAssertEqual(model.applicationShortcutError, "无法保存配置")
        XCTAssertEqual(calls, [["application-shortcut-add", "test.application6"]])
        fail = false
        calls = []
        await model.addApplicationShortcut(bundleID: "test.application6")
        XCTAssertEqual(calls, [["application-shortcut-add", "test.application6"], ["status"]])
        XCTAssertEqual(model.applicationShortcuts.count, 7)
        XCTAssertEqual(model.applicationShortcuts.last?.slot, 6)
        XCTAssertTrue(model.applicationShortcutError.isEmpty)
        calls = []
        await model.moveApplicationShortcut(index: 6, target: 5)
        await model.updateApplicationShortcut(index: 6, bundleID: "test.replacement")
        await model.removeApplicationShortcut(index: 6)
        XCTAssertEqual(
            calls,
            [
                ["application-shortcut-move", "6", "5"], ["status"],
                ["application-shortcut-set", "6", "test.replacement"], ["status"],
                ["application-shortcut-remove", "6"], ["status"],
            ])
    }
}
