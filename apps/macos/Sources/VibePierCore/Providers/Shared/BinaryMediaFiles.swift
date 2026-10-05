import CryptoKit
import Darwin
import Foundation

/// Private immutable snapshots: provider validation owns the source; the helper
/// receives only this copy and an opaque, per-device download capability.
enum BinaryMediaFiles {
    struct Snapshot {
        let file: URL
        let size: Int
        let digest: String
        func discard() { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }

    private static func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vibepier-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("snapshot")
    }

    static func snapshot(_ bytes: Data) throws -> Snapshot {
        guard !bytes.isEmpty, bytes.count <= SessionVideoFiles.maximumBytes else {
            throw CLIError(L10n.text("files.video_size_limit"))
        }
        let file = try location()
        guard FileManager.default.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600])
        else {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            throw CLIError(L10n.text("session.could_not_read_the_file_retry"))
        }
        return Snapshot(
            file: file, size: bytes.count, digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    static func snapshot(fd: Int32, size: Int) throws -> Snapshot {
        let file = try location()
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        guard size > 0, size <= SessionVideoFiles.maximumBytes,
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw CLIError(L10n.text("session.could_not_read_the_file_retry"))
        }
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }
        var hash = SHA256()
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while offset < size {
            let count = pread(fd, &buffer, min(buffer.count, size - offset), off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw CLIError(L10n.text("session.could_not_read_the_file_retry")) }
            let bytes = Data(buffer.prefix(count))
            hash.update(data: bytes)
            try output.write(contentsOf: bytes)
            offset += count
        }
        try output.synchronize()
        keep = true
        return Snapshot(file: file, size: size, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func offer(
        _ snapshot: Snapshot, device: String, thread: String, mime: String, files: BinaryFileTransfers = .shared
    ) throws -> [String: Any] {
        let scope =
            SHA256.hash(data: Data(thread.utf8)).map { String(format: "%02x", $0) }.joined() + ":" + UUID().uuidString
        guard
            let profile = files.mediaOffer(
                device: device, scope: scope, file: snapshot.file,
                size: snapshot.size, mime: mime, digest: snapshot.digest)
        else {
            snapshot.discard()
            throw CLIError(L10n.text("session.image_preview_unavailable"))
        }
        return profile
    }
}
