import Foundation
import Security

/// Relay credentials stay in the app's Keychain; the JSON config holds only endpoint and room.
enum RelayCredentialStore {
    private struct Record: Codable {
        let url: String
        let room: String
        let secret: String
    }
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.junweiup.vibepier.relay.v1",
            kSecAttrAccount as String: "configured-relay",
        ]
    }
    static func read(url: String?, room: String?) -> String? {
        guard let url, let room else { return nil }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data, let record = try? JSONDecoder().decode(Record.self, from: data),
            record.url == url, record.room == room
        else { return nil }
        return record.secret
    }
    static func save(_ settings: RelaySettings?) throws {
        guard let settings else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CLIError(L10n.text("core.could_not_remove_the_relay_secret_from_keychain_0", status))
            }
            return
        }
        let data = try JSONEncoder().encode(
            Record(url: settings.url.absoluteString, room: settings.room, secret: settings.secret))
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CLIError(L10n.text("core.could_not_save_the_relay_secret_to_keychain_0", status))
        }
    }
}
