import Darwin
import Foundation

/// Read-only workspace access, plus exact files explicitly referenced by this
/// session. Callers supply trusted cwd/references, never values from the phone.
/// Snapshots belong to one device and session; browsing stays inside the workspace.
final class SessionMarkdownFiles: @unchecked Sendable {
    static let maximumBytes = 2 * 1024 * 1024
    static let chunkScalars = 8_000
    static let chunkBytes = 24 * 1024
    private struct Snapshot {
        let device: String
        let thread: String
        let root: String
        let path: String
        let bytes: Data
        var usedAt: Double
    }
    private var snapshots: [String: Snapshot] = [:]
    private let cacheLock = NSLock()
    private var generation = UUID()
    var currentGeneration: UUID { cacheLock.withLock { generation } }
    private let clock: () -> Double
    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    func remove(device: String) {
        cacheLock.withLock {
            snapshots = snapshots.filter { $0.value.device != device }
            generation = UUID()
        }
    }

    func request(_ request: [String: Any], cwd: String, device: String, thread: String, referencedPaths: Set<String>)
        throws -> SessionFileRequest
    {
        let data = try JSONSerialization.data(withJSONObject: request)
        let generation = cacheLock.withLock { self.generation }
        return SessionFileRequest(thread: thread) { [self] in
            let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return try reply(
                fields, cwd: cwd, device: device, thread: thread, referencedPaths: referencedPaths,
                expectedGeneration: generation)
        }
    }

    static func browseRequest(_ folder: String, cwd: String, thread: String) -> SessionFileRequest {
        SessionFileRequest(thread: thread) { try browse(folder, cwd: cwd) }
    }

