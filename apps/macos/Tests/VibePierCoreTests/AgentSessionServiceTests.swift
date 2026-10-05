import Foundation
import XCTest

@testable import VibePierCore

final class AgentSessionServiceTests: XCTestCase {
    private final class Harness: @unchecked Sendable {
        let lock = NSRecursiveLock()
        let root: URL
        let directory: AgentSessionDirectory
        let journal: SessionReceiptJournal
        var requests: [Data] = []
        var events: [Data] = []
        var failSaving = false
        var clock: Double = 0
        var holdOpen = false
        var heldOpen: (@Sendable (Data) -> Void)?
        var heldOpens: [@Sendable (Data) -> Void] = []
        var holdItems = false
        var heldItem: (@Sendable (Data) -> Void)?
        var nativeHeld: (@Sendable () -> Void)?
        var page: [String: Any]
        var sendReply: [String: Any]
        var newReply: [String: Any]
        var settingsReply: [String: Any]?
        let nativeID = "00000000-0000-4000-8000-000000000010"
        let provider: String
        lazy var service = makeService()
        init(provider: String = "codex") throws {
            self.provider = provider
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directory = try AgentSessionDirectory(file: root.appendingPathComponent("index.json"))
            journal = try SessionReceiptJournal(file: root.appendingPathComponent("receipts.json"))
            let actions = Dictionary(
                uniqueKeysWithValues: SessionV1Contract.capabilityKeys.map {
                    ($0, ["supported": true, "available": true, "reason": "available"] as [String: Any])
                })
            page = [
                "ok": true, "threadId": nativeID, "viewVersion": 7, "status": "idle", "canSend": true, "messages": [],
                "composer": ["model": "fixture-model", "mode": "auto", "effort": "medium"], "approvals": [],
                "queuedMessages": [], "activeTurnId": "",
                "nativeOwnerEpoch": "native-owner",
                "agentCapabilities": [
                    "version": 1, "adapterId": provider + ".currentV1", "provider": provider, "revision": "native-caps",
                    "actions": actions,
                ],
            ]
            sendReply = [
                "ok": true, "accepted": true, "threadId": nativeID, "nativeMessageId": "native-message",
                "turnId": "native-turn", "turnIdentityKind": "nativeTurn",
            ]
            newReply = ["ok": true, "threadId": "00000000-0000-4000-8000-000000000011", "cwd": "/synthetic"]
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func makeService(directory supplied: AgentSessionDirectory? = nil, useDirectory: Bool = true)
            -> AgentSessionService
        {
            AgentSessionService(
                directory: useDirectory ? supplied ?? directory : nil,
                execute: { [weak self] bytes, provider, client, completion in
                    guard let self else { return }
                    let operation = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["op"] as? String
                    if lock.withLock({ holdOpen && operation == "open" }) {
                        lock.withLock {
                            heldOpen = completion
                            heldOpens.append(completion)
                        }
                        nativeHeld?()
                        return
                    }
                    if lock.withLock({
                        holdItems && ["history", "parts", "message", "approvalDetails"].contains(operation ?? "")
                    }) {
                        lock.withLock {
                            requests.append(bytes)
                            heldItem = completion
                        }
                        nativeHeld?()
                        return
                    }
                    let reply: Data = lock.withLock {
                        requests.append(bytes)
                        let native = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
                        let op = native["op"] as? String ?? ""
                        let value: [String: Any]
                        switch op {
                        case "projects":
                            value = [
                                "ok": true, "projects": [["cwd": "/synthetic", "project": "synthetic"]],
                                "nextOffset": -1,
                            ]
                        case "list":
                            value = [
                                "ok": true, "threads": [["id": nativeID, "cwd": "/synthetic", "title": "Synthetic"]],
                                "nextOffset": -1,
                            ]
                        case "open", "sync": value = page
                        case "close": value = ["ok": true, "released": true]
                        case "history":
                            value = [
                                "ok": true, "threadId": native["threadId"] ?? "", "messages": [["id": "earlier"]],
                                "hasOlder": false,
                            ]
                        case "parts":
                            value = [
                                "ok": true, "threadId": native["threadId"] ?? "",
                                "parts": [["id": "part", "index": 0]], "partCount": 1,
                            ]
                        case "message":
                            value = [
                                "ok": true, "threadId": native["threadId"] ?? "", "text": "synthetic body",
                                "nextOffset": -1,
                            ]
                        case "send": value = sendReply
                        case "new": value = newReply
                        case "newOptions":
                            value = [
                                "ok": true, "creationVersion": 1, "draftId": native["draftId"] ?? "",
                                "models": [["id": "fixture-model", "efforts": ["medium"]]],
                                "permissionModes": [["id": "auto"]],
                                "executionModes": page["executionModes"] ?? [],
                                "agentCapabilities": page["agentCapabilities"] ?? [:],
                            ]
                        case "settings":
                            value =
                                settingsReply ?? [
                                    "ok": true, "accepted": true, "threadId": nativeID,
                                    "composer": ["model": native["model"] ?? "fixture-model"],
                                ]
                        case "interrupt":
                            value = [
                                "ok": true, "accepted": true, "threadId": nativeID,
                                "turnId": native["expectedTurnId"] ?? "", "interruptRequested": true,
                            ]
                        case "approve":
                            value = [
                                "ok": true, "submitted": true, "threadId": nativeID,
                                "fingerprint": native["fingerprint"] ?? "",
                            ]
                        case "receiptCheck", "newReceiptCheck", "settingsReceiptCheck", "interruptReceiptCheck":
                            value = ["ok": false, "error": "fixture lookup is observational"]
                        default: value = ["ok": false, "error": "unsupported fixture method"]
                        }
                        return AgentSessionProfile.data(value)
                    }
                    completion(reply)
                },
                journal: .init(
                    read: { [weak self] key, completion in
                        guard let self else { return }
                        lock.withLock {
                            let value = journal.receipt(key).map {
                                AgentSessionService.Journal.Record(
                                    hash: $0.hash, thread: $0.thread, result: $0.result, intent: $0.intent,
                                    retired: $0.retired == true, evidence: $0.evidence)
                            }
                            completion(.success(value))
                        }
                    },
                    reserve: { [weak self] key, hash, thread, intent, completion in
                        guard let self else { return }
                        lock.withLock {
                            do {
                                switch try journal.reserve(key, hash: hash, thread: thread, intent: intent) {
                                case .fresh: completion(.success(.fresh))
                                case .unknown: completion(.success(.unknown))
                                case .conflict: completion(.success(.conflict))
                                case .complete(let value): completion(.success(.complete(value)))
                                }
                            } catch { completion(.failure(error)) }
                        }
                    },
                    complete: { [weak self] key, data, completion in
                        guard let self else { return }
                        lock.withLock {
                            if failSaving {
                                completion(.failure(SessionReceiptJournal.Failure.invalid))
                                return
                            }
                            do {
                                try journal.complete(key, result: data)
                                completion(.success(()))
                            } catch { completion(.failure(error)) }
                        }
                    },
                    recordEvidence: { [weak self] key, data, completion in
                        guard let self else { return }
                        lock.withLock {
                            do {
                                try journal.recordEvidence(key, evidence: data)
                                completion(.success(()))
                            } catch { completion(.failure(error)) }
                        }
                    }),
                describe: { _, completion in completion(AgentSessionProfile.data(["version": 1, "adapters": []])) },
                freshMutationFailure: { _, _, completion in completion(nil) },
                eventSink: { [weak self] _, data in self?.lock.withLock { self?.events.append(data) } },
                now: { [weak self] in self?.lock.withLock { self?.clock ?? 0 } ?? 0 })
        }
        func count(_ op: String) -> Int {
            lock.withLock {
                requests.filter {
                    (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["op"] as? String == op
                }.count
            }
        }
    }
    private func request(
        _ method: String, target: [String: Any] = [:], params: [String: Any] = [:], operation: String? = nil,
        lease: String? = nil, view: Int64 = 7
    ) throws -> AgentSessionProfile.Request {
        let id = UUID().uuidString.lowercased()
        var body: [String: Any] = [
            "agentProtocol": 2, "requestId": id, "method": method, "target": target, "params": params,
        ]
        if let operation { body["operationId"] = operation }
        if let lease { body["controlLease"] = lease }
        return try AgentSessionProfile.decode(["id": id, "viewVersion": view, "body": body])
    }
    private func perform(
        _ harness: Harness, _ request: AgentSessionProfile.Request, client: String = "phone",
        service: AgentSessionService? = nil
    ) throws -> [String: Any] {
        let finished = expectation(description: request.method)
        let storage = Response()
        (service ?? harness.service).perform(request, client: client) { data in
            storage.data = data
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: storage.data) as? [String: Any])
    }
    private final class Response: @unchecked Sendable { var data = Data() }
    private func result(_ response: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((response["body"] as? [String: Any])?["result"] as? [String: Any])
    }
    private func open(_ harness: Harness, client: String = "phone") throws -> (target: [String: Any], lease: String) {
        let listing = try result(
            perform(
                harness, request("session.list", target: ["adapterId": harness.provider + ".currentV1"]), client: client
            ))
        let item = try XCTUnwrap((listing["sessions"] as? [[String: Any]])?.first)
        let output = try result(
            perform(harness, request("session.open", target: ["sessionRef": item["sessionRef"]!]), client: client))
        let target = try XCTUnwrap(output["session"] as? [String: Any]).filter {
            ["sessionRef", "adapterId", "ownershipEpoch", "capabilityRevision"].contains($0.key)
        }
        XCTAssertEqual((output["snapshot"] as? [String: Any])?["contentState"] as? String, "complete")
        return (target, try XCTUnwrap(output["controlLease"] as? String))
    }
    private func submit(
        _ opened: (target: [String: Any], lease: String), operation: String = UUID().uuidString.lowercased(),
        text: String = "synthetic", mode: String = "start"
    ) throws -> AgentSessionProfile.Request {
        try request(
            "message.submit", target: opened.target,
            params: ["mode": mode, "content": [["type": "text", "text": text]]], operation: operation,
            lease: opened.lease)
    }
    func testNativeProofIsSavedBeforeConfirmedAndOriginalOperationReplaysAfterClose() throws {
        let harness = try Harness()
        let opened = try open(harness)
        let operation = UUID().uuidString.lowercased()
        let first = try perform(harness, submit(opened, operation: operation))
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertEqual((first["body"] as? [String: Any])?["status"] as? String, "confirmed")
        XCTAssertEqual(try result(first)["nativeMessageId"] as? String, "native-message")
        XCTAssertNotNil(harness.journal.receipt("phone:" + operation)?.result)
        harness.service.close(client: "phone")
        let replay = try perform(harness, submit(opened, operation: operation))
        XCTAssertEqual(replay["ok"] as? Bool, true)
        XCTAssertEqual(harness.count("send"), 1)
        let conflict = try perform(harness, submit(opened, operation: operation, text: "different"))
        XCTAssertEqual(conflict["code"] as? String, "operation_id_conflict")
        XCTAssertEqual(harness.count("send"), 1)
    }
    func testLegacyJournalUUIDCannotBecomeFreshProfileTwoOperation() throws {
        let harness = try Harness()
        let opened = try open(harness)
        let operation = UUID().uuidString.lowercased()
        _ = try harness.journal.reserve(
            "phone:" + operation, hash: "legacy", thread: harness.nativeID, intent: Data("{}".utf8))
        let response = try perform(harness, submit(opened, operation: operation))
        XCTAssertEqual(response["code"] as? String, "operation_id_conflict")
        XCTAssertEqual(harness.count("send"), 0)
    }
    func testWrongNativeIdentityAndPersistenceFailureRemainUnknown() throws {
        let harness = try Harness()
        let opened = try open(harness)
        harness.sendReply["threadId"] = "different"
        let operation = UUID().uuidString.lowercased()
        let unknown = try perform(harness, submit(opened, operation: operation))
        XCTAssertEqual(unknown["unknown"] as? Bool, true)
        XCTAssertNil(harness.journal.receipt("phone:" + operation)?.result)
        harness.sendReply["threadId"] = harness.nativeID
        harness.failSaving = true
        let unsaved = try perform(harness, submit(opened))
        XCTAssertEqual(unsaved["unknown"] as? Bool, true)
        XCTAssertEqual(try result(unsaved)["code"] as? String, "agent_receipt_save_failed")
    }
    func testOperationLookupCannotTurnObservationalFailureIntoRejectionOrResend() throws {
        let harness = try Harness()
        let opened = try open(harness)
        harness.sendReply.removeValue(forKey: "turnId")
        let operation = UUID().uuidString.lowercased()
        _ = try perform(harness, submit(opened, operation: operation))
        let response = try result(perform(harness, request("operation.get", params: ["operationId": operation])))
        XCTAssertEqual((response["operation"] as? [String: Any])?["status"] as? String, "unknown")
        XCTAssertEqual(harness.count("send"), 1)
        XCTAssertEqual(harness.count("receiptCheck"), 1)
        XCTAssertNil(harness.journal.receipt("phone:" + operation)?.result)
    }
    func testExecutionModeRequiresIssuedCatalogAndNativeReadback() throws {
        let missing = try Harness()
        let unavailable = try open(missing)
        let refused = try perform(
            missing,
            request(
                "session.configure", target: unavailable.target,
                params: ["options": ["executionMode": "plan"]], operation: UUID().uuidString, lease: unavailable.lease))
        XCTAssertEqual((refused["body"] as? [String: Any])?["status"] as? String, "rejected")
        XCTAssertEqual(missing.count("settings"), 0)

        for (actual, verified, expected) in [
            ("default", true, "unknown"), ("plan", false, "unknown"), ("plan", true, "confirmed"),
        ] {
            let harness = try Harness()
            harness.page["executionModes"] = [["id": "default"], ["id": "plan"]]
            harness.settingsReply = [
                "ok": true, "accepted": true, "threadId": harness.nativeID,
                "composer": ["executionMode": actual, "mode": "auto"], "executionModeVerified": verified,
            ]
            let opened = try open(harness)
            let id = UUID().uuidString
            let response = try perform(
                harness,
                request(
                    "session.configure", target: opened.target,
                    params: ["options": ["executionMode": "plan"]], operation: id, lease: opened.lease))
            XCTAssertEqual((response["body"] as? [String: Any])?["status"] as? String, expected)
            XCTAssertEqual(harness.count("settings"), 1)
            let original = try XCTUnwrap(
                harness.requests.first {
                    (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["op"] as? String == "settings"
                })
            XCTAssertEqual(
                (try JSONSerialization.jsonObject(with: original) as? [String: Any])?["executionMode"] as? String,
                "plan")
            if expected == "unknown" {
                XCTAssertNil(harness.journal.receipt("phone:" + id)?.result)
                _ = try perform(
                    harness,
                    request(
                        "session.configure", target: opened.target,
                        params: ["options": ["executionMode": "plan"]], operation: id, lease: opened.lease))
                XCTAssertEqual(harness.count("settings"), 1)
            }
        }
    }

    func testEmptySearchDiscoveryOpensEveryCurrentProviderFromFreshIdentity() throws {
        for provider in SessionV1Contract.providers {
            let harness = try Harness(provider: provider)
            let adapter = provider + ".currentV1"
            let filter: [String: Any] = ["search": "", "offset": 0, "limit": 8]
            let workspaces = try result(
                perform(
                    harness,
                    request(
                        "workspace.list", target: ["adapterId": adapter], params: filter)))
            XCTAssertEqual((workspaces["workspaces"] as? [[String: Any]])?.count, 1)
            let listed = try result(
                perform(
                    harness,
                    request(
                        "session.list", target: ["adapterId": adapter], params: filter)))
            let session = try XCTUnwrap((listed["sessions"] as? [[String: Any]])?.first)
            let target = session.filter { ["sessionRef", "ownershipEpoch", "capabilityRevision"].contains($0.key) }
            let opened = try perform(harness, request("session.open", target: target))
            XCTAssertEqual(opened["ok"] as? Bool, true)
            let snapshot = try XCTUnwrap(try result(opened)["snapshot"] as? [String: Any])
            XCTAssertEqual(snapshot["threadId"] as? String, harness.nativeID)
            XCTAssertEqual(snapshot["contentState"] as? String, "complete")
            XCTAssertEqual(harness.count("open"), 1)
        }
    }

    func testLeaseCannotBeBorrowedByAnotherPhoneOrUsedAfterExpiry() throws {
        let harness = try Harness()
        let opened = try open(harness)
        let other = try perform(harness, submit(opened), client: "other-phone")
        XCTAssertEqual(other["code"] as? String, "agent_lease_expired")
        harness.clock = 61
        let expired = try perform(harness, submit(opened))
        XCTAssertEqual(expired["code"] as? String, "agent_lease_expired")
        XCTAssertEqual(harness.count("send"), 0)
    }
    func testAuthoritativeSnapshotRenewsSameScopeLeaseAndExpiredLeaseRequiresFreshSnapshot() throws {
        let harness = try Harness()
        let opened = try open(harness)
        harness.clock = 59
        let renewed = try result(perform(harness, request("session.snapshot", target: opened.target)))
        XCTAssertEqual(renewed["controlLease"] as? String, opened.lease)
        harness.clock = 61
        XCTAssertEqual(try perform(harness, submit(opened))["ok"] as? Bool, true)
        harness.clock = 120
        let stale = try perform(harness, submit(opened))
        XCTAssertEqual(stale["code"] as? String, "agent_lease_expired")
        XCTAssertEqual(harness.count("send"), 1)
        let refreshed = try result(perform(harness, request("session.snapshot", target: opened.target)))
        let target = try XCTUnwrap(refreshed["session"] as? [String: Any]).filter {
            ["sessionRef", "adapterId", "ownershipEpoch", "capabilityRevision"].contains($0.key)
        }
        let fresh = (target: target, lease: try XCTUnwrap(refreshed["controlLease"] as? String))
        XCTAssertNotEqual(fresh.lease, opened.lease, "An already expired token is never revived")
        XCTAssertEqual(try perform(harness, submit(fresh))["ok"] as? Bool, true)
        XCTAssertEqual(harness.count("send"), 2)
    }
    func testSnapshotCannotRenewWriteAuthorityFromWrongNativeViewOrOpeningPage() throws {
        let harness = try Harness()
        let opened = try open(harness)
        harness.clock = 61
        harness.page["viewVersion"] = 8
        let wrong = try perform(harness, request("session.snapshot", target: opened.target))
        XCTAssertEqual(wrong["code"] as? String, "agent_target_mismatch")
        XCTAssertEqual(try perform(harness, submit(opened))["code"] as? String, "agent_lease_expired")
        harness.page["viewVersion"] = 7
        harness.page["opening"] = true
        let opening = try result(perform(harness, request("session.snapshot", target: opened.target)))
        XCTAssertNil(opening["controlLease"])
        XCTAssertEqual(harness.count("send"), 0)
    }
    func testExplicitStartCannotBecomeQueueAndSteerIsUnsupported() throws {
        let harness = try Harness()
        harness.page["status"] = "active"
        harness.page["activeTurnId"] = "native-turn"
        let opened = try open(harness)
        let start = try perform(harness, submit(opened))
        XCTAssertEqual(start["code"] as? String, "agent_state_changed")
        let steer = try perform(harness, submit(opened, mode: "steer"))
        XCTAssertEqual(steer["code"] as? String, "agent_mode_unsupported")
        XCTAssertEqual(harness.count("send"), 0)
        harness.sendReply["queued"] = true
        harness.sendReply["queueId"] = "native-queue"
        let queued = try perform(harness, submit(opened, mode: "queue"))
        XCTAssertEqual(queued["ok"] as? Bool, true)
        XCTAssertEqual((queued["body"] as? [String: Any])?["effect"] as? String, "message.queued")
    }
    func testPlanCreationMapsVerifiedNativeFirstInputAndKeepsUnknownEvidence() throws {
        let replies: [(String, [String: Any], String)] = [
            ("codex", ["nativeTurnId": "creation-turn"], "confirmed"),
            (
                "claude",
                [
                    "turnId": "transcript:00000000-0000-4000-8000-000000000011:creation-message",
                    "turnIdentityKind": "nativeMessageAnchor",
                ],
                "confirmed"
            ),
            ("codex", ["turnId": "other-turn", "nativeTurnId": "creation-turn"], "unknown"),
            ("claude", ["turnId": "transcript:00000000-0000-4000-8000-000000000011:creation-message"], "unknown"),
            (
                "claude",
                ["turnId": "transcript:wrong-session:creation-message", "turnIdentityKind": "nativeMessageAnchor"],
                "unknown"
            ),
            (
                "claude",
                [
                    "turnId": "transcript:00000000-0000-4000-8000-000000000011:other-message",
                    "turnIdentityKind": "nativeMessageAnchor",
                ], "unknown"
            ),
            ("codex", ["nativeTurnId": "creation-turn", "executionModeVerified": false], "unknown"),
        ]
        for (provider, proof, expected) in replies {
            let harness = try Harness(provider: provider)
            harness.page["executionModes"] = [["id": "default"], ["id": "plan"]]
            harness.newReply.merge([
                "accepted": true, "nativeMessageId": "creation-message",
                "executionModeVerified": true, "effectiveExecutionMode": "plan",
            ]) { $1 }
            harness.newReply.merge(proof) { $1 }
            let adapter = provider + ".currentV1"
            let listing = try result(perform(harness, request("workspace.list", target: ["adapterId": adapter])))
            let workspace = try XCTUnwrap(
                (listing["workspaces"] as? [[String: Any]])?.first?["workspaceRef"] as? String)
            let options = try result(
                perform(
                    harness,
                    request(
                        "session.creationOptions", target: ["adapterId": adapter],
                        params: ["workspaceRef": workspace, "draftId": UUID().uuidString.lowercased()])))
            let scope = try XCTUnwrap(options["creationLease"] as? [String: Any])
            let target = try XCTUnwrap(scope["target"] as? [String: Any])
            let lease = try XCTUnwrap(scope["controlLease"] as? String)
            let operation = UUID().uuidString.lowercased()
            let create = try request(
                "session.create", target: target,
                params: [
                    "options": ["executionMode": "plan"],
                    "initialMessage": ["content": [["type": "text", "text": "first"]]],
                ], operation: operation, lease: lease)
            let reply = try perform(harness, create)
            XCTAssertEqual((reply["body"] as? [String: Any])?["status"] as? String, expected)
            let value = try result(reply)
            XCTAssertEqual(value["sessionCreated"] as? Bool, true)
            if expected == "confirmed" {
                XCTAssertEqual(value["initialInput"] as? String, "confirmed")
                XCTAssertEqual(value["executionModeState"] as? String, "confirmed")
                XCTAssertEqual(value["messageId"] as? String, "creation-message")
                XCTAssertNotNil(value["turnId"] as? String)
                XCTAssertEqual(
                    value["turnIdentityKind"] as? String, provider == "claude" ? "nativeMessageAnchor" : "nativeTurn")
            } else {
                XCTAssertNil(harness.journal.receipt("phone:" + operation)?.result)
            }
            _ = try perform(harness, create)
            XCTAssertEqual(harness.count("new"), 1)
        }
    }

    func testPartialCreationPersistsNativeIdentityAndDoesNotResubmitFirstInput() throws {
        let harness = try Harness()
        harness.newReply["ok"] = false
        harness.newReply["unknown"] = true
        let listing = try result(perform(harness, request("workspace.list", target: ["adapterId": "codex.currentV1"])))
        let workspace = try XCTUnwrap((listing["workspaces"] as? [[String: Any]])?.first?["workspaceRef"] as? String)
        let draft = UUID().uuidString.lowercased()
        let options = try result(
            perform(
                harness,
                request(
                    "session.creationOptions", target: ["adapterId": "codex.currentV1"],
                    params: ["workspaceRef": workspace, "draftId": draft])))
        let creation = try XCTUnwrap(options["creationLease"] as? [String: Any])
        let target = try XCTUnwrap(creation["target"] as? [String: Any])
        let lease = try XCTUnwrap(creation["controlLease"] as? String)
        let operation = UUID().uuidString.lowercased()
        let create = try request(
            "session.create", target: target,
            params: ["initialMessage": ["content": [["type": "text", "text": "first"]]]], operation: operation,
            lease: lease)
        let response = try perform(harness, create)
        XCTAssertEqual(response["unknown"] as? Bool, true)
        XCTAssertEqual(try result(response)["initialInput"] as? String, "unknown")
        let ref = try XCTUnwrap((try result(response)["session"] as? [String: Any])?["sessionRef"] as? String)
        XCTAssertNotNil(harness.directory.session(ref))
        XCTAssertNotNil(harness.journal.receipt("phone:" + operation)?.evidence)
        let restoredDirectory = try AgentSessionDirectory(file: harness.root.appendingPathComponent("index.json"))
        let rebooted = harness.makeService(directory: restoredDirectory)
        let replay = try perform(harness, create, service: rebooted)
        XCTAssertEqual((try result(replay)["session"] as? [String: Any])?["sessionRef"] as? String, ref)
        XCTAssertEqual(harness.count("new"), 1)
    }
    func testApprovalRequiresIssuedIDFingerprintRevisionAndOnceScope() throws {
        let harness = try Harness()
        harness.page["approvals"] = [
            [
                "id": 42, "method": "item/commandExecution/requestApproval", "fingerprint": "native-fingerprint",
                "canDecide": true,
            ]
        ]
        let opened = try open(harness)
        let snapshot = try result(perform(harness, request("session.snapshot", target: opened.target)))
        let approval = try XCTUnwrap(
            ((snapshot["snapshot"] as? [String: Any])?["approvals"] as? [[String: Any]])?.first)
        let currentTarget = try XCTUnwrap(snapshot["session"] as? [String: Any]).filter {
            ["sessionRef", "adapterId", "ownershipEpoch", "capabilityRevision"].contains($0.key)
        }
        let lease = try XCTUnwrap(snapshot["controlLease"] as? String)
        var params: [String: Any] = [
            "approvalId": approval["id"]!, "fingerprint": approval["fingerprint"]!, "revision": approval["revision"]!,
            "decision": "allow",
        ]
        let allowed = try perform(
            harness,
            request(
                "approval.resolve", target: currentTarget, params: params, operation: UUID().uuidString.lowercased(),
                lease: lease))
        XCTAssertEqual(allowed["ok"] as? Bool, true)
        params["revision"] = "stale"
        let changed = try perform(
            harness,
            request(
                "approval.resolve", target: currentTarget, params: params, operation: UUID().uuidString.lowercased(),
                lease: lease))
        XCTAssertEqual(changed["code"] as? String, "agent_approval_changed")
        XCTAssertEqual(harness.count("approve"), 1)
    }
    func testOnlyNativeOnceClaudePlanCanBeApprovedFromProfileTwo() throws {
        for (provider, scope, expected) in [
            ("claude", "once", "confirmed"), ("claude", "session", "rejected"), ("codex", "once", "rejected"),
        ] {
            let harness = try Harness(provider: provider)
            harness.page["approvals"] = [
                [
                    "id": "native-plan", "fingerprint": "native-plan-fingerprint", "toolUseId": "native-tool",
                    "plan": true, "planApprovalScope": scope, "canDecide": true, "details": "Complete synthetic plan",
                ]
            ]
            let opened = try open(harness)
            let snapshot = try result(perform(harness, request("session.snapshot", target: opened.target)))
            let approval = try XCTUnwrap(
                ((snapshot["snapshot"] as? [String: Any])?["approvals"] as? [[String: Any]])?.first)
            let target = try XCTUnwrap(snapshot["session"] as? [String: Any]).filter {
                ["sessionRef", "adapterId", "ownershipEpoch", "capabilityRevision"].contains($0.key)
            }
            let params: [String: Any] = [
                "approvalId": approval["id"]!, "fingerprint": approval["fingerprint"]!,
                "revision": approval["revision"]!, "decision": "allow",
            ]
            let response = try perform(
                harness,
                request(
                    "approval.resolve", target: target, params: params,
                    operation: UUID().uuidString, lease: try XCTUnwrap(snapshot["controlLease"] as? String)))
            XCTAssertEqual((response["body"] as? [String: Any])?["status"] as? String, expected)
            XCTAssertEqual(harness.count("approve"), expected == "confirmed" ? 1 : 0)
        }
    }

    func testDirtyEventsInvalidateLeaseAndReplaySignalsSnapshotWithoutExecuting() throws {
        let harness = try Harness()
        let opened = try open(harness)
        let observed = try result(
            perform(harness, request("session.observe", target: opened.target, params: ["subscriptionId": "observer"])))
        let epoch = try XCTUnwrap(observed["streamEpoch"] as? String)
        harness.service.receiveCurrentV1Event(
            AgentSessionProfile.data(["threadId": harness.nativeID, "viewVersion": 7, "revision": 8]),
            provider: "codex", client: "phone")
        let rejected = try perform(harness, submit(opened))
        XCTAssertEqual(rejected["code"] as? String, "agent_lease_expired")
        XCTAssertEqual(harness.count("send"), 0)
        let event = try XCTUnwrap(harness.events.first).flatMapJSON()
        let body = try XCTUnwrap(event["body"] as? [String: Any])
        XCTAssertEqual(body["event"] as? String, "session.stateChanged")
        XCTAssertEqual(body["subscriptionId"] as? String, "observer")
        let refreshed = try open(harness)
        let recovered = try result(
            perform(
                harness,
                request(
                    "session.observe", target: refreshed.target,
                    params: ["subscriptionId": "observer", "streamEpoch": epoch, "afterSequence": 0])))
        XCTAssertEqual(recovered["resyncRequired"] as? Bool, false)
        XCTAssertEqual((recovered["events"] as? [[String: Any]])?.count, 1)
    }
    func testContinuousContentEventsKeepControlLeaseAndPermitOneQueuedSubmission() throws {
        let harness = try Harness()
        harness.page["status"] = "active"
        harness.page["activeTurnId"] = "native-turn"
        harness.sendReply["queued"] = true
        harness.sendReply["queueId"] = "synthetic-queue"
        let opened = try open(harness)
        _ = try perform(
            harness, request("session.observe", target: opened.target, params: ["subscriptionId": "tokens"]))
        for revision in 1...20 {
            var delta = harness.page
            delta["event"] = "delta"
            delta["revision"] = revision
            delta["messages"] = [["id": "reply", "role": "assistant", "text": "Synthetic token \(revision)"]]
            var composer = delta["composer"] as! [String: Any]
            composer["contextUsage"] = "Synthetic usage \(revision)"
            delta["composer"] = composer
            harness.service.receiveCurrentV1Event(AgentSessionProfile.data(delta), provider: "codex", client: "phone")
        }
        let submitted = try perform(harness, submit(opened, mode: "queue"))
        XCTAssertEqual(submitted["ok"] as? Bool, true)
        XCTAssertEqual(harness.count("send"), 1)
        XCTAssertEqual(harness.events.count, 20)
        for bytes in harness.events {
            let body = try XCTUnwrap(try bytes.flatMapJSON()["body"] as? [String: Any])
            let data = try XCTUnwrap(body["data"] as? [String: Any])
            XCTAssertEqual(data["dirty"] as? Bool, true)
            XCTAssertEqual(data["controlDirty"] as? Bool, false)
        }
    }
    private func withoutQueue(_ harness: Harness) {
        harness.page.removeValue(forKey: "queuedMessages")
        var caps = harness.page["agentCapabilities"] as! [String: Any]
        var actions = caps["actions"] as! [String: [String: Any]]
        for key in ["queue", "queueDelete", "queueSteer"] {
            actions[key] = ["supported": false, "available": false, "reason": "unsupported"]
        }
        caps["actions"] = actions
        harness.page["agentCapabilities"] = caps
    }
    func testClaudeCompletePageWithoutNativeQueuePreservesLeaseForContentChanges() throws {
        let harness = try Harness(provider: "claude")
        // ClaudeBridge.makePage supplies an incarnation-bound owner epoch, approvals and composer, but no queue.
        withoutQueue(harness)
        harness.page["composer"] = ["model": "default", "mode": "acceptEdits", "effort": "default"]
        let opened = try open(harness)
        _ = try perform(
            harness, request("session.observe", target: opened.target, params: ["subscriptionId": "claude-content"]))
        var delta = harness.page
        delta["event"] = "delta"
        delta["revision"] = 1
        delta["messages"] = [["id": "reply", "role": "assistant", "text": "Synthetic appended output"]]
        harness.service.receiveCurrentV1Event(AgentSessionProfile.data(delta), provider: "claude", client: "phone")
        XCTAssertEqual(try perform(harness, submit(opened))["ok"] as? Bool, true)
        XCTAssertEqual(harness.count("send"), 1)
        let body = try XCTUnwrap(try harness.events.first?.flatMapJSON()["body"] as? [String: Any])
        XCTAssertEqual((body["data"] as? [String: Any])?["controlDirty"] as? Bool, false)
        XCTAssertNil(harness.page["queuedMessages"])
    }
    func testZCodeCompletePageWithoutOwnerProofRemainsFailClosedAndFreshSnapshotAllowsIdleSubmission() throws {
        let harness = try Harness(provider: "zcode")
        // ZCodeBridge.page carries queuedFollowUps and activeTurnId, but does not carry an owner identity.
        withoutQueue(harness)
        harness.page.removeValue(forKey: "nativeOwnerEpoch")
        harness.page["queuedFollowUps"] = []
        harness.page["composer"] = ZCodeConversation.composer([:], latest: ["modelId": "GLM-fixture"])
        let opened = try open(harness)
        _ = try perform(
            harness, request("session.observe", target: opened.target, params: ["subscriptionId": "zcode-content"]))
        var delta = harness.page
        delta["event"] = "delta"
        delta["revision"] = 1
        delta["messages"] = [["id": "reply", "role": "assistant", "text": "Synthetic appended output"]]
        harness.service.receiveCurrentV1Event(AgentSessionProfile.data(delta), provider: "zcode", client: "phone")
        XCTAssertEqual(try perform(harness, submit(opened))["code"] as? String, "agent_lease_expired")
        XCTAssertEqual(harness.count("send"), 0)
        let body = try XCTUnwrap(try harness.events.first?.flatMapJSON()["body"] as? [String: Any])
        XCTAssertEqual((body["data"] as? [String: Any])?["controlDirty"] as? Bool, true)
        let refreshed = try result(perform(harness, request("session.snapshot", target: opened.target)))
        let target = try XCTUnwrap(refreshed["session"] as? [String: Any]).filter {
            ["sessionRef", "adapterId", "ownershipEpoch", "capabilityRevision"].contains($0.key)
        }
        let prepared = (target: target, lease: try XCTUnwrap(refreshed["controlLease"] as? String))
        XCTAssertEqual(try perform(harness, submit(prepared))["ok"] as? Bool, true)
        XCTAssertEqual(harness.count("send"), 1)
        XCTAssertNil(harness.page["owner"])
        XCTAssertNil(harness.page["nativeOwnerEpoch"])
        XCTAssertNil(harness.page["queuedMessages"])
        XCTAssertEqual(harness.page["activeTurnId"] as? String, "")
    }
    func testVerifiedZCodePageWithoutQueuePreservesLeaseDuringContentStreamAndAllowsOneInterrupt() throws {
        let harness = try Harness(provider: "zcode")
        withoutQueue(harness)
        harness.page["queuedFollowUps"] = []
        harness.page["composer"] = ZCodeConversation.composer([:], latest: ["modelId": "GLM-fixture"])
        // ZCodeDesktop returns this opaque epoch only for its verified process, window and native session tuple.
        harness.page["nativeOwnerEpoch"] = UUID().uuidString.lowercased()
        harness.page["status"] = "active"
        harness.page["activeTurnId"] = "native-user-message"
        var caps = harness.page["agentCapabilities"] as! [String: Any]
        var actions = caps["actions"] as! [String: [String: Any]]
        actions["send"] = ["supported": true, "available": false, "reason": "busy"]
        caps["actions"] = actions
        harness.page["agentCapabilities"] = caps
        let opened = try open(harness)
        _ = try perform(
            harness, request("session.observe", target: opened.target, params: ["subscriptionId": "zcode-tokens"]))
        for revision in 1...20 {
            var delta = harness.page
            delta["event"] = "delta"
            delta["revision"] = revision
            delta["messages"] = [["id": "reply", "role": "assistant", "text": "Synthetic token \(revision)"]]
            harness.service.receiveCurrentV1Event(AgentSessionProfile.data(delta), provider: "zcode", client: "phone")
        }
        let interrupted = try perform(
            harness,
            request(
                "turn.interrupt", target: opened.target, params: ["expectedTurnId": "native-user-message"],
                operation: UUID().uuidString.lowercased(), lease: opened.lease))
        XCTAssertEqual(interrupted["ok"] as? Bool, true)
        XCTAssertEqual(harness.count("interrupt"), 1)
        XCTAssertEqual(harness.count("send"), 0)
        XCTAssertEqual(harness.events.count, 20)
        for bytes in harness.events {
            let body = try XCTUnwrap(try bytes.flatMapJSON()["body"] as? [String: Any])
            XCTAssertEqual((body["data"] as? [String: Any])?["controlDirty"] as? Bool, false)
        }
        XCTAssertNil(harness.page["queuedMessages"])
    }
    func testOpenAndSnapshotShareInternalOwnerVerificationScopeWithoutRemoteParameterOverrides() throws {
        let harness = try Harness(provider: "zcode")
        let opened = try open(harness)
        XCTAssertEqual(try perform(harness, request("session.snapshot", target: opened.target))["ok"] as? Bool, true)
        let reads = try harness.requests.map { try $0.flatMapJSON() }.filter { $0["op"] as? String == "open" }
        XCTAssertEqual(reads.count, 2)
        for read in reads {
            XCTAssertEqual(read["verifyNativeOwner"] as? Bool, true)
            XCTAssertEqual(read["threadId"] as? String, harness.nativeID)
            XCTAssertEqual(read["viewVersion"] as? Int, 7)
        }
        XCTAssertThrowsError(
            try request("session.snapshot", target: opened.target, params: ["verifyNativeOwner": false]))
        XCTAssertEqual(harness.count("open"), 2)
    }
    func testMissingSupportedQueueAndMalformedUnsupportedQueueStillInvalidateControls() throws {
        for supported in [true, false] {
            let harness = try Harness()
            if !supported { withoutQueue(harness) }
            let opened = try open(harness)
            var delta = harness.page
            delta["event"] = "delta"
            if supported { delta.removeValue(forKey: "queuedMessages") } else { delta["queuedMessages"] = "invalid" }
            harness.service.receiveCurrentV1Event(AgentSessionProfile.data(delta), provider: "codex", client: "phone")
            XCTAssertEqual(try perform(harness, submit(opened))["code"] as? String, "agent_lease_expired")
            XCTAssertEqual(harness.count("send"), 0)
        }
    }
    func testMissingAndOversizedRawApprovalsAreNeverHiddenByEventNormalization() throws {
        for oversized in [false, true] {
            let harness = try Harness()
            let approvals = (0..<128).map { ["id": "native-approval-\($0)", "fingerprint": "synthetic-\($0)"] }
            if oversized { harness.page["approvals"] = approvals }
            let opened = try open(harness)
            _ = try perform(
                harness, request("session.observe", target: opened.target, params: ["subscriptionId": "approvals"]))
            var delta = harness.page
            delta["event"] = "delta"
            if oversized {
                delta["approvals"] = approvals + [["id": "hidden-native-approval"]]
            } else {
                delta.removeValue(forKey: "approvals")
            }
            harness.service.receiveCurrentV1Event(AgentSessionProfile.data(delta), provider: "codex", client: "phone")
            XCTAssertEqual(try perform(harness, submit(opened))["code"] as? String, "agent_lease_expired")
            XCTAssertEqual(harness.count("send"), 0)
            let body = try XCTUnwrap(try harness.events.first?.flatMapJSON()["body"] as? [String: Any])
            XCTAssertEqual((body["data"] as? [String: Any])?["controlDirty"] as? Bool, true)
        }
    }
    func testMissingAndOversizedRawSnapshotApprovalsCannotEstablishACompleteControlDigest() throws {
        for oversized in [false, true] {
            let harness = try Harness()
            let approvals = (0..<128).map { ["id": "native-approval-\($0)", "fingerprint": "synthetic-\($0)"] }
            if oversized {
                harness.page["approvals"] = approvals + [["id": "hidden-native-approval"]]
            } else {
                harness.page.removeValue(forKey: "approvals")
            }
            let opened = try open(harness)
            // This complete event matches the normalized snapshot exactly; the raw snapshot was still incomplete.
            var delta = harness.page
            delta["event"] = "delta"
            delta["approvals"] = oversized ? approvals : []
            harness.service.receiveCurrentV1Event(AgentSessionProfile.data(delta), provider: "codex", client: "phone")
            XCTAssertEqual(try perform(harness, submit(opened))["code"] as? String, "agent_lease_expired")
            XCTAssertEqual(harness.count("send"), 0)
        }
    }
    func testControlChangesAndUnknownSparseEventsStillRevokeWriteAuthority() throws {
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["nativeOwnerEpoch"] = "different-owner" },
            { $0["owner"] = "different-native-owner" },
            {
                $0["status"] = "active"
                $0["activeTurnId"] = "new-turn"
            },
            {
                var composer = $0["composer"] as! [String: Any]
                composer["effort"] = "high"
                $0["composer"] = composer
            },
            {
                var composer = $0["composer"] as! [String: Any]
                composer["modeLocked"] = true
                $0["composer"] = composer
            },
            {
                $0["approvals"] = [
                    [
                        "id": "native-approval", "fingerprint": "changed", "details": "Synthetic approval",
                        "canDecide": true,
                    ]
                ]
            },
            {
                $0["queuedMessages"] = [
                    ["id": "queue", "text": "Synthetic queued text", "canDelete": true, "canSteer": true]
                ]
            },
            {
                var caps = $0["agentCapabilities"] as! [String: Any]
                caps["revision"] = "new-caps"
                $0["agentCapabilities"] = caps
            },
            { $0.removeValue(forKey: "composer") },
            { $0["contentState"] = "partial" },
            { $0["event"] = "unavailable" },
        ]
        for change in changes {
            let harness = try Harness()
            let opened = try open(harness)
            var delta = harness.page
            delta["event"] = "delta"
            change(&delta)
            harness.service.receiveCurrentV1Event(AgentSessionProfile.data(delta), provider: "codex", client: "phone")
            let rejected = try perform(harness, submit(opened))
            XCTAssertEqual(rejected["code"] as? String, "agent_lease_expired")
            XCTAssertEqual(harness.count("send"), 0)
        }
    }
    func testSameScopeSnapshotsCoalesceBackgroundAndControlReadsWithOwnReplyIDsAndBoundedWaiters() throws {
        let harness = try Harness()
        let opened = try open(harness)
        harness.holdOpen = true
        let held = expectation(description: "one native snapshot for all readers")
        harness.nativeHeld = { held.fulfill() }
        let done = expectation(description: "all sixteen coalesced readers receive a verified result")
        done.expectedFulfillmentCount = 16
        let replies = (0..<16).map { _ in Response() }
        let reads = try (0..<16).map { index in
            try request(index == 1 ? "session.open" : "session.snapshot", target: opened.target)
        }
        for (index, read) in reads.enumerated() {
            harness.service.perform(read, client: "phone") { bytes in
                replies[index].data = bytes
                done.fulfill()
            }
        }
        wait(for: [held], timeout: 2)
        let capacity = try perform(harness, request("session.snapshot", target: opened.target))
        XCTAssertEqual(capacity["code"] as? String, "capacity_exceeded")
        XCTAssertEqual(harness.heldOpens.count, 1)
        var content = harness.page
        content["event"] = "delta"
        content["messages"] = [["id": "reply", "text": "Synthetic progress while snapshot is pending"]]
        harness.service.receiveCurrentV1Event(AgentSessionProfile.data(content), provider: "codex", client: "phone")
        // Queue a read barrier after the content event; content must neither cancel the shared read nor revoke its lease.
        XCTAssertEqual(try perform(harness, submit(opened))["ok"] as? Bool, true)
        harness.heldOpen?(AgentSessionProfile.data(harness.page))
        wait(for: [done], timeout: 2)
        for (index, response) in replies.enumerated() {
            let value = try response.data.flatMapJSON()
            XCTAssertEqual(value["id"] as? String, reads[index].id)
            XCTAssertEqual((value["body"] as? [String: Any])?["requestId"] as? String, reads[index].id)
            XCTAssertEqual(try result(value)["controlLease"] as? String, opened.lease)
        }
        XCTAssertEqual(harness.count("send"), 1)
    }
    func testCrossScopeConcurrentSnapshotCannotCoalesceOrReplaceTheNewViewWithALateOldReply() throws {
        let harness = try Harness()
        let opened = try open(harness)
        harness.holdOpen = true
        let held = expectation(description: "different scopes use separate native snapshots")
        held.expectedFulfillmentCount = 2
        harness.nativeHeld = { held.fulfill() }
        let old = expectation(description: "old reader rejected")
        let new = expectation(description: "new reader accepted")
        let oldResponse = Response()
        let newResponse = Response()
        harness.service.perform(try request("session.snapshot", target: opened.target), client: "phone") {
            oldResponse.data = $0
            old.fulfill()
        }
        let nextID = "00000000-0000-4000-8000-000000000099"
        let next = try harness.directory.registerSession(
            adapter: "codex.currentV1", provider: "codex", native: nextID, cwd: "/synthetic")
        harness.service.perform(try request("session.open", target: ["sessionRef": next.ref], view: 8), client: "phone")
        {
            newResponse.data = $0
            new.fulfill()
        }
        wait(for: [held], timeout: 2)
        var nextPage = harness.page
        nextPage["threadId"] = nextID
        nextPage["viewVersion"] = 8
        harness.heldOpens[1](AgentSessionProfile.data(nextPage))
        wait(for: [new], timeout: 2)
        harness.heldOpens[0](AgentSessionProfile.data(harness.page))
        wait(for: [old], timeout: 2)
        XCTAssertEqual(try newResponse.data.flatMapJSON()["ok"] as? Bool, true)
        XCTAssertEqual(try oldResponse.data.flatMapJSON()["code"] as? String, "agent_session_view_closed")
        let current = try result(
            perform(
                harness, request("session.items", target: ["sessionRef": next.ref], params: ["kind": "recent"], view: 8)
            ))
        XCTAssertNotNil(current["items"])
    }
    func testUnavailableDirectoryRejectsProfileTwoWithoutInvokingNativeDriver() throws {
        let harness = try Harness()
        let unavailable = harness.makeService(useDirectory: false)
        let response = try perform(harness, request("agent.describe"), service: unavailable)
        XCTAssertEqual(response["code"] as? String, "agent_index_invalid")
        XCTAssertTrue(harness.requests.isEmpty)
    }
    func testAdmissionUsesPrivateSessionIndexAndKnownJournalRatherThanEnvelopeProvider() throws {
        let harness = try Harness()
        let opened = try open(harness)
        let completed = expectation(description: "private provider")
        harness.service.admissionProvider(
            try request("session.snapshot", target: ["sessionRef": opened.target["sessionRef"]!]), client: "phone"
        ) { provider in
            XCTAssertEqual(provider, "codex")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        let conflict = expectation(description: "mismatched adapter")
        harness.service.admissionProvider(
            try request(
                "session.snapshot",
                target: ["sessionRef": opened.target["sessionRef"]!, "adapterId": "claude.currentV1"]), client: "phone"
        ) { provider in
            // The invalid request can only occupy the control admission lane before formal rejection.
            XCTAssertNil(provider)
            conflict.fulfill()
        }
        wait(for: [conflict], timeout: 2)
    }
    func testLateNativeOpenCallbackCannotRestoreLeaseAfterClose() throws {
        let harness = try Harness()
        let listing = try result(perform(harness, request("session.list", target: ["adapterId": "codex.currentV1"])))
        let ref = try XCTUnwrap((listing["sessions"] as? [[String: Any]])?.first?["sessionRef"] as? String)
        let held = expectation(description: "native read in progress")
        let completed = expectation(description: "closed read answered")
        let response = Response()
        harness.holdOpen = true
        harness.nativeHeld = { held.fulfill() }
        harness.service.perform(try request("session.open", target: ["sessionRef": ref]), client: "phone") { data in
            response.data = data
            completed.fulfill()
        }
        wait(for: [held], timeout: 2)
        harness.service.close(client: "phone")
        harness.heldOpen?(AgentSessionProfile.data(harness.page))
        wait(for: [completed], timeout: 2)
        let body = try response.data.flatMapJSON()
        XCTAssertEqual(body["code"] as? String, "agent_session_view_closed")
        XCTAssertNil((body["body"] as? [String: Any])?["result"])
    }
    func testLastUnobserveClosesOnlyThatPhonesObservationAndRevokesItsLease() throws {
        let harness = try Harness()
        let phone = try open(harness)
        let other = try open(harness, client: "other-phone")
        for id in ["one", "two"] {
            _ = try perform(harness, request("session.observe", target: phone.target, params: ["subscriptionId": id]))
        }
        let first = try result(
            perform(harness, request("session.unobserve", target: phone.target, params: ["subscriptionId": "one"])))
        XCTAssertEqual(first["reason"] as? String, "other_subscription_active")
        XCTAssertEqual(harness.count("close"), 0)
        let last = try result(
            perform(harness, request("session.unobserve", target: phone.target, params: ["subscriptionId": "two"])))
        XCTAssertEqual(last["nativeObservationReleased"] as? Bool, true)
        XCTAssertEqual(harness.count("close"), 1)
        XCTAssertEqual(harness.count("interrupt"), 0)
        let denied = try perform(harness, submit(phone))
        XCTAssertEqual(denied["code"] as? String, "agent_lease_expired")
        let unaffected = try perform(harness, submit(other), client: "other-phone")
        XCTAssertEqual(unaffected["ok"] as? Bool, true)
    }
    func testLateUnobserveCannotCloseAReplacementSessionEvenWithSameViewVersion() throws {
        let harness = try Harness()
        let prior = try open(harness)
        _ = try perform(
            harness, request("session.observe", target: prior.target, params: ["subscriptionId": "old-view"]))
        let replacementID = "00000000-0000-4000-8000-000000000099"
        let replacement = try harness.directory.registerSession(
            adapter: "codex.currentV1", provider: "codex", native: replacementID, cwd: "/synthetic")
        harness.page["threadId"] = replacementID
        _ = try perform(harness, request("session.open", target: ["sessionRef": replacement.ref]))
        let released = try result(
            perform(harness, request("session.unobserve", target: prior.target, params: ["subscriptionId": "old-view"]))
        )
        XCTAssertEqual(released["nativeObservationReleased"] as? Bool, false)
        XCTAssertEqual(harness.count("close"), 0)
        let stillOpen = try perform(harness, request("session.items", target: ["sessionRef": replacement.ref]))
        XCTAssertEqual(stillOpen["ok"] as? Bool, true)
    }
    func testFrequentSnapshotsReuseTheLiveLeaseRatherThanExhaustingQuota() throws {
        let harness = try Harness()
        let opened = try open(harness)
        for _ in 0..<140 {
            let snapshot = try result(perform(harness, request("session.snapshot", target: opened.target)))
            XCTAssertEqual(snapshot["controlLease"] as? String, opened.lease)
        }
    }
    func testDirtySnapshotInvalidationKeepsExactNativeObservationForCleanup() throws {
        let harness = try Harness()
        let opened = try open(harness)
        _ = try perform(
            harness, request("session.observe", target: opened.target, params: ["subscriptionId": "dirty-view"]))
        harness.service.receiveCurrentV1Event(
            AgentSessionProfile.data(["threadId": harness.nativeID, "viewVersion": 7, "revision": 8]),
            provider: "codex", client: "phone")
        let released = try result(
            perform(
                harness, request("session.unobserve", target: opened.target, params: ["subscriptionId": "dirty-view"])))
        XCTAssertEqual(released["nativeObservationReleased"] as? Bool, true)
        XCTAssertEqual(harness.count("close"), 1)
        XCTAssertEqual(harness.count("interrupt"), 0)
    }
    func testDirtyHistoryAndReplyReadsKeepNativeObservationWithoutRestoringWriteAuthority() throws {
        let harness = try Harness()
        let opened = try open(harness)
        harness.service.receiveCurrentV1Event(
            AgentSessionProfile.data(["threadId": harness.nativeID, "viewVersion": 7, "revision": 8]),
            provider: "codex", client: "phone")
        for kind in ["history", "parts", "message"] {
            let output = try result(
                perform(
                    harness,
                    request(
                        "session.items", target: opened.target,
                        params: ["kind": kind, "messageId": "reply", "offset": 0])))
            XCTAssertEqual(output["threadId"] as? String, harness.nativeID)
            let native = try XCTUnwrap(harness.requests.last).flatMapJSON()
            XCTAssertEqual(native["op"] as? String, kind)
            XCTAssertEqual(native["threadId"] as? String, harness.nativeID)
            XCTAssertEqual(AgentSessionProfile.integer(native["viewVersion"]), 7)
            XCTAssertEqual(native["agentAdapterId"] as? String, "codex.currentV1")
            XCTAssertNil(native["nativeOwnerEpoch"])
        }
        let denied = try perform(harness, submit(opened))
        XCTAssertEqual(denied["code"] as? String, "agent_lease_expired")
        XCTAssertEqual(harness.count("send"), 0)
        for kind in ["recent", "approvalDetails", "composerOptions"] {
            let rejected = try perform(
                harness,
                request(
                    "session.items", target: opened.target,
                    params: ["kind": kind, "messageId": "approval"]))
            XCTAssertEqual(rejected["code"] as? String, "agent_session_not_open")
        }
        XCTAssertEqual(harness.count("approvalDetails"), 0)
        XCTAssertEqual(harness.count("composerOptions"), 0)
    }
    func testDirtyItemReadsRejectOtherPhoneWrongViewAndClosedObservation() throws {
        let harness = try Harness()
        let opened = try open(harness)
        harness.service.receiveCurrentV1Event(
            AgentSessionProfile.data(["threadId": harness.nativeID, "viewVersion": 7, "revision": 8]),
            provider: "codex", client: "phone")
        let read = try request("session.items", target: opened.target, params: ["kind": "history"])
        let other = try perform(harness, read, client: "other-phone")
        XCTAssertEqual(other["code"] as? String, "agent_session_not_open")
        let wrongView = try perform(
            harness,
            request(
                "session.items", target: opened.target,
                params: ["kind": "history"], view: 8))
        XCTAssertEqual(wrongView["code"] as? String, "agent_session_not_open")
        harness.service.close(client: "phone")
        let closed = try perform(harness, read)
        XCTAssertEqual(closed["code"] as? String, "agent_session_not_open")
        XCTAssertEqual(harness.count("history"), 0)
    }
    func testPendingReplacementRejectsOldDirtyItemReadsEvenWithSameViewVersion() throws {
        let harness = try Harness()
        let opened = try open(harness)
        harness.service.receiveCurrentV1Event(
            AgentSessionProfile.data(["threadId": harness.nativeID, "viewVersion": 7, "revision": 8]),
            provider: "codex", client: "phone")
        let replacementID = "00000000-0000-4000-8000-000000000099"
        let replacement = try harness.directory.registerSession(
            adapter: "codex.currentV1", provider: "codex", native: replacementID, cwd: "/synthetic")
        harness.page["threadId"] = replacementID
        harness.holdOpen = true
        let held = expectation(description: "replacement open in progress")
        let completed = expectation(description: "replacement opened")
        harness.nativeHeld = { held.fulfill() }
        harness.service.perform(try request("session.open", target: ["sessionRef": replacement.ref]), client: "phone") {
            _ in
            completed.fulfill()
        }
        wait(for: [held], timeout: 2)
        let oldRead = try request(
            "session.items", target: opened.target, params: ["kind": "parts", "messageId": "reply"])
        let pending = try perform(harness, oldRead)
        XCTAssertEqual(pending["code"] as? String, "agent_session_not_open")
        XCTAssertEqual(harness.count("parts"), 0)
        harness.heldOpen?(AgentSessionProfile.data(harness.page))
        wait(for: [completed], timeout: 2)
        let replaced = try perform(harness, oldRead)
        XCTAssertEqual(replaced["code"] as? String, "agent_session_not_open")
        let current = try result(
            perform(
                harness,
                request(
                    "session.items", target: ["sessionRef": replacement.ref],
                    params: ["kind": "parts", "messageId": "reply"])))
        XCTAssertEqual(current["threadId"] as? String, replacementID)
        XCTAssertEqual(harness.count("parts"), 1)
    }
    func testPendingNewViewRejectsOldItemReadsForTheSameSession() throws {
        let harness = try Harness()
        let opened = try open(harness)
        harness.holdOpen = true
        harness.page["viewVersion"] = 8
        let held = expectation(description: "new view open in progress")
        let completed = expectation(description: "new view opened")
        harness.nativeHeld = { held.fulfill() }
        harness.service.perform(try request("session.snapshot", target: opened.target, view: 8), client: "phone") { _ in
            completed.fulfill()
        }
        wait(for: [held], timeout: 2)
        harness.service.receiveCurrentV1Event(
            AgentSessionProfile.data(["threadId": harness.nativeID, "viewVersion": 7, "revision": 8]),
            provider: "codex", client: "phone")
        for view: Int64 in [7, 8] {
            let pending = try perform(
                harness,
                request(
                    "session.items", target: opened.target,
                    params: ["kind": "message", "messageId": "reply"], view: view))
            XCTAssertEqual(pending["code"] as? String, "agent_session_not_open")
        }
        XCTAssertEqual(harness.count("message"), 0)
        harness.heldOpen?(AgentSessionProfile.data(harness.page))
        wait(for: [completed], timeout: 2)
        let old = try perform(
            harness,
            request(
                "session.items", target: opened.target,
                params: ["kind": "message", "messageId": "reply"]))
        XCTAssertEqual(old["code"] as? String, "agent_session_not_open")
        let current = try perform(
            harness,
            request(
                "session.items", target: opened.target,
                params: ["kind": "message", "messageId": "reply"], view: 8))
        XCTAssertEqual(current["ok"] as? Bool, true)
    }
    func testDirtyEventDuringReplacementDoesNotCancelTheNewSessionOrRestoreTheOldReadRoute() throws {
        let harness = try Harness()
        let opened = try open(harness)
        _ = try perform(
            harness,
            request(
                "session.observe", target: opened.target,
                params: ["subscriptionId": "old-view"]))
        let nextID = "00000000-0000-4000-8000-000000000099"
        let next = try harness.directory.registerSession(
            adapter: "codex.currentV1", provider: "codex", native: nextID, cwd: "/synthetic")
        harness.page["threadId"] = nextID
        harness.holdOpen = true
        let held = expectation(description: "replacement open in progress")
        let completed = expectation(description: "replacement answered despite old dirty event")
        let response = Response()
        harness.nativeHeld = { held.fulfill() }
        harness.service.perform(try request("session.open", target: ["sessionRef": next.ref]), client: "phone") {
            data in
            response.data = data
            completed.fulfill()
        }
        wait(for: [held], timeout: 2)
        harness.service.receiveCurrentV1Event(
            AgentSessionProfile.data(["threadId": harness.nativeID, "viewVersion": 7, "revision": 8]),
            provider: "codex", client: "phone")
        let oldRead = try perform(
            harness,
            request(
                "session.items", target: opened.target,
                params: ["kind": "history"]))
        XCTAssertEqual(oldRead["code"] as? String, "agent_session_not_open")
        let cleanup = try result(
            perform(
                harness,
                request(
                    "session.unobserve", target: opened.target,
                    params: ["subscriptionId": "old-view"])))
        XCTAssertEqual(cleanup["nativeObservationReleased"] as? Bool, false)
        XCTAssertEqual(harness.count("close"), 0)
        harness.heldOpen?(AgentSessionProfile.data(harness.page))
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(try response.data.flatMapJSON()["ok"] as? Bool, true)
        harness.holdOpen = false
        let recovered = try result(
            perform(
                harness,
                request(
                    "session.items", target: ["sessionRef": next.ref],
                    params: ["kind": "history"])))
        XCTAssertEqual(recovered["threadId"] as? String, nextID)
        XCTAssertEqual(harness.count("history"), 1)
    }
    func testLateItemReplyCannotReturnAfterCloseOrSessionReplacement() throws {
        for replacement in [false, true] {
            let harness = try Harness()
            let opened = try open(harness)
            harness.holdItems = true
            let held = expectation(description: "item read in progress")
            let completed = expectation(description: "obsolete item read answered")
            let response = Response()
            harness.nativeHeld = { held.fulfill() }
            harness.service.perform(
                try request("session.items", target: opened.target, params: ["kind": "history"]), client: "phone"
            ) { data in
                response.data = data
                completed.fulfill()
            }
            wait(for: [held], timeout: 2)
            if replacement {
                let nextID = "00000000-0000-4000-8000-000000000099"
                let next = try harness.directory.registerSession(
                    adapter: "codex.currentV1", provider: "codex", native: nextID, cwd: "/synthetic")
                harness.page["threadId"] = nextID
                _ = try perform(harness, request("session.open", target: ["sessionRef": next.ref]))
            } else {
                harness.service.close(client: "phone")
            }
            harness.heldItem?(
                AgentSessionProfile.data(["ok": true, "threadId": harness.nativeID, "messages": [["id": "late"]]]))
            wait(for: [completed], timeout: 2)
            let output = try response.data.flatMapJSON()
            XCTAssertEqual(output["code"] as? String, "agent_session_view_closed")
            XCTAssertNil((output["body"] as? [String: Any])?["result"])
        }
    }
    func testDirtySnapshotRejectsAnApprovalDetailsReplyAlreadyInFlight() throws {
        let harness = try Harness()
        harness.page["approvals"] = [["id": "approval", "fingerprint": "approval-fingerprint"]]
        let opened = try open(harness)
        let snapshot = try result(perform(harness, request("session.snapshot", target: opened.target)))
        let page = try XCTUnwrap(snapshot["snapshot"] as? [String: Any])
        let approvalID = try XCTUnwrap((page["approvals"] as? [[String: Any]])?.first?["id"] as? String)
        harness.holdItems = true
        let held = expectation(description: "approval details read in progress")
        let completed = expectation(description: "dirty approval details rejected")
        let response = Response()
        harness.nativeHeld = { held.fulfill() }
        harness.service.perform(
            try request(
                "session.items", target: opened.target,
                params: ["kind": "approvalDetails", "messageId": approvalID]), client: "phone"
        ) { data in
            response.data = data
            completed.fulfill()
        }
        wait(for: [held], timeout: 2)
        harness.service.receiveCurrentV1Event(
            AgentSessionProfile.data(["threadId": harness.nativeID, "viewVersion": 7, "revision": 8]),
            provider: "codex", client: "phone")
        harness.heldItem?(
            AgentSessionProfile.data(["ok": true, "threadId": harness.nativeID, "approval": ["id": "approval"]]))
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(try response.data.flatMapJSON()["code"] as? String, "agent_session_view_closed")
    }
}

extension Data {
    fileprivate func flatMapJSON() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}
