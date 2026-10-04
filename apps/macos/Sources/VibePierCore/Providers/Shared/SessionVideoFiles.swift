import Darwin
import Foundation

/// Bounded encrypted RPC chunks; each read revalidates the workspace and the same file version.
enum SessionVideoFiles {
    static let maximumBytes = 128 * 1024 * 1024
    static let chunkBytes = 128 * 1024
    private static func version(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    static func read(_ request: [String: Any], root: URL) throws -> [String: Any] {
        let url = try SessionMarkdownFiles.resolve(request["path"] as? String ?? "", root: root)
        guard SessionMarkdownFiles.contains(url.path, root: root.path), url.pathExtension.lowercased() == "mp4" else {
            throw CLIError(L10n.text("files.video_workspace_only"))
        }
        let fd = try SessionMarkdownFiles.openSafe(url, root: root)
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size > 0, before.st_size <= maximumBytes
        else { throw CLIError(L10n.text("files.video_size_limit")) }
        let offset = request["offset"] as? Int ?? 0
        let revision = version(before)
        guard offset >= 0, offset < before.st_size,
            offset == 0 || request["version"] as? String == revision
        else { throw CLIError(L10n.text("session.the_file_is_being_updated_retry")) }
        var bytes = [UInt8](repeating: 0, count: min(chunkBytes, Int(before.st_size) - offset))
        let expected = bytes.count
        var received = 0
        while received < bytes.count {
            let count = bytes.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress!.advanced(by: received), expected - received, off_t(offset + received))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw CLIError(L10n.text("session.could_not_read_the_file_retry")) }
            received += count
        }
        var after = stat()
        guard fstat(fd, &after) == 0, version(after) == revision else {
            throw CLIError(L10n.text("session.the_file_is_being_updated_retry"))
        }
        return [
            "path": SessionMarkdownFiles.relative(url, root: root), "size": Int(before.st_size),
            "version": revision, "offset": offset,
            "nextOffset": offset + bytes.count == before.st_size ? -1 : offset + bytes.count,
            "video": Data(bytes).base64EncodedString(), "mime": "video/mp4",
        ]
    }
}