    /// Match the phone's inert Markdown file links. Tool arguments/output and
    /// code literals do not authorize files merely by mentioning a path.
    static func referencedPaths(in rows: [[String: Any]]) -> Set<String> {
        var references = Set<String>()
        for row in rows {
            references.formUnion(markdownPaths(row["text"] as? String ?? ""))
            let parts = row["parts"] as? [[String: Any]] ?? row["sequence"] as? [[String: Any]] ?? []
            for part in parts {
                let kind = part["kind"] as? String ?? ""
                if ["text", "plan", "thinking"].contains(kind) {
                    references.formUnion(markdownPaths(part["text"] as? String ?? ""))
                }
                if kind == "file" {
                    for file in part["files"] as? [[String: Any]] ?? [] {
                        if let path = markdownTarget(file["path"] as? String ?? "") { references.insert(path) }
                    }
                }
            }
        }
        return references
    }
    static func markdownTarget(_ target: String) -> String? {
        var path = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        guard let decoded = path.removingPercentEncoding else { return nil }
        path = decoded
        if let hint = path.range(of: #"(?::[1-9][0-9]*(?::[1-9][0-9]*)?|#L[1-9][0-9]*)$"#, options: .regularExpression)
        {
            path.removeSubrange(hint)
        }
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.contains("\0"), !path.contains("\n"), !path.contains("\r"),
            !path.hasPrefix("//"), path.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) == nil,
            ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        else { return nil }
        return path
    }
    static func markdownPaths(_ text: String) -> Set<String> {
        var paths = Set<String>()
        var fence: Character?
        var fenceLength = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Array(raw)
            let trimmed = Array(raw.drop(while: { $0 == " " }))
            let indentation = line.count - trimmed.count
            if indentation <= 3, let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if fence == nil {
                        fence = first
                        fenceLength = count
                    } else if fence == first, count >= fenceLength,
                        trimmed.dropFirst(count).allSatisfy({ $0.isWhitespace })
                    {
                        fence = nil
                    }
                    continue
                }
            }
            guard fence == nil else { continue }
            var index = 0
            while index < line.count {
                if line[index] == "\\" {
                    index += 2
                    continue
                }
                if line[index] == "`" {
                    let start = index
                    while index < line.count, line[index] == "`" { index += 1 }
                    let count = index - start
                    while index < line.count {
                        if line[index] != "`" {
                            index += 1
                            continue
                        }
                        let endStart = index
                        while index < line.count, line[index] == "`" { index += 1 }
                        if index - endStart == count { break }
                    }
                    continue
                }
                guard line[index] == "[", index == 0 || line[index - 1] != "!" else {
                    index += 1
                    continue
                }
                let start = index
                index += 1
                guard let labelEnd = line[index...].firstIndex(of: "]"), labelEnd + 1 < line.count,
                    line[labelEnd + 1] == "("
                else { continue }
                var cursor = labelEnd + 2
                var depth = 1
                var angle = false
                let targetStart = cursor
                while cursor < line.count {
                    let character = line[cursor]
                    if character == "\\" {
                        cursor += 2
                        continue
                    }
                    if character == "<", cursor == targetStart {
                        angle = true
                    } else if character == ">" {
                        angle = false
                    } else if !angle, character == "(" {
                        depth += 1
                    } else if !angle, character == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    cursor += 1
                }
                guard depth == 0 else {
                    index = max(index, start + 1)
                    continue
                }
                index = cursor + 1
                let target = String(line[targetStart..<cursor]).replacingOccurrences(
                    of: #"\\([()\\ ])"#, with: "$1", options: .regularExpression)
                if let path = markdownTarget(target) { paths.insert(path) }
            }
        }
        return paths
    }

    static func root(_ cwd: String) throws -> URL {
        guard cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.utf8.count <= 4_096 else {
            throw CLIError(L10n.text("session.the_session_directory_is_unavailable_check_on_the_mac"))
        }
        guard let actual = realpath(cwd, nil) else {
            throw SessionFileAccess.failure(
                errno: errno, fallback: L10n.text("session.the_session_directory_no_longer_exists_check_on_the_mac"))
        }
        defer { free(actual) }
        let root = URL(fileURLWithPath: String(cString: actual))
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            throw SessionFileAccess.failure(
                errno: errno, fallback: L10n.text("session.the_session_directory_no_longer_exists_check_on_the_mac"))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw CLIError(L10n.text("session.the_session_directory_no_longer_exists_check_on_the_mac"))
        }
        return root
    }
    static func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    static func resolve(_ path: String, root: URL, referencedPaths: Set<String> = []) throws -> URL {
        guard !path.contains("\0"), path.utf8.count <= 4_096 else {
            throw CLIError(L10n.text("session.invalid_file_path"))
        }
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        guard let actual = realpath(candidate.path, nil) else {
            throw SessionFileAccess.failure(
                errno: errno, fallback: L10n.text("session.the_file_does_not_exist_or_cannot_be_read"))
        }
        defer { free(actual) }
        let url = URL(fileURLWithPath: String(cString: actual))
        if !contains(url.path, root: root.path) {
            let permitted = referencedPaths.contains { reference in
                guard !reference.contains("\0"), reference.utf8.count <= 4_096 else { return false }
                let file =
                    reference.hasPrefix("/") ? URL(fileURLWithPath: reference) : root.appendingPathComponent(reference)
                guard let actual = realpath(file.path, nil) else { return false }
                defer { free(actual) }
                return String(cString: actual) == url.path
            }
            guard permitted else {
                throw CLIError(
                    L10n.text("session.the_file_is_outside_this_session_s_project_and_is_not_referenced_by_"))
            }
        }
        return url
    }
    static func relative(_ url: URL, root: URL) -> String {
        if url.path == root.path { return "" }
        guard contains(url.path, root: root.path) else { return url.path }
        return String(url.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
    }
    private static func descriptorPath(_ fd: Int32, reportPermissionFailures: Bool = true) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else {
            throw SessionFileAccess.failure(
                errno: errno, fallback: L10n.text("session.could_not_verify_the_file_location_retry"),
                report: reportPermissionFailures)
        }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    /// Resolve first to allow in-project symlinks, then walk with openat/O_NOFOLLOW.
    /// Every component remains beneath the opened root if a symlink is replaced
    /// between validation and reading; FIFOs/devices cannot block the bridge.
    static func openSafe(
        _ url: URL, root: URL, directory: Bool = false, reportPermissionFailures: Bool = true
    ) throws -> Int32 {
        var current = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else {
            throw SessionFileAccess.failure(
                errno: errno, fallback: L10n.text("session.could_not_read_the_session_directory"),
                report: reportPermissionFailures)
        }
        do {
            guard try descriptorPath(current, reportPermissionFailures: reportPermissionFailures) == root.path else {
                throw CLIError(L10n.text("session.the_session_directory_changed_reopen_the_file"))
            }
            let parts = relative(url, root: root).split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                let isDirectory = index < parts.count - 1 || directory
                let next = openat(
                    current, part, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (isDirectory ? O_DIRECTORY : 0))
                guard next >= 0 else {
                    throw SessionFileAccess.failure(
                        errno: errno, fallback: L10n.text("session.the_file_is_missing_unreadable_or_has_moved"),
                        report: reportPermissionFailures)
                }
                Darwin.close(current)
                current = next
            }
            guard try descriptorPath(current, reportPermissionFailures: reportPermissionFailures) == url.path else {
                throw CLIError(L10n.text("session.the_file_location_changed_reopen_it"))
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }
    private static func read(
        _ url: URL, root: URL, maximumBytes: Int, monitor: FileAccessMonitor? = .shared
    ) throws -> Data {
        let token = monitor?.recordProbe {
            _ = try readContents(url, root: root, maximumBytes: maximumBytes)
        }
        do {
            let bytes = try readContents(url, root: root, maximumBytes: maximumBytes)
            if let token { monitor?.record(.accessConfirmed, for: token) }
            return bytes
        } catch {
            if let token {
                monitor?.record(
                    error is SessionFileAccess.PermissionDenied ? .permissionRequired : .unknown, for: token)
            }
            throw error
        }
    }
    /// State/notifications are committed by the owning read token or explicit
    /// check, so an obsolete worker cannot publish an old refusal as current.
    private static func readContents(_ url: URL, root: URL, maximumBytes: Int) throws -> Data {
        let fd = try openSafe(url, root: root, reportPermissionFailures: false)
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else {
            throw SessionFileAccess.failure(
                errno: errno, fallback: L10n.text("session.could_not_read_the_file_retry"),
                report: false)
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw CLIError(L10n.text("session.only_regular_files_are_supported"))
        }
        guard before.st_size >= 0, before.st_size <= maximumBytes else {
            throw CLIError(L10n.text("session.the_file_exceeds_the_preview_size_limit"))
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maximumBytes {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0 {
                let failure = errno
                if failure == EINTR { continue }
                throw SessionFileAccess.failure(
                    errno: failure, fallback: L10n.text("session.could_not_read_the_file_retry"),
                    report: false)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumBytes else {
            throw CLIError(L10n.text("session.the_file_exceeds_the_preview_size_limit"))
        }
        var after = stat()
        guard fstat(fd, &after) == 0 else {
            throw SessionFileAccess.failure(
                errno: errno, fallback: L10n.text("session.could_not_read_the_file_retry"),
                report: false)
        }
        guard before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw CLIError(L10n.text("session.the_file_is_being_updated_retry")) }
        return data
    }
    /// Binary counterpart for native conversation images. References must come
    /// from the provider's trusted conversation projection, never RPC fields.
    static func readReferencedFile(_ path: String, cwd: String, referencedPaths: Set<String>, maximumBytes: Int) throws
        -> Data
    {
        let root = try root(cwd)
        let url = try resolve(path, root: root, referencedPaths: referencedPaths)
        return try read(
            url, root: contains(url.path, root: root.path) ? root : URL(fileURLWithPath: "/"),
            maximumBytes: maximumBytes)
    }
    /// Read an exact provider-owned path without resolving symlinks to a different attachment.
    static func readContainedFile(_ url: URL, root: URL, maximumBytes: Int) throws -> Data {
        guard contains(url.path, root: root.path),
            !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else {
            throw CLIError(L10n.text("session.invalid_file_path"))
        }
        return try read(url, root: root, maximumBytes: maximumBytes)
    }
    func reply(
        _ request: [String: Any], cwd: String, device: String, thread: String, referencedPaths: Set<String> = [],
        expectedGeneration: UUID? = nil, anyText: Bool = false
    )
        throws -> [String: Any]
    {
        let generation = cacheLock.withLock { expectedGeneration ?? self.generation }
        let root = try Self.root(cwd)
        let url = try Self.resolve(
            request["path"] as? String ?? "", root: root, referencedPaths: anyText ? [] : referencedPaths)
        guard anyText || ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw CLIError(L10n.text("session.only_md_and_markdown_files_are_supported"))
        }
        let path = Self.relative(url, root: root)
        let offset = request["offset"] as? Int ?? 0
        let now = clock()
        guard offset >= 0 else { throw CLIError(L10n.text("session.invalid_markdown_page_offset")) }
        let cached = cacheLock.withLock {
            snapshots = snapshots.filter { now - $0.value.usedAt < 300 }
            return (request["version"] as? String).flatMap { snapshots[$0] }
        }
        let version: String
        var snapshot: Snapshot
        if let requestedVersion = request["version"] as? String {
            guard let saved = cached, saved.device == device, saved.thread == thread,
                saved.root == root.path, saved.path == path
            else {
                throw CLIError(L10n.text("session.the_file_preview_expired_or_belongs_to_another_session_reopen_it"))
            }
            version = requestedVersion
            snapshot = saved
        } else {
            guard offset == 0 else {
                throw CLIError(L10n.text("session.further_pages_require_the_file_version_reopen_the_file"))
            }
            let bytes = try Self.read(
                url, root: Self.contains(url.path, root: root.path) ? root : URL(fileURLWithPath: "/"),
                maximumBytes: Self.maximumBytes)
            if anyText, bytes.prefix(8_192).contains(0) || String(data: bytes, encoding: .utf8) == nil {
                return [
                    "threadId": thread, "path": path, "name": url.lastPathComponent, "size": bytes.count,
                    "unavailable": "binary",
                ]
            }
            guard String(data: bytes, encoding: .utf8) != nil else {
                throw CLIError(L10n.text("session.this_markdown_file_is_not_valid_utf_8_text"))
            }
            version = UUID().uuidString
            snapshot = Snapshot(device: device, thread: thread, root: root.path, path: path, bytes: bytes, usedAt: now)
        }
        let bytes = snapshot.bytes
        guard offset <= bytes.count, offset == bytes.count || bytes[offset] & 0xC0 != 0x80 else {
            throw CLIError(L10n.text("session.invalid_markdown_page_offset"))
        }
        var end = offset
        var scalars = 0
        while end < bytes.count, scalars < Self.chunkScalars {
            let first = bytes[end]
            let length = first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
            if end + length - offset > Self.chunkBytes { break }
            end += length
            scalars += 1
        }
        snapshot.usedAt = now
        try cacheLock.withLock {
            guard self.generation == generation else {
                throw CLIError(L10n.text("session.the_session_view_changed"))
            }
            if snapshots[version] == nil {
                if snapshots.values.filter({ $0.device == device }).count >= 4,
                    let victim = snapshots.filter({ $0.value.device == device }).min(by: {
                        $0.value.usedAt < $1.value.usedAt
                    })?.key
                {
                    snapshots.removeValue(forKey: victim)
                }
                if snapshots.count >= 8, let victim = snapshots.min(by: { $0.value.usedAt < $1.value.usedAt })?.key {
                    snapshots.removeValue(forKey: victim)
                }
            }
            snapshots[version] = snapshot
        }
        return [
            "threadId": thread, "path": path, "name": url.lastPathComponent, "size": bytes.count,
            "text": String(decoding: bytes[offset..<end], as: UTF8.self), "version": version,
            "nextOffset": end < bytes.count ? end : -1,
        ]
    }
    static func browse(_ folder: String, cwd: String) throws -> [String: Any] {
        let root = try root(cwd)
        let url = try resolve(folder, root: root)
        let fd = try openSafe(url, root: root, directory: true)
        guard let directory = fdopendir(fd) else {
            let failure = errno
            Darwin.close(fd)
            throw SessionFileAccess.failure(
                errno: failure, fallback: L10n.text("session.could_not_browse_this_directory"))
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !name.hasPrefix(".") { names.append(name) }
        }
        var entries: [[String: Any]] = []
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).prefix(200) {
            guard let safe = try? resolve(url.appendingPathComponent(name).path, root: root),
                let file = try? openSafe(safe, root: root)
            else { continue }
            var info = stat()
            let valid = fstat(file, &info) == 0
            Darwin.close(file)
            let directory = info.st_mode & S_IFMT == S_IFDIR
            guard valid, directory || info.st_mode & S_IFMT == S_IFREG else { continue }
            var entry: [String: Any] = ["name": name, "path": relative(safe, root: root), "directory": directory]
            if !directory { entry["size"] = Int(info.st_size) }
            entries.append(entry)
        }
        return ["folder": relative(url, root: root), "entries": entries, "truncated": names.count > 200]
    }
}
