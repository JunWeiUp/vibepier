import Darwin
import Foundation

/// Immutable binary snapshot; each offer revalidates the workspace and file version.
enum SessionVideoFiles {
    static let maximumBytes = 128 * 1024 * 1024
    private static func version(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    static func read(
        _ request: [String: Any], root: URL, device: String, thread: String,
        offer: BinaryMediaFiles.Offer = BinaryMediaFiles.currentOffer
    ) throws -> [String:
        Any]
    {
        try BinaryMediaFiles.requireCurrent(request)
        let path = request["path"] as? String ?? ""
        guard !path.contains("\0"), path.utf8.count <= 4_096 else {
            throw CLIError(L10n.text("session.invalid_file_path"))
        }
        var selectedPath = path
        // Some replies repeat a workspace suffix in a relative output path.
        // Only repair a missing path, and keep the resolved file inside this workspace.
        if !path.hasPrefix("/"), !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let components = path.split(separator: "/").map(String.init)
            let rootComponents = root.standardizedFileURL.pathComponents
            if !components.contains(".."), !components.contains("."), components.count > 1 {
                for count in stride(from: min(components.count - 1, rootComponents.count), through: 1, by: -1) {
                    guard Array(components.prefix(count)) == Array(rootComponents.suffix(count)) else { continue }
                    let candidate = components.dropFirst(count).joined(separator: "/")
                    if FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
                        selectedPath = candidate
                        break
                    }
                }
            }
        }
        let url = try SessionMarkdownFiles.resolve(selectedPath, root: root)
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
        guard offset == 0 else { throw CLIError(L10n.text("session.invalid_file_path")) }
        let snapshot = try BinaryMediaFiles.snapshot(fd: fd, size: Int(before.st_size))
        var after = stat()
        guard fstat(fd, &after) == 0, version(after) == revision else {
            snapshot.discard()
            throw CLIError(L10n.text("session.the_file_is_being_updated_retry"))
        }
        let profile = try offer(snapshot, device, thread, "video/mp4")
        return [
            "path": SessionMarkdownFiles.relative(url, root: root), "size": Int(before.st_size),
            "version": revision, "offset": 0, "nextOffset": -1, "mime": "video/mp4", "binary": profile,
        ]
    }
}
