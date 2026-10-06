import SwiftUI
import VibePierCore

struct SessionProviderSection: View {
    @ObservedObject var model: DeviceModel

    private var enabledCount: Int {
        SessionProviderPolicy.ids.filter { model.sessionProviders[$0] == true }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("providers.title"))
                Spacer()
                Text(L10n.text("providers.enabled_count", enabledCount))
            }
            .font(.caption.weight(.medium)).foregroundStyle(VibeAppearance.secondary)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ForEach(SessionProviderPolicy.ids, id: \.self) { provider in
                providerRow(provider)
                if provider != SessionProviderPolicy.ids.last {
                    Divider().overlay(VibeAppearance.surface3).padding(.horizontal, 12)
                }
            }
            if !model.sessionProviderError.isEmpty {
                Text(model.sessionProviderError).font(.caption).foregroundStyle(VibeAppearance.warning)
                    .padding(12).fixedSize(horizontal: false, vertical: true)
            }
        }
        .vibeCard()
        .help(L10n.text("providers.help"))
    }

    private func providerRow(_ provider: String) -> some View {
        let enabled = model.sessionProviders[provider] == true
        let title = ["codex": "Codex", "claude": "Claude Code"][provider] ?? provider
        let tint = provider == "claude" ? VibeAppearance.warning : VibeAppearance.blue
        return HStack(spacing: 10) {
            Text(provider == "claude" ? "✻" : "C")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(tint).frame(width: 22)
                .accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Circle().fill(enabled ? VibeAppearance.accent : VibeAppearance.faint).frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(L10n.text(enabled ? "providers.enabled" : "providers.disabled"))
                .font(.caption).foregroundStyle(VibeAppearance.secondary)
            Toggle(
                title,
                isOn: Binding(
                    get: { model.sessionProviders[provider] == true },
                    set: { value in Task { await model.setSessionProvider(provider, enabled: value) } }
                )
            )
            .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(VibeAppearance.accent)
            .disabled(!model.daemonRunning || model.refreshing)
            .accessibilityIdentifier("session-provider-\(provider)")
            .accessibilityLabel(L10n.text("providers.toggle_access", title))
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
    }
}
