import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import VibePierCore

struct PhoneAPKView: View {
    @State private var phones: [AuthorizedPhone] = []
    @State private var device = ""
    @State private var file: URL?
    @State private var status: PhoneAPKStatus?
    @State private var installedVersion: String?
    @State private var latestVersion: String?
    @State private var staging = false
    @State private var error: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("mac.install_apk_on_phone")).font(.title2.bold())
            Text(L10n.text("mac.open_vibepier_on_the_phone_the_first_bluetooth_connection_asks_for_a"))
                .foregroundStyle(VibeAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            if phones.isEmpty {
                Text(L10n.text("mac.no_authorized_phones_connect_over_bluetooth_and_approve_the_phone_on"))
                    .foregroundStyle(VibeAppearance.secondary)
            } else {
                Picker(L10n.text("mac.receiving_phone"), selection: $device) {
                    ForEach(phones) { Text($0.name).tag($0.id) }
                }
                if let installedVersion { Text(L10n.text("updates.installed", installedVersion)).font(.caption) }
                if let latestVersion { Text(L10n.text("updates.available", latestVersion)).font(.caption) }
                HStack {
                    Button(L10n.text("mac.choose_apk")) {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK {
                            file = panel.url
                            error = nil
                        }
                    }
                    Text(file?.lastPathComponent ?? L10n.text("mac.no_file_selected")).lineLimit(1).truncationMode(
                        .middle)
                }
                HStack {
                    Button(L10n.text("updates.register")) {
                        guard let file else { return }
                        staging = true
                        SessionRemote.shared.publishAndroidUpdate(file) { message in
                            Task { @MainActor in
                                staging = false
                                error = message
                                refresh()
                            }
                        }
                    }.disabled(file == nil || staging)
                    Button(L10n.text("updates.send_latest")) {
                        staging = true
                        SessionRemote.shared.stageLatestAndroidUpdate(device: device) { message in
                            Task { @MainActor in
                                staging = false
                                error = message
                                refresh()
                            }
                        }
                    }.disabled(latestVersion == nil || device.isEmpty || staging)
                }
                Text(L10n.text("mac.accepts_one_complete_apk_up_to_512_mb_including_vibepier_updates_ins")).font(
                    .caption
                ).foregroundStyle(
                    VibeAppearance.secondary)
                HStack {
                    Button(staging ? L10n.text("mac.preparing") : L10n.text("mac.send_to_phone")) {
                        guard let file else { return }
                        staging = true
                        error = nil
                        SessionRemote.shared.stageAPK(file, device: device) { message in
                            Task { @MainActor in
                                staging = false
                                error = message
                                refresh()
                            }
                        }
                    }.disabled(file == nil || device.isEmpty || staging)
                    if status != nil {
                        Button(L10n.text("mac.cancel_transfer")) {
                            SessionRemote.shared.cancelAPK(device)
                            status = nil
                        }
                    }
                }
            }
            if let status {
                Text(status.name).lineLimit(1)
                ProgressView(value: Double(status.received), total: Double(status.size))
                Text(
                    "\(ByteCountFormatter.string(fromByteCount: Int64(status.received), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(status.size), countStyle: .file)) · \(status.state)"
                )
                .font(.caption).foregroundStyle(VibeAppearance.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("mac.cancelling_stops_further_transfer_once_the_system_installer_has_take")).font(
                    .caption
                ).foregroundStyle(VibeAppearance.secondary)
            }
            if let error {
                Text(error).foregroundStyle(VibeAppearance.danger).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(width: 490)
            .onAppear { refresh() }
            .onChange(of: device) { _, _ in refresh() }
            .onReceive(timer) { _ in refresh() }
    }
    private func refresh() {
        phones = SessionRemote.shared.authorizedPhones()
        if !phones.contains(where: { $0.id == device }) { device = phones.first?.id ?? "" }
        status = SessionRemote.shared.apkStatus(device)
        func label(_ value: [String: Any]?) -> String? {
            guard let value, let name = value["versionName"] as? String, let code = value["versionCode"] as? Int else {
                return nil
            }
            return "\(name) (\(code))"
        }
        installedVersion = label(SessionRemote.shared.phoneAppVersion(device))
        latestVersion = label(SessionRemote.shared.latestAndroidVersion())
    }
}
