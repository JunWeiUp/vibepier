import AppKit
import SwiftUI
import VibePierCore

/// Cloud relay settings: lets the phone reach this Mac away from its Wi-Fi and Bluetooth.
struct RelayView: View {
    @ObservedObject var model: DeviceModel
    @State private var url = ""
    @State private var room = ""
    @State private var secret = ""
    @State private var dnsRecovery = false
    @State private var loaded = false
    @State private var notice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("mac.cloud_relay")).font(.title2.bold())
            Text(L10n.text("mac.the_relay_carries_encrypted_sessions_controls_and_settings_when_the_"))
                .font(.callout).foregroundStyle(VibeAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(L10n.text("mac.relay_url"), text: $url, prompt: Text("wss://example.com/vibepier/relay"))
                HStack {
                    TextField(L10n.text("mac.room"), text: $room, prompt: Text(L10n.text("mac.letters_numbers_or")))
                    Button(L10n.text("mac.random")) { room = "mac-" + Self.randomHex(4) }
                }
                HStack {
                    SecureField(
                        L10n.text("mac.secret"), text: $secret,
                        prompt: Text(
                            model.relayURL.isEmpty
                                ? L10n.text("mac.match_etc_vibepier_relay_secret_on_the_server")
                                : L10n.text("mac.leave_blank_to_keep_the_saved_secret")))
                    Button(L10n.text("mac.generate")) {
                        secret = Self.randomHex(32)
                        notice = L10n.text("mac.new_secret_generated_set_the_same_secret_on_the_server_before_connec")
                    }
                }
            }
            Toggle(L10n.text("mac.use_alidns_https_recovery_if_phone_dns_fails"), isOn: $dnsRecovery)
            Text(L10n.text("mac.optional_queries_alidns_for_the_relay_hostname_only_after_wss_system"))
                .font(.caption).foregroundStyle(VibeAppearance.secondary)
            HStack(spacing: 8) {
                Circle().fill(model.relayConnectedCount > 0 ? VibeAppearance.accent : VibeAppearance.secondary).frame(
                    width: 8, height: 8)
                Text(model.relayURL.isEmpty ? L10n.text("mac.disabled") : model.relayState).font(.callout)
            }
            if !model.relayError.isEmpty {
                Text(model.relayError).font(.caption).foregroundStyle(VibeAppearance.danger)
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(VibeAppearance.secondary) }
            HStack {
                Button(L10n.text("mac.save_and_connect")) {
                    Task {
                        if await model.setRelay(url: url, room: room, secret: secret, dnsRecovery: dnsRecovery) {
                            secret = ""
                            notice = L10n.text("mac.saved")
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || room.isEmpty)
                Button(L10n.text("mac.copy_phone_pairing_code")) {
                    Task {
                        guard let code = await model.relayPairingCode() else {
                            notice = L10n.text("mac.save_the_relay_settings_first")
                            return
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        notice = L10n.text("mac.pairing_code_copied_including_its_secret_paste_it_into_connection_cl")
                    }
                }
                .disabled(model.relayURL.isEmpty)
                Spacer()
                Button(L10n.text("mac.disable_relay")) {
                    Task {
                        if await model.setRelay(url: "", room: "", secret: "") {
                            url = ""
                            room = ""
                            notice = L10n.text("mac.disabled_2")
                        }
                    }
                }
                .disabled(model.relayURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            await model.refreshStatus()
            guard !loaded else { return }
            loaded = true
            dnsRecovery = model.relayDNSRecovery
            url = model.relayURL
            room = model.relayRoom.isEmpty ? "mac-" + Self.randomHex(4) : model.relayRoom
        }
    }

    private static func randomHex(_ bytes: Int) -> String {
        var data = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &data)
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
