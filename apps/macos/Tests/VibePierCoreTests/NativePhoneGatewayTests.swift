import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import VibePierCore

/// Test-only transport: uint32 big-endian length + unmodified SessionEnvelope JSON frame.
/// Opt in with VIBEPIER_NATIVE_PHONE_GATEWAY=1, VIBEPIER_NATIVE_PHONE_WORKSPACE and
/// VIBEPIER_NATIVE_PHONE_EVIDENCE (an existing, owner-only directory). No adb is invoked here.
/// bootstrap.json is transferred ONLY through `adb ... run-as ...` stdin.
/// VIBEPIER_NATIVE_PHONE_INSPECT names an original private run directory for read-only recovery.
/// Recovery never enables mutations, even when VIBEPIER_NATIVE_PHONE_MUTATIONS is set.
/// Workspace registration in the native apps is a separate, explicitly authorized prerequisite.
final class NativePhoneGatewayTests: XCTestCase {
    func testEncryptedPhoneFrameNeedsTransportSenderMetadata() throws {
        let device = UUID().uuidString.lowercased()
        let packet = UUID().uuidString.lowercased()
        let key = Data(repeating: 9, count: 32)  // synthetic; no Keystore, socket, or native provider
        let clear = AgentSessionProfile.data([
            "id": UUID().uuidString.lowercased(), "op": "providers",
            "sentAt": Date().timeIntervalSince1970 * 1000,
        ])
        let sealed = try SessionEnvelope.seal(clear, key: key, device: device, packet: packet, direction: "phone")
        let bytes = try XCTUnwrap(SessionEnvelope.frames(sealed, device: device, packet: packet, sender: device).first)
        var frame = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        // Actual SessionClient output, before RemoteSender supplies transport metadata.
        frame.removeValue(forKey: "sender")
        var inbox = SessionPacketInbox()
        XCTAssertNil(inbox.receive(AgentSessionProfile.data(frame), sender: device, key: key))
        frame["sender"] = UUID().uuidString.lowercased()
        XCTAssertNil(inbox.receive(AgentSessionProfile.data(frame), sender: device, key: key))
        frame["sender"] = device
        frame["device"] = UUID().uuidString.lowercased()
        XCTAssertNil(inbox.receive(AgentSessionProfile.data(frame), sender: device, key: key))
        frame["device"] = device
        XCTAssertNil(inbox.receive(AgentSessionProfile.data(frame), sender: device, key: Data(repeating: 8, count: 32)))
        let opened = try XCTUnwrap(inbox.receive(AgentSessionProfile.data(frame), sender: device, key: key))
        XCTAssertEqual(opened.clear, clear)
        XCTAssertEqual(opened.request["op"] as? String, "providers")
        // Replay remains blocked.
        XCTAssertNil(inbox.receive(AgentSessionProfile.data(frame), sender: device, key: key))
    }

