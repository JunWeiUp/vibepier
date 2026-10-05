import Foundation

/// Mac-only preferences, separate from portable settings, logs and phone state.
/// A saved empty record prevents cleared passwords from returning through legacy migration.
final class UnlockPreferences: @unchecked Sendable {
    private struct Record: Codable {
        var version = 1
        let account: String
        let password: String?
    }
    private let mutex = NSLock()
    private let file: URL
    private let account: String
    private let legacyRead: () throws -> String?
    private let legacyRemove: () -> Void

    init(file: URL, account: String, legacyRead: @escaping () throws -> String?, legacyRemove: @escaping () -> Void) {
        self.file = file
        self.account = account
        self.legacyRead = legacyRead
        self.legacyRemove = legacyRemove
    }

    func read() throws -> String? {
        try mutex.withLock {
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                        (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4096
                    else { throw failure("invalid") }
                    let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
                    guard record.version == 1, record.account == account,
                        record.password.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true
                    else { throw failure("invalid") }
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    return record.password
                } catch { throw failure("read") }
            }
            let password = try legacyRead()
            guard password.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { throw failure("invalid") }
            try persist(password)
            // Only remove the legacy item after the preferences commit succeeds.
            legacyRemove()
            return password
        }
    }

    func save(_ password: String?) throws {
        try mutex.withLock {
            guard password.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { throw failure("invalid") }
            try persist(password)
            legacyRemove()
        }
    }

    private func persist(_ password: String?) throws {
        let parent = file.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".unlock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw failure("save") }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            let data = try JSONEncoder().encode(Record(account: account, password: password))
            guard
                FileManager.default.createFile(
                    atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
            else {
                throw failure("save")
            }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.synchronize()
            guard rename(temporary.path, file.path) == 0 else { throw failure("save") }
        } catch { throw failure("save") }
    }

    private func failure(_ operation: String) -> CLIError {
        switch operation {
        case "invalid": CLIError(L10n.text("core.unlock_preferences_invalid_failed"))
        case "read": CLIError(L10n.text("core.unlock_preferences_read_failed"))
        default: CLIError(L10n.text("core.unlock_preferences_save_failed"))
        }
    }
}
