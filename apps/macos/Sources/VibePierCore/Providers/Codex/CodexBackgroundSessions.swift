import AppKit
import Darwin
import Foundation

/// Owns only threads created by this gateway. Account storage remains native; no
/// credential or prompt is copied into the private ownership registry.
final class CodexBackgroundSessions: @unchecked Sendable {
    private struct Record: Codable {
        let cwd: String
        let projectID: String
        let settings: Data
        var submissions: [String: Submission]?
    }
    private struct Submission: Codable {
        let inputHash: String
        var turnID: String?
    }
    private struct Registry: Codable {
        var version = 1
        var threads: [String: Record] = [:]
    }
    private struct Pending {
        let nativeID: Data
        let source: [String: Any]
        let turn: String
        var submitted = false
        var resolved = false
    }
    private let registryURL: URL
    private let confirmationTimeout: TimeInterval
    private var readTurnEvidence:
        (String, String, String, String, String, String) throws -> CodexBackgroundTurnEvidence.Proof?
    private let connectNative: () throws -> CodexRuntimeConnection
    private let operations = NSRecursiveLock()
    private let stateLock = NSLock()
    private let eventQueue = DispatchQueue(label: "vibepier.codex-background-events")
    private var registry: Registry?
    private var registryFailed = false
    private var connection: CodexRuntimeConnection?
    private var connectionGeneration = UUID()
    private var loaded = Set<String>()
    private var nativeSettings: [String: [String: Any]] = [:]
    private var settingsVersions: [String: Int] = [:]
    private var turnModes: [String: [String: [String: Any]]] = [:]
    private var requests: [String: [String: Pending]] = [:]
    private var tokenUsage: [String: [String: Any]] = [:]
    private var sink: (@Sendable (String) -> Void)?
    var event: (@Sendable (String) -> Void)? {
        get { stateLock.withLock { sink } }
        set { stateLock.withLock { sink = newValue } }
    }