    func testLifecycleExitPreservesPrivateAuthorizationButReadOnlyReleasesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bootstrap.json")
        let synthetic = Data("synthetic-test-authorization".utf8)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: file.path, contents: synthetic,
                attributes: [.posixPermissions: 0o600]))
        try NativePhoneGateway.releaseBootstrap(file, lifecycle: true)
        XCTAssertEqual(try Data(contentsOf: file), synthetic)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try NativePhoneGateway.releaseBootstrap(file, lifecycle: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testReadOnlyRecoveryRequiresOriginalConfirmedScopeAndRejectsMutations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let device = UUID().uuidString.lowercased()
        let original = NativePhoneGateway.Scope(workspace: folder.path, directory: folder, enabled: true)
        let saved = try XCTUnwrap(original.bootstrap as? [String: [String: String]])
        let index = try AgentSessionDirectory()
        let workspace = try index.registerWorkspace(adapter: "codex.currentV1", provider: "codex", cwd: folder.path)
        let session = try index.registerSession(
            adapter: "codex.currentV1", provider: "codex",
            native: UUID().uuidString.lowercased(), cwd: folder.path)
        let file = folder.appendingPathComponent("journal.json")
        let journal = try SessionReceiptJournal(file: file)
        let operation = try XCTUnwrap(saved["codex"]?["create"])
        let key = device + ":" + operation
        _ = try journal.reserve(key, hash: "synthetic-hash", thread: workspace.ref)
        let recovery = NativePhoneGateway.Scope(
            workspace: folder.path, directory: folder, enabled: false, restored: saved)
        XCTAssertThrowsError(try recovery.restoreConfirmed(device: device, journal: journal, index: index))
        try journal.complete(
            key,
            result: AgentSessionProfile.data([
                "ok": true,
                "body": [
                    "operationId": operation, "status": "confirmed", "effect": "session.created",
                    "result": [
                        "initialInput": "confirmed", "messageId": "client-message", "turnId": "native-turn",
                        "turnIdentityKind": "nativeTurn",
                        "session": [
                            "sessionRef": session.ref,
                            "nativeThreadId": session.nativeID, "workspaceRef": workspace.ref,
                        ],
                    ],
                ],
            ]))
        let before = try Data(contentsOf: file)
        try recovery.restoreConfirmed(device: device, journal: journal, index: index)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(recovery.inspectionSessions, ["codex": session.ref])
        let event = AgentSessionProfile.data(["threadId": session.nativeID, "event": "patch", "viewVersion": 1])
        XCTAssertTrue(recovery.allowsEvent(event, client: device, provider: "codex", device: device))
        XCTAssertFalse(recovery.allowsEvent(event, client: "other", provider: "codex", device: device))
        XCTAssertFalse(recovery.allowsEvent(event, client: device, provider: "claude", device: device))
        XCTAssertFalse(
            recovery.allowsEvent(
                AgentSessionProfile.data(["threadId": "other"]), client: device, provider: "codex", device: device))
        XCTAssertFalse(
            recovery.allowsEvent(
                AgentSessionProfile.data(["event": "unavailable"]), client: device, provider: "codex", device: device))
        func request(_ method: String, target: [String: String], mutable: Bool = false) throws
            -> AgentSessionProfile.Request
        {
            let id = UUID().uuidString.lowercased()
            var body: [String: Any] = [
                "agentProtocol": 2, "requestId": id, "method": method,
                "target": target, "params": [String: String](),
            ]
            if mutable {
                body["operationId"] = operation
                body["controlLease"] = UUID().uuidString.lowercased()
            }
            return try AgentSessionProfile.decode(["id": id, "body": body])
        }
        XCTAssertTrue(recovery.allows(try request("session.open", target: ["sessionRef": session.ref]), refs: [:]))
        XCTAssertFalse(recovery.allows(try request("session.snapshot", target: ["sessionRef": "other"]), refs: [:]))
        for method in ["session.create", "message.submit", "approval.resolve"] {
            XCTAssertFalse(
                recovery.allows(try request(method, target: ["sessionRef": session.ref], mutable: true), refs: [:]))
        }
        XCTAssertFalse(recovery.allowsNative(["op": "send", "threadId": session.nativeID], provider: "codex"))
        XCTAssertFalse(recovery.allowsNative(["op": "open", "threadId": "other"], provider: "codex"))
        XCTAssertTrue(recovery.allowsNative(["op": "open", "threadId": session.nativeID], provider: "codex"))
        let wrongDevice = NativePhoneGateway.Scope(
            workspace: folder.path, directory: folder, enabled: false, restored: saved)
        XCTAssertThrowsError(
            try wrongDevice.restoreConfirmed(device: UUID().uuidString, journal: journal, index: index))
    }
    func testCodexReceiptIdentityUsesClientIDAndExactMessageContent() {
        let row: [String: Any] = [
            "id": "native-item", "clientId": "receipt-message", "role": "user", "text": "fixture",
        ]
        XCTAssertTrue(
            NativePhoneGateway.Scope.messageMatches(row, provider: "codex", id: "receipt-message", text: "fixture"))
        XCTAssertFalse(
            NativePhoneGateway.Scope.messageMatches(row, provider: "codex", id: "native-item", text: "fixture"))
        XCTAssertFalse(
            NativePhoneGateway.Scope.messageMatches(row, provider: "codex", id: "receipt-message", text: "other"))
        XCTAssertFalse(
            NativePhoneGateway.Scope.messageMatches(row, provider: "claude", id: "receipt-message", text: "fixture"))
    }

    func testPrivateRuntimeDirectoryUsesPOSIXCanonicalPathAndRejectsLinksOrPublicAccess() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/vpp-test-" + UUID().uuidString)
        let link = URL(fileURLWithPath: directory.path + "-link")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertNoThrow(try NativePhoneGateway.checkPrivateDirectory(directory))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertThrowsError(try NativePhoneGateway.checkPrivateDirectory(link))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try NativePhoneGateway.checkPrivateDirectory(directory))
    }

    func testCodexOnlyScopeRejectsClaudeAndCompletesOnlyAfterItsOwnCreateAndSendProofs() throws {
        XCTAssertEqual(try NativePhoneGateway.selectedProviders([:]), ["codex", "claude"])
        XCTAssertEqual(try NativePhoneGateway.selectedProviders(["VIBEPIER_NATIVE_PHONE_PROVIDER": "codex"]), ["codex"])
        XCTAssertThrowsError(try NativePhoneGateway.selectedProviders(["VIBEPIER_NATIVE_PHONE_PROVIDER": "unexpected"]))
        let scope = NativePhoneGateway.Scope(
            workspace: "/synthetic", directory: URL(fileURLWithPath: "/synthetic"),
            enabled: true, providers: ["codex"])
        XCTAssertEqual(Set(scope.bootstrap.keys), ["codex"])
        XCTAssertFalse(scope.finished)
        XCTAssertFalse(scope.allowsNative(["op": "newOptions", "cwd": "/synthetic"], provider: "claude"))
        XCTAssertFalse(scope.allowsNative(["op": "new", "cwd": "/synthetic"], provider: "claude"))
        XCTAssertFalse(scope.allowsNative(["op": "send", "threadId": "other"], provider: "claude"))
        let thread = UUID().uuidString.lowercased()
        func request(_ method: String, operation: String? = nil, target: [String: String]) throws
            -> AgentSessionProfile.Request
        {
            let id = UUID().uuidString.lowercased()
            var body: [String: Any] = [
                "agentProtocol": 2, "requestId": id, "method": method,
                "target": target, "params": [String: String](),
            ]
            if let operation {
                body["operationId"] = operation
                body["controlLease"] = UUID().uuidString.lowercased()
            }
            return try AgentSessionProfile.decode(["id": id, "body": body])
        }
        let create = try request(
            "session.create", operation: scope.operations["codex"]!["create"],
            target: ["adapterId": "codex.currentV1", "workspaceRef": "workspace"])
        let foreignCreate = try request(
            "session.create", operation: scope.operations["codex"]!["create"],
            target: ["adapterId": "claude.currentV1", "workspaceRef": "foreign"])
        XCTAssertFalse(scope.allows(foreignCreate, refs: ["claude": "foreign"]))
        scope.observeNative(
            ["op": "new"], provider: "codex",
            reply: AgentSessionProfile.data([
                "ok": true, "accepted": true, "cwd": "/synthetic", "threadId": thread,
                "nativeMessageId": "first-client", "turnId": "first-turn",
            ]))
        scope.observeProfile(
            create,
            reply: AgentSessionProfile.data([
                "ok": true,
                "body": [
                    "status": "confirmed",
                    "result": [
                        "initialInput": "confirmed", "messageId": "first-client",
                        "turnId": "first-turn", "session": ["nativeThreadId": thread, "sessionRef": "session"],
                    ],
                ],
            ]))
        let snapshot = try request("session.snapshot", target: ["sessionRef": "session"])
        let page: [String: Any] = [
            "threadId": thread, "contentState": "complete", "status": "idle",
            "messages": [
                [
                    "id": "first-item", "clientId": "first-client", "role": "user",
                    "text": scope.text("codex", "create"),
                ],
                [
                    "id": "second-item", "clientId": "second-client", "role": "user",
                    "text": scope.text("codex", "send"),
                ],
            ],
        ]
        let read = AgentSessionProfile.data(["ok": true, "body": ["result": ["snapshot": page]]])
        scope.observeProfile(snapshot, reply: read)
        XCTAssertFalse(scope.finished)  // A matching row cannot substitute for a confirmed send receipt.
        let send = try request(
            "message.submit", operation: scope.operations["codex"]!["send"], target: ["sessionRef": "session"])
        scope.observeProfile(
            send,
            reply: AgentSessionProfile.data([
                "ok": true,
                "body": [
                    "status": "confirmed",
                    "result": ["messageId": "second-client", "turnId": "second-turn"],
                ],
            ]))
        var tail = page
        let rows = try XCTUnwrap(page["messages"] as? [[String: Any]])
        tail["messages"] = [rows[1]]
        tail["hasOlder"] = true
        scope.observeProfile(
            snapshot, reply: AgentSessionProfile.data(["ok": true, "body": ["result": ["snapshot": tail]]]))
        XCTAssertFalse(scope.finished)  // Only the latest turn is present; no made-up earlier snapshot row.
        let historyID = UUID().uuidString.lowercased()
        let history = try AgentSessionProfile.decode([
            "id": historyID,
            "body": [
                "agentProtocol": 2, "requestId": historyID, "method": "session.items",
                "target": ["sessionRef": "session"],
                "params": ["kind": "history", "before": "second-item"],
            ],
        ])
        XCTAssertTrue(scope.allows(history, refs: [:]))
        scope.observeProfile(
            history,
            reply: AgentSessionProfile.data([
                "ok": true,
                "body": [
                    "result": [
                        "threadId": "other", "messages": [rows[0]], "contentState": "partial",
                    ]
                ],
            ]))
        XCTAssertFalse(scope.finished)
        scope.observeProfile(
            history,
            reply: AgentSessionProfile.data([
                "ok": true,
                "body": [
                    "result": [
                        "threadId": thread, "messages": [rows[0]], "contentState": "partial",
                    ]
                ],
            ]))
        XCTAssertTrue(scope.finished)  // Real scoped history completes evidence; no Claude call is needed.
    }

    func testEncryptedNativePhoneGateway() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VIBEPIER_NATIVE_PHONE_GATEWAY"] == "1" else {
            throw XCTSkip("Explicit native phone gateway opt-in required")
        }
        let host: NativePhoneGateway
        if let original = env["VIBEPIER_NATIVE_PHONE_INSPECT"] {
            host = try NativePhoneGateway(inspecting: URL(fileURLWithPath: original), environment: env)
        } else {
            host = try NativePhoneGateway(environment: env)
        }
        let finished = expectation(description: "bounded native phone probe")
        let outcome = NativePhoneGateway.ResultBox()
        DispatchQueue.global().async {
            do {
                try host.run()
                outcome.set(Data())
            } catch {
                host.reportFailure(error)
                outcome.set(nil)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: host.lifecycle ? 610 : 190)
        XCTAssertNotNil(outcome.get(), "Gateway failed; no request was retried. Inspect native prerequisite locally.")
    }
}

