import AppKit
import SwiftUI
import VibePierCore
import XCTest

@testable import VibePierApp

/// Native views with synthetic status and an injected CLI; no service, Keychain or hardware access.
@MainActor
final class LocalizationPreviewTests: XCTestCase {
    private func model() -> DeviceModel {
        DeviceModel(runCommand: { arguments in
            switch arguments.first {
            case "status":
                return .init(
                    exitCode: 0,
                    stdout:
                        #"{"ok":true,"dongleConnected":false,"micLinked":false,"accessibilityTrusted":true,"remoteListening":true,"remotePort":47800,"remoteConnectedAddresses":[],"bluetooth":{"state":"Ready","connectedCount":1},"relay":{"state":"Connected","connectedCount":1,"url":"wss://relay.example.com/vibepier/relay","room":"demo-room","dnsRecovery":false},"taskActivity":{"runningCount":0,"unreadCount":0,"sessions":[]}}"#,
                    stderr: "")
            case "info", "settings": return .init(exitCode: 0, stdout: "{}", stderr: "")
            case "buttons", "hooks": return .init(exitCode: 0, stdout: "", stderr: "")
            default:
                XCTFail("Preview attempted an unexpected command: \(arguments.first ?? "none")")
                return .init(exitCode: 1, stdout: "", stderr: "Fixture refuses mutations")
            }
        })
    }

    private func render<V: View>(_ content: V, width: CGFloat, name: String, dark: Bool) throws {
        let host = NSHostingView(rootView: content.vibeAppearance().environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        XCTAssertEqual(size.width, width, accuracy: 1)
        XCTAssertGreaterThan(size.height, 100)
        XCTAssertLessThan(size.height, 1000)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["VIBEPIER_PREVIEW_DIR"] {
            // A hidden hosting window may have only a partial layer redraw after layout.
            host.needsDisplay = true
            host.display()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try bytes.write(to: url.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    func testLocalizedNativeConnectionAndRelayLayouts() async throws {
        let requested = ProcessInfo.processInfo.environment["VIBEPIER_PREVIEW_APPEARANCE"]
        let appearances = requested.map { [$0 == "dark"] } ?? [false, true]
        for dark in appearances {
            let model = model()
            await model.refreshStatus()
            PhoneRemoteNavigation.shared.page = .connection
            try render(PhoneRemoteView(model: model), width: 920, name: "phone", dark: dark)
            try render(RelayView(model: model), width: 520, name: "relay", dark: dark)
            model.stopMonitoring()
        }
    }
}