    init(
        directory: URL = Paths.supportDirectory.appendingPathComponent("codex-background"),
        confirmationTimeout: TimeInterval = 10,
        connectNative: (() throws -> CodexRuntimeConnection)? = nil
    ) {
        registryURL = directory.appendingPathComponent("threads.json")
        self.confirmationTimeout = min(10, max(0.02, confirmationTimeout))
        readTurnEvidence =
            { thread, cwd, project, turn, marker, hash in
                guard let file = try CodexThreadStore().backgroundRollout(thread: thread, cwd: cwd, projectID: project)
                else {
                    return nil
                }
                return CodexBackgroundTurnEvidence.read(
                    file: file, thread: thread, cwd: cwd, turn: turn, marker: marker, inputHash: hash)
            }
        self.connectNative =
            connectNative ?? {
                let bundle =
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first?
                    .bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
                // The reviewed bundle's bin/codex is a shell wrapper. Use its exact
                // Mach-O target so process identity remains verifiable on reconnect.
                guard
                    let executable = bundle?.appendingPathComponent(
                        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
                    FileManager.default.isExecutableFile(atPath: executable.path)
                else { throw CLIError(L10n.text("usage.codex_missing")) }
                return try CodexSocketRuntimeConnection(
                    configuration: .init(enabled: true, executablePath: executable.path, directoryPath: directory.path),
                    nativeHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
            }
    }

    convenience init(
        directory: URL, confirmationTimeout: TimeInterval = 10,
        turnEvidence:
            @escaping (String, String, String, String, String, String) throws -> CodexBackgroundTurnEvidence.Proof?,
        connectNative: @escaping () throws -> CodexRuntimeConnection
    ) {
        self.init(directory: directory, confirmationTimeout: confirmationTimeout, connectNative: connectNative)
        readTurnEvidence = turnEvidence
    }

    func owns(thread: String) throws -> Bool {
        try operations.withLock { try readRegistry().threads[thread] != nil }
    }

    func owner(thread: String) throws -> String {
        try operations.withLock {
            _ = try record(thread)
            return "vibepier-background:" + (try native()).instanceID
        }
    }

    /// Registry membership is sufficient to list a session, never to authorize a
    /// write. The native cwd and current owner are checked again when it is opened.
    func listed(cwd: String? = nil, search: String = "") throws -> [[String: Any]] {
        try operations.withLock {
            try readRegistry().threads.sorted { $0.key < $1.key }.compactMap { id, entry in
                guard cwd == nil || cwd == entry.cwd,
                    search.isEmpty
                        || entry.cwd.localizedCaseInsensitiveContains(search)
                else { return nil }
                return [
                    "id": id, "threadId": id, "cwd": entry.cwd,
                    "title": URL(fileURLWithPath: entry.cwd).lastPathComponent,
                ]
            }
        }
    }

    func view(thread: String) throws -> CodexConfiguredCreation.View {
        try operations.withLock {
            let entry = try record(thread)
            let native = try native()
            try load(thread, entry: entry, native: native)
            let reply = try rpc(native, "thread/read", ["threadId": thread, "includeTurns": true])
            return .init(owner: try owner(thread: thread), state: try project(reply, thread: thread, entry: entry))
        }
    }

    /// Readback is matched against the digest reserved before native submission.
    /// A client marker alone cannot upgrade a lost/wrong-body response to success.
    func receipt(thread: String, marker: String) throws -> [String: Any] {
        try operations.withLock {
            guard let proof = try record(thread).submissions?[marker] else {
                return ["accepted": false, "threadId": thread]
            }
            let state = try view(thread: thread).state
            var found: [(String, [String: Any])] = []
            for turn in CodexConversation.turns(state) {
                guard let id = turn["turnId"] as? String else { continue }
                for item in turn["items"] as? [[String: Any]] ?? [] {
                    let accepted =
                        item["type"] as? String == "userMessage"
                        || (item["type"] as? String == "steeringUserMessage" && item["status"] as? String == "accepted")
                    if accepted, (item["clientId"] as? String ?? item["clientUserMessageId"] as? String) == marker {
                        found.append((id, item))
                    }
                }
            }
            guard found.count == 1, proof.turnID == nil || proof.turnID == found[0].0,
                let content = found[0].1["content"] as? [[String: Any]]
                    ?? found[0].1["input"] as? [[String: Any]],
                try Self.inputHash(content) == proof.inputHash
            else {
                return ["accepted": false, "threadId": thread]
            }
            return [
                "accepted": true, "threadId": thread, "nativeMessageId": marker,
                "turnId": found[0].0, "turnIdentityKind": "nativeTurn",
            ]
        }
    }

    /// Recover one exact original creation, including after the app restarts.
    /// Registry intent/current settings never stand in for first-turn evidence.
    func creationReceipt(request: [String: Any], client: String, expectedInput: [[String: Any]]) throws -> [String:
        Any]?
    {
        try operations.withLock {
            guard let operation = request["operation"] as? String, UUID(uuidString: operation) != nil,
                let cwd = request["cwd"] as? String, request["provider"] as? String == "codex",
                !expectedInput.isEmpty
            else { return nil }
            let hash = try Self.inputHash(expectedInput)
            var candidates: [(String, Record, String, Submission)] = []
            for (thread, entry) in try readRegistry().threads where entry.cwd == cwd {
                let marker = try CodexMessageIdentity(client: client, thread: thread, operation: operation).nativeID
                if let proof = entry.submissions?[marker], proof.inputHash == hash {
                    candidates.append((thread, entry, marker, proof))
                }
            }
            guard candidates.count == 1 else { return nil }
            let (thread, entry, marker, stored) = candidates[0]
            let configured = try object(entry.settings)
            let intentComposer = CodexComposer.selection([
                "latestThreadSettings": configured, "currentPermissions": configured,
            ])
            for key in ["model", "effort", "mode", "executionMode", "serviceTier"] where request[key] != nil {
                guard request[key] is String, request[key] as? String == intentComposer[key] as? String else {
                    return nil
                }
            }
            let actual = try view(thread: thread).state
            let inputReceipt = try receipt(thread: thread, marker: marker)
            guard inputReceipt["accepted"] as? Bool == true, let turn = inputReceipt["turnId"] as? String,
                CodexConversation.turns(actual).first?["turnId"] as? String == turn,
                stored.turnID == nil || stored.turnID == turn
            else { return nil }
            if stored.turnID == nil {
                try saveSubmission(thread, marker: marker, proof: .init(inputHash: hash, turnID: turn))
            }
            var result: [String: Any] = [
                "ok": false, "accepted": false, "unknown": true, "provider": "codex", "threadId": thread,
                "cwd": cwd, "nativeMessageId": marker, "nativeTurnId": turn,
                "title": String((request["text"] as? String ?? "").prefix(80)),
            ]
            guard let evidence = try readTurnEvidence(thread, cwd, entry.projectID, turn, marker, hash) else {
                return result
            }
            let modeSettings = evidence.mode["settings"] as? [String: Any] ?? [:]
            var expected = configured.filter {
                ["collaborationMode", "model", "effort", "serviceTier"].contains($0.key)
            }
            if expected["serviceTier"] == nil { expected["serviceTier"] = NSNull() }
            let effective: [String: Any] = [
                "collaborationMode": evidence.mode, "model": modeSettings["model"] ?? NSNull(),
                "effort": modeSettings["reasoning_effort"] ?? NSNull(),
                "serviceTier": evidence.serviceTier == "standard" ? "default" : evidence.serviceTier,
            ]
            guard Self.matches(expected, effective, runtimeVersion: try native().runtimeVersion) else { return result }
            stateLock.withLock { turnModes[thread, default: [:]][turn] = evidence.mode }
            var historicalComposer = intentComposer
            historicalComposer["executionMode"] = evidence.mode["mode"]
            historicalComposer["serviceTier"] = evidence.serviceTier
            result["ok"] = true
            result["accepted"] = true
            result.removeValue(forKey: "unknown")
            result["composer"] = historicalComposer
            if let requested = request["executionMode"] as? String {
                result["executionModeVerified"] = true
                result["effectiveExecutionMode"] = requested
            }
            return result
        }
    }

    func perform(
        input: CodexConfiguredCreation.Input, observation: CodexConfiguredCreation.Observation,
        arm: () -> Void
    ) throws -> Data {
        try operations.withLock {
            let settings = try object(input.settings)
            guard input.settings.count <= 32_000, Self.settingsKeys.isSuperset(of: settings.keys) else {
                throw RuntimeDriverError.invalidRequest
            }
            guard try readRegistry().threads.count < 256 else { throw RuntimeDriverError.quotaExceeded }
            let native = try native()
            return try CodexConfiguredCreation.run(
                input,
                services: .init(
                    start: { parameters in
                        let started = try CodexThreadBootstrap.startPersisted(
                            parameters: parameters, project: input.project, settings: settings, title: input.text
                        ) { method, params in try self.rpc(native, method, params) }
                        let created = try CodexThreadBootstrap.verified(
                            started, project: input.project, settings: settings)
                        try self.register(
                            created.id,
                            record: .init(
                                cwd: created.cwd, projectID: input.project.id, settings: input.settings,
                                submissions: nil))
                        try self.load(
                            created.id, entry: self.record(created.id), native: native, creationSettings: settings)
                        let actual = self.stateLock.withLock { self.nativeSettings[created.id] ?? [:] }
                        guard
                            Self.matches(
                                settings.filter {
                                    $0.key != "collaborationMode" && $0.key != "serviceTier"
                                }, actual, runtimeVersion: native.runtimeVersion)
                        else { throw RuntimeDriverError.staleOwner }
                        return started
                    }, open: { _ in }, view: { try self.view(thread: $0) },
                    send: { owner, parameters in
                        guard let thread = parameters["conversationId"] as? String,
                            try self.owner(thread: thread) == owner,
                            let turnStart = parameters["turnStart"] as? [String: Any],
                            let request = turnStart["request"] as? [String: Any]
                        else { throw RuntimeDriverError.staleOwner }
                        let result = try self.submit(thread: thread, parameters: request, native: native)
                        return ["result": ["result": result]]
                    }), observation: observation, arm: arm)
        }
    }

    /// Desktop-owned creation: this private App Server only persists the empty native thread, then lets go of it so
    /// the Codex desktop app becomes its single live owner. Nothing is registered as background-owned.
    func startForDesktop(
        _ parameters: [String: Any], project: CodexCreationProject, settings: [String: Any], title: String
    ) throws -> [String: Any] {
        try operations.withLock {
            let native = try native()
            let started = try CodexThreadBootstrap.startPersisted(
                parameters: parameters, project: project, settings: settings, title: title
            ) { method, params in try self.rpc(native, method, params) }
            let created = try CodexThreadBootstrap.verified(started, project: project, settings: settings)
            // A still-subscribed proxy would be a second writer once the desktop submits the first turn.
            _ = try rpc(native, "thread/unsubscribe", ["threadId": created.id])
            loaded.remove(created.id)
            return started
        }
    }

    /// Moves a thread created by an earlier build from this proxy to the desktop app, so its turns render live there.
    /// Refused while a background turn is running; the registry entry is removed only after the proxy unsubscribes.
    func releaseToDesktop(thread: String) throws {
        try operations.withLock {
            let entry = try record(thread)
            let native = try native()
            let reply = try rpc(native, "thread/read", ["threadId": thread, "includeTurns": true])
            _ = try checkedThread(reply, thread: thread, entry: entry)
            guard activeNative(reply) == nil else { throw RuntimeDriverError.staleOwner }
            if loaded.contains(thread) { _ = try rpc(native, "thread/unsubscribe", ["threadId": thread]) }
            loaded.remove(thread)
            try withRegistryWriteLock {
                var next = try readRegistry()
                next.threads.removeValue(forKey: thread)
                try RuntimePrivateStorage.write(try JSONEncoder().encode(next), to: registryURL)
                stateLock.withLock {
                    registry = next
                    requests.removeValue(forKey: thread)
                    nativeSettings.removeValue(forKey: thread)
                }
            }
        }
    }

    func mutate(op: String, request: [String: Any], client: String) throws -> [String: Any] {
        try operations.withLock {
            guard let thread = request["threadId"] as? String else { throw RuntimeDriverError.invalidRequest }
            let current = try view(thread: thread)
            let native = try native()
            if op == "send" || op == "steer" {
                guard let operation = request["id"] as? String else { throw RuntimeDriverError.invalidRequest }
                let identity = try CodexMessageIdentity(client: client, thread: thread, operation: operation)
                let input =
                    request["input"] as? [[String: Any]] ?? [
                        ["type": "text", "text": request["text"] as? String ?? ""]
                    ]
                var parameters: [String: Any] = [
                    "threadId": thread, "input": input, "clientUserMessageId": identity.nativeID,
                ]
                if op == "steer" {
                    guard let turn = active(current.state), request["expectedTurnId"] as? String == turn else {
                        throw RuntimeDriverError.staleOwner
                    }
                    parameters["expectedTurnId"] = turn
                    let result = try submit(
                        thread: thread, parameters: parameters, native: native, method: "turn/steer")
                    return [
                        "accepted": true, "threadId": thread, "nativeMessageId": identity.nativeID,
                        "turnId": result["turnId"] ?? "", "turnIdentityKind": "nativeTurn",
                    ]
                }
                guard active(current.state) == nil else { throw RuntimeDriverError.staleOwner }
                let result = try submit(thread: thread, parameters: parameters, native: native)
                let turn = result["turn"] as? [String: Any] ?? [:]
                return [
                    "accepted": true, "threadId": thread, "nativeMessageId": identity.nativeID,
                    "turnId": turn["id"] ?? "", "turnIdentityKind": "nativeTurn",
                ]
            }
            if op == "settings" {
                guard let settings = request["settings"] as? [String: Any], !settings.isEmpty,
                    Self.settingsKeys.isSuperset(of: settings.keys), active(current.state) == nil
                else { throw RuntimeDriverError.invalidRequest }
                let entry = try record(thread)
                let refreshVersion = stateLock.withLock { settingsVersions[thread] ?? 0 }
                let refreshed = try rpc(native, "thread/resume", ["threadId": thread, "cwd": entry.cwd])
                _ = try checkedThread(refreshed, thread: thread, entry: entry)
                let effective = mergeRefreshedSettings(refreshed, thread: thread, version: refreshVersion)
                if Self.matches(settings, effective, runtimeVersion: native.runtimeVersion) {
                    let actual = try view(thread: thread)
                    let composer = try CodexExecutionMode.verifiedComposer(actual.state, request: request)
                    return [
                        "accepted": true, "threadId": thread, "composer": composer,
                        "executionModeVerified": request["executionMode"] != nil,
                    ]
                }
                let before = stateLock.withLock { settingsVersions[thread] ?? 0 }
                return try UnconfirmedDesktopMutation.attempting {
                    _ = try rpc(native, "thread/settings/update", settings.merging(["threadId": thread]) { $1 })
                    guard
                        waitFor({
                            self.stateLock.withLock {
                                (self.settingsVersions[thread] ?? 0) > before
                                    && Self.matches(
                                        settings, self.nativeSettings[thread] ?? [:],
                                        runtimeVersion: native.runtimeVersion)
                            }
                        })
                    else { throw RuntimeDriverError.unavailable }
                    let actual = try self.view(thread: thread)
                    let composer = try CodexExecutionMode.verifiedComposer(actual.state, request: request)
                    return [
                        "accepted": true, "threadId": thread, "composer": composer,
                        "executionModeVerified": request["executionMode"] != nil,
                    ]
                }
            }
            if op == "interrupt" {
                guard let turn = active(current.state), request["expectedTurnId"] as? String == turn else {
                    throw RuntimeDriverError.staleOwner
                }
                return try UnconfirmedDesktopMutation.attempting {
                    _ = try rpc(native, "turn/interrupt", ["threadId": thread, "turnId": turn])
                    guard
                        try waitForRead(
                            thread: thread,
                            { state in
                                CodexConversation.turns(state).contains {
                                    ($0["turnId"] as? String) == turn && $0["status"] as? String == "interrupted"
                                }
                            })
                    else { throw RuntimeDriverError.unavailable }
                    return [
                        "accepted": true, "threadId": thread, "turnId": turn,
                        "interruptRequested": true, "turnIdentityKind": "nativeTurn",
                    ]
                }
            }
            if op == "approve" || op == "answerQuestion" {
                return try approve(request, thread: thread, current: current.state, native: native)
            }
            throw CLIError(L10n.text("session.unsupported_session_operation"))
        }
    }

    private static let settingsKeys: Set<String> = [
        "model", "effort", "permissions", "approvalPolicy", "approvalsReviewer", "collaborationMode", "serviceTier",
    ]
    private func readRegistry() throws -> Registry {
        if registryFailed { throw RuntimeDriverError.storageUnavailable }
        do {
            var info = stat()
            let exists = lstat(registryURL.path, &info) == 0
            if !exists, errno != ENOENT { throw RuntimeDriverError.storageUnavailable }
            if !exists, stateLock.withLock({ registry?.threads.isEmpty == false }) {
                throw RuntimeDriverError.storageUnavailable
            }
            let result =
                exists
                ? try JSONDecoder().decode(
                    Registry.self, from: RuntimePrivateStorage.read(registryURL, limit: 2_097_152)) : Registry()
            guard result.version == 1, result.threads.count <= 256 else { throw RuntimeDriverError.storageUnavailable }
            for (id, record) in result.threads {
                guard UUID(uuidString: id) != nil, UUID(uuidString: record.projectID) != nil,
                    record.cwd.hasPrefix("/"), !record.cwd.contains("\0"), record.cwd.utf8.count <= 4096,
                    record.settings.count <= 32_000,
                    Self.settingsKeys.isSuperset(of: try object(record.settings).keys),
                    (record.submissions?.count ?? 0) <= 256,
                    (record.submissions ?? [:]).allSatisfy({ marker, proof in
                        !marker.isEmpty && marker.utf8.count <= 256 && proof.inputHash.count == 64
                            && proof.inputHash.allSatisfy({ $0.isHexDigit })
                            && (proof.turnID.map { !$0.isEmpty && $0.utf8.count <= 256 } ?? true)
                    })
                else { throw RuntimeDriverError.storageUnavailable }
            }
            stateLock.withLock { registry = result }
            return result
        } catch {
            registryFailed = true
            throw RuntimeDriverError.storageUnavailable
        }
    }
    private func record(_ thread: String) throws -> Record {
        guard let record = try readRegistry().threads[thread] else { throw RuntimeDriverError.staleOwner }
        return record
    }
    private func register(_ thread: String, record: Record) throws {
        try withRegistryWriteLock { try registerLocked(thread, record: record) }
    }
    private func registerLocked(_ thread: String, record: Record) throws {
        var next = try readRegistry()
        guard next.threads[thread] == nil, next.threads.count < 256 else { throw RuntimeDriverError.quotaExceeded }
        next.threads[thread] = record
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= 2_097_152 else { throw RuntimeDriverError.quotaExceeded }
        try RuntimePrivateStorage.write(bytes, to: registryURL)
        stateLock.withLock { registry = next }
    }
    private func saveSubmission(_ thread: String, marker: String, proof: Submission, reserve: Bool = false) throws {
        try withRegistryWriteLock { try saveSubmissionLocked(thread, marker: marker, proof: proof, reserve: reserve) }
    }
    private func saveSubmissionLocked(_ thread: String, marker: String, proof: Submission, reserve: Bool) throws {
        var next = try readRegistry()
        guard var entry = next.threads[thread], marker.utf8.count <= 256 else { throw RuntimeDriverError.staleOwner }
        if let existing = entry.submissions?[marker] {
            guard existing.inputHash == proof.inputHash else { throw RuntimeDriverError.invalidRequest }
            if reserve { throw UnconfirmedDesktopMutation(reason: L10n.text("core.invalid_receipt")) }
            guard existing.turnID == nil || existing.turnID == proof.turnID else { throw RuntimeDriverError.staleOwner }
        } else if !reserve {
            throw RuntimeDriverError.staleOwner
        }
        if entry.submissions?[marker] == nil, (entry.submissions?.count ?? 0) >= 256 {
            throw RuntimeDriverError.quotaExceeded
        }
        var proofs = entry.submissions ?? [:]
        proofs[marker] = proof
        entry.submissions = proofs
        next.threads[thread] = entry
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= 2_097_152 else { throw RuntimeDriverError.quotaExceeded }
        try RuntimePrivateStorage.write(bytes, to: registryURL)
        stateLock.withLock { registry = next }
    }
    /// Atomic replacement protects readers; a separate, stable inode serializes
    /// read/modify/write across the app and CLI's independently owned adapters.
    private func withRegistryWriteLock<T>(_ body: () throws -> T) throws -> T {
        try RuntimePrivateStorage.ensureDirectory(registryURL.deletingLastPathComponent())
        let fd = Darwin.open(
            registryURL.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw RuntimeDriverError.storageUnavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
            info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1
        else { throw RuntimeDriverError.storageUnavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR,
                ProcessInfo.processInfo.systemUptime < deadline
            else { throw RuntimeDriverError.storageUnavailable }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    private func native() throws -> CodexRuntimeConnection {
        if let connection {
            if connection.connected { return connection }
            stateLock.withLock { connectionGeneration = UUID() }
            connection.onNotification = nil
            connection.onServerRequest = nil
            connection.disconnect()
            self.connection = nil
            loaded.removeAll()
            stateLock.withLock {
                nativeSettings.removeAll()
                settingsVersions.removeAll()
                // Reverse RPC identities belong to the old proxy connection.
                // Reconnect can observe history, never repeat their decisions.
                requests.removeAll()
                tokenUsage.removeAll()
            }
        }
        let candidate = try connectNative()
        let generation = stateLock.withLock { () -> UUID in
            connectionGeneration = UUID()
            return connectionGeneration
        }
        candidate.onNotification = { [weak self] method, bytes in
            self?.receive(method, bytes: bytes, generation: generation)
        }
        candidate.onServerRequest = { [weak self] id, method, bytes in
            self?.receiveRequest(id, method: method, bytes: bytes, generation: generation) ?? false
        }
        connection = candidate
        return candidate
    }
    private func load(
        _ thread: String, entry: Record, native: CodexRuntimeConnection, creationSettings: [String: Any]? = nil
    ) throws {
        if loaded.contains(thread) { return }
        // Read an exact registered ID before loading it. Never list or resume an
        // arbitrary desktop session, and never replace an active external writer.
        let before = try rpc(native, "thread/read", ["threadId": thread, "includeTurns": true])
        _ = try checkedThread(before, thread: thread, entry: entry)
        let status = ((before["thread"] as? [String: Any])?["status"] as? [String: Any])?["type"] as? String
        guard ["notLoaded", "idle", "active"].contains(status ?? "") else { throw RuntimeDriverError.staleOwner }
        let previousTurn = activeNative(before)
        // resume attaches this proxy to the exact owned thread's event stream;
        // it does not submit a turn or overwrite its native configuration.
        let settingsVersion = stateLock.withLock { settingsVersions[thread] ?? 0 }
        let reply = try rpc(
            native, "thread/resume",
            Self.resumeParameters(thread: thread, cwd: entry.cwd, creationSettings: creationSettings))
        _ = try checkedThread(reply, thread: thread, entry: entry)
        if status == "active", activeNative(reply) != previousTurn { throw RuntimeDriverError.staleOwner }
        _ = mergeRefreshedSettings(reply, thread: thread, version: settingsVersion)
        loaded.insert(thread)
    }
    private func mergeRefreshedSettings(_ reply: [String: Any], thread: String, version: Int) -> [String: Any] {
        stateLock.withLock {
            // A notification can arrive between the RPC's snapshot and return.
            // Preserve that newer native state together with its version.
            if (settingsVersions[thread] ?? 0) == version { nativeSettings[thread] = Self.settings(reply) }
            return nativeSettings[thread] ?? [:]
        }
    }
    static func resumeParameters(
        thread: String, cwd: String, creationSettings: [String: Any]? = nil
    ) -> [String: Any] {
        var parameters: [String: Any] = ["threadId": thread, "cwd": cwd]
        if let settings = creationSettings {
            for key in ["model", "permissions", "approvalPolicy", "approvalsReviewer", "serviceTier"] {
                parameters[key] = settings[key]
            }
            if let effort = settings["effort"] as? String {
                parameters["config"] = ["model_reasoning_effort": effort]
            }
        }
        return parameters
    }
    private func checkedThread(_ reply: [String: Any], thread: String, entry: Record) throws -> [String: Any] {
        guard let raw = reply["thread"] as? [String: Any], raw["id"] as? String == thread,
            raw["cwd"] as? String == entry.cwd, raw["projectId"] as? String == entry.projectID
        else { throw RuntimeDriverError.staleOwner }
        return raw
    }
    private func project(_ reply: [String: Any], thread: String, entry: Record) throws -> [String: Any] {
        let raw = try checkedThread(reply, thread: thread, entry: entry)
        guard let turns = raw["turns"] as? [[String: Any]] else { throw RuntimeDriverError.unavailable }
        var state = raw
        state["id"] = thread
        state["conversationId"] = thread
        state["title"] = raw["name"] ?? raw["preview"] ?? URL(fileURLWithPath: entry.cwd).lastPathComponent
        state["threadRuntimeStatus"] = raw["status"]
        state["resumeState"] = "resumed"
        let modes = stateLock.withLock { turnModes[thread] ?? [:] }
        state["turns"] = turns.map { turn in
            var result = turn
            result["turnId"] = turn["id"]
            if let id = turn["id"] as? String, let proof = modes[id], result["params"] == nil {
                result["params"] = ["collaborationMode": proof]
            }
            return result
        }
        let complete = turns.allSatisfy { turn in
            turn["itemsView"] == nil || turn["itemsView"] as? String == "full"
        }
        let activeTurns = Set(
            turns.filter { $0["status"] as? String == "inProgress" }.compactMap { $0["id"] as? String })
        state["turnsPagination"] = ["hasLoadedOldest": complete]
        stateLock.withLock {
            state["latestThreadSettings"] = nativeSettings[thread] ?? [:]
            state["currentPermissions"] = nativeSettings[thread] ?? [:]
            state["requests"] = (requests[thread] ?? [:]).values.filter {
                !$0.resolved && activeTurns.contains($0.turn)
            }.map(\.source)
            if let usage = tokenUsage[thread] { state["latestTokenUsageInfo"] = usage }
        }
        return state
    }
    private func submit(
        thread: String, parameters: [String: Any], native: CodexRuntimeConnection, method: String = "turn/start"
    ) throws -> [String: Any] {
        _ = try record(thread)
        guard parameters["threadId"] as? String == thread,
            let marker = parameters["clientUserMessageId"] as? String, !marker.isEmpty,
            let input = parameters["input"] as? [[String: Any]], !input.isEmpty,
            (try JSONSerialization.data(withJSONObject: input)).count <= 280_000
        else { throw RuntimeDriverError.invalidRequest }
        let before = stateLock.withLock { settingsVersions[thread] ?? 0 }
        let priorSettings = stateLock.withLock { nativeSettings[thread] ?? [:] }
        let hash = try Self.inputHash(input)
        if let existing = try record(thread).submissions?[marker] {
            guard existing.inputHash == hash else { throw RuntimeDriverError.invalidRequest }
            throw UnconfirmedDesktopMutation(reason: L10n.text("core.invalid_receipt"))
        }
        try saveSubmission(
            thread, marker: marker, proof: .init(inputHash: hash, turnID: parameters["expectedTurnId"] as? String),
            reserve: true)
        return try UnconfirmedDesktopMutation.attempting {
            let reply = try rpc(native, method, parameters)
            let turn = (reply["turn"] as? [String: Any])?["id"] as? String ?? reply["turnId"] as? String
            guard let turn, UUID(uuidString: turn) != nil else { throw RuntimeDriverError.unavailable }
            // ACK identifies the accepted native turn before its user item is
            // published. Retain it even if the read-only confirmation times out.
            try saveSubmission(thread, marker: marker, proof: .init(inputHash: hash, turnID: turn))
            guard
                try waitForRead(
                    thread: thread,
                    { state in
                        let turns = CodexConversation.turns(state).filter { $0["turnId"] as? String == turn }
                        guard turns.count == 1 else { return false }
                        let items = (turns[0]["items"] as? [[String: Any]] ?? []).filter {
                            ($0["type"] as? String == "userMessage"
                                || ($0["type"] as? String == "steeringUserMessage"
                                    && $0["status"] as? String == "accepted"))
                                && ($0["clientId"] as? String ?? $0["clientUserMessageId"] as? String) == marker
                        }
                        guard items.count == 1,
                            let content = items[0]["content"] as? [[String: Any]]
                                ?? items[0]["input"] as? [[String: Any]]
                        else { return false }
                        return Self.sameInput(input, content)
                    })
            else { throw RuntimeDriverError.unavailable }
            let expected = parameters.filter { ["collaborationMode", "serviceTier"].contains($0.key) }
            if !expected.isEmpty {
                guard
                    waitFor({
                        self.stateLock.withLock {
                            let actual = self.nativeSettings[thread] ?? [:]
                            return Self.matches(expected, actual, runtimeVersion: native.runtimeVersion)
                                && ((self.settingsVersions[thread] ?? 0) > before
                                    || Self.matches(expected, priorSettings, runtimeVersion: native.runtimeVersion))
                        }
                    })
                else { throw RuntimeDriverError.unavailable }
                stateLock.withLock {
                    if let proof = nativeSettings[thread]?["collaborationMode"] as? [String: Any],
                        parameters["collaborationMode"] != nil, turnModes[thread]?[turn] == nil
                    {
                        // The serialized native mutation, exact user item and a
                        // new matching settings notification bind this proof to
                        // the acknowledged turn. Later setters cannot alter it.
                        turnModes[thread, default: [:]][turn] = proof
                    }
                }
            }
            return reply
        }
    }
    /// Ignore only native empty text-element defaults. Every text/image/file
    /// value and its ordering must match; unsupported representations stay unknown.
    private static func sameInput(_ expected: [[String: Any]], _ actual: [[String: Any]]) -> Bool {
        guard let left = try? inputHash(expected), let right = try? inputHash(actual) else { return false }
        return left == right
    }
    private static func inputHash(_ input: [[String: Any]]) throws -> String {
        guard let canonical = CodexConfiguredCreation.Observation.canonicalInput(input) else {
            throw RuntimeDriverError.invalidRequest
        }
        return CodexConversation.dataHash(canonical)
    }
    private func approve(
        _ request: [String: Any], thread: String, current: [String: Any], native: CodexRuntimeConnection
    ) throws -> [String: Any] {
        guard let fingerprint = request["fingerprint"] as? String,
            let projected = CodexConversation.approvals(current).first(where: {
                $0["fingerprint"] as? String == fingerprint
            }),
            projected["canDecide"] as? Bool == true, let id = projected["id"],
            let nativeID = try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed])
        else { throw RuntimeDriverError.staleOwner }
        let key = CodexConversation.dataHash(nativeID)
        let pending = stateLock.withLock { requests[thread]?[key] }
        guard let pending, !pending.submitted, !pending.resolved, active(current) == pending.turn else {
            throw RuntimeDriverError.staleOwner
        }
        let response: [String: Any]
        if projected["kind"] as? String == "questions" {
            let submission = try CodexQuestions.submission(
                request, projected: projected, thread: thread, cwd: current["cwd"] as? String ?? "")
            guard submission.method == "thread-follower-submit-user-input",
                let value = submission.params["response"] as? [String: Any]
            else { throw RuntimeDriverError.invalidRequest }
            response = value
        } else {
            guard let allow = request["allow"] as? Bool else { throw RuntimeDriverError.invalidRequest }
            if pending.source["method"] as? String == "item/permissions/requestApproval" {
                guard let parameters = pending.source["params"] as? [String: Any],
                    let permissions = parameters["permissions"] as? [String: Any]
                else {
                    throw RuntimeDriverError.invalidRequest
                }
                response = ["permissions": allow ? permissions : [:], "scope": "turn"]
            } else {
                response = ["decision": allow ? "accept" : "decline"]
            }
        }
        stateLock.withLock { requests[thread]?[key]?.submitted = true }
        return try UnconfirmedDesktopMutation.attempting {
            try native.respond(requestID: pending.nativeID, result: JSONSerialization.data(withJSONObject: response))
            guard waitFor({ self.stateLock.withLock { self.requests[thread]?[key]?.resolved == true } }) else {
                throw RuntimeDriverError.unavailable
            }
            // This event proves resolution, but does not identify the adopted
            // decision/client. A competing proxy may have replied first.
            throw UnconfirmedDesktopMutation(reason: L10n.text("core.invalid_receipt"))
        }
    }
    private func receiveRequest(_ id: Data, method: String, bytes: Data, generation: UUID) -> Bool {
        guard
            [
                "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                "item/permissions/requestApproval", CodexQuestions.nativeMethod,
            ].contains(method),
            bytes.count <= 60_000, let params = try? object(bytes),
            let thread = params["threadId"] as? String, let turn = params["turnId"] as? String,
            let rawID = try? JSONSerialization.jsonObject(with: id, options: [.fragmentsAllowed])
        else { return false }
        let source: [String: Any] = ["id": rawID, "method": method, "params": params]
        let accepted = stateLock.withLock {
            guard generation == connectionGeneration, registry?.threads[thread] != nil, !turn.isEmpty,
                requests.values.reduce(0, { $0 + $1.count }) < 32,
                requests[thread]?[CodexConversation.dataHash(id)] == nil
            else { return false }
            requests[thread, default: [:]][CodexConversation.dataHash(id)] = .init(
                nativeID: id, source: source, turn: turn)
            return true
        }
        if accepted { notify(thread) }
        return accepted
    }
    private func receive(_ method: String, bytes: Data, generation: UUID) {
        if method == "vibepier/disconnected" {
            let threads = stateLock.withLock {
                generation == connectionGeneration ? registry.map { Array($0.threads.keys) } ?? [] : []
            }
            for thread in threads { notify(thread) }
            return
        }
        guard bytes.count <= 300_000, let value = try? object(bytes),
            let thread = value["threadId"] as? String ?? (value["thread"] as? [String: Any])?["id"] as? String
        else { return }
        let accepted = stateLock.withLock {
            guard generation == connectionGeneration, registry?.threads[thread] != nil else { return false }
            if method == "thread/settings/updated", let settings = value["threadSettings"] as? [String: Any],
                settings["cwd"] as? String == registry?.threads[thread]?.cwd
            {
                nativeSettings[thread] = Self.settings(settings)
                settingsVersions[thread, default: 0] += 1
            }
            if method == "serverRequest/resolved", let id = value["requestId"],
                let bytes = try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed])
            {
                let key = CodexConversation.dataHash(bytes)
                if requests[thread]?[key]?.submitted == true { requests[thread]?[key]?.resolved = true }
            }
            if method == "thread/tokenUsage/updated", let usage = value["tokenUsage"] as? [String: Any] {
                tokenUsage[thread] = usage
            }
            if method == "turn/completed", let turn = (value["turn"] as? [String: Any])?["id"] as? String {
                requests[thread] = requests[thread]?.filter { $0.value.turn != turn }
            }
            return true
        }
        if accepted { notify(thread) }
    }
    private func notify(_ thread: String) {
        eventQueue.async { [weak self] in self?.event?(thread) }
    }
    private static func settings(_ reply: [String: Any]) -> [String: Any] {
        var result = reply.filter { settingsKeys.contains($0.key) }
        if let effort = reply["reasoningEffort"] { result["effort"] = effort }
        if let thread = reply["thread"] as? [String: Any] {
            if result["model"] == nil { result["model"] = thread["model"] }
            if result["effort"] == nil { result["effort"] = thread["reasoningEffort"] }
        }
        if let profile = reply["activePermissionProfile"] as? [String: Any], let id = profile["id"] as? String {
            result["permissions"] = id
        }
        return result
    }
    static func matches(_ expected: [String: Any], _ actual: [String: Any], runtimeVersion: String) -> Bool {
        expected.allSatisfy { key, value in
            guard let found = actual[key] else { return false }
            if key == "serviceTier", value is NSNull {
                return found is NSNull || found as? String == "default"
            }
            if key == "collaborationMode" {
                return matchesCollaborationMode(value, found, runtimeVersion: runtimeVersion)
            }
            if key == "approvalsReviewer", let wanted = value as? String, let received = found as? String,
                ["guardian_subagent", "auto_review"].contains(wanted),
                ["guardian_subagent", "auto_review"].contains(received)
            {
                return true
            }
            return NSDictionary(dictionary: ["v": value]).isEqual(to: ["v": found])
        }
    }
    private static func matchesCollaborationMode(_ expected: Any, _ actual: Any, runtimeVersion: String) -> Bool {
        guard let expected = expected as? [String: Any], let actual = actual as? [String: Any],
            Set(expected.keys) == ["mode", "settings"], Set(actual.keys) == ["mode", "settings"],
            let mode = expected["mode"] as? String, ["default", "plan"].contains(mode),
            actual["mode"] as? String == mode,
            let wanted = expected["settings"] as? [String: Any], let received = actual["settings"] as? [String: Any],
            Set(wanted.keys) == ["model", "reasoning_effort", "developer_instructions"],
            Set(received.keys) == Set(wanted.keys), let model = wanted["model"] as? String, !model.isEmpty,
            received["model"] as? String == model,
            let effort = wanted["reasoning_effort"], let actualEffort = received["reasoning_effort"],
            effort is NSNull || ((effort as? String)?.isEmpty == false),
            NSDictionary(dictionary: ["v": effort]).isEqual(to: ["v": actualEffort]),
            let instructions = wanted["developer_instructions"],
            let actualInstructions = received["developer_instructions"],
            instructions is NSNull || instructions is String,
            actualInstructions is NSNull || actualInstructions is String
        else { return false }
        if runtimeVersion == CodexHeadlessRuntimeContract.version, instructions is NSNull,
            let expanded = actualInstructions as? String, !expanded.isEmpty, expanded.utf8.count <= 128_000
        {
            // Reviewed 0.160 turn/start normalizes null to the selected bundled
            // preset. The native tuple, not the null request, is retained as proof.
            return true
        }
        return NSDictionary(dictionary: ["v": instructions]).isEqual(to: ["v": actualInstructions])
    }
    private func active(_ state: [String: Any]) -> String? {
        CodexConversation.turns(state).last { $0["status"] as? String == "inProgress" }?["turnId"] as? String
    }
    private func activeNative(_ response: [String: Any]) -> String? {
        ((response["thread"] as? [String: Any])?["turns"] as? [[String: Any]])?
            .last { $0["status"] as? String == "inProgress" }?["id"] as? String
    }
    private func waitFor(_ condition: () -> Bool) -> Bool {
        for _ in 0..<8 {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }
    private func waitForRead(thread: String, _ condition: ([String: Any]) -> Bool) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + confirmationTimeout
        repeat {
            if condition(try view(thread: thread).state) { return true }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            Thread.sleep(forTimeInterval: min(0.1, remaining))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    private func object(_ bytes: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw RuntimeDriverError.invalidRequest
        }
        return result
    }
    private func rpc(_ native: CodexRuntimeConnection, _ method: String, _ parameters: [String: Any]) throws -> [String:
        Any]
    {
        try object(native.request(method, params: JSONSerialization.data(withJSONObject: parameters)))
    }
}
