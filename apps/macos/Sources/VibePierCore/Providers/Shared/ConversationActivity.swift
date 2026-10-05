import AppKit
import CryptoKit
import Darwin
import Foundation

/// A completion revision identifies a finished turn, never a title update or a
/// connection failure. Providers expose only metadata and bounded local tails.
struct ConversationActivityObservation: Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case idle, running, completed, failed }
    let provider: String
    let id: String
    var title: String
    var phase: Phase = .idle
    var run: String? = nil
    var completion: String? = nil
    var nativeUnread: Bool? = nil
    var nativeRevision: String? = nil
    var nativeViewedCompletion: String? = nil
    var key: String { provider + ":" + id }
}

/// Persist confirmed unread/view watermarks, including the active turn across
/// restarts. A baseline of ordinary historical completions does not create dots.
struct ConversationActivityLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var provider: String
        var id: String
        var title: String
        var running = false
        var run: String?
        var runBaselineCompletion: String?
        var completion: String?
        var unread: String?
        var viewed: String?
        var nativeUnread: Bool?
        var nativeRevision: String?
    }
    var entries: [String: Entry] = [:]

    mutating func observe(_ value: ConversationActivityObservation, baseline: Bool) {
        let previous = entries[value.key]
        var entry = previous ?? Entry(provider: value.provider, id: value.id, title: value.title)
        entry.title = String(value.title.prefix(160))
        entry.running = value.phase == .running
        if entry.running {
            if previous?.running != true || previous?.run != value.run {
                entry.runBaselineCompletion = value.completion ?? previous?.completion
            }
            entry.run = value.run
        }
        if value.phase == .completed, let completion = value.completion, !completion.isEmpty {
            let changed = previous?.completion != completion
            let finishedObservedRun =
                previous?.running == true && previous?.runBaselineCompletion != completion
                && (value.run == nil || previous?.run == value.run)
            entry.completion = completion
            if entry.viewed != completion, value.nativeUnread != false,
                value.nativeUnread == true || finishedObservedRun
                    || (!baseline && previous != nil && changed && previous?.running != true)
            {
                entry.unread = completion
            }
            // Only a native read transition for this same finished revision
            // clears it. Logout/missing identity is not evidence of a read.
            if value.nativeViewedCompletion == completion
                || (value.nativeViewedCompletion == nil && value.nativeUnread == false && previous?.nativeUnread == true
                    && previous?.completion == completion && previous?.nativeRevision == value.nativeRevision)
            {
                entry.unread = nil
                entry.viewed = completion
            }
        }
        if value.phase != .running {
            entry.run = nil
            entry.runBaselineCompletion = nil
        }
        if let native = value.nativeUnread {
            entry.nativeUnread = native
            entry.nativeRevision = value.nativeRevision
        }
        entries[value.key] = entry
    }

    /// Emit only newly confirmed completions, never startup history or failed turns.
    func completionEvent(_ value: ConversationActivityObservation, baseline: Bool) -> [String: String]? {
        guard !baseline, value.phase == .completed,
            let completion = value.completion, !completion.isEmpty,
            let previous = entries[value.key], previous.completion != completion,
            !previous.running || value.run == nil || previous.run == value.run
        else { return nil }
        let identity = [value.provider, value.id, completion].joined(separator: "\u{0}")
        let eventID = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return ["event": "taskCompleted", "eventId": eventID, "provider": value.provider, "threadId": value.id]
    }

    /// The captured revision matters when navigation overlaps a new completion.
    mutating func markViewed(provider: String, id: String, completion: String?) {
        let key = provider + ":" + id
        guard var entry = entries[key], let completion, entry.completion == completion || entry.unread == completion
        else { return }
        entry.viewed = completion
        if entry.unread == completion { entry.unread = nil }
        entries[key] = entry
    }

    /// Clears only the listed dots, each at its current revision, so a later completion still creates a new one.
    @discardableResult
    mutating func markAllViewed(keys: Set<String>) -> Int {
        let targets = entries.filter { keys.contains($0.key) && $0.value.unread != nil }
        for entry in targets.values { markViewed(provider: entry.provider, id: entry.id, completion: entry.unread) }
        return targets.count
    }

    mutating func removeMissing(provider: String, ids: Set<String>) {
        entries = entries.filter { $0.value.provider != provider || ids.contains($0.value.id) }
    }

    var snapshot: [String: Any] {
        let sessions = entries.values.filter { $0.running || $0.unread != nil }.sorted {
            if $0.running != $1.running { return $0.running }
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            return $0.id < $1.id
        }.map { entry -> [String: Any] in
            [
                "id": entry.id, "provider": entry.provider, "title": entry.title,
                "isRunning": entry.running, "isUnread": entry.unread != nil,
            ]
        }
        return [
            "runningCount": sessions.filter { $0["isRunning"] as? Bool == true }.count,
            "unreadCount": sessions.filter { $0["isUnread"] as? Bool == true }.count,
            "sessions": sessions,
        ]
    }
}

