import SwiftUI
import VibePierCore

struct CodexAccessView: View {
    @State private var phones: [AuthorizedPhone] = []
    @State private var errorMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("mac.phone_session_access")).font(.title2.bold())
            Text(L10n.text("mac.authorized_phones_can_view_and_reply_to_supported_codex_claude_code_"))
                .foregroundStyle(VibeAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            if phones.isEmpty {
                Text(L10n.text("mac.no_authorized_phones")).foregroundStyle(VibeAppearance.secondary).padding(
                    .vertical, 16)
            }
            ForEach(phones) { phone in
                HStack {
                    Image(systemName: "iphone")
                    VStack(alignment: .leading) {
                        Text(phone.name)
                        Text(String(phone.id.prefix(8))).font(.caption).foregroundStyle(VibeAppearance.secondary)
                    }
                    Spacer()
                    Button(L10n.text("mac.revoke_access"), role: .destructive) {
                        SessionRemote.shared.revoke(phone.id) { message in Task { @MainActor in errorMessage = message }
                        }
                    }
                }
            }
            Text(L10n.text("mac.revoking_access_stops_this_phone_s_sessions_voice_and_shortcut_contr")).font(.caption)
                .foregroundStyle(VibeAppearance.secondary)
        }
        .padding(24).frame(width: 440)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SessionRemote.accessChanged).receive(on: RunLoop.main)) {
            _ in refresh()
        }
        .alert(
            L10n.text("mac.could_not_revoke_access"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(L10n.text("mac.ok")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    private func refresh() { phones = SessionRemote.shared.authorizedPhones() }
}
