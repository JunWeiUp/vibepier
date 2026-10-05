import SwiftUI
import VibePierCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signals: [DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacPermissionsGuide.shared.startMonitoringFileAccess()
        MacPermissionsGuide.shared.showOnInstalledLaunch()
        signals = [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            return source
        }
        do {
            try EmbeddedDriver.shared.start()
            NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("mac.control_service_is_not_running")
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MacPermissionsGuide.shared.stopMonitoringFileAccess()
        EmbeddedDriver.shared.stop()
    }
}

@main
struct VibePierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DeviceModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model).vibeAppearance()
        } label: {
            Image(
                nsImage: TaskActivityCompositeIcon.image(
                    base: MenuBarIcon.image(symbol: model.statusIcon), activity: model.taskActivity)
            )
            .accessibilityLabel("VibePier：\(model.menuIconDescription)")
            .help(model.menuIconDescription)
        }
        .menuBarExtraStyle(.window)

        WindowGroup(L10n.text("mac.au05_device_settings"), id: "au05-settings") {
            AU05SettingsView(model: model).vibeAppearance()
        }
        .windowResizability(.contentSize)

        WindowGroup(L10n.text("mac.phone_remote"), id: "phone-remote") {
            PhoneRemoteView(model: model).vibeAppearance()
        }
        .windowResizability(.contentSize)

        WindowGroup(L10n.text("mac.key_bindings"), id: "bindings") {
            BindingsView(model: model).vibeAppearance()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 420)
    }
}