enum ConversationActivityTail {
    struct State: Equatable {
        var phase: ConversationActivityObservation.Phase = .idle
        var run: String?
        var completion: String?
        var startedAt: Double?
    }

    static func codex(_ data: Data, previous: State = .init(), offset: UInt64 = 0) -> State {
        var state = previous
        var position = offset
        for line in data.split(separator: 10, omittingEmptySubsequences: false) {
            defer { position += UInt64(line.count + 1) }
            // Tool output and message bodies are not JSON-decoded by this reader.
            guard
                line.range(of: Data("\"task_started\"".utf8)) != nil
                    || line.range(of: Data("\"task_complete\"".utf8)) != nil
                    || line.range(of: Data("\"turn_aborted\"".utf8)) != nil,
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any]
            else { continue }
            let turn = payload["turn_id"] as? String
            switch payload["type"] as? String {
            case "task_started":
                state.phase = .running
                state.run = turn ?? "offset:\(position)"
                if let number = payload["started_at"] as? NSNumber {
                    state.startedAt = number.doubleValue > 1e12 ? number.doubleValue / 1000 : number.doubleValue
                } else if let stamp = (payload["started_at"] ?? object["timestamp"]) as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = formatter.date(from: stamp) {
                        state.startedAt = date.timeIntervalSince1970
                    } else {
                        formatter.formatOptions = [.withInternetDateTime]
                        state.startedAt = formatter.date(from: stamp)?.timeIntervalSince1970
                    }
                }
            case "turn_aborted":
                state.phase = .failed
                state.run = turn
                state.completion = nil
            case "task_complete":
                let hasError = payload["error"] != nil && !(payload["error"] is NSNull)
                if hasError
                    || ["failed", "error", "cancelled", "canceled", "interrupted", "aborted"].contains(
                        payload["status"] as? String ?? "")
                {
                    state.phase = .failed
                    state.run = turn
                    state.completion = nil
                } else {
                    state.phase = .completed
                    state.run = turn
                    let stamp = String(describing: payload["completed_at"] ?? object["timestamp"] ?? position)
                    state.completion = (turn ?? "offset:\(position)") + ":" + stamp
                }
            default: break
            }
        }
        return state
    }

    static func claude(_ data: Data) -> State {
        for line in data.split(separator: 10).reversed() {
            guard
                line.range(of: Data("\"stop_reason\"".utf8)) != nil || line.range(of: Data("\"is_error\"".utf8)) != nil
                    || line.range(of: Data("\"isApiErrorMessage\"".utf8)) != nil,
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                object["isSidechain"] as? Bool != true
            else { continue }
            if object["type"] as? String == "result" {
                if object["is_error"] as? Bool == true { return .init(phase: .failed) }
                if object["subtype"] as? String == "success", let id = object["uuid"] as? String {
                    return .init(phase: .completed, completion: id)
                }
            }
            if object["type"] as? String == "assistant", let message = object["message"] as? [String: Any] {
                if object["isApiErrorMessage"] as? Bool == true { return .init(phase: .failed) }
                guard message["stop_reason"] as? String == "end_turn", let id = object["uuid"] as? String else {
                    continue
                }
                return .init(phase: .completed, completion: id)
            }
        }
        return .init()
    }
}

