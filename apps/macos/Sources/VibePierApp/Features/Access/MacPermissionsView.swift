import AppKit
import SwiftUI
import VibePierCore

/// System Settings owns authorization. Never infer a grant from opening the guide
/// or inspect/modify the TCC database to report permission state.
@MainActor
final class MacPermissionsGuide: ObservableObject {
    static let shared = MacPermissionsGuide()
    static let setupKey = "macPermissionsGuideVersion"
    private var window: NSWindow?
    @Published private(set) var fileAccessDenied = false
    @Published private(set) var fileAccessStatus: FileAccessStatus
    @Published private(set) var fileAccessCheckInFlight = false
    private let fileAccessMonitor: FileAccessMonitor
    private var presentedFileAccessFailure = false
    private var failureObserver: NSObjectProtocol?
    private var statusObserver: NSObjectProtocol?
    private var notifications: NotificationCenter?

    init(fileAccessMonitor: FileAccessMonitor = .shared) {
        self.fileAccessMonitor = fileAccessMonitor
        fileAccessStatus = fileAccessMonitor.status
    }

    func checkFileAccess() {
        _ = fileAccessMonitor.check()
        refreshFileAccessStatus()
    }

    private func refreshFileAccessStatus() {
        fileAccessStatus = fileAccessMonitor.status
        fileAccessCheckInFlight = fileAccessMonitor.checkInFlight
        if fileAccessStatus == .accessConfirmed { fileAccessDenied = false }
    }

    private static func isInstalled(_ bundleURL: URL) -> Bool {
        bundleURL.deletingLastPathComponent().standardizedFileURL.path == "/Applications"
    }

    static func shouldShowOnLaunch(bundleURL: URL, setupVersion: Int) -> Bool {
        isInstalled(bundleURL) && setupVersion < 1
    }

    /// Real permission failures bypass the first-launch record; repeated image/file
    /// failures share one automatic presentation for this process. Manual reopening stays available.
    @discardableResult
    func handleFileAccessDenied(bundleURL: URL, present: (() -> Void)? = nil) -> Bool {
        guard Self.isInstalled(bundleURL) else { return false }
        fileAccessDenied = true
        guard !presentedFileAccessFailure else { return false }
        presentedFileAccessFailure = true
        if let present { present() } else { show() }
        return true
    }

    func startMonitoringFileAccess(
        notifications: NotificationCenter = .default,
        bundleURL: @escaping () -> URL = { Bundle.main.bundleURL }, present: (() -> Void)? = nil
    ) {
        guard failureObserver == nil else { return }
        self.notifications = notifications
        refreshFileAccessStatus()
        statusObserver = notifications.addObserver(
            forName: FileAccessMonitor.statusChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFileAccessStatus() }
        }
        failureObserver = notifications.addObserver(
            forName: SessionFileAccess.permissionDenied, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.fileAccessMonitor.status == .permissionRequired else { return }
                self.handleFileAccessDenied(bundleURL: bundleURL(), present: present)
            }
        }
    }

    func stopMonitoringFileAccess() {
        if let failureObserver { notifications?.removeObserver(failureObserver) }
        if let statusObserver { notifications?.removeObserver(statusObserver) }
        failureObserver = nil
        statusObserver = nil
        notifications = nil
    }

    func showOnInstalledLaunch() {
        guard
            Self.shouldShowOnLaunch(
                bundleURL: Bundle.main.bundleURL,
                setupVersion: UserDefaults.standard.integer(forKey: Self.setupKey))
        else { return }
        show()
        // Records that the guide was presented, never that authorization was granted.
        UserDefaults.standard.set(1, forKey: Self.setupKey)
        _ = Self.openSettings("Privacy_AllFiles")
    }

    func show() {
        if window == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = L10n.text("mac.permissions_title")
            created.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MacPermissionsView(guide: self).vibeAppearance())
            created.contentView = host
            created.setContentSize(host.fittingSize)
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // A reopened guide may now include the permission-refusal explanation.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, window.isVisible, let content = window.contentView else { return }
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
    }

    static func openSettings(_ pane: String) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}

struct MacPermissionsView: View {
    @ObservedObject var guide: MacPermissionsGuide = .shared
    @State private var settingsFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if guide.fileAccessDenied {
                Label(L10n.text("mac.file_access_denied"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(VibeAppearance.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(L10n.text("mac.disk_access_title"), systemImage: "externaldrive.badge.checkmark")
                .font(.title2.bold())
            Text(L10n.text("mac.disk_access_reason"))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("mac.disk_access_steps"))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("mac.open_disk_settings")) {
                    settingsFailed = !MacPermissionsGuide.openSettings("Privacy_AllFiles")
                }.buttonStyle(.borderedProminent)
                Button(L10n.text("mac.reveal_installed_app")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }
            Button(L10n.text("mac.open_folder_settings")) {
                settingsFailed = !MacPermissionsGuide.openSettings("Privacy_FilesAndFolders")
            }
            Text(L10n.text("mac.disk_access_system_status"))
                .font(.caption).foregroundStyle(VibeAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                guide.checkFileAccess()
            } label: {
                HStack {
                    if guide.fileAccessStatus == .checking { ProgressView().controlSize(.small) }
                    Text(L10n.text(fileAccessStatusKey))
                }
            }.disabled(guide.fileAccessCheckInFlight)
            Text(L10n.text(fileAccessDetailKey))
                .font(.caption).foregroundStyle(VibeAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(L10n.text("mac.accessibility_setup")).font(.headline)
            Text(L10n.text("mac.accessibility_setup_detail"))
                .foregroundStyle(VibeAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("mac.open_accessibility_settings")) {
                settingsFailed = !MacPermissionsGuide.openSettings("Privacy_Accessibility")
            }
            if settingsFailed {
                Text(L10n.text("mac.permissions_settings_failed")).foregroundStyle(.red)
            }
        }
        .padding(24).frame(width: 520)
    }

    private var fileAccessStatusKey: String {
        switch guide.fileAccessStatus {
        case .unknown: return "mac.file_access_unknown"
        case .checking: return "mac.file_access_checking"
        case .accessConfirmed: return "mac.file_access_confirmed"
        case .permissionRequired: return "mac.file_access_required"
        }
    }
    private var fileAccessDetailKey: String {
        if guide.fileAccessCheckInFlight && guide.fileAccessStatus == .unknown {
            return "mac.file_access_check_timeout"
        }
        switch guide.fileAccessStatus {
        case .unknown: return "mac.file_access_unknown_detail"
        case .checking: return "mac.file_access_check_detail"
        case .accessConfirmed: return "mac.file_access_confirmed_detail"
        case .permissionRequired: return "mac.file_access_required_detail"
        }
    }
}
