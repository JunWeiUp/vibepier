import AppKit
import Foundation
import UniformTypeIdentifiers

/// The phone's read-only project browser for one session's own workspace: git state beside the directory listing,
/// any UTF-8 file, its diff against HEAD, a name search, the files the latest turn changed, and opening a file on the
/// Mac. Every path the phone sends goes through `SessionMarkdownFiles.resolve`, so nothing leaves the workspace.
/// git runs without hooks, external diff drivers, text conversion or fsmonitor, and only from a real git binary
/// (never the /usr/bin shim, which would prompt to install the command-line tools).
enum SessionProjectFiles {
    static let operations: Set<String> = [
        "fileChanges", "readFile", "readImageFile", "readVideoFile", "fileDiff", "searchFiles", "openFile",
    ]
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
    ]
    static let maximumDiffBytes = 128 * 1024  // Replies over 300 KB are refused; escaping can grow a diff.
    private static let skippedDirectories: Set<String> = [
        "node_modules", "DerivedData", "Pods", "build", "dist", "target", "out",
    ]

    /// One session request; `rows` is the provider's full projection (with file parts), read only for `fileChanges`.
    static func reply(
        _ op: String, _ request: [String: Any], cwd: String, rows: () -> [[String: Any]],
        reader: SessionMarkdownFiles, device: String, thread: String, expectedGeneration: UUID? = nil,
        mediaOffer: BinaryMediaFiles.Offer = BinaryMediaFiles.currentOffer
    ) throws -> [String: Any] {
        let root = try SessionMarkdownFiles.root(cwd)
        var value: [String: Any]
        switch op {
        case "fileChanges": value = changes(rows(), root: root)
        case "readFile":
            value = try readFile(
                request, cwd: cwd, root: root, reader: reader, device: device, thread: thread,
                expectedGeneration: expectedGeneration)
        case "readVideoFile":
            value = try SessionVideoFiles.read(request, root: root, device: device, thread: thread, offer: mediaOffer)
        case "readImageFile":
            try BinaryMediaFiles.requireCurrent(request)
            let url = try file(request, root: root)
            guard imageExtensions.contains(url.pathExtension.lowercased()) else {
                throw CLIError(L10n.text("files.this_image_type_cannot_be_previewed"))
            }
            let large = request["size"] as? String == "large"
            let image = try ConversationReply.jpeg(
                url.path, cwd: root.path, maxPixel: large ? 2048 : 480,
                maximumBytes: 4 * 1024 * 1024)
            value = ["path": SessionMarkdownFiles.relative(url, root: root)]
            value["binary"] = try mediaOffer(
                BinaryMediaFiles.snapshot(image), device, thread, "image/jpeg")

        case "fileDiff": value = try diff(request, root: root)
        case "searchFiles": value = try search(request["query"] as? String ?? "", root: root)
        case "openFile": value = try open(request, root: root)
        default: throw CLIError(L10n.text("files.unknown_file_operation"))
        }
        value["threadId"] = thread
        value["rootPath"] = root.path
        return value
    }

    /// Capture immutable provider data before moving filesystem work off its queue.
    static func request(
        _ op: String, _ request: [String: Any], cwd: String, rows: [[String: Any]],
        reader: SessionMarkdownFiles, device: String, thread: String
    ) throws -> SessionFileRequest {
        let payload = try JSONSerialization.data(withJSONObject: request)
        let projected = try JSONSerialization.data(withJSONObject: rows)
        let generation = reader.currentGeneration
        return SessionFileRequest(thread: thread) {
            let fields = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
            let messages = try JSONSerialization.jsonObject(with: projected) as? [[String: Any]] ?? []
            return try reply(
                op, fields, cwd: cwd, rows: { messages }, reader: reader, device: device,
                thread: thread, expectedGeneration: generation)
        }
    }

    static func browseRequest(_ folder: String, cwd: String, thread: String) -> SessionFileRequest {
        SessionFileRequest(thread: thread) { try browse(folder, cwd: cwd) }
    }

    /// The directory listing with each entry's git state, plus the project's name and branch for the header.
    static func browse(_ folder: String, cwd: String) throws -> [String: Any] {
        var value = try SessionMarkdownFiles.browse(folder, cwd: cwd)
        let root = try SessionMarkdownFiles.root(cwd)
        value["root"] = root.lastPathComponent
        value["rootPath"] = root.path
        guard let git = Git.status(root) else { return value }
        value["branch"] = git.branch
        value["entries"] = (value["entries"] as? [[String: Any]] ?? []).map { entry in
            var entry = entry
            let path = entry["path"] as? String ?? ""
            if entry["directory"] as? Bool == true {
                if git.changed(inside: path) { entry["changed"] = true }
            } else if let status = git.status(path) {
                entry["status"] = status
            }
            return entry
        }
        return value
    }

    private static func file(_ request: [String: Any], root: URL) throws -> URL {
        let url = try SessionMarkdownFiles.resolve(request["path"] as? String ?? "", root: root)
        guard SessionMarkdownFiles.contains(url.path, root: root.path) else {
            throw CLIError(L10n.text("files.the_file_is_outside_this_session_workspace"))
        }
        return url
    }

    private static func readFile(
        _ request: [String: Any], cwd: String, root: URL, reader: SessionMarkdownFiles, device: String, thread: String,
        expectedGeneration: UUID? = nil
    ) throws -> [String: Any] {
        let url = try file(request, root: root)
        let path = SessionMarkdownFiles.relative(url, root: root)
        let fd = try SessionMarkdownFiles.openSafe(url, root: root)
        var info = stat()
        let valid = fstat(fd, &info) == 0
        Darwin.close(fd)
        guard valid, info.st_mode & S_IFMT == S_IFREG else {
            throw CLIError(L10n.text("files.only_regular_files_are_supported"))
        }
        var base: [String: Any] = ["path": path, "name": url.lastPathComponent, "size": Int(info.st_size)]
        if let status = Git.status(root)?.status(path) { base["status"] = status }
        if request["version"] == nil {
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                return base.merging(["unavailable": "image"]) { $1 }
            }
            if info.st_size > SessionMarkdownFiles.maximumBytes {
                return base.merging(["unavailable": "tooLarge"]) { $1 }
            }
        }
        var value = try reader.reply(
            request, cwd: cwd, device: device, thread: thread, expectedGeneration: expectedGeneration, anyText: true)
        if let status = base["status"] { value["status"] = status }
        return value
    }

    /// Files touched by the newest turn: every file step after the last message the person sent, merged by path.
    static func changes(_ rows: [[String: Any]], root: URL) -> [String: Any] {
        let start = (rows.lastIndex { $0["role"] as? String == "user" }).map { $0 + 1 } ?? 0
        var order: [String] = []
        var merged: [String: [String: Any]] = [:]
        for row in rows[min(start, rows.count)...] {
            for part in row["parts"] as? [[String: Any]] ?? row["sequence"] as? [[String: Any]] ?? []
            where part["kind"] as? String == "file" {
                for change in part["files"] as? [[String: Any]] ?? [] {
                    guard let path = workspacePath(change["path"] as? String ?? "", root: root) else { continue }
                    var entry =
                        merged[path] ?? [
                            "path": path, "kind": change["kind"] as? String ?? "update", "added": 0, "removed": 0,
                        ]
                    entry["added"] = (entry["added"] as? Int ?? 0) + (change["added"] as? Int ?? 0)
                    entry["removed"] = (entry["removed"] as? Int ?? 0) + (change["removed"] as? Int ?? 0)
                    if merged[path] == nil { order.append(path) }
                    merged[path] = entry
                }
            }
        }
        let git = Git.status(root)
        let files = order.prefix(200).compactMap { path -> [String: Any]? in
            guard var entry = merged[path] else { return nil }
            if let status = git?.status(path) { entry["status"] = status }
            return entry
        }
        var value: [String: Any] = [
            "root": root.lastPathComponent, "rootPath": root.path, "files": files, "git": git != nil,
        ]
        if let git {
            value["branch"] = git.branch
            value["gitChanged"] = git.count
        }
        return value
    }

    /// A step's path, relative to the workspace, or nil when it names a file outside it.
    static func workspacePath(_ raw: String, root: URL) -> String? {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\0"), path.utf8.count <= 4_096 else { return nil }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .standardizedFileURL
        var ancestor = url
        var suffix: [String] = []
        var info = stat()
        while lstat(ancestor.path, &info) != 0 {
            guard errno == ENOENT, ancestor.path != "/" else { return nil }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        guard var resolved = try? SessionMarkdownFiles.resolve(ancestor.path, root: root) else { return nil }
        for part in suffix { resolved.appendPathComponent(part) }
        return resolved.path == root.path ? nil : SessionMarkdownFiles.relative(resolved, root: root)
    }

    private static func diff(_ request: [String: Any], root: URL) throws -> [String: Any] {
        // Deleted tracked files have no realpath; resolve the nearest existing ancestor instead.
        guard let path = workspacePath(request["path"] as? String ?? "", root: root) else {
            throw CLIError(L10n.text("files.the_file_is_outside_this_session_workspace"))
        }
        guard let git = Git.status(root) else { return ["path": path, "git": false] }
        let status = git.status(path)
        if git.untracked(path) { return ["path": path, "git": true, "status": "A", "untracked": true] }
        guard let pathspec = git.pathspec(path) else { return ["path": path, "git": true] }
        let output = try Git.run(
            ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "-U3", "HEAD", "--", pathspec], in: root,
            limit: maximumDiffBytes + 1)
        let truncated = output.count > maximumDiffBytes
        let text = String(decoding: output.prefix(maximumDiffBytes), as: UTF8.self)
        let counts = ConversationReply.lineCounts(text)
        var value: [String: Any] = [
            "path": path, "git": true, "diff": text, "added": counts.added, "removed": counts.removed,
            "truncated": truncated,
        ]
        if let status { value["status"] = status }
        if text.contains("\nBinary files ") || text.hasPrefix("Binary files ") { value["binary"] = true }
        return value
    }

    /// Files whose name holds every word of `query` (or, for several words, whose path does); names that start with
    /// the first word lead, then shorter paths. git's own listing honours .gitignore; otherwise a bounded walk skips
    /// hidden and build folders.
    static func search(_ query: String, root: URL) throws -> [String: Any] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty, query.count <= 120 else { return ["query": query, "results": [], "truncated": false] }
        var paths: [String] = []
        var complete = true
        if Git.binary != nil,
            let listed = try? Git.run(
                ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root, limit: 16 * 1024 * 1024)
        {
            paths = listed.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        } else {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
            guard
                let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return ["query": query, "results": []] }
            for case let url as URL in walker {
                if paths.count >= 20_000 {
                    complete = false
                    break
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                if values?.isRegularFile == true {
                    paths.append(SessionMarkdownFiles.relative(url.resolvingSymlinksInPath(), root: root))
                }
            }
        }
        let matches = paths.filter { path in
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
                return false
            }
            let name = path.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
            let lower = path.lowercased()
            return words.allSatisfy { name.contains($0) }
                || (words.count > 1 && words.allSatisfy { lower.contains($0) })
        }
        let first = words[0]
        let ranked = matches.sorted { a, b in
            let an = (a.split(separator: "/").last.map(String.init) ?? a).lowercased().hasPrefix(first)
            let bn = (b.split(separator: "/").last.map(String.init) ?? b).lowercased().hasPrefix(first)
            if an != bn { return an }
            return a.count != b.count ? a.count < b.count : a < b
        }
        let git = Git.status(root)
        let results = ranked.prefix(100).map { path -> [String: Any] in
            var entry: [String: Any] = ["path": path, "name": path.split(separator: "/").last.map(String.init) ?? path]
            if let status = git?.status(path) { entry["status"] = status }
            return entry
        }
        return ["query": query, "results": results, "truncated": ranked.count > 100 || !complete]
    }

    /// Open with the Mac's default app, or reveal in Finder. Anything that would run code when opened is refused.
    private static func open(_ request: [String: Any], root: URL) throws -> [String: Any] {
        let url = try file(request, root: root)
        let path = SessionMarkdownFiles.relative(url, root: root)
        let reveal = request["reveal"] as? Bool == true
        let fd = try SessionMarkdownFiles.openSafe(url, root: root)
        var info = stat()
        let valid = fstat(fd, &info) == 0
        Darwin.close(fd)
        guard valid else { throw CLIError(L10n.text("files.the_file_does_not_exist_or_cannot_be_read")) }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        if !reveal {
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw CLIError(L10n.text("files.only_regular_files_can_be_opened_use_show_in_finder_instead"))
            }
            try ensureInert(url, mode: info.st_mode)
        }
        DispatchQueue.main.async {
            if reveal || directory {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return ["path": path, "opened": true, "locked": ScreenLock.locked()]
    }

    private static let launchingExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "ksh", "fish", "workflow", "action", "scpt",
        "scptd",
        "applescript", "pkg", "mpkg", "dmg", "prefpane", "mobileconfig", "webloc", "inetloc", "fileloc", "url",
        "shortcut",
        "jar", "osax", "kext", "plugin", "bundle", "framework", "saver", "qlgenerator", "docset",
    ]
    private static let launchingApplications: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "io.alacritty", "org.python.PythonLauncher", "com.apple.ScriptEditor2", "com.apple.Automator",
        "com.apple.automator.runner",
        "com.apple.installer", "com.apple.archiveutility", "com.apple.DiskImageMounter", "com.apple.systempreferences",
        "com.apple.SystemPreferences", "com.apple.JarLauncher", "com.apple.shortcuts",
    ]

    /// The phone may only ask the Mac to show a document, never to run something.
    static func ensureInert(_ url: URL, mode: mode_t) throws {
        if mode & 0o111 != 0 { throw CLIError(L10n.text("files.this_file_is_executable_use_show_in_finder")) }
        let ext = url.pathExtension.lowercased()
        if launchingExtensions.contains(ext) {
            throw CLIError(L10n.text("files.opening_this_file_type_could_run_code_use_show_in_finder"))
        }
        if let type = UTType(filenameExtension: ext),
            [.executable, .application, .applicationBundle, .bundle, .package, .shellScript, .diskImage].contains(
                where: type.conforms(to:))
        {
            throw CLIError(L10n.text("files.opening_this_file_type_could_run_code_use_show_in_finder"))
        }
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            throw CLIError(L10n.text("files.no_application_on_the_mac_can_open_this_file"))
        }
        if let identifier = Bundle(url: handler)?.bundleIdentifier, launchingApplications.contains(identifier) {
            throw CLIError(L10n.text("files.the_default_application_may_execute_this_file_use_show_in_finder"))
        }
    }

    /// One repository's working-tree state, cached briefly so expanding folders does not rerun git each time.
    struct Git {
        let branch: String
        let prefix: String
        private let statuses: [String: String]
        private let untrackedFiles: Set<String>
        private let untrackedDirectories: [String]
        var count: Int { statuses.count + untrackedDirectories.count }

        func status(_ path: String) -> String? {
            if let status = statuses[path] { return status }
            return untrackedDirectories.contains { path.hasPrefix($0) } ? "A" : nil
        }
        func untracked(_ path: String) -> Bool {
            untrackedFiles.contains(path) || untrackedDirectories.contains { path.hasPrefix($0) }
        }
        func changed(inside folder: String) -> Bool {
            let start = folder.isEmpty ? "" : folder + "/"
            return statuses.keys.contains { $0.hasPrefix(start) }
                || untrackedDirectories.contains { $0.hasPrefix(start) || start.hasPrefix($0) }
        }
        /// A workspace path as git's top-level-relative pathspec.
        func pathspec(_ path: String) -> String? { ":(top,literal)" + prefix + path }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var cache: [String: (at: Double, value: Git?)] = [:]
        static let binary: String? = [
            "/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }

        static func status(_ root: URL) -> Git? {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if let saved = cache[root.path], now - saved.at < 3 {
                lock.unlock()
                return saved.value
            }
            lock.unlock()
            let value = read(root)
            lock.lock()
            cache = cache.filter { now - $0.value.at < 60 }
            cache[root.path] = (now, value)
            lock.unlock()
            return value
        }

        private static func read(_ root: URL) -> Git? {
            guard binary != nil, let top = try? run(["rev-parse", "--show-prefix"], in: root, limit: 8_192) else {
                return nil
            }
            let prefix = String(decoding: top, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard
                let output = try? run(
                    ["status", "--porcelain=v1", "-z", "--branch", "--no-renames", "--untracked-files=normal"],
                    in: root, limit: 8 * 1024 * 1024)
            else { return nil }
            var branch = ""
            var statuses: [String: String] = [:]
            var files = Set<String>()
            var directories: [String] = []
            for record in output.split(separator: 0) {
                let line = String(decoding: record, as: UTF8.self)
                if line.hasPrefix("## ") {
                    // "main...origin/main [ahead 1]", "No commits yet on main" or "HEAD (no branch)".
                    var name = String(line.dropFirst(3))
                    if name.hasPrefix("No commits yet on ") { name = String(name.dropFirst(18)) }
                    if let range = name.range(of: "...") { name = String(name[..<range.lowerBound]) }
                    branch = name.split(separator: " ").first.map(String.init) ?? name
                    continue
                }
                guard line.count > 3 else { continue }
                let code = Array(line.prefix(2))
                let full = String(line.dropFirst(3))
                guard full.hasPrefix(prefix) else { continue }
                let path = String(full.dropFirst(prefix.count))
                if code == ["?", "?"] {
                    if path.hasSuffix("/") {
                        directories.append(path)
                    } else {
                        statuses[path] = "A"
                        files.insert(path)
                    }
                    continue
                }
                if code == ["!", "!"] { continue }
                statuses[path] = code.contains("A") ? "A" : code.contains("D") ? "D" : "M"
            }
            return Git(
                branch: branch, prefix: prefix, statuses: statuses, untrackedFiles: files,
                untrackedDirectories: directories)
        }

        /// git with no repository hooks, external diff drivers, conversions, pagers or prompts; stopped after five seconds.
        static func run(_ arguments: [String], in directory: URL, limit: Int) throws -> Data {
            guard let binary else { throw CLIError(L10n.text("files.git_is_not_available_on_the_mac")) }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments =
                [
                    "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.hooksPath=/dev/null",
                    "-c", "diff.external=", "-c", "core.pager=cat", "--no-optional-locks",
                ] + arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment["LC_ALL"] = "C"
            process.environment = environment
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
            var data = Data()
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
            }
            process.waitUntilExit()
            deadline.cancel()
            guard process.terminationStatus == 0 else { throw CLIError(L10n.text("files.could_not_read_git_data")) }
            return data
        }
    }
}