struct ConversationActivityScan {
    var observations: [ConversationActivityObservation] = []
    var visibleIDs: [String: Set<String>] = [:]
    var paths: Set<String> = []
}

protocol ConversationActivitySource: AnyObject, Sendable {
    func scan(tracked: [String: ConversationActivityLedger.Entry]) -> ConversationActivityScan
    func contains(provider: String, id: String) -> Bool
    func acceptsCodexContext(_ params: [String: Any]) -> Bool
    func acceptCodexReadState(_ params: [String: Any])
}

/// Independent of phone subscriptions. File events coalesce; there is no idle
/// network/history polling, hooks, or executor created for activity detection.
final class ConversationActivity: @unchecked Sendable {
    static let shared = ConversationActivity()
    typealias Opener = @Sendable (String, String) async throws -> Void
    private let queue = DispatchQueue(label: "vibepier.conversation-activity")
    private let lock = NSLock()
    private let file: URL
    private let source: any ConversationActivitySource
    private var ledger: ConversationActivityLedger
    private var cached: [String: Any]
    private var completions: [String: String]
    private var completionHandler: (@Sendable ([String: String]) -> Void)?
    private var opener: Opener?
    private var started = false
    private var baselined: Set<String> = []
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var scheduled: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private let ipc: CodexIPC?
    private var ipcConnected = false
    private var storageReadable = true

