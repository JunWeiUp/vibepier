import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import VibePierCore

struct PhoneAPKView: View {
    @ObservedObject var model: DeviceModel
    @State private var phones: [PhoneAPKDeviceSnapshot] = []
    @State private var device = ""
    @State private var file: URL?
    @State private var latestVersion: String?
    @State private var publishing = false
    @State private var working = false
    @State private var refreshing = false
    @State private var error: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var selected: PhoneAPKDeviceSnapshot? { phones.first { $0.id == device } }
    private var status: PhoneAPKStatus? { selected?.status }
    private var transferBusy: Bool { status?.phase.isActive == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("mac.install_apk_on_phone")).font(.title2.bold())
            Text(L10n.text("mac.open_vibepier_on_the_phone_the_first_bluetooth_connection_asks_for_a"))
                .foregroundStyle(VibeAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("updates.registered_release")).font(.headline)
                if let latestVersion { Text(L10n.text("updates.available", latestVersion)).font(.caption) }
                HStack {
                    Button(L10n.text("mac.choose_apk")) { chooseAPK() }.disabled(working)
                    Text(file?.lastPathComponent ?? L10n.text("mac.no_file_selected"))
                        .lineLimit(1).truncationMode(.middle).help(file?.lastPathComponent ?? "")
                }
                Button(publishing ? L10n.text("mac.preparing") : L10n.text("updates.register")) {
                    guard let file else { return }
                    working = true
                    error = nil
                    SessionRemote.shared.publishAndroidUpdate(file) { message in
                        Task { @MainActor in
                            working = false
                            error = message
                            await refresh()
                        }
                    }
                }.disabled(file == nil || working || publishing)
                Text(L10n.text("updates.registration_hint")).font(.caption).foregroundStyle(VibeAppearance.secondary)
            }
            Divider()
            if phones.isEmpty {
                Text(L10n.text("mac.no_authorized_phones_connect_over_bluetooth_and_approve_the_phone_on"))
                    .foregroundStyle(VibeAppearance.secondary)
            } else {
                Picker(L10n.text("mac.receiving_phone"), selection: $device) {
                    Text(L10n.text("updates.choose_phone")).tag("")
                    ForEach(phones) { phone in
                        Text("\(phone.name) · \(phone.id.prefix(8))").tag(phone.id)
                    }
                }.disabled(working)
                if let selected {
                    Label(
                        model.connectedPhoneIDs.contains(selected.id)
                            ? L10n.text("mac.connected") : L10n.text("updates.phone_offline"),
                        systemImage: model.connectedPhoneIDs.contains(selected.id) ? "checkmark.circle" : "clock"
                    )
                    .font(.caption).foregroundStyle(VibeAppearance.secondary)
                    if let version = selected.installedVersion {
                        Text(L10n.text("updates.installed", version)).font(.caption)
                    }
                }
                HStack {
                    Button(L10n.text("updates.send_latest")) {
                        send { SessionRemote.shared.stageLatestAndroidUpdate(device: device, completion: $0) }
                    }.disabled(latestVersion == nil || device.isEmpty || working || transferBusy)
                    Button(working ? L10n.text("mac.preparing") : L10n.text("mac.send_to_phone")) {
                        guard let file else { return }
                        send { SessionRemote.shared.stageAPK(file, device: device, completion: $0) }
                    }.disabled(file == nil || device.isEmpty || working || transferBusy)
                    if status?.phase.canCancel == true {
                        Button(L10n.text("mac.cancel_transfer")) {
                            SessionRemote.shared.cancelAPK(device)
                            Task { await refresh() }
                        }
                    }
                }
                Text(L10n.text("mac.accepts_one_complete_apk_up_to_512_mb_including_vibepier_updates_ins"))
                    .font(.caption).foregroundStyle(VibeAppearance.secondary)
            }
            if let status {
                VStack(alignment: .leading, spacing: 8) {
                    Text(status.name).lineLimit(1).help(status.name)
                    if status.phase == .preparing {
                        ProgressView().controlSize(.small)
                    } else {
                        ProgressView(value: Double(status.received), total: Double(max(1, status.size)))
                        Text(
                            "\(ByteCountFormatter.string(fromByteCount: Int64(status.received), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(status.size), countStyle: .file))"
                        )
                        .font(.caption).foregroundStyle(VibeAppearance.secondary)
                    }
                    Text(status.state).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(status.phase == .failed ? VibeAppearance.danger : VibeAppearance.secondary)
                    if [.received, .permission, .installing].contains(status.phase) {
                        Text(L10n.text("updates.finish_on_phone")).font(.caption).foregroundStyle(
                            VibeAppearance.secondary)
                    }
                    if !status.phase.isActive {
                        Button(L10n.text("common.close")) {
                            SessionRemote.shared.dismissAPKStatus(device)
                            Task { await refresh() }
                        }
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(VibeAppearance.danger).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(width: 560)
            .task { await refresh() }
            .onReceive(timer) { _ in Task { await refresh() } }
            .onChange(of: device) { _, _ in error = nil }
    }
    private func chooseAPK() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            Task { @MainActor in
                if response == .OK {
                    file = panel.url
                    error = nil
                }
            }
        }
    }
    private func send(_ begin: (@escaping @Sendable (String?) -> Void) -> Void) {
        working = true
        error = nil
        begin { message in
            Task { @MainActor in
                working = false
                error = message
                await refresh()
            }
        }
    }
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let snapshot = await SessionRemote.shared.apkSnapshot()
        phones = snapshot.phones
        if !phones.contains(where: { $0.id == device }) { device = phones.count == 1 ? phones[0].id : "" }
        latestVersion = snapshot.latestVersion
        publishing = snapshot.publishing
    }
}
