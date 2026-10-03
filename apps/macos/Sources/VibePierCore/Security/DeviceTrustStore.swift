// SPDX-License-Identifier: MIT

import Foundation
import Security

/// A transactionally persisted, thread-safe trust source for every transport and feature.
final class DeviceTrustStore: @unchecked Sendable {
    static let changed = Notification.Name("vibepier.device-trust-changed")
    static let shared = DeviceTrustStore(read: { try DeviceKeychain.read() }, write: { try DeviceKeychain.write($0) })

    struct Record: Codable, Equatable {
        let name: String
        let key: Data
    }
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var loadError: Error?
    private let persist: @Sendable (Data) throws -> Void

    init(read: () throws -> Data?, write: @escaping @Sendable (Data) throws -> Void) {
        persist = write
        do {
            if let data = try read() {
                records = try JSONDecoder().decode([String: Record].self, from: data)
                guard records.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.key.count == 32 }) else {
                    throw CLIError(L10n.text("core.device_authorization_storage_is_invalid_resolve_it_on_the_mac"))
                }
            }
        } catch {
            records = [:]
            loadError = error
        }
    }

    func key(for id: String) -> Data? { lock.withLock { records[id]?.key } }

    var phones: [AuthorizedPhone] {
        lock.withLock { records.map { .init(id: $0.key, name: $0.value.name) }.sorted { $0.name < $1.name } }
    }

    func authorize(id: String, name: String, key: Data) throws {
        try lock.withLock {
            if let loadError { throw loadError }
            guard UUID(uuidString: id) != nil, key.count == 32 else {
                throw CLIError(L10n.text("core.invalid_device_authorization"))
            }
            var next = records
            next[id] = Record(name: String(name.prefix(60)), key: key)
            try persist(JSONEncoder().encode(next))
            records = next
        }
        NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: ["device": id, "revoked": false])
    }

    func revoke(_ id: String) throws {
        try lock.withLock {
            if let loadError { throw loadError }
            var next = records
            next.removeValue(forKey: id)
            try persist(JSONEncoder().encode(next))
            records = next
        }
        NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: ["device": id, "revoked": true])
    }
}

private enum DeviceKeychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.junweiup.vibepier.devices.v1",
            kSecAttrAccount as String: "phones",
        ]
    }

    static func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CLIError(L10n.text("core.could_not_read_device_authorization_from_keychain_0", status))
        }
        return data
    }

    static func write(_ data: Data) throws {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CLIError(L10n.text("core.could_not_save_device_authorization_to_keychain_0", status))
        }
    }
}
