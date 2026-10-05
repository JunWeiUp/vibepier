import Foundation

extension ZCodeDesktop {
    /// Presentation data only. Native choices are revalidated at the mutation boundary.
    final class OptionCatalog: @unchecked Sendable {
        private struct Stored: Codable {
            let version: Int
            let composer: [String: String]
            let models: [Choice]
            let modes: [Choice]
            let efforts: [Choice]
        }
        private let lock = NSLock()
        private let reader = NSLock()
        private let file: URL?
        private var value: Entry?
        private var attempted = false
        init(file: URL? = nil) {
            self.file = file
            if let file, let bytes = try? ReceiptJournalFile.read(file, limit: 512 * 1024),
                let saved = try? JSONDecoder().decode(Stored.self, from: bytes), saved.version == 2
            {
                var entry = Entry()
                entry.composer = saved.composer
                entry.models = saved.models
                entry.modes = saved.modes
                entry.efforts = saved.efforts
                if Self.valid(entry) { value = entry }
            }
        }
        func cached() -> Entry? { lock.withLock { value } }
        /// Startup reads once; failed reads retain the last valid presentation catalog.
        func load(refresh: Bool = false, read: () throws -> Entry) throws -> Entry {
            if !refresh, let value = cached() { return value }
            return try reader.withLock {
                if !refresh, let value = cached() { return value }
                lock.withLock { attempted = true }
                let source = try read()
                var entry = Entry()
                entry.models = source.models
                entry.modes = source.modes
                entry.efforts = source.efforts
                entry.composer = source.composer.filter {
                    ["model", "modelLabel", "mode", "modeLabel", "effort", "effortLabel", "executionMode"].contains(
                        $0.key)
                }
                guard Self.valid(entry) else { throw CLIError(L10n.text("core.invalid_receipt")) }
                lock.withLock { value = entry }
                if let file {
                    let composer = entry.composer.filter {
                        ["model", "modelLabel", "mode", "modeLabel", "effort", "effortLabel", "executionMode"].contains(
                            $0.key)
                    }.compactMapValues { $0 as? String }
                    let saved = Stored(
                        version: 2, composer: composer, models: entry.models, modes: entry.modes, efforts: entry.efforts
                    )
                    if let bytes = try? JSONEncoder().encode(saved) {
                        do {
                            let current = try ReceiptJournalFile.read(file, limit: 512 * 1024)
                            try ReceiptJournalFile.commit(
                                bytes, to: file, expected: current.map(SessionReceiptJournal.digest), limit: 512 * 1024)
                        } catch {  // Presentation persistence failure never authorizes an action.
                        }
                    }
                }
                return entry
            }
        }
        func warm(canReadNative: Bool = true, read: () throws -> Entry) {
            guard canReadNative else { return }
            let shouldRead = lock.withLock {
                if attempted { return false }
                attempted = true
                return true
            }
            if shouldRead { _ = try? load(refresh: true, read: read) }
        }
        private static func valid(_ entry: Entry) -> Bool {
            guard !entry.models.isEmpty, entry.models.count <= 512, entry.modes.count <= 16, entry.efforts.count <= 32,
                let model = entry.composer["model"] as? String, entry.models.contains(where: { $0.id == model }),
                let mode = entry.composer["mode"] as? String, mode != "plan", modeLabels[mode] != nil,
                let execution = entry.composer["executionMode"] as? String, ["default", "plan"].contains(execution),
                entry.modes.contains(where: { $0.id == mode })
            else { return false }
            return [entry.models, entry.modes, entry.efforts].allSatisfy { rows in
                Set(rows.map(\.id)).count == rows.count
                    && rows.enumerated().allSatisfy { index, row in
                        row.ordinal == index && !row.id.isEmpty && row.id.utf8.count <= 256 && !row.signature.isEmpty
                            && row.signature.count <= 256 && !row.label.isEmpty && row.label.count <= 1024
                            && row.title.count <= 2048
                    }
            }
        }
    }
}
