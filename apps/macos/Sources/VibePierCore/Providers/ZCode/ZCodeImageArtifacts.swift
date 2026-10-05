import Darwin
import Foundation

/// Native ZCode stores attachment data URLs as prefixed tool-result UUID files.
/// Only a trusted reference from the selected session can select one exact artifact.
enum ZCodeImageArtifacts {
    static func jpeg(
        _ source: String, session: String, root path: String, maxPixel: Int, maximumBytes: Int
    ) throws -> Data {
        let unavailable = CLIError(L10n.text("session.image_preview_unavailable"))
        guard let uri = URLComponents(string: source), uri.scheme == "zcode-artifact",
            uri.host == session, uri.user == nil, uri.password == nil, uri.port == nil,
            uri.query == nil, uri.fragment == nil,
            session.hasPrefix("sess_"), session.utf8.count <= 256,
            session.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains(
                    $0)
            })
        else { throw unavailable }
        let id = String(uri.path.dropFirst())
        guard uri.path.hasPrefix("/tool-result-"), id.count == 48,
            let uuid = UUID(uuidString: String(id.dropFirst(12))),
            "tool-result-" + uuid.uuidString.lowercased() == id
        else { throw unavailable }
        let root = try SessionMarkdownFiles.root(path)
        let folder = root.appendingPathComponent(session)
        let fd = try SessionMarkdownFiles.openSafe(folder, root: root, directory: true)
        guard let directory = fdopendir(fd) else {
            Darwin.close(fd)
            throw unavailable
        }
        defer { closedir(directory) }
        var match: String?
        var count = 0
        errno = 0
        while let entry = readdir(directory) {
            count += 1
            guard count <= 10_000 else { throw unavailable }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            // Attachment persistence in the inspected native CLI uses text/plain data URLs.
            guard name == id + ".txt" || name.hasSuffix("-" + id + ".txt") else { continue }
            guard match == nil else { throw unavailable }
            match = name
        }
        guard errno == 0, let match else { throw unavailable }
        let bytes = try SessionMarkdownFiles.readContainedFile(
            folder.appendingPathComponent(match), root: root, maximumBytes: 48 * 1024 * 1024)
        guard let dataURL = String(data: bytes, encoding: .utf8), dataURL.hasPrefix("data:image/") else {
            throw unavailable
        }
        return try ConversationReply.jpeg(dataURL, cwd: root.path, maxPixel: maxPixel, maximumBytes: maximumBytes)
    }
}