private final class NativePhoneGateway: @unchecked Sendable {
    enum Failure: String, Error { case configuration, io, timeout, denied, incomplete }
    private final class InitDiagnostic {
        enum Stage: String {
            case configuration, originalDirectory, outputDirectory, authorizationFile, authorizationSchema,
                outputCreation, directoryIndex, workspaceIndex, journalRead, confirmedScope,
                runtimeManifest, runtimeDirectory, followUps, adapters, service, ready
        }
        var stage = Stage.configuration
        var knownOperations = 0
        var confirmedOperations = 0
        var unresolvedOperations = 0
        func emit(ready: Bool) {
            FileHandle.standardError.write(
                AgentSessionProfile.data([
                    "phase": "inspect_init_" + stage.rawValue,
                    "code": ready ? "ready" : "validation_failed",
                    "knownOperations": knownOperations, "confirmedOperations": confirmedOperations,
                    "unresolvedOperations": unresolvedOperations,
                ]) + Data([10]))
        }
    }
    enum Phase: String {
        case setup, listening, frameHeader, frameBody, frameAuthentication, providersService, agentService,
            responseWrite, completed
    }
    private var phase = Phase.setup
    private var receivedFrames = 0
    private var authenticatedRequests = 0
    private func mark(_ next: Phase) { phase = next }
    private func diagnostic(_ code: String) -> Data {
        AgentSessionProfile.data([
            "phase": phase.rawValue, "code": code,
            "receivedFrames": receivedFrames, "authenticatedRequests": authenticatedRequests,
        ])
    }
    func reportFailure(_ error: Error) {
        // Enum names and counters only; never NSError descriptions, request fields, or native diagnostics.
        let code = (error as? Failure)?.rawValue ?? "internal_failure"
        let bytes = diagnostic(code)
        FileHandle.standardError.write(bytes + Data([10]))
        try? Self.privateWrite(bytes, to: evidence.appendingPathComponent("diagnostic.json"))
    }
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func set(_ value: Data?) {
            lock.lock()
            defer { lock.unlock() }
            data = value
        }
        func get() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
    // All journal accesses are serialized; no production Paths/SessionRemote/Keychain singleton.
    final class JournalBox: @unchecked Sendable {
        let queue = DispatchQueue(label: "native-phone.journal")
        let journal: SessionReceiptJournal
        init(_ file: URL) throws { journal = try SessionReceiptJournal(file: file) }
        var binding: AgentSessionService.Journal {
            .init(
                read: { key, done in
                    self.queue.async {
                        guard self.journal.isReliable else {
                            done(.failure(Failure.io))
                            return
                        }
                        done(
                            .success(
                                self.journal.receipt(key).map {
                                    .init(
                                        hash: $0.hash, thread: $0.thread, result: $0.result, intent: $0.intent,
                                        retired: $0.retired == true, evidence: $0.evidence)
                                }))
                    }
                },
                reserve: { key, hash, thread, intent, done in
                    self.queue.async {
                        done(
                            Result {
                                switch try self.journal.reserve(key, hash: hash, thread: thread, intent: intent) {
                                case .fresh: return .fresh
                                case .complete(let value): return .complete(value)
                                case .unknown: return .unknown
                                case .conflict: return .conflict
                                }
                            })
                    }
                },
                complete: { key, data, done in
                    self.queue.async {
                        done(Result { try self.journal.complete(key, result: data) })
                    }
                },
                recordEvidence: { key, data, done in
                    self.queue.async {
                        done(Result { try self.journal.recordEvidence(key, evidence: data) })
                    }
                })
        }
    }
    /// A per-run capability boundary, separate from the production service's leases and durable journal.
    final class Scope: @unchecked Sendable {
        let workspace: String
        let directory: URL
        let enabled: Bool
        let runID = UUID().uuidString.lowercased()
        let providers: [String]
        let operations: [String: [String: String]]
        let restored: [String: [String: String]]?
        var readOnlyRecovery: Bool { restored != nil }
        private let lock = NSLock()
        private var threads: [String: String] = [:]
        private var sessions: [String: String] = [:]
        private var proofs: [String: [String: [String: String]]] = [:]
        private var verified = Set<String>()
        private var snapshotMatches: [String: Set<String>] = [:]
        private var snapshotReady = Set<String>()
        init(
            workspace: String, directory: URL, enabled: Bool, restored: [String: [String: String]]? = nil,
            providers: [String] = ["codex", "claude"]
        ) {
            self.workspace = workspace
            self.directory = directory
            self.enabled = enabled
            self.restored = restored
            self.providers = restored?.keys.sorted() ?? providers
            operations =
                restored?.mapValues { ["create": $0["create"] ?? "", "send": $0["send"] ?? ""] }
                ?? Dictionary(
                    uniqueKeysWithValues: providers.map {
                        ($0, ["create": UUID().uuidString.lowercased(), "send": UUID().uuidString.lowercased()])
                    })
        }
        func text(_ provider: String, _ phase: String) -> String {
            if let restored { return restored[provider]?[phase + "Text"] ?? "" }
            return
                "VibePier isolated phone fixture \(runID) \(provider) \(phase). Reply READY only. Do not use tools, access files, or modify anything."
        }
        var bootstrap: [String: Any] {
            Dictionary(
                uniqueKeysWithValues: operations.map { provider, ids in
                    (
                        provider,
                        [
                            "create": ids["create"]!, "send": ids["send"]!,
                            "createText": text(provider, "create"), "sendText": text(provider, "send"),
                        ]
                    )
                })
        }
        var finished: Bool {
            lock.withLock {
                readOnlyRecovery ? !sessions.isEmpty && verified == Set(sessions.keys) : verified == Set(providers)
            }
        }
        var inspectionSessions: [String: String] { lock.withLock { sessions } }
        func restoreConfirmed(device: String, journal: SessionReceiptJournal, index: AgentSessionDirectory) throws {
            guard readOnlyRecovery, !operations.isEmpty, Set(operations.keys).isSubset(of: ["codex", "claude"]) else {
                throw Failure.configuration
            }
            for (provider, ids) in operations {
                for phase in ["create", "send"] {
                    guard let id = ids[phase], UUID(uuidString: id) != nil, !text(provider, phase).isEmpty else {
                        throw Failure.configuration
                    }
                    guard let receipt = journal.receipt(device + ":" + id), let bytes = receipt.result,
                        let outer = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                        let body = outer["body"] as? [String: Any], body["operationId"] as? String == id,
                        body["status"] as? String == "confirmed",
                        let result = body["result"] as? [String: Any]
                    else { continue }
                    guard let message = result["messageId"] as? String, !message.isEmpty,
                        let turn = result["turnId"] as? String, !turn.isEmpty
                    else { throw Failure.configuration }
                    if phase == "create" {
                        guard body["effect"] as? String == "session.created",
                            result["initialInput"] as? String == "confirmed",
                            let session = result["session"] as? [String: Any],
                            let ref = session["sessionRef"] as? String,
                            let known = index.session(ref), known.cwd == workspace, known.provider == provider,
                            known.adapterID == provider + ".currentV1",
                            known.nativeID == session["nativeThreadId"] as? String,
                            let workspaceRef = session["workspaceRef"] as? String, receipt.thread == workspaceRef,
                            index.workspace(workspaceRef)?.cwd == workspace
                        else { throw Failure.configuration }
                        sessions[provider] = ref
                        threads[provider] = known.nativeID
                    } else {
                        guard body["effect"] as? String == "message.submitted", sessions[provider] == receipt.thread
                        else {
                            throw Failure.configuration
                        }
                    }
                    proofs[provider, default: [:]][phase] = [
                        "messageId": message, "turnId": turn,
                        "turnIdentityKind": result["turnIdentityKind"] as? String ?? "",
                    ]
                }
            }
            guard !sessions.isEmpty else { throw Failure.configuration }
        }
        static func messageMatches(_ row: [String: Any], provider: String, id: String, text: String) -> Bool {
            // Codex receipts identify the submitted client message; UI item IDs belong to another namespace.
            let identity = provider == "codex" ? row["clientId"] as? String : row["id"] as? String
            return identity == id && row["role"] as? String == "user" && row["text"] as? String == text
        }
        func allows(_ request: AgentSessionProfile.Request, refs: [String: String]) -> Bool {
            if request.method == "agent.describe" { return request.target.isEmpty && request.params.isEmpty }
            if readOnlyRecovery && request.mutable { return false }
            if request.method == "session.creationOptions" {
                guard !readOnlyRecovery else { return false }
                return Set(request.target.keys) == ["adapterId"]
                    && refs.contains { provider, ref in
                        operations[provider] != nil && request.target["adapterId"] as? String == provider + ".currentV1"
                            && request.params["workspaceRef"] as? String == ref
                    }
            }
            guard enabled || readOnlyRecovery else { return false }
            if request.method == "operation.get" {
                return operations.values.contains { $0.values.contains(request.params["operationId"] as? String ?? "") }
            }
            if request.method == "session.create" {
                return refs.contains { provider, ref in
                    operations[provider] != nil && request.target["adapterId"] as? String == provider + ".currentV1"
                        && request.target["workspaceRef"] as? String == ref
                        && request.operationID == operations[provider]?["create"]
                }
            }
            guard let ref = request.target["sessionRef"] as? String,
                let provider = lock.withLock({ sessions.first { $0.value == ref }?.key })
            else { return false }
            switch request.method {
            case "session.open", "session.snapshot": return true
            case "session.items": return request.params["kind"] as? String == "history"
            case "message.submit": return request.operationID == operations[provider]?["send"]
            default: return false  // No discovery, arbitrary items, configuration, tools, approval, or interruption.
            }
        }
        func allowsNative(_ fields: [String: Any], provider: String) -> Bool {
            guard operations[provider] != nil, let op = fields["op"] as? String else { return false }
            if op == "newOptions" {
                guard !readOnlyRecovery else { return false }
                return fields["cwd"] as? String == workspace && fields["threadId"] == nil
            }
            guard enabled || readOnlyRecovery else { return false }
            if ["open", "history"].contains(op) {
                return lock.withLock { threads[provider] != nil && fields["threadId"] as? String == threads[provider] }
            }
            guard !readOnlyRecovery, ["new", "send"].contains(op) else { return false }
            let phase = op == "new" ? "create" : "send"
            guard fields["id"] as? String == operations[provider]?[phase],
                fields["text"] as? String == text(provider, phase),
                (fields["attachments"] as? [Any] ?? []).isEmpty,
                fields["confirmation"] == nil, fields["executionMode"] == nil,
                fields["serviceTier"] == nil
            else { return false }
            if op == "new" {
                return fields["cwd"] as? String == workspace && fields["threadId"] == nil
                    && fields["mode"] as? String == (provider == "codex" ? "auto" : "default")
            }
            return fields["submissionMode"] as? String == "start"
                && lock.withLock {
                    threads[provider] != nil && fields["threadId"] as? String == threads[provider]
                        && proofs[provider]?["create"] != nil
                }
        }
        func allowsEvent(_ data: Data, client: String, provider: String, device: String) -> Bool {
            guard client == device, providers.contains(provider), data.count <= SessionPacketInbox.plaintextLimit,
                let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let thread = value["threadId"] as? String
            else { return false }
            return lock.withLock { threads[provider] == thread }
        }
        func reserveNative(_ fields: [String: Any], provider: String) throws {
            guard let op = fields["op"] as? String, ["new", "send"].contains(op) else { return }
            // Service journal reservation already exists. A crash at any following point stays unknown.
            try NativePhoneGateway.privateWrite(
                AgentSessionProfile.data([
                    "operationId": fields["id"]!, "provider": provider, "status": "attempted-or-unknown",
                ]), to: directory.appendingPathComponent(provider + "-" + op + ".attempt.json"))
        }
        func observeNative(_ fields: [String: Any], provider: String, reply: Data) {
            guard fields["op"] as? String == "new",
                let value = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
                value["ok"] as? Bool == true, value["accepted"] as? Bool == true,
                value["cwd"] as? String == workspace,
                let thread = value["threadId"] as? String, UUID(uuidString: thread) != nil,
                !(value["nativeMessageId"] as? String ?? "").isEmpty,
                !(value["nativeTurnId"] as? String ?? value["turnId"] as? String ?? "").isEmpty
            else { return }
            lock.withLock { threads[provider] = thread }
        }
        func observeProfile(_ request: AgentSessionProfile.Request, reply: Data) {
            guard enabled || readOnlyRecovery,
                let outer = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
                outer["ok"] as? Bool == true, let body = outer["body"] as? [String: Any],
                let result = body["result"] as? [String: Any]
            else { return }
            lock.withLock {
                if request.mutable {
                    guard body["status"] as? String == "confirmed",
                        let provider = operations.first(where: { $0.value.values.contains(request.operationID ?? "") })?
                            .key,
                        let message = result["messageId"] as? String, !message.isEmpty,
                        let turn = result["turnId"] as? String, !turn.isEmpty
                    else { return }
                    let phase = request.method == "session.create" ? "create" : "send"
                    if phase == "create" {
                        guard result["initialInput"] as? String == "confirmed",
                            let session = result["session"] as? [String: Any],
                            session["nativeThreadId"] as? String == threads[provider],
                            let ref = session["sessionRef"] as? String
                        else { return }
                        sessions[provider] = ref
                    }
                    proofs[provider, default: [:]][phase] = [
                        "messageId": message, "turnId": turn,
                        "turnIdentityKind": result["turnIdentityKind"] as? String ?? "",
                    ]
                } else if let provider = sessions.first(where: { $0.value == request.target["sessionRef"] as? String })?
                    .key
                {
                    let isSnapshot = ["session.open", "session.snapshot"].contains(request.method)
                    let isHistory = request.method == "session.items" && request.params["kind"] as? String == "history"
                    guard isSnapshot || isHistory else { return }
                    let page = isSnapshot ? result["snapshot"] as? [String: Any] : result
                    guard let page, page["threadId"] as? String == threads[provider],
                        let messages = page["messages"] as? [[String: Any]]
                    else { return }
                    if isSnapshot {
                        snapshotMatches[provider] = []
                        snapshotReady.remove(provider)
                        verified.remove(provider)
                        guard page["contentState"] as? String == "complete", page["status"] as? String == "idle" else {
                            return
                        }
                        snapshotReady.insert(provider)
                    }
                    guard snapshotReady.contains(provider) else { return }
                    let phases =
                        readOnlyRecovery
                        ? ["create", "send"].filter { proofs[provider]?[$0] != nil } : ["create", "send"]
                    for phase in phases {
                        if let message = proofs[provider]?[phase]?["messageId"],
                            messages.contains(where: {
                                Self.messageMatches($0, provider: provider, id: message, text: text(provider, phase))
                            })
                        {
                            snapshotMatches[provider, default: []].insert(phase)
                        }
                    }
                    guard snapshotMatches[provider] == Set(phases), !phases.isEmpty else { return }
                    if !readOnlyRecovery {
                        guard proofs[provider]?["create"]?["messageId"] != proofs[provider]?["send"]?["messageId"],
                            proofs[provider]?["create"]?["turnId"] != proofs[provider]?["send"]?["turnId"]
                        else { return }
                    }
                    verified.insert(provider)
                }
            }
        }
    }
    let lifecycle: Bool
    let scope: Scope
    let workspace: String
    let evidence: URL
    let device: String
    let key: Data
    private var inspection = false
    private var mode: String { inspection ? "inspect" : lifecycle ? "create-send" : "onlyoptions" }
    let coordinator: AgentSessionCoordinator
    let service: AgentSessionService
    let refs: [String: String]

