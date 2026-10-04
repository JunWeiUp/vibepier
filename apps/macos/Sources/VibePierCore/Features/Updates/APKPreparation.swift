import CryptoKit
import Foundation

/// Cancellation never frees a worker while a native file operation is still running.
final class APKPreparationJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CLIError(L10n.text("updates.preparation_cancelled")) }
    }
}

struct PreparedAPK: Sendable {
    let id: String
    let name: String
    let file: URL
    let size: Int
    let sha256: String

    /// Opens only the explicitly selected file. All resulting snapshots are private and immutable.
    static func prepare(_ url: URL, root: URL, job: APKPreparationJob) throws -> PreparedAPK {
        try job.check()
        guard url.pathExtension.lowercased() == "apk" else {
            throw CLIError(L10n.text("control.choose_a_complete_apk_file_split_apks_and_xapk_are_not_supported"))
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= PhoneAPK.maxSize else {
            throw CLIError(L10n.text("control.the_apk_must_be_between_1_byte_and_512_mb"))
        }
        try job.check()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let snapshot = root.appendingPathComponent(id + ".apk")
        guard
            FileManager.default.createFile(atPath: snapshot.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CLIError(L10n.text("updates.invalid_metadata")) }
        do {
            let output = try FileHandle(forWritingTo: snapshot)
            defer { try? output.close() }
            var hash = SHA256()
            var total = 0
            while true {
                try job.check()
                guard let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty else { break }
                total += bytes.count
                guard total <= size else {
                    throw CLIError(L10n.text("control.the_file_changed_while_being_copied_select_it_again"))
                }
                try output.write(contentsOf: bytes)
                hash.update(data: bytes)
            }
            guard total == size else {
                throw CLIError(L10n.text("control.the_file_changed_while_being_copied_select_it_again"))
            }
            try output.synchronize()
            try job.check()
            return PreparedAPK(
                id: id, name: String(url.lastPathComponent.prefix(160)), file: snapshot, size: size,
                sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
    }
    func discard() { try? FileManager.default.removeItem(at: file) }
}

/// Rejects overflow immediately, without retaining an unbounded queue behind blocked file opens.
final class APKPreparationWorkers: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private let capacity: Int
    private let queue = DispatchQueue(label: "vibepier.apk-preparation", qos: .userInitiated, attributes: .concurrent)
    init(capacity: Int = 2) { self.capacity = capacity }
    @discardableResult
    func submit(_ work: @escaping @Sendable () -> Void) -> Bool {
        guard
            lock.withLock({
                guard running < capacity else { return false }
                running += 1
                return true
            })
        else { return false }
        queue.async {
            defer { self.lock.withLock { self.running -= 1 } }
            work()
        }
        return true
    }
}
