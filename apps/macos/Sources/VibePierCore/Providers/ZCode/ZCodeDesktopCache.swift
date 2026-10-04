import Foundation

/// Bounded native view/receipt state; no native mutation or credential storage.
extension ZCodeDesktop {
    struct Entry {
        var title = ""
        var composer: [String: Any] = [:]
        var models: [Choice] = []
        var modes: [Choice] = []
        var efforts: [Choice] = []
        var verified = false
        var observed: TimeInterval = 0
        var draftEmpty: Bool?
    }
    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: Entry] = [:]
        var receipts: [String: [String: Any]] = [:]
        var pending: [String: (before: String?, text: String, creationCwd: String?)] = [:]
        var currentID: String?
        var settingsStamp: Date?
        var settings: [String: Any] = [:]
        func entry(_ id: String) -> Entry {
            lock.lock()
            defer { lock.unlock() }
            return entries[id] ?? Entry()
        }
        func put(_ entry: Entry, id: String) {
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= 32, entries[id] == nil { entries.removeValue(forKey: entries.keys.first ?? "") }
            entries[id] = entry
        }
        func verified(_ id: String) {
            lock.lock()
            currentID = id
            lock.unlock()
        }
        func isCurrent(_ id: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return currentID == id
        }
        func receipt(_ key: String) -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            return receipts[key]
        }
        func pendingSubmission(_ key: String) -> (before: String?, text: String, creationCwd: String?)? {
            lock.lock()
            defer { lock.unlock() }
            return pending[key]
        }
        func record(
            _ key: String, _ value: [String: Any], before: String? = nil, text: String? = nil,
            creationCwd: String? = nil
        ) throws {
            lock.lock()
            defer { lock.unlock() }
            if value["accepted"] as? Bool == true {
                receipts.removeValue(forKey: key)
                pending.removeValue(forKey: key)
                return
            }
            let nextBytes =
                (text?.utf8.count ?? pending[key]?.text.utf8.count ?? 0)
                + (creationCwd?.utf8.count ?? pending[key]?.creationCwd?.utf8.count ?? 0)
            let otherBytes = pending.filter { $0.key != key }.values.reduce(0) {
                $0 + $1.text.utf8.count + ($1.creationCwd?.utf8.count ?? 0)
            }
            guard receipts[key] != nil || receipts.count < 128, otherBytes + nextBytes <= 8 * 1024 * 1024 else {
                throw CLIError(L10n.text("provider.receipt_capacity"))
            }
            receipts[key] = value
            if let text { pending[key] = (before, text, creationCwd) }
        }
        func desktopSettings(at path: URL) -> [String: Any] {
            let stamp = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate]) as? Date
            lock.lock()
            defer { lock.unlock() }
            if let stamp, stamp == settingsStamp { return settings }
            guard let data = try? Data(contentsOf: path),
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            // Only view identity and enabled agent types are retained; remote relay credentials are excluded.
            settings = value.filter {
                ["enabledBuiltinAgentCliProviders", "lastWorkspaceSession", "lastActiveTabIndex"].contains($0.key)
            }
            settingsStamp = stamp
            return settings
        }
    }
}
