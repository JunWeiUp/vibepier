import SwiftUI
import VibePierCore

struct AppVersion {
    static let current = AppVersion(info: Bundle.main.infoDictionary ?? [:])

    let version: String?
    let build: String?

    init(info: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let text = info[key] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
    }

    var label: String {
        guard let version, let build else { return L10n.text("mac.app_version_unavailable") }
        return L10n.text("mac.app_version", version, build)
    }
}

struct AppVersionBadge: View {
    var version: AppVersion = .current

    var body: some View {
        Text(version.label)
            .font(.caption)
            .foregroundStyle(VibeAppearance.secondary)
            .textSelection(.enabled)
            .help(L10n.text("mac.app_version_help"))
    }
}
