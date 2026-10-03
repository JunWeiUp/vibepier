import AppKit
import CryptoKit
import Darwin
import Foundation

/// Metadata-only SQLite reads and incremental lifecycle tails. Nothing follows a
/// desktop transcript stream or asks the model/network for status.
final class NativeConversationActivitySource: ConversationActivitySource, @unchecked Sendable {
    struct ReadContext: Equatable {
        let identity: String
        let host: String
        var key: String { identity + ":" + host }
    }
    struct FileVersion: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Double
        init?(_ path: String) {
            guard let values = try? FileManager.default.attributesOfItem(atPath: path),
                let inode = values[.systemFileNumber] as? NSNumber, let size = values[.size] as? NSNumber,
                let modified = values[.modificationDate] as? Date
            else { return nil }
            self.inode = inode.uint64Value
            self.size = size.uint64Value
            self.modified = modified.timeIntervalSince1970
        }
    }
    private struct Cursor {
        let version: FileVersion
        let offset: UInt64
        let state: ConversationActivityTail.State
    }
    private struct ClaudeMetadata {
        let id: String
        let host: String
        let title: String
        let archived: Bool
        let summaryID: String?
        let failed: Bool
    }
    private let home: URL
    private let codex: ZCodeSQLiteReader
    private let zcode: ZCodeSQLiteReader
    private let zcodeIndex: ZCodeSQLiteReader
    private var context: ReadContext?
    private var authVersion: FileVersion?
    private var readOverrides: [String: Bool] = [:]
    private var readCompletions: [String: String] = [:]
    private var codexRows: [String: [String: Any]] = [:]
    private var codexVersion = ""
    private var zcodeRows: [[String: Any]] = []
    private var zcodeVersion = ""
    private var zcodeTerminalVersion = ""
    private var zcodeTerminals: [String: ConversationActivityObservation.Phase] = [:]
    private var zcodeActivity: [String: [Int64]] = [:]
    private var cursors: [String: Cursor] = [:]
    private var claudeFiles: [String: String] = [:]
    private var claudeCache: [String: (FileVersion, ConversationActivityTail.State)] = [:]
    private var claudeTitles: [String: String] = [:]
    private var claudeMetadataCache: [String: (FileVersion, ClaudeMetadata)] = [:]
    private let visibleClaudeHost: @Sendable () -> String?
    private var ids: [String: Set<String>] = [:]

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        visibleClaudeHost: @escaping @Sendable () -> String? = { ClaudeDesktop.visibleSessionHost() }
    ) {
        self.home = home
        self.visibleClaudeHost = visibleClaudeHost
        codex = ZCodeSQLiteReader(path: home.appendingPathComponent(".codex/state_5.sqlite").path)
        zcode = ZCodeSQLiteReader(
            path: home.appendingPathComponent(".zcode/cli/db/db.sqlite").path,
            attachmentPath: home.appendingPathComponent(".zcode/v2/tasks-index.sqlite").path)
        zcodeIndex = ZCodeSQLiteReader(path: home.appendingPathComponent(".zcode/v2/tasks-index.sqlite").path)
        let authPath = home.appendingPathComponent(".codex/auth.json")
        authVersion = FileVersion(authPath.path)
        context = (try? Data(contentsOf: authPath)).flatMap(Self.bootstrapContext)
    }

    static func digest(_ value: [Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func readContext(_ context: [String: Any]) -> ReadContext? {
        guard let identity = context["identity"] as? [String: Any], let kind = identity["kind"] as? String,
            let host = context["executionHostKey"] as? String, host.hasPrefix("local:"), host.count == 70
        else { return nil }
        let fields: [Any]
        if kind == "chatgpt", let account = identity["accountId"] as? String, !account.isEmpty,
            let user = identity["userId"] as? String, !user.isEmpty
        {
            fields = [kind, account, user]
        } else if kind == "execution-storage", let mode = identity["authMode"] as? String {
            fields = [kind, mode]
        } else {
            return nil
        }
        guard let identity = digest(fields) else { return nil }
        return .init(identity: identity, host: host)
    }

    /// Matches the native bootstrap's getAuthStatus access-token claim mapping.
    /// `sub`/id_token and other account/remote host buckets are never substituted.
    static func bootstrapContext(_ auth: Data) -> ReadContext? {
        guard let value = try? JSONSerialization.jsonObject(with: auth) as? [String: Any],
            value["auth_mode"] as? String == "chatgpt",
            let tokens = value["tokens"] as? [String: Any], let token = tokens["access_token"] as? String
        else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
            of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let expiry = claims["exp"] as? NSNumber, expiry.doubleValue > 0,
            expiry.doubleValue.rounded() == expiry.doubleValue,
            let details = claims["https://api.openai.com/auth"] as? [String: Any],
            let account = (details["chatgpt_account_id"] ?? details["account_id"]) as? String,
            let user = (details["user_id"] ?? details["chatgpt_user_id"]) as? String,
            let host = digest(["local", "local", NSNull()])
        else { return nil }
        return readContext([
            "identity": ["kind": "chatgpt", "accountId": account, "userId": user], "executionHostKey": "local:" + host,
        ])
    }

    static func unreadIDs(_ data: Data, context: ReadContext) -> Set<String>? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let state = value["electron-thread-read-state-v1"] as? [String: Any], state["version"] as? Int == 1,
            let identities = state["unreadByIdentity"] as? [String: Any],
            let hosts = identities[context.identity] as? [String: Any],
            let ids = hosts[context.host] as? [String]
        else { return nil }
        return Set(ids)
    }

    func acceptCodexReadState(_ params: [String: Any]) {
        guard params["hostId"] as? String == "local", let id = params["conversationId"] as? String,
            UUID(uuidString: id) != nil, let unread = params["hasUnreadTurn"] as? Bool,
            let value = params["context"] as? [String: Any], let current = Self.readContext(value)
        else { return }
        guard context == nil || context == current else { return }
        if context != current {
            readOverrides.removeAll()
            readCompletions.removeAll()
        }
        context = current
        readOverrides[id] = unread
        if unread {
            readCompletions.removeValue(forKey: id)
        } else if let path = codexRows[id]?["rollout_path"] as? String, let completion = cursors[path]?.state.completion
        {
            // Use the last observed revision, never advance the disk cursor for
            // a delayed Boolean read event that might describe an older turn.
            readCompletions[id] = completion
        }
    }

    func acceptsCodexContext(_ params: [String: Any]) -> Bool {
        guard params["hostId"] as? String == "local", let value = params["context"] as? [String: Any],
            let incoming = Self.readContext(value)
        else { return false }
        // When bootstrap identity is unavailable, only the native validated local
        // context can establish it. Once known, other accounts/hosts cannot clear.
        return context == incoming
    }

    func scan(tracked: [String: ConversationActivityLedger.Entry]) -> ConversationActivityScan {
        var result = ConversationActivityScan()
        for path in [codex.path, zcode.path, zcodeIndex.path] {
            result.paths.formUnion([path, path + "-wal", URL(fileURLWithPath: path).deletingLastPathComponent().path])
        }
        result.paths.formUnion([
            home.appendingPathComponent(".codex/.codex-global-state.json").path,
            home.appendingPathComponent(".codex/auth.json").path,
            home.appendingPathComponent(".codex/ipc").path,
            home.appendingPathComponent(".claude/sessions").path,
        ])
        scanCodex(tracked: tracked, into: &result)
        scanZCode(tracked: tracked, into: &result)
        scanClaude(tracked: tracked, into: &result)
        ids.merge(result.visibleIDs) { _, new in new }
        return result
    }

    private static let codexVisible = CodexThreadStore.visible
    private func scanCodex(
        tracked: [String: ConversationActivityLedger.Entry], into result: inout ConversationActivityScan
    ) {
        guard let version = try? codex.version() else { return }
        if version != codexVersion {
            guard
                let rows = try? codex.rows(
                    "SELECT id,coalesce(nullif(name,''),title) AS title,rollout_path,updated_at_ms FROM threads WHERE \(Self.codexVisible) ORDER BY updated_at_ms DESC LIMIT 10000"
                )
            else { return }
            codexRows = Dictionary(
                rows.compactMap { row in (row["id"] as? String).map { ($0, row) } },
                uniquingKeysWith: { _, last in last })
            codexVersion = version
        }
        let rows = codexRows.values.sorted {
            ($0["updated_at_ms"] as? Int64 ?? 0) > ($1["updated_at_ms"] as? Int64 ?? 0)
        }
        result.visibleIDs["codex"] = Set(codexRows.keys)
        let authPath = home.appendingPathComponent(".codex/auth.json").path
        let authStamp = FileVersion(authPath)
        if authStamp != authVersion {
            authVersion = authStamp
            let next = (try? Data(contentsOf: URL(fileURLWithPath: authPath))).flatMap(Self.bootstrapContext)
            if context != next {
                context = next
                readOverrides.removeAll()
                readCompletions.removeAll()
            }
        }
        var unread: Set<String>?
        if let context, let data = try? Data(contentsOf: home.appendingPathComponent(".codex/.codex-global-state.json"))
        {
            unread = Self.unreadIDs(data, context: context)
        }
        if let unread {
            readOverrides = readOverrides.filter { unread.contains($0.key) != $0.value }
        }
        let now = Date().timeIntervalSince1970
        let application = codexApplication()
        for (index, row) in rows.enumerated() {
            guard let id = row["id"] as? String, let path = row["rollout_path"] as? String else { continue }
            let old = tracked["codex:" + id]
            let modified = (row["updated_at_ms"] as? Int64 ?? 0) / 1000
            // Older history contributes ID/title metadata only. Active and native
            // unread sessions remain watched regardless of list position.
            guard
                (index < 200 && Double(modified) > now - 86400) || old?.running == true || old?.unread != nil
                    || unread?.contains(id) == true || readOverrides[id] != nil
            else { continue }
            guard var state = codexTail(path) else { continue }
            // An actual long turn does not expire merely because it has no new
            // output. A terminated/restarted desktop process cannot own its old
            // unclosed start marker; workspace launch/exit events refresh this.
            if state.phase == .running {
                if application == nil {
                    state.phase = .idle
                } else if let launch = application?.launchDate?.timeIntervalSince1970, let start = state.startedAt,
                    start < launch
                {
                    state.phase = .idle
                }
            }
            let native = readOverrides[id] ?? unread.map { $0.contains(id) }
            result.observations.append(
                .init(
                    provider: "codex", id: id, title: row["title"] as? String ?? "Codex",
                    phase: state.phase, run: state.run, completion: state.completion,
                    nativeUnread: native, nativeRevision: context?.key,
                    nativeViewedCompletion: readCompletions[id]))
            result.paths.insert(path)
        }
    }

    private func codexTail(_ path: String) -> ConversationActivityTail.State? {
        guard let version = FileVersion(path) else { return nil }
        if let cached = cursors[path], cached.version == version { return cached.state }
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        var state = ConversationActivityTail.State()
        var consumed = version.size
        if let cached = cursors[path], cached.version.inode == version.inode, version.size > cached.version.size,
            version.size >= cached.offset,
            version.size - cached.offset <= 8 << 20
        {
            guard (try? file.seek(toOffset: cached.offset)) != nil,
                let data = try? file.read(upToCount: Int(version.size - cached.offset))
            else { return nil }
            let length = data.lastIndex(of: 10).map { $0 + 1 } ?? 0
            state = ConversationActivityTail.codex(data.prefix(length), previous: cached.state, offset: cached.offset)
            consumed = cached.offset + UInt64(length)
        } else {
            for window in [UInt64(256 << 10), 2 << 20, 8 << 20] {
                let offset = version.size > window ? version.size - window : 0
                guard (try? file.seek(toOffset: offset)) != nil,
                    let data = try? file.read(upToCount: Int(version.size - offset))
                else { return nil }
                let beginning = offset == 0 ? 0 : (data.firstIndex(of: 10).map { $0 + 1 } ?? data.count)
                let end = data.lastIndex(of: 10).map { $0 + 1 } ?? beginning
                state = ConversationActivityTail.codex(
                    data.subdata(in: beginning..<max(beginning, end)), offset: offset + UInt64(beginning))
                consumed = offset + UInt64(end)
                if state.phase != .idle || offset == 0 { break }
            }
        }
        cursors[path] = Cursor(version: version, offset: consumed, state: state)
        return state
    }

    private func scanZCode(
        tracked: [String: ConversationActivityLedger.Entry], into result: inout ConversationActivityScan
    ) {
        let sql = """
            SELECT s.id,coalesce(nullif(t.title,''),s.title) AS title,t.task_status,t.unread_at,t.last_unread_at,s.time_updated
            FROM session s JOIN desktop_tasks.tasks t ON t.task_id=s.id
            WHERE s.time_archived IS NULL AND coalesce(s.task_type,'')!='subagent_child'
              AND coalesce(t.deleted,0)=0 AND coalesce(t.archived,0)=0 AND t.provider='glm'
            """
        guard let mainVersion = try? zcode.version(), let indexVersion = try? zcodeIndex.version() else { return }
        let version = mainVersion + ":" + indexVersion
        if version != zcodeVersion {
            guard let rows = try? zcode.rows(sql) else { return }
            zcodeRows = rows
            zcodeVersion = version
        }
        if mainVersion != zcodeTerminalVersion {
            zcodeTerminals.removeAll()
            zcodeActivity.removeAll()
            zcodeTerminalVersion = mainVersion
        }
        let rows = zcodeRows
        result.visibleIDs["zcode"] = Set(rows.compactMap { $0["id"] as? String })
        let application = NSRunningApplication.runningApplications(withBundleIdentifier: ZCodeDesktop.bundleID).first
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            let status = row["task_status"] as? String ?? ""
            let stamp = row["last_unread_at"] as? Int64
            let unread = (row["unread_at"] as? Int64 ?? 0) > 0
            let old = tracked["zcode:" + id]
            let needsTerminal =
                unread || old?.unread != nil || old?.running == true || (status == "running" && application != nil)
            let terminal = needsTerminal ? zcodeTerminal(id) : .idle
            // The desktop maps interrupted and successful turns to the same
            // index status. Require the original latest user/assistant pair's
            // explicit successful terminal scalar before creating a green dot.
            let activity =
                status == "running" && application != nil
                ? [(row["time_updated"] as? Int64 ?? 0)] + zcodeActivityTimes(id) : []
            let active = Self.zcodeRunning(
                status: status, launch: application?.launchDate, activity: activity, terminal: terminal)
            let phase: ConversationActivityObservation.Phase =
                active ? .running : status == "completed" ? terminal : status == "error" ? .failed : .idle
            let revision = stamp.map { "native:\($0)" }
            result.observations.append(
                .init(
                    provider: "zcode", id: id, title: row["title"] as? String ?? "ZCode", phase: phase,
                    completion: revision, nativeUnread: unread, nativeRevision: revision,
                    nativeViewedCompletion: !unread && phase == .completed ? revision : nil))
        }
    }

    /// A previous host's unfinished index record is unknown, not a completion.
    /// Once this host has started/resumed the session, an arbitrarily long quiet
    /// turn retains its running ring; there is no elapsed-time expiry.
    static func zcodeRunning(
        status: String, launch: Date?, activity: [Int64], terminal: ConversationActivityObservation.Phase
    ) -> Bool {
        guard status == "running", terminal != .completed, let launch else { return false }
        let boundary = Int64(ceil(launch.timeIntervalSince1970 * 1000))
        return (activity.max() ?? 0) >= boundary
    }

    private func zcodeActivityTimes(_ id: String) -> [Int64] {
        if let activity = zcodeActivity[id] { return activity }
        let sql = """
            SELECT
              (SELECT time_updated FROM message WHERE session_id=? AND json_extract(data,'$.role')='user'
                 AND coalesce(json_extract(data,'$.semantics.kind'),'user_prompt')='user_prompt'
                 ORDER BY sequence DESC,id DESC LIMIT 1) AS user_updated,
              (SELECT time_updated FROM message WHERE session_id=? AND json_extract(data,'$.role')='assistant'
                 AND coalesce(json_extract(data,'$.semantics.kind'),'assistant_response')='assistant_response'
                 ORDER BY sequence DESC,id DESC LIMIT 1) AS assistant_updated,
              (SELECT max(time_updated) FROM part WHERE session_id=?) AS part_updated
            """
        let row = try? zcode.rows(sql, bind: [id, id, id]).first
        let activity = ["user_updated", "assistant_updated", "part_updated"].compactMap { row?[$0] as? Int64 }
        zcodeActivity[id] = activity
        return activity
    }

    private func zcodeTerminal(_ id: String) -> ConversationActivityObservation.Phase {
        if let phase = zcodeTerminals[id] { return phase }
        let user = try? zcode.rows(
            "SELECT id FROM message WHERE session_id=? AND json_extract(data,'$.role')='user' AND coalesce(json_extract(data,'$.semantics.kind'),'user_prompt')='user_prompt' AND coalesce(json_extract(data,'$.semantics.uiVisibility'),'visible')!='hidden' ORDER BY sequence DESC,id DESC LIMIT 1",
            bind: [id]
        ).first
        let assistant = try? zcode.rows(
            "SELECT json_extract(data,'$.parentID') AS parentID,json_extract(data,'$.finish') AS finish,json_extract(data,'$.time.completed') AS completed,json_type(data,'$.error') AS errorType FROM message WHERE session_id=? AND json_extract(data,'$.role')='assistant' AND coalesce(json_extract(data,'$.semantics.kind'),'assistant_response')='assistant_response' AND coalesce(json_extract(data,'$.semantics.uiVisibility'),'visible')!='hidden' ORDER BY sequence DESC,id DESC LIMIT 1",
            bind: [id]
        ).first
        let phase: ConversationActivityObservation.Phase
        if let userID = user?["id"] as? String, assistant?["parentID"] as? String == userID {
            let error = assistant?["errorType"] as? String
            if error != nil && error != "null" {
                phase = .failed
            } else if assistant?["finish"] as? String == "stop", (assistant?["completed"] as? Int64 ?? 0) > 0 {
                phase = .completed
            } else {
                phase = .idle
            }
        } else {
            phase = .idle
        }
        zcodeTerminals[id] = phase
        return phase
    }

    private func codexApplication() -> NSRunningApplication? {
        guard let url = URL(string: "codex://threads/new"),
            let location = NSWorkspace.shared.urlForApplication(toOpen: url),
            let id = Bundle(url: location)?.bundleIdentifier
        else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    private func scanClaude(
        tracked: [String: ConversationActivityLedger.Entry], into result: inout ConversationActivityScan
    ) {
        let directory = home.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var live: [String: [String: Any]] = [:]
        for file in files where file.pathExtension == "json" {
            result.paths.insert(file.path)
            guard let data = try? Data(contentsOf: file),
                let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = row["sessionId"] as? String, UUID(uuidString: id) != nil,
                let pid = (row["pid"] as? NSNumber)?.int32Value, pid > 0, kill(pid, 0) == 0 || errno == EPERM
            else { continue }
            if live[id] == nil || row["status"] as? String == "busy" { live[id] = row }
        }
        let metadata = claudeMetadata(into: &result)
        let visibleHost = visibleClaudeHost()
        let candidates = Set(live.keys).union(tracked.values.filter { $0.provider == "claude" }.map(\.id)).union(
            metadata.keys)
        var visible = Set<String>()
        for id in candidates {
            if metadata[id]?.archived == true { continue }
            guard let path = claudeFile(id) else { continue }
            visible.insert(id)
            result.paths.insert(path)
            let row = live[id]
            let busy = row?["status"] as? String == "busy"
            var state = claudeTail(path)
            if busy {
                state.phase = .running
                state.run = String(describing: row?["statusUpdatedAt"] ?? row?["updatedAt"] ?? id)
            } else if metadata[id]?.failed == true, metadata[id]?.summaryID == state.completion {
                state.phase = .failed
            }
            let host = metadata[id]?.host ?? row?["hostSessionId"] as? String
            let viewed =
                !busy && state.phase == .completed && host != nil && visibleHost == host ? state.completion : nil
            let nativeTitle = metadata[id]?.title ?? ""
            let title = nativeTitle.isEmpty ? claudeTitle(id, path: path) : nativeTitle
            result.observations.append(
                .init(
                    provider: "claude", id: id, title: title, phase: state.phase,
                    run: busy ? state.run : nil, completion: state.completion,
                    nativeViewedCompletion: viewed))
        }
        result.visibleIDs["claude"] = visible
    }

    private func claudeMetadata(into result: inout ConversationActivityScan) -> [String: ClaudeMetadata] {
        var records: [String: ClaudeMetadata] = [:]
        for app in ["Claude", "Claude-3p"] {
            let root = home.appendingPathComponent("Library/Application Support/\(app)/claude-code-sessions")
            result.paths.insert(root.path)
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { continue }
            for case let file as URL in enumerator {
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    result.paths.insert(file.path)
                    continue
                }
                guard file.pathExtension == "json", file.lastPathComponent.hasPrefix("local_"),
                    let version = FileVersion(file.path), version.size <= 2 << 20
                else { continue }
                result.paths.insert(file.path)
                let value: ClaudeMetadata
                if let cached = claudeMetadataCache[file.path], cached.0 == version {
                    value = cached.1
                } else {
                    guard let data = try? Data(contentsOf: file),
                        let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let id = row["cliSessionId"] as? String, UUID(uuidString: id) != nil,
                        let host = row["sessionId"] as? String, host.hasPrefix("local_")
                    else { continue }
                    let summary = row["postTurnSummary"] as? [String: Any]
                    value = ClaudeMetadata(
                        id: id, host: host, title: row["title"] as? String ?? "",
                        archived: row["isArchived"] as? Bool == true,
                        summaryID: summary?["summarizes_uuid"] as? String ?? row["postTurnSummaryFor"] as? String,
                        failed: ["failed", "error"].contains(summary?["status_category"] as? String ?? ""))
                    claudeMetadataCache[file.path] = (version, value)
                }
                if records[value.id] == nil { records[value.id] = value }
            }
        }
        return records
    }

    private func claudeFile(_ id: String) -> String? {
        if let path = claudeFiles[id], FileManager.default.fileExists(atPath: path) { return path }
        let root = home.appendingPathComponent(".claude/projects")
        for project in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let path = project.appendingPathComponent(id + ".jsonl").path
            if FileManager.default.fileExists(atPath: path) {
                claudeFiles[id] = path
                return path
            }
        }
        return nil
    }

    private func claudeTail(_ path: String) -> ConversationActivityTail.State {
        guard let version = FileVersion(path) else { return .init() }
        if let old = claudeCache[path], old.0 == version { return old.1 }
        guard let file = FileHandle(forReadingAtPath: path) else { return .init() }
        defer { try? file.close() }
        let offset = version.size > 512 << 10 ? version.size - UInt64(512 << 10) : 0
        guard (try? file.seek(toOffset: offset)) != nil, let data = try? file.read(upToCount: 512 << 10) else {
            return .init()
        }
        let state = ConversationActivityTail.claude(data)
        claudeCache[path] = (version, state)
        return state
    }

    private func claudeTitle(_ id: String, path: String) -> String {
        let custom = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("custom-title.json")
        if let data = try? Data(contentsOf: custom),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = value["customTitle"] as? String, !title.isEmpty
        {
            claudeTitles[id] = title
            return title
        }
        if let title = claudeTitles[id] { return title }
        guard let file = FileHandle(forReadingAtPath: path) else { return "Claude Code" }
        defer { try? file.close() }
        let data = (try? file.read(upToCount: 64 << 10)) ?? Data()
        let title = ClaudeSessionSummary.read(data)?.title ?? "Claude Code"
        claudeTitles[id] = title
        return title
    }

    func contains(provider: String, id: String) -> Bool {
        guard ["codex", "claude", "zcode"].contains(provider), !id.isEmpty, id.utf8.count < 200 else { return false }
        switch provider {
        case "codex":
            return UUID(uuidString: id) != nil
                && ((try? codex.rows("SELECT id FROM threads WHERE \(Self.codexVisible) AND id=?", bind: [id]).isEmpty)
                    == false)
        case "claude": return UUID(uuidString: id) != nil && claudeFile(id) != nil
        default:
            return
                ((try? zcode.rows(
                    "SELECT s.id FROM session s JOIN desktop_tasks.tasks t ON t.task_id=s.id WHERE s.id=? AND s.time_archived IS NULL AND coalesce(s.task_type,'')!='subagent_child' AND coalesce(t.deleted,0)=0 AND coalesce(t.archived,0)=0 AND t.provider='glm'",
                    bind: [id]
                ).isEmpty) == false)
        }
    }
}
