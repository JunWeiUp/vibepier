import Foundation

/// Move a legacy development secret only after secure storage succeeds; never erase the only copy.
enum RelayCredentialMigration {
    static func migrate(
        _ config: Config,
        store: (RelaySettings) throws -> Void = { try RelayCredentialStore.save($0) },
        persist: (Config) throws -> Void = { try $0.save() }
    ) throws -> Config {
        guard let secret = config.relaySecret else { return config }
        guard
            let settings = RelaySettings(
                url: config.relayURL, room: config.relayRoom, secret: secret,
                dnsRecovery: config.relayDNSRecovery ?? false)
        else { throw CLIError(L10n.text("core.the_legacy_development_relay_settings_are_invalid_correct_the_url_ro")) }
        try store(settings)
        var clean = config
        clean.relayURL = settings.url.absoluteString
        clean.relayRoom = settings.room
        clean.relaySecret = nil
        try persist(clean)
        return clean
    }
}
