import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Capture is initiated only when the authenticated phone selects a specific running app.
enum CodexAppshot {
    private final class ResultBox: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var value: Result<Data, Error>?
        func finish(_ value: Result<Data, Error>) {
            lock.withLock { self.value = value }
            semaphore.signal()
        }
    }
    static func apps() -> [[String: Any]] {
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "io.github.junweiup.vibepier"
        }.compactMap {
            guard let id = $0.bundleIdentifier else { return nil }
            return ["id": id, "name": $0.localizedName ?? id]
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }
    static func capture(bundleID: String) throws -> Data {
        guard
            NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleIdentifier == bundleID && $0.activationPolicy == .regular
            })
        else { throw CLIError(L10n.text("session.the_selected_application_is_not_running")) }
        guard CGPreflightScreenCaptureAccess() else {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                _ = CGRequestScreenCaptureAccess()
            }
            throw CLIError(L10n.text("session.allow_screen_recording_for_vibepier_in_the_mac_system_prompt_then_ad"))
        }
        let box = ResultBox()
        // Older SDKs do not mark ScreenCaptureKit objects Sendable. Keep them in one
        // nonisolated task; only the encoded JPEG crosses into the waiting caller.
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }),
                    let window = content.windows.filter({
                        $0.owningApplication?.processID == app.processID && $0.frame.width > 100
                            && $0.frame.height > 100 && $0.windowLayer == 0
                    }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
                else { throw CLIError(L10n.text("session.the_selected_application_has_no_visible_window")) }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let scale = min(1, 1600 / max(window.frame.width, window.frame.height))
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration)
                guard
                    let data = NSBitmapImageRep(cgImage: image).representation(
                        using: .jpeg, properties: [.compressionFactor: 0.85])
                else { throw CLIError(L10n.text("session.could_not_capture_the_application_window")) }
                box.finish(.success(data))
            } catch { box.finish(.failure(error)) }
        }
        guard box.semaphore.wait(timeout: .now() + 15) == .success, let result = box.lock.withLock({ box.value }) else {
            throw CLIError(L10n.text("session.application_screenshot_capture_timed_out_retry"))
        }
        return try result.get()
    }
}