    static func selectedProviders(_ environment: [String: String]) throws -> [String] {
        switch environment["VIBEPIER_NATIVE_PHONE_PROVIDER"] ?? "both" {
        case "both": return ["codex", "claude"]
        case "codex": return ["codex"]
        default: throw Failure.configuration
        }
    }

    init(environment: [String: String]) throws {
        guard let path = environment["VIBEPIER_NATIVE_PHONE_WORKSPACE"], path.hasPrefix("/"),
            let root = environment["VIBEPIER_NATIVE_PHONE_EVIDENCE"], root.hasPrefix("/")
        else {
            throw Failure.configuration
        }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard canonical == path, path != "/", path != NSHomeDirectory(),
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { throw Failure.configuration }
        workspace = canonical
        device = UUID().uuidString.lowercased()
        key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        lifecycle = environment["VIBEPIER_NATIVE_PHONE_MUTATIONS"] == "1"
        var info = stat()
        guard lstat(root, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0,
            URL(fileURLWithPath: root).resolvingSymlinksInPath().path == root
        else { throw Failure.configuration }
        evidence = URL(fileURLWithPath: root).appendingPathComponent("phone-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(
            at: evidence, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let selected = try Self.selectedProviders(environment)
        scope = Scope(workspace: canonical, directory: evidence, enabled: lifecycle, providers: selected)
        if lifecycle {
            // A second host using this evidence root must not resubmit an unknown run with fresh IDs.
            try Self.privateWrite(
                AgentSessionProfile.data(["workspace": canonical, "run": evidence.path]),
                to: URL(fileURLWithPath: root).appendingPathComponent("create-send.claim"))
        }
        try Self.privateWrite(
            AgentSessionProfile.data(scope.bootstrap),
            to: evidence.appendingPathComponent("operations.json"))
        let followUps = evidence.appendingPathComponent("codex-follow-ups.json")
        try Self.privateWrite(AgentSessionProfile.data(["queued-follow-ups": [String: Any]()]), to: followUps)
        let directory = try AgentSessionDirectory(file: evidence.appendingPathComponent("directory.json"))
        var workspaces: [String: String] = [:]
        for provider in selected {
            workspaces[provider] = try directory.registerWorkspace(
                adapter: provider + ".currentV1", provider: provider, cwd: canonical
            ).ref
        }
        refs = workspaces
        // Real native readers/catalogs and IPC; only VibePier-owned writable storage is redirected.
        // Do not replace native home/history: prerequisite registration must be genuine.
        let runtime = URL(fileURLWithPath: "/private/tmp/vpp-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try Self.privateWrite(
            AgentSessionProfile.data([
                "runtimeDirectory": runtime.path,
                "workspace": canonical, "mode": lifecycle ? "create-send" : "onlyoptions", "providers": selected,
                "cleanup": "Retain runtime and receipts after unknown; explicit cleanup after inspection.",
            ]),
            to: evidence.appendingPathComponent("manifest.json"))
        let codex = CodexBridge(
            followUps: CodexFollowUps(file: followUps),
            attachments: try CodexAttachments(root: evidence.appendingPathComponent("codex-attachments")),
            background: CodexBackgroundSessions(directory: runtime))
        let claude = ClaudeBridge(
            settingsFile: evidence.appendingPathComponent("claude-settings.json"),
            attachmentRoot: evidence.appendingPathComponent("claude-attachments"))
        let adapters: [CurrentV1AgentAdapter] = [
            CurrentV1AgentAdapter(
                provider: "codex", backendKinds: ["desktopAttached", "managedRuntime"],
                execute: { codex.perform($0, client: $1, completion: $2) },
                stop: { codex.stop($0) }, stopAll: { codex.stopAll() }),
            CurrentV1AgentAdapter(
                provider: "claude", backendKinds: ["desktopAttached", "managedRuntime"],
                execute: { claude.perform($0, client: $1, completion: $2) },
                stop: { claude.stop($0) }, stopAll: { claude.stopAll() },
                creationAvailable: { ClaudeBridge.executable() != nil }),
        ]
        let coordinator = AgentSessionCoordinator(
            registry: try AgentAdapterRegistry(adapters.filter { selected.contains($0.providerID) }))
        self.coordinator = coordinator
        let journal = try JournalBox(evidence.appendingPathComponent("receipts.json"))
        let scope = self.scope
        service = AgentSessionService(
            directory: directory,
            execute: { data, provider, client, done in
                let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                guard scope.allowsNative(fields, provider: provider) else {
                    done(AgentSessionProfile.data(["ok": false, "code": "native_phone_scope_denied"]))
                    return
                }
                do { try scope.reserveNative(fields, provider: provider) } catch {
                    done(
                        AgentSessionProfile.data(["ok": false, "unknown": true, "code": "native_phone_attempt_exists"]))
                    return
                }
                coordinator.performCurrentV1(data, provider: provider, trustedClient: client) { reply in
                    // New thread authority comes ONLY from this call's verified native creation result.
                    scope.observeNative(
                        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:],
                        provider: provider, reply: reply)
                    done(reply)
                }
            }, journal: journal.binding,
            describe: { client, done in
                done(
                    AgentSessionProfile.data(
                        coordinator.describe(
                            client: client, requestedVersion: 1,
                            policy: SessionProviderPolicy()) ?? [:]))
            },
            freshMutationFailure: { data, client, done in
                let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                guard let provider = fields["provider"] as? String, scope.allowsNative(fields, provider: provider)
                else {
                    done("native_phone_scope_denied")
                    return
                }
                done(coordinator.freshMutationFailure(fields, client: client))
            }, eventSink: { _, _ in })
        Self.connectEvents(
            codex: codex, claude: claude, adapters: adapters, coordinator: coordinator,
            service: service, scope: scope, device: device)
    }

    init(inspecting original: URL, environment: [String: String]) throws {
        let diagnostic = InitDiagnostic()
        var ready = false
        defer { diagnostic.emit(ready: ready) }
        guard environment["VIBEPIER_NATIVE_PHONE_MUTATIONS"] != "1",
            let output = environment["VIBEPIER_NATIVE_PHONE_EVIDENCE"]
        else { throw Failure.configuration }
        diagnostic.stage = .originalDirectory
        try Self.checkPrivateDirectory(original, stage: "originalDirectory")
        let outputURL = URL(fileURLWithPath: output)
        diagnostic.stage = .outputDirectory
        try Self.checkPrivateDirectory(outputURL, stage: "outputDirectory")
        diagnostic.stage = .authorizationFile
        let saved = try Self.privateObject(original.appendingPathComponent("bootstrap.json"))
        diagnostic.stage = .authorizationSchema
        guard saved["mode"] as? String == "create-send", let id = saved["device"] as? String,
            UUID(uuidString: id) != nil, let encoded = saved["key"] as? String,
            let material = Data(base64Encoded: encoded), material.count == 32,
            let cwd = saved["workspace"] as? String, cwd == environment["VIBEPIER_NATIVE_PHONE_WORKSPACE"],
            URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == cwd,
            let operations = try Self.privateObject(original.appendingPathComponent("operations.json"))
                as? [String: [String: String]],
            let workspaces = saved["workspaces"] as? [String: String]
        else { throw Failure.configuration }
        inspection = true
        lifecycle = true
        device = id
        key = material
        workspace = cwd
        diagnostic.stage = .outputCreation
        evidence = outputURL.appendingPathComponent("inspect-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(
            at: evidence, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        diagnostic.stage = .directoryIndex
        let index = try AgentSessionDirectory(file: original.appendingPathComponent("directory.json"))
        diagnostic.stage = .workspaceIndex
        guard !workspaces.isEmpty, Set(workspaces.keys) == Set(operations.keys),
            workspaces.allSatisfy({ provider, ref in
                index.workspace(ref)?.provider == provider && index.workspace(ref)?.cwd == cwd
            })
        else { throw Failure.configuration }
        refs = workspaces
        diagnostic.stage = .journalRead
        let journal = try JournalBox(original.appendingPathComponent("receipts.json"))
        scope = Scope(workspace: cwd, directory: evidence, enabled: false, restored: operations)
        for ids in scope.operations.values {
            for operation in ids.values {
                guard let receipt = journal.journal.receipt(id + ":" + operation) else { continue }
                diagnostic.knownOperations += 1
                if let bytes = receipt.result,
                    let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                    (value["body"] as? [String: Any])?["status"] as? String == "confirmed"
                {
                    diagnostic.confirmedOperations += 1
                } else {
                    diagnostic.unresolvedOperations += 1
                }
            }
        }
        diagnostic.stage = .confirmedScope
        try scope.restoreConfirmed(device: id, journal: journal.journal, index: index)
        diagnostic.stage = .runtimeManifest
        let manifest = try Self.privateObject(original.appendingPathComponent("manifest.json"))
        guard let runtimePath = manifest["runtimeDirectory"] as? String, runtimePath.hasPrefix("/private/tmp/vpp-")
        else { throw Failure.configuration }
        let runtime = URL(fileURLWithPath: runtimePath)
        diagnostic.stage = .runtimeDirectory
        try Self.checkPrivateDirectory(runtime, stage: "runtimeDirectory")
        diagnostic.stage = .followUps
        _ = try Self.privateObject(original.appendingPathComponent("codex-follow-ups.json"))
        try Self.privateWrite(
            AgentSessionProfile.data([
                "mode": "inspect", "originalRun": original.path,
                "runtimeDirectory": runtimePath, "mutationResumeSupported": false,
                "device": id, "journalFile": original.appendingPathComponent("receipts.json").path,
            ]),
            to: evidence.appendingPathComponent("manifest.json"))
        diagnostic.stage = .adapters
        let codex = CodexBridge(
            followUps: CodexFollowUps(file: original.appendingPathComponent("codex-follow-ups.json")),
            attachments: try CodexAttachments(root: evidence.appendingPathComponent("codex-attachments")),
            background: CodexBackgroundSessions(directory: runtime))
        let claude = ClaudeBridge(
            settingsFile: original.appendingPathComponent("claude-settings.json"),
            attachmentRoot: evidence.appendingPathComponent("claude-attachments"))
        let adapters: [CurrentV1AgentAdapter] = [
            CurrentV1AgentAdapter(
                provider: "codex", backendKinds: ["desktopAttached", "managedRuntime"],
                execute: { codex.perform($0, client: $1, completion: $2) },
                stop: { codex.stop($0) }, stopAll: { codex.stopAll() }),
            CurrentV1AgentAdapter(
                provider: "claude", backendKinds: ["desktopAttached", "managedRuntime"],
                execute: { claude.perform($0, client: $1, completion: $2) },
                stop: { claude.stop($0) }, stopAll: { claude.stopAll() }),
        ]
        let coordinator = AgentSessionCoordinator(
            registry: try AgentAdapterRegistry(adapters.filter { operations.keys.contains($0.providerID) }))
        self.coordinator = coordinator
        let scope = self.scope
        let readOnlyJournal = AgentSessionService.Journal(
            read: journal.binding.read,
            reserve: { _, _, _, _, done in done(.failure(Failure.denied)) },
            complete: { _, _, done in done(.failure(Failure.denied)) },
            recordEvidence: { _, _, done in done(.failure(Failure.denied)) })
        diagnostic.stage = .service
        service = AgentSessionService(
            directory: index,
            execute: { bytes, provider, client, done in
                let fields = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
                guard ["open", "history"].contains(fields["op"] as? String ?? ""),
                    scope.allowsNative(fields, provider: provider), client == id
                else {
                    done(AgentSessionProfile.data(["ok": false, "code": "inspection_read_only"]))
                    return
                }
                coordinator.performCurrentV1(bytes, provider: provider, trustedClient: client, completion: done)
            }, journal: readOnlyJournal,
            describe: { client, done in
                done(
                    AgentSessionProfile.data(
                        coordinator.describe(
                            client: client, requestedVersion: 1,
                            policy: SessionProviderPolicy()) ?? [:]))
            }, freshMutationFailure: { _, _, done in done("inspection_read_only") }, eventSink: { _, _ in })
        Self.connectEvents(
            codex: codex, claude: claude, adapters: adapters, coordinator: coordinator,
            service: service, scope: scope, device: device)
        diagnostic.stage = .ready
        ready = true
    }
    private static func connectEvents(
        codex: CodexBridge, claude: ClaudeBridge,
        adapters: [CurrentV1AgentAdapter], coordinator: AgentSessionCoordinator,
        service: AgentSessionService, scope: Scope, device: String
    ) {
        let codexAdapter = adapters.first { $0.providerID == "codex" }
        let claudeAdapter = adapters.first { $0.providerID == "claude" }
        codex.event = { [weak codexAdapter] client, bytes in
            guard scope.allowsEvent(bytes, client: client, provider: "codex", device: device) else { return }
            codexAdapter?.emit(client: client, data: bytes)
        }
        claude.event = { [weak claudeAdapter] client, bytes in
            guard scope.allowsEvent(bytes, client: client, provider: "claude", device: device) else { return }
            claudeAdapter?.emit(client: client, data: bytes)
        }
        // Coordinator enriches capabilities exactly as production does; service invalidates stale leases.
        coordinator.event = { [weak service] client, provider, bytes in
            guard scope.allowsEvent(bytes, client: client, provider: provider, device: device) else { return }
            service?.receiveCurrentV1Event(bytes, provider: provider, client: client)
        }
    }

    static func checkPrivateDirectory(_ url: URL, stage: String = "testDirectory") throws {
        var info = stat()
        let result = lstat(url.path, &info)
        let statErrno = result == 0 ? 0 : errno
        // Foundation rewrites canonical /private/tmp to /tmp on macOS; POSIX realpath does not.
        let resolved = realpath(url.path, nil)
        let realpathErrno = resolved == nil ? errno : 0
        defer { if let resolved { free(resolved) } }
        let canonical = resolved.map { url.path == String(cString: $0) } ?? false
        let uidMatch = result == 0 && info.st_uid == getuid()
        let isDirectory = result == 0 && info.st_mode & S_IFMT == S_IFDIR
        let isPrivate = result == 0 && info.st_mode & 0o077 == 0
        FileHandle.standardError.write(
            AgentSessionProfile.data([
                "phase": "inspect_init_" + stage, "code": "directory_metadata",
                "lstatErrno": statErrno, "realpathErrno": realpathErrno,
                "uidMatch": uidMatch, "isDir": isDirectory, "private": isPrivate,
                "canonical": canonical, "foundationCanonical": url.path == url.resolvingSymlinksInPath().path,
            ]) + Data([10]))
        guard canonical, uidMatch, isDirectory, isPrivate else { throw Failure.configuration }
    }
    private static func privateObject(_ url: URL) throws -> [String: Any] {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
            info.st_mode & 0o077 == 0,
            let bytes = try ReceiptJournalFile.read(url, limit: 16 * 1024 * 1024),
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else {
            throw Failure.configuration
        }
        return object
    }

    func run() throws {
        mark(.setup)
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.io }
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let addressSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, addressSize) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw Failure.io }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        guard named == 0 else { throw Failure.io }
        let bootstrap = evidence.appendingPathComponent("bootstrap.json")
        try Self.privateWrite(
            AgentSessionProfile.data(
                [
                    "version": 1, "device": device, "key": key.base64EncodedString(),
                    "port": Int(UInt16(bigEndian: address.sin_port)), "workspace": workspace, "workspaces": refs,
                    "mode": mode, "providers": inspection ? scope.inspectionSessions.keys.sorted() : scope.providers,
                    "operations": scope.bootstrap, "inspectionSessions": scope.inspectionSessions,
                ].filter { !inspection || $0.key != "key" }), to: bootstrap)
        if lifecycle && !inspection {
            // Written before accepting any phone request, so a crash cannot erase the recovery boundary.
            try Self.privateWrite(
                AgentSessionProfile.data([
                    "device": device, "mode": "create-send", "authorizationFile": bootstrap.path,
                    "journalFile": evidence.appendingPathComponent("receipts.json").path,
                    "operationsFile": evidence.appendingPathComponent("operations.json").path,
                    "androidNamespace": "native-phone-" + device,
                    "crossProcessRecoverySupported": "confirmed-session-read-only", "automaticResubmit": false,
                    "state": "unresolved-until-receipts-and-phone-evidence-inspected",
                    "cleanup":
                        "Manual only after all operation IDs are confirmed; preserve unknown authorization and receipts.",
                    "boundary":
                        "Only explicit INSPECT restores original confirmed-session reads. No mutation resume; do not remove create-send.claim or replace identity to retry.",
                ]), to: evidence.appendingPathComponent("recovery.json"))
        }
        defer { try? Self.releaseBootstrap(bootstrap, lifecycle: lifecycle) }
        // Paths only: never print bootstrap contents, native replies, or pairing material.
        print("NativePhoneGateway bootstrap file: \(bootstrap.path)")
        let deadline = ProcessInfo.processInfo.systemUptime + (lifecycle ? 600 : 180)
        mark(.listening)
        try ready(listener, event: Int16(POLLIN), deadline: deadline, idle: lifecycle ? 600 : 180)
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { throw Failure.io }
        defer {
            Darwin.close(peer)
            service.close(client: device)
            coordinator.stopObservation(client: device)
        }
        var yes: Int32 = 1
        guard setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
            fcntl(peer, F_SETFL, O_NONBLOCK) == 0
        else { throw Failure.io }
        var inbox = SessionPacketInbox()
        var successful = Set<String>()
        var requests = 0
        // One connection, <=2048 input frames, <=128 completed requests, one native request in flight.
        for _ in 0..<2048 {
            mark(.frameHeader)
            let header = try read(peer, count: 4, deadline: deadline)
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard (1...4096).contains(length) else { throw Failure.denied }
            mark(.frameBody)
            let frame = try read(peer, count: length, deadline: deadline)
            receivedFrames += 1
            mark(.frameAuthentication)
            // Incomplete encrypted packets remain in the bounded production inbox. Never bypass its checks.
            guard let packet = inbox.receive(frame, sender: device, key: key) else { continue }
            authenticatedRequests += 1
            requests += 1
            guard requests <= 128 else { throw Failure.denied }
            let request = packet.request
            let id = request["id"] as? String ?? ""
            let reply: Data
            var completedProvider: String?
            if request["op"] as? String == "providers" {
                // Obtain profile methods from the real service, not a synthetic hard-coded handshake.
                let describe = try AgentSessionProfile.decode([
                    "id": id,
                    "body": [
                        "agentProtocol": AgentSessionProfile.version, "requestId": id,
                        "method": "agent.describe", "target": [String: String](), "params": [String: String](),
                    ],
                ])
                mark(.providersService)
                let described = try perform(describe, deadline: deadline)
                guard let object = try JSONSerialization.jsonObject(with: described) as? [String: Any],
                    let body = object["body"] as? [String: Any], let result = body["result"] as? [String: Any],
                    let methods = result["methods"] as? [String],
                    var capabilities = result["agentCapabilities"] as? [String: Any]
                else { throw Failure.denied }
                capabilities["adapters"] = (capabilities["adapters"] as? [[String: Any]] ?? []).map {
                    $0.merging(["default": true]) { $1 }
                }
                reply = AgentSessionProfile.data([
                    "id": id, "ok": true, "agentCapabilities": capabilities,
                    "agentProfiles": [
                        "versions": [AgentSessionProfile.version],
                        "minimumClientVersion": AgentSessionProfile.version, "methods": methods,
                    ],
                ])
            } else if request["op"] as? String == "agentRequest",
                let requestedProvider = request["provider"] as? String, scope.providers.contains(requestedProvider),
                let decoded = try? AgentSessionProfile.decode(request),
                scope.allows(decoded, refs: refs)
            {
                mark(.agentService)
                reply = try perform(decoded, deadline: deadline)
                if decoded.method == "session.creationOptions",
                    let adapter = decoded.target["adapterId"] as? String,
                    let provider = scope.providers.first(where: { adapter == $0 + ".currentV1" }),
                    let body = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
                    body["ok"] as? Bool == true
                {
                    completedProvider = provider
                }
                scope.observeProfile(decoded, reply: reply)

            } else {
                reply = AgentSessionProfile.data(["id": id, "ok": false, "code": "native_phone_read_only"])
            }
            guard reply.count <= SessionPacketInbox.plaintextLimit else { throw Failure.denied }
            let packetID = UUID().uuidString.lowercased()
            let encrypted = try SessionEnvelope.seal(
                reply, key: key, device: device, packet: packetID, direction: "mac")
            mark(.responseWrite)
            for bytes in SessionEnvelope.frames(encrypted, device: device, packet: packetID, sender: device) {
                var length = UInt32(bytes.count).bigEndian
                let prefix = withUnsafeBytes(of: &length) { Data($0) }
                try write(peer, data: prefix + bytes, deadline: deadline)
            }
            if let completedProvider { successful.insert(completedProvider) }
            if inspection ? scope.finished : successful == Set(scope.providers) && (!lifecycle || scope.finished) {
                try Self.privateWrite(
                    AgentSessionProfile.data([
                        "scope": inspection
                            ? "original-session-read-only" : lifecycle ? "create-send" : "read-only-creation-options",
                        "providers": inspection ? scope.inspectionSessions.keys.sorted() : successful.sorted(),
                        "phase": "host-replies-written",
                        "encryptedTransport": true, "mutations": lifecycle && !inspection, "approvals": "untested",
                        "authorizationRetained": lifecycle,
                        "crossProcessRecoverySupported": "confirmed-session-read-only",
                        "cleanup": lifecycle ? "manual-after-phone-confirmation" : "read-only-key-release",
                    ]),
                    to: evidence.appendingPathComponent("result.json"))
                mark(.completed)
                return
            }
        }
        throw Failure.incomplete
    }
    private func perform(_ request: AgentSessionProfile.Request, deadline: Double) throws -> Data {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        service.perform(request, client: device) { data in
            box.set(data)
            semaphore.signal()
        }
        guard
            semaphore.wait(
                timeout: .now()
                    + min(
                        lifecycle ? 90 : 45,
                        max(0, deadline - ProcessInfo.processInfo.systemUptime))) == .success,
            let value = box.get()
        else { throw Failure.timeout }
        return value
    }
    // Host replies written is not a phone acknowledgement. Keep lifecycle credentials even on local success.
    static func releaseBootstrap(_ file: URL, lifecycle: Bool) throws {
        if !lifecycle { try FileManager.default.removeItem(at: file) }
    }
    private static func privateWrite(_ bytes: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.io }
        defer { Darwin.close(fd) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.io }
    }
    private func ready(_ fd: Int32, event: Int16, deadline: Double, idle: Double = 15) throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw Failure.timeout }
        var descriptor = pollfd(fd: fd, events: event, revents: 0)
        guard poll(&descriptor, 1, Int32(min(remaining, idle) * 1000)) > 0,
            descriptor.revents & event != 0
        else { throw Failure.timeout }
    }
    private func read(_ fd: Int32, count: Int, deadline: Double) throws -> Data {
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try ready(fd, event: Int16(POLLIN), deadline: deadline)
                let got = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                guard got > 0 else { throw Failure.io }
                offset += got
            }
        }
        return bytes
    }
    private func write(_ fd: Int32, data: Data, deadline: Double) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try ready(fd, event: Int16(POLLOUT), deadline: deadline)
                let sent = send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                guard sent > 0 else { throw Failure.io }
                offset += sent
            }
        }
    }
}
