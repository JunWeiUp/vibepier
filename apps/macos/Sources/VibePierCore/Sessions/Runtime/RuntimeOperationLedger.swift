import CryptoKit
import Darwin
import Foundation

/// Defense in depth for local drivers. SessionReceiptJournal remains the phone
/// authority. Records contain hashes and native identities, never prompt bodies.
final class RuntimeOperationLedger {
    private struct Record: Codable {
        let deviceID: String
        let fingerprint: String
        let commandHash: String
        var receipt: RuntimeReceipt
    }
    private struct State: Codable {
        var version = 1
        var records: [String: Record] = [:]
    }
    private let url: URL
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    func reserve(_ command: RuntimeCommand, context: RuntimeOperationContext) throws -> RuntimeReceipt? {
        guard !context.trustedDeviceID.isEmpty, context.trustedDeviceID.utf8.count <= 256,
            !context.operationID.isEmpty, context.operationID.utf8.count <= 256,
            !context.journalReservationID.isEmpty, context.journalReservationID.utf8.count <= 256,
            context.requestFingerprint.count == 64,
            context.requestFingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw RuntimeDriverError.invalidRequest }
        let encoded = try Self.encodeCommand(command)
        guard encoded.count <= 280_000 else { throw RuntimeDriverError.invalidRequest }
        let commandHash = Self.hash(encoded)
        return try transaction { state in
            let key = Self.key(context)
            if let record = state.records[key] {
                guard record.deviceID == context.trustedDeviceID,
                    record.fingerprint == context.requestFingerprint, record.commandHash == commandHash
                else { throw RuntimeDriverError.operationConflict }
                return record.receipt
            }
            guard state.records.count < 2048 else { throw RuntimeDriverError.quotaExceeded }
            state.records[key] = Record(
                deviceID: context.trustedDeviceID,
                fingerprint: context.requestFingerprint, commandHash: commandHash,
                receipt: RuntimeReceipt(
                    operationID: context.operationID, status: .unknown,
                    session: context.session, reason: "native_confirmation_pending"))
            return nil
        }
    }

    func record(_ receipt: RuntimeReceipt, context: RuntimeOperationContext) throws {
        try transaction { state in
            let key = Self.key(context)
            guard var old = state.records[key], old.deviceID == context.trustedDeviceID,
                old.fingerprint == context.requestFingerprint, receipt.operationID == context.operationID
            else { throw RuntimeDriverError.operationConflict }
            if old.receipt.status == .confirmed { return }
            old.receipt = receipt
            state.records[key] = old
        }
    }

    func lookup(_ context: RuntimeOperationContext) throws -> RuntimeReceipt {
        try transaction(write: false) { state in
            guard let record = state.records[Self.key(context)] else {
                return RuntimeReceipt(
                    operationID: context.operationID, status: .unknown,
                    session: context.session, reason: "native_confirmation_unavailable")
            }
            guard record.deviceID == context.trustedDeviceID, record.fingerprint == context.requestFingerprint
            else { throw RuntimeDriverError.operationConflict }
            return record.receipt
        }
    }

    func matchesCommand(_ command: RuntimeCommand, context: RuntimeOperationContext) throws -> Bool {
        let hash = Self.hash(try Self.encodeCommand(command))
        return try transaction(write: false) { state in
            guard let record = state.records[Self.key(context)], record.deviceID == context.trustedDeviceID,
                record.fingerprint == context.requestFingerprint
            else { return false }
            return record.commandHash == hash
        }
    }

    func knownSessions(adapterID: String, instanceID: String) throws -> [RuntimeSessionReference] {
        try transaction(write: false) { state in
            Array(
                Set(
                    state.records.values.compactMap { record in
                        guard record.receipt.status == .confirmed, let ref = record.receipt.session,
                            ref.adapterID == adapterID, ref.instanceID == instanceID
                        else { return nil }
                        return ref
                    }))
        }
    }

    private static func key(_ context: RuntimeOperationContext) -> String {
        hash(Data((context.trustedDeviceID + "\0" + context.operationID).utf8))
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func encodeCommand(_ command: RuntimeCommand) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(command)
    }

    private func transaction<T>(write: Bool = true, _ body: (inout State) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let directory = url.deletingLastPathComponent()
        try RuntimePrivateStorage.ensureDirectory(directory)
        let fd = open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuntimeDriverError.storageUnavailable }
        defer {
            _ = flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw RuntimeDriverError.storageUnavailable }
        var state = State()
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try RuntimePrivateStorage.read(url, limit: 4_194_304)
            do { state = try JSONDecoder().decode(State.self, from: bytes) } catch {
                throw RuntimeDriverError.storageUnavailable
            }
            guard state.version == 1, state.records.count <= 2048 else { throw RuntimeDriverError.storageUnavailable }
        }
        let result = try body(&state)
        if write {
            let data = try JSONEncoder().encode(state)
            guard data.count <= 4_194_304 else { throw RuntimeDriverError.quotaExceeded }
            try RuntimePrivateStorage.write(data, to: url)
        }
        return result
    }
}

enum RuntimePrivateStorage {
    static func ensureDirectory(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw RuntimeDriverError.invalidRequest }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_uid == getuid(), info.st_mode & 0o077 == 0
        else { throw RuntimeDriverError.storageUnavailable }
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RuntimeDriverError.storageUnavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
            (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit
        else { throw RuntimeDriverError.storageUnavailable }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= limit else { throw RuntimeDriverError.storageUnavailable }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
    static func write(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".runtime-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuntimeDriverError.storageUnavailable }
        defer {
            Darwin.close(fd)
            unlink(temporary.path)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw RuntimeDriverError.storageUnavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw RuntimeDriverError.storageUnavailable }
        let directoryFD = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw RuntimeDriverError.storageUnavailable }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw RuntimeDriverError.storageUnavailable }
    }
}
