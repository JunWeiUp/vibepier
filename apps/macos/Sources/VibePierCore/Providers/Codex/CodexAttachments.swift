import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO

/// Only caller-selected files enter the composer. Attachment identifiers are bound to device and thread.
final class CodexAttachments {
    private struct Record: Codable {
        let device: String
        let thread: String
        let id: String
        let name: String
        let path: String
        let mime: String
        let size: Int
        var complete: Bool
        let managed: Bool
        var sourcePath: String?
        var used: Bool = false
    }
    private let root: URL
    private let files: BinaryFileTransfers
    private var records: [String: Record] = [:]
    private var manifest: URL { root.appendingPathComponent("manifest.json") }
    init(
        root: URL = Paths.supportDirectory.appendingPathComponent("codex-attachments"),
        files: BinaryFileTransfers = .shared
    ) throws {
        self.root = root
        self.files = files
        if FileManager.default.fileExists(atPath: manifest.path) {
            let stored = try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: manifest))
            for (id, value) in stored {
                guard UUID(uuidString: id) != nil, UUID(uuidString: value.id) != nil,
                    Self.key(id) == Self.key(value.id), records[Self.key(id)] == nil
                else { throw CLIError(L10n.text("session.attachment_id_conflict")) }
                records[Self.key(id)] = value
            }
        }
    }
    private static func key(_ id: String) -> String { id.lowercased() }
    private func record(_ id: String, device: String, thread: String) throws -> Record {
        guard let record = records[Self.key(id)], record.device == device, record.thread == thread else {
            throw CLIError(L10n.text("session.the_attachment_is_missing_or_belongs_to_another_session"))
        }
        return record
    }
    private func save() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(records).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
    private func info(_ record: Record) -> [String: Any] {
        let result: [String: Any] = [
            "attachmentId": record.id, "name": record.name, "mime": record.mime, "size": record.size,
            "complete": record.complete,
        ]
        return result
    }
    func start(_ request: [String: Any], device: String, thread: String) throws -> [String: Any] {
        guard let id = request["attachmentId"] as? String, UUID(uuidString: id) != nil,
            let size = request["size"] as? Int, size > 0, size <= 10 * 1024 * 1024,
            let rawName = request["name"] as? String, !rawName.isEmpty, rawName.utf8.count <= 256
        else { throw CLIError(L10n.text("session.attachments_must_be_between_1_byte_and_10_mb_and_have_a_valid_name")) }
        let name = URL(fileURLWithPath: rawName).lastPathComponent
        guard name != ".", name != "..", !name.contains("\n"), !name.contains("\0") else {
            throw CLIError(L10n.text("session.invalid_attachment_name"))
        }
        let mime = String((request["mime"] as? String ?? "application/octet-stream").prefix(100))
        if let old = records[Self.key(id)] {
            guard old.device == device, old.thread == thread, old.name == name, old.size == size, old.mime == mime
            else { throw CLIError(L10n.text("session.attachment_id_conflict")) }
            return startInfo(old, request: request)
        }
        guard records.values.filter({ !$0.complete && $0.device == device }).count < 6 else {
            throw CLIError(L10n.text("session.too_many_incomplete_attachments_remove_them_or_finish_uploading_firs"))
        }
        let directory = root.appendingPathComponent(Self.key(id), isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard mkdir(directory.path, 0o700) == 0 else {
            throw CLIError(L10n.text("session.attachment_id_conflict"))
        }
        let file = directory.appendingPathComponent(name)
        guard
            FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        else { throw CLIError(L10n.text("session.could_not_create_the_attachment")) }
        let value = Record(
            device: device, thread: thread, id: Self.key(id), name: name, path: file.path, mime: mime, size: size,
            complete: false, managed: true)
        records[Self.key(id)] = value
        do { try save() } catch {
            records.removeValue(forKey: Self.key(id))
            throw error
        }
        return startInfo(value, request: request)
    }
    private func startInfo(_ value: Record, request: [String: Any]) -> [String: Any] {
        var result = info(value)
        if request["binaryVersion"] as? Int == 1, !value.complete,
            let binary = files.uploadOffer(device: value.device, scope: value.thread, id: value.id, size: value.size)
        {
            result["binary"] = binary
        }
        return result
    }
    /// Internal byte import for Mac-generated attachments. No JSON/base64 upload RPC is accepted here.
    func appendImportedData(_ data: Data, id: String, offset: Int, device: String, thread: String) throws -> [String:
        Any]
    {
        let value = try record(id, device: device, thread: thread)
        guard value.managed, !value.complete, offset >= 0, !data.isEmpty, data.count <= 128 * 1024,
            offset <= value.size, data.count <= value.size - offset
        else { throw CLIError(L10n.text("session.invalid_attachment_chunk")) }
        let file = try FileHandle(forUpdating: URL(fileURLWithPath: value.path))
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard offset <= length else {
            throw CLIError(L10n.text("session.attachment_chunks_are_missing_upload_it_again"))
        }
        if offset + data.count <= length {
            try file.seek(toOffset: UInt64(offset))
            guard try file.read(upToCount: data.count) == data else {
                throw CLIError(L10n.text("session.attachment_chunk_content_conflicts"))
            }
        } else {
            // Rewriting an incomplete chunk at its original offset is idempotent after disconnect/crash.
            try file.seek(toOffset: UInt64(offset))
            try file.write(contentsOf: data)
            try file.synchronize()
        }
        return ["attachmentId": id, "offset": offset + data.count]
    }
    func complete(_ request: [String: Any], device: String, thread: String) throws -> [String: Any] {
        let id = request["attachmentId"] as? String ?? ""
        var value = try record(id, device: device, thread: thread)
        if let ticket = request["binaryTicket"] as? String, !value.complete {
            let staging = try files.claimUpload(device: device, scope: thread, id: id, ticket: ticket, size: value.size)
            let source = try FileHandle(forReadingFrom: staging)
            defer { try? source.close() }
            let target = try FileHandle(forWritingTo: URL(fileURLWithPath: value.path))
            defer { try? target.close() }
            try target.truncate(atOffset: 0)
            while let bytes = try source.read(upToCount: 256 * 1024), !bytes.isEmpty {
                try target.write(contentsOf: bytes)
            }
            try target.synchronize()
        }
        let bytes = try contents(value)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard bytes.count == value.size, request["sha256"] as? String == hash else {
            throw CLIError(L10n.text("session.attachment_verification_failed_upload_it_again"))
        }
        if value.mime.hasPrefix("image/")
            && CGImageSourceCreateWithData(bytes as CFData, nil) == nil
        {
            throw CLIError(L10n.text("session.the_image_format_cannot_be_read"))
        }
        value.complete = true
        let previous = records[Self.key(id)]
        records[Self.key(id)] = value
        do { try save() } catch {
            records[Self.key(id)] = previous
            throw error
        }
        files.cancelUpload(device: device, scope: thread, id: id)
        return info(value)
    }
    func reference(_ relative: String, cwd: String, id: String, device: String, thread: String) throws -> [String: Any]
    {
        guard UUID(uuidString: id) != nil else { throw CLIError(L10n.text("session.invalid_attachment_id")) }
        let url = try Self.workspaceFile(relative, cwd: cwd)
        if let old = records[Self.key(id)] {
            guard old.device == device, old.thread == thread, old.managed, old.sourcePath == url.path else {
                throw CLIError(L10n.text("session.attachment_id_conflict"))
            }
            return info(old)
        }
        // Read through the existing descriptor-based workspace boundary before storing an
        // immutable private copy. The provider must never reopen a mutable workspace path.
        let bytes = try SessionMarkdownFiles.readReferencedFile(
            url.path, cwd: cwd, referencedPaths: [], maximumBytes: 10 * 1024 * 1024)
        guard !bytes.isEmpty
        else { throw CLIError(L10n.text("session.only_files_between_1_byte_and_10_mb_are_supported")) }
        let ext = url.pathExtension.lowercased()
        let mime = ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) ? "image/" + ext : "application/octet-stream"
        if mime.hasPrefix("image/"), CGImageSourceCreateWithData(bytes as CFData, nil) == nil {
            throw CLIError(L10n.text("session.the_image_format_cannot_be_read"))
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(Self.key(id), isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else {
            throw CLIError(L10n.text("session.could_not_create_the_attachment"))
        }
        let file = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try bytes.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let value = Record(
                device: device, thread: thread, id: Self.key(id), name: url.lastPathComponent, path: file.path,
                mime: mime,
                size: bytes.count, complete: true, managed: true, sourcePath: url.path)
            records[Self.key(id)] = value
            try save()
            return info(value)
        } catch {
            records.removeValue(forKey: Self.key(id))
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    func remove(_ id: String, device: String, thread: String) throws {
        files.cancelUpload(device: device, scope: thread, id: id)
        let value = try record(id, device: device, thread: thread)
        if value.used { return }
        if value.managed {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(value.id, isDirectory: true))
        }
        records.removeValue(forKey: Self.key(id))
        try save()
    }
    func selected(_ ids: [String], device: String, thread: String, markUsed: Bool = true) throws -> (
        input: [[String: Any]], files: [[String: Any]], images: [[String: Any]]
    ) {
        guard ids.count <= 6, Set(ids.map(Self.key)).count == ids.count else {
            throw CLIError(L10n.text("session.up_to_6_distinct_attachments_are_supported"))
        }
        var input: [[String: Any]] = []
        var files: [[String: Any]] = []
        var images: [[String: Any]] = []
        for id in ids {
            var value = try record(id, device: device, thread: thread)
            guard value.managed, value.complete, FileManager.default.fileExists(atPath: value.path) else {
                throw CLIError(L10n.text("session.the_attachment_is_incomplete_or_no_longer_available"))
            }
            if markUsed {
                value.used = true
                records[Self.key(id)] = value
            }
            let metadata: [String: Any] = ["id": id, "fsPath": value.path, "path": value.path, "label": value.name]
            if value.mime.hasPrefix("image/") {
                input.append(["type": "localImage", "path": value.path])
                images.append(metadata)
            } else {
                input.append([
                    "type": "text",
                    "text": L10n.text("session.user_attached_file_0_local_path_on_the_mac_1", value.name, value.path),
                    "text_elements": [],
                ])
                files.append(metadata)
            }
        }
        if markUsed && !ids.isEmpty { try save() }
        return (input, files, images)
    }
    func preview(_ id: String, device: String, thread: String) throws -> [String: Any] {
        let value = try record(id, device: device, thread: thread)
        guard value.complete, value.mime.hasPrefix("image/") else {
            throw CLIError(L10n.text("session.could_not_preview_this_attachment"))
        }
        let bytes = try contents(value)
        guard value.managed, value.complete, value.mime.hasPrefix("image/"),
            let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary),
            let jpeg = NSBitmapImageRep(cgImage: image).representation(
                using: .jpeg, properties: [.compressionFactor: 0.65]), jpeg.count <= 180_000
        else { throw CLIError(L10n.text("session.could_not_preview_this_attachment")) }
        return ["attachmentId": id, "image": jpeg.base64EncodedString()]
    }
    func claudePrompt(_ text: String, ids: [String], device: String, thread: String) throws -> ClaudePrompt {
        guard ids.count <= 6, Set(ids.map(Self.key)).count == ids.count else {
            throw CLIError(L10n.text("session.up_to_6_distinct_attachments_are_supported"))
        }
        var images: [ClaudePrompt.Image] = []
        var references: [String] = []
        for id in ids {
            let value = try record(id, device: device, thread: thread)
            guard value.managed, value.complete else {
                throw CLIError(L10n.text("session.the_attachment_is_incomplete_or_no_longer_available"))
            }
            if value.mime.hasPrefix("image/") {
                images.append(try ClaudePrompt.image(contents(value)))
            } else {
                references.append(
                    L10n.text("session.user_attached_file_0_local_path_on_the_mac_1", value.name, value.path))
            }
        }
        let prompt = try ClaudePrompt(
            text: ([text] + references).filter { !$0.isEmpty }.joined(separator: "\n\n"), images: images)
        _ = try selected(ids, device: device, thread: thread)  // Retain exact managed files before starting the child.
        return prompt
    }
    private func contents(_ value: Record) throws -> Data {
        // Old path-only references have no trustworthy workspace boundary. Preserve their
        // records, but require the user to remove/reselect them instead of reopening them.
        guard value.managed else {
            throw CLIError(L10n.text("session.the_attachment_is_incomplete_or_no_longer_available"))
        }
        return try SessionMarkdownFiles.readReferencedFile(
            value.path, cwd: root.path, referencedPaths: [], maximumBytes: 10 * 1024 * 1024)
    }
    static func workspaceFile(_ relative: String, cwd: String) throws -> URL {
        guard let root = realpath(cwd, nil) else {
            throw CLIError(L10n.text("session.only_files_inside_the_current_session_s_project_are_allowed"))
        }
        let base = URL(fileURLWithPath: String(cString: root))
        free(root)
        guard !relative.hasPrefix("/"), !relative.contains("\0") else {
            throw CLIError(L10n.text("session.only_files_inside_the_current_session_s_project_are_allowed"))
        }
        // Foundation on older macOS leaves symlinks unresolved when the final leaf is missing.
        // Resolve the deepest existing parent through the filesystem, then append only missing names.
        var parent = base.appendingPathComponent(relative).standardizedFileURL
        var missing: [String] = []
        var resolved: URL?
        while resolved == nil {
            if let actual = realpath(parent.path, nil) {
                resolved = URL(fileURLWithPath: String(cString: actual))
                free(actual)
                break
            }
            let failure = errno
            var info = stat()
            guard failure == ENOENT, lstat(parent.path, &info) != 0, errno == ENOENT, parent.path != "/" else {
                throw CLIError(L10n.text("session.only_files_inside_the_current_session_s_project_are_allowed"))
            }
            missing.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
        guard var result = resolved else {
            throw CLIError(L10n.text("session.only_files_inside_the_current_session_s_project_are_allowed"))
        }
        for component in missing.reversed() { result.appendPathComponent(component) }
        guard result.path == base.path || result.path.hasPrefix(base.path == "/" ? "/" : base.path + "/") else {
            throw CLIError(L10n.text("session.the_file_is_outside_the_current_session_s_project"))
        }
        return result
    }
    static func browse(relative: String, cwd: String) throws -> [String: Any] {
        let directory = try workspaceFile(relative, cwd: cwd)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        let entries: [[String: Any]] = try urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.prefix(200).compactMap { url in
            let safe = try? workspaceFile((relative.isEmpty ? "" : relative + "/") + url.lastPathComponent, cwd: cwd)
            guard safe != nil else { return nil }
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard info.isDirectory == true || info.isRegularFile == true else { return nil }
            return [
                "name": url.lastPathComponent, "path": (relative.isEmpty ? "" : relative + "/") + url.lastPathComponent,
                "directory": info.isDirectory == true,
            ]
        }
        return ["folder": relative, "entries": entries, "truncated": urls.count > 200]
    }
}