    init(
        file: URL = Paths.supportDirectory.appendingPathComponent("conversation-activity.json"),
        source: (any ConversationActivitySource)? = nil
    ) {
        self.file = file
        self.source = source ?? NativeConversationActivitySource()
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                ledger = try JSONDecoder().decode(ConversationActivityLedger.self, from: Data(contentsOf: file))
            } catch {
                ledger = .init()
                storageReadable = false
            }
        } else {
            ledger = .init()
        }
        cached = ledger.snapshot
        completions = ledger.entries.compactMapValues { $0.unread ?? $0.completion }
        ipc = source == nil ? CodexIPC() : nil
    }

    var snapshot: [String: Any] { lock.withLock { cached } }
    func setOpener(_ value: @escaping Opener) { lock.withLock { opener = value } }

    func setCompletionHandler(_ value: @escaping @Sendable ([String: String]) -> Void) {
        lock.withLock { completionHandler = value }
    }

    func start() {
        queue.async { [self] in
            guard !self.started else { return }
            self.started = true
            self.baselined.removeAll()
            self.ipc?.broadcast = { [weak self] data in
                self?.queue.async { [weak self] in
                    guard let self, self.started,
                        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        object["method"] as? String == "thread-read-state-changed", object["version"] as? Int == 3,
                        let params = object["params"] as? [String: Any]
                    else { return }
                    self.source.acceptCodexReadState(params)
                    self.schedule()
                }
            }
            self.ipc?.disconnected = { [weak self] in self?.queue.async { [weak self] in self?.ipcConnected = false } }
            let center = NSWorkspace.shared.notificationCenter
            for name in [
                NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification,
            ] {
                self.observers.append(
                    center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                        self?.queue.async { [weak self] in self?.schedule() }
                    })
            }
            self.refresh()
        }
    }

    func stop() {
        queue.sync {
            started = false
            scheduled?.cancel()
            scheduled = nil
            for watcher in watchers.values { watcher.cancel() }
            watchers.removeAll()
            let center = NSWorkspace.shared.notificationCenter
            for observer in observers { center.removeObserver(observer) }
            observers.removeAll()
            ipc?.close()
            ipcConnected = false
        }
    }

    func markViewed(provider: String, id: String) {
        markViewed(provider: provider, id: id, completion: viewCompletion(provider: provider, id: id))
    }

    func viewCompletion(provider: String, id: String) -> String? { lock.withLock { completions[provider + ":" + id] } }

    func acceptsCodexContext(_ params: [String: Any]) -> Bool { queue.sync { source.acceptsCodexContext(params) } }

    func markViewed(provider: String, id: String, completion: String?) {
        queue.sync {
            let previous = ledger
            ledger.markViewed(provider: provider, id: id, completion: completion)
            commit(previous)
        }
    }

    @discardableResult
    func markAllViewed(keys: Set<String>) -> Int {
        queue.sync {
            let previous = ledger
            let count = ledger.markAllViewed(keys: keys)
            commit(previous)
            return count
        }
    }

    func open(provider: String, id: String) async throws {
        let completion: String? = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.source.contains(provider: provider, id: id) else {
                    continuation.resume(
                        throwing: CLIError(
                            L10n.text("session.the_native_session_no_longer_exists_or_could_not_be_verified_nothing")))
                    return
                }
                let entry = self.ledger.entries[provider + ":" + id]
                continuation.resume(returning: entry?.unread ?? entry?.completion)
            }
        }
        guard let open = lock.withLock({ opener }) else {
            throw CLIError(L10n.text("session.this_provider_has_no_configured_opener_that_verifies_the_native_sess"))
        }
        try await open(provider, id)
        // If another turn finished while the native app navigated, retain its dot.
        queue.sync {
            let previous = ledger
            ledger.markViewed(provider: provider, id: id, completion: completion)
            commit(previous)
        }
    }

    private func schedule() {
        guard started, scheduled == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            guard self.started else { return }
            self.refresh()
        }
        scheduled = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func refresh() {
        if !ipcConnected, let ipc {
            do {
                try ipc.connect()
                ipcConnected = true
            } catch {}
        }
        let previous = ledger
        let scan = source.scan(tracked: ledger.entries)
        for (provider, ids) in scan.visibleIDs { ledger.removeMissing(provider: provider, ids: ids) }
        var completed: [[String: String]] = []
        for observation in scan.observations {
            let baseline = !baselined.contains(observation.provider)
            if let event = ledger.completionEvent(observation, baseline: baseline) { completed.append(event) }
            ledger.observe(observation, baseline: baseline)
        }
        baselined.formUnion(scan.visibleIDs.keys)
        commit(previous)
        if let handler = lock.withLock({ completionHandler }) { completed.forEach(handler) }
        watch(scan.paths)
    }

    private func commit(_ previous: ConversationActivityLedger) {
        guard previous != ledger else { return }
        if storageReadable {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(ledger) {
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        let value = ledger.snapshot
        let changed = !NSDictionary(dictionary: snapshot).isEqual(to: value)
        let revisions = ledger.entries.compactMapValues { $0.unread ?? $0.completion }
        lock.withLock {
            cached = value
            completions = revisions
        }
        if changed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: nil)
            }
        }
    }

    private func watch(_ requested: Set<String>) {
        var paths = requested
        for path in requested {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            while !FileManager.default.fileExists(atPath: parent), parent != "/" {
                parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            }
            paths.insert(parent)
        }
        for path in Set(watchers.keys).subtracting(paths) { watchers.removeValue(forKey: path)?.cancel() }
        for path in paths where watchers[path] == nil {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
            watcher.setEventHandler { [weak self] in
                guard let self, self.started else { return }
                let flags = self.watchers[path]?.data ?? []
                if flags.contains(.delete) || flags.contains(.rename) {
                    self.watchers.removeValue(forKey: path)?.cancel()
                }
                self.schedule()
            }
            watcher.setCancelHandler { Darwin.close(fd) }
            watchers[path] = watcher
            watcher.resume()
        }
    }
}
