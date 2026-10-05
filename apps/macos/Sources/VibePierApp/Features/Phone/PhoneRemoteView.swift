import SwiftUI
import VibePierCore

/// Every phone-facing setting lives in one window; the menu panel opens it on the page it needs.
enum PhoneRemotePage: String, CaseIterable, Identifiable {
    case connection, bindings, shortcuts, access, relay, apk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connection: return L10n.text("mac.connection")
        case .bindings: return L10n.text("mac.key_bindings")
        case .shortcuts: return L10n.text("mac.app_shortcuts")
        case .access: return L10n.text("mac.session_access")
        case .relay: return L10n.text("mac.cloud_relay")
        case .apk: return L10n.text("mac.install_apk")
        }
    }
    var symbol: String {
        switch self {
        case .connection: return "wifi"
        case .bindings: return "keyboard"
        case .shortcuts: return "square.grid.2x2"
        case .access: return "bubble.left.and.bubble.right"
        case .relay: return "cloud"
        case .apk: return "arrow.down.app"
        }
    }
}

@MainActor
final class PhoneRemoteNavigation: ObservableObject {
    static let shared = PhoneRemoteNavigation()
    @Published var page: PhoneRemotePage = .connection
}

struct PhoneRemoteView: View {
    @ObservedObject var model: DeviceModel
    @ObservedObject private var navigation = PhoneRemoteNavigation.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VibeAppearance.background)
        }
        .frame(width: 920, height: 660)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(PhoneRemotePage.allCases) { page in
                let selected = navigation.page == page
                Button {
                    navigation.page = page
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: page.symbol).frame(width: 18)
                            .foregroundStyle(selected ? VibeAppearance.accent : VibeAppearance.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.title).lineLimit(1)
                                .foregroundStyle(selected ? VibeAppearance.accent : VibeAppearance.text)
                            if let badge = badge(page) {
                                Text(badge).font(.caption).foregroundStyle(VibeAppearance.faint)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        selected ? VibeAppearance.accentContainer : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
            AppVersionBadge()
                .padding(.horizontal, 10).padding(.bottom, 4)
        }
        .padding(10)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(VibeAppearance.sidebar)
    }

    private func badge(_ page: PhoneRemotePage) -> String? {
        switch page {
        case .connection:
            if !model.remoteConnectedAddresses.isEmpty { return "Wi-Fi" }
            if model.bluetoothConnectedCount > 0 { return L10n.text("mac.bluetooth") }
            if model.relayConnectedCount > 0 { return L10n.text("mac.relay") }
            return L10n.text("mac.disconnected")
        case .shortcuts: return model.applicationShortcuts.isEmpty ? nil : "\(model.applicationShortcuts.count)"
        case .relay: return model.relayURL.isEmpty ? L10n.text("mac.off_2") : nil
        default: return nil
        }
    }

    @ViewBuilder private var content: some View {
        switch navigation.page {
        case .connection: PhoneConnectionPage(model: model)
        case .bindings: PhoneBindingsView(model: model)
        case .shortcuts: ApplicationShortcutsView(model: model)
        case .access: CodexAccessView()
        case .relay: RelayView(model: model)
        case .apk: PhoneAPKView(model: model)
        }
    }
}

/// How each transport is doing right now; nothing here changes settings.
private struct PhoneConnectionPage: View {
    @ObservedObject var model: DeviceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("mac.connection")).font(.title2.bold())
                Text(L10n.text("mac.open_vibepier_on_the_phone_and_tap_its_connection_status_to_choose_w"))
                    .font(.callout).foregroundStyle(VibeAppearance.secondary)
            }
            VStack(spacing: 0) {
                row(
                    "Wi-Fi", symbol: "wifi",
                    detail: model.remoteListening
                        ? (model.remoteConnectedAddresses.isEmpty
                            ? L10n.text("mac.listening_on_port_0_waiting_for_a_phone", model.remotePort)
                            : model.remoteConnectedAddresses.joined(separator: "，"))
                        : L10n.text("mac.off_3"),
                    connected: !model.remoteConnectedAddresses.isEmpty)
                Divider().padding(.leading, 56)
                row(
                    L10n.text("mac.bluetooth"), symbol: "dot.radiowaves.left.and.right",
                    detail: model.bluetoothConnectedCount > 0
                        ? L10n.text("mac.connected_phones_0_2", model.bluetoothConnectedCount) : model.bluetoothState,
                    connected: model.bluetoothConnectedCount > 0)
                Divider().padding(.leading, 56)
                row(
                    L10n.text("mac.cloud_relay"), symbol: "cloud",
                    detail: model.relayURL.isEmpty
                        ? L10n.text("mac.not_configured_for_use_across_networks") : model.relayState,
                    connected: model.relayConnectedCount > 0)
            }
            .vibeCard()
            Text(L10n.text("mac.the_voice_key_uses_the_mac_microphone_by_default_choose_the_phone_mi"))
                .font(.callout).foregroundStyle(VibeAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }

    private func row(_ title: String, symbol: String, detail: String, connected: Bool) -> some View {
        HStack(spacing: 12) {
            IconBadge(
                symbol: symbol, tint: connected ? VibeAppearance.accent : VibeAppearance.secondary,
                container: connected ? VibeAppearance.accentContainer : VibeAppearance.surface3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(VibeAppearance.secondary).textSelection(.enabled)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(connected ? VibeAppearance.accent : VibeAppearance.faint).frame(width: 6, height: 6)
                Text(connected ? L10n.text("mac.connected") : L10n.text("mac.disconnected")).font(.caption)
                    .foregroundStyle(connected ? VibeAppearance.accent : VibeAppearance.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
