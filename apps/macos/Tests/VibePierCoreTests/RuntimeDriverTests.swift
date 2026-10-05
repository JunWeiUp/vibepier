import Darwin
import XCTest

@testable import VibePierCore

final class RuntimeDriverTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var value: TimeInterval = 1000 }
    private final class JSONReply: @unchecked Sendable { var data = Data() }
    private final class FakeCodex: CodexRuntimeConnection, @unchecked Sendable {
        var runtimeVersion = CodexManagedRuntimeContract.version
        let instanceID = "isolated-server"
        var onNotification: (@Sendable (String, Data) -> Void)?
        var onServerRequest: (@Sendable (Data, String, Data) -> Bool)?
        var replies: [Data] = []
        var methods: [String] = []
        var disconnected = false
        var turnID: String?
        var marker: String?
        var text: String?
        var status = "idle"
        var failSubmit = false
        var loggedIn = true
        var omitMessage = false
        var supportsExecutionModes = false
        var missingModel = false
        var modeNotification = true
        var submitModeNotification = true
        var changeModeBeforeInitial = false
        var selectedMode: [String: Any]?
        var parameters: [String: [String: Any]] = [:]
        func request(_ method: String, params: Data) throws -> Data {
            methods.append(method)
            let parameters = try JSONSerialization.jsonObject(with: params) as! [String: Any]
            self.parameters[method] = parameters
            switch method {
            case "account/read":
                return try json(["requiresOpenaiAuth": true, "account": loggedIn ? ["type": "chatgpt"] : NSNull()])
            case "thread/start": return try json(["cwd": "/tmp/project", "thread": ["id": "native-session"]])
            case "collaborationMode/list":
                return try json(["data": [["mode": "default", "name": "Default"], ["mode": "plan", "name": "Plan"]]])
            case "model/list":
                return try json([
                    "data": [
                        [
                            "model": "native-model", "isDefault": true, "hidden": false,
                            "defaultReasoningEffort": "medium",
                            "supportedReasoningEfforts": [["reasoningEffort": "medium"]],
                        ]
                    ], "nextCursor": NSNull(),
                ])
            case "thread/settings/update":
                selectedMode = parameters["collaborationMode"] as? [String: Any]
                if modeNotification { try emitMode() }
                return try json([:])
            case "turn/start":
                marker = parameters["clientUserMessageId"] as? String
                text = (parameters["input"] as? [[String: Any]])?.first?["text"] as? String
                turnID = "turn-a"
                status = "inProgress"
                if failSubmit { throw RuntimeDriverError.timeout }
                if let collaboration = parameters["collaborationMode"] as? [String: Any] {
                    selectedMode = collaboration
                    if submitModeNotification { try emitMode() }
                }
                return try json(["turn": ["id": "turn-a", "status": "inProgress"]])
            case "turn/interrupt":
                status = "interrupted"
                return try json([:])
            case "thread/read":
                if changeModeBeforeInitial, selectedMode != nil {
                    changeModeBeforeInitial = false
                    try emitMode(mode: "default")
                }
                var turns: [[String: Any]] = []
                if let turnID {
                    let items: [[String: Any]] =
                        omitMessage
                        ? []
                        : [
                            [
                                "type": "userMessage", "id": marker!,
                                "content": [["type": "text", "text": text!]],
                            ]
                        ]
                    turns = [["id": turnID, "status": status, "items": items]]
                }
                let active = status == "inProgress"
                return try json([
                    "thread": [
                        "id": "native-session", "cwd": "/tmp/project",
                        "status": ["type": active ? "active" : "idle"], "turns": turns,
                        "model": missingModel ? NSNull() : "native-model", "reasoningEffort": "medium",
                    ]
                ])
            default: throw RuntimeDriverError.invalidRequest
            }
        }
        func emitMode(mode: String? = nil, threadID: String = "native-session", sandbox: String = "readOnly") throws {
            var collaboration = selectedMode ?? [:]
            if let mode { collaboration["mode"] = mode }
            onNotification?(
                "thread/settings/updated",
                try json([
                    "threadId": threadID,
                    "threadSettings": [
                        "collaborationMode": collaboration, "model": "native-model", "effort": "medium",
                        "cwd": "/tmp/project", "approvalPolicy": "on-request", "sandboxPolicy": ["type": sandbox],
                    ],
                ]))
        }
        func disconnect() { disconnected = true }
        func respond(requestID: Data, result: Data) throws {
            replies.append(result)
            let id = try JSONSerialization.jsonObject(with: requestID, options: .fragmentsAllowed)
            onNotification?("serverRequest/resolved", try json(["threadId": "native-session", "requestId": id]))
        }
        func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vibepier-runtime-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func context(_ id: String, session: RuntimeSessionReference? = nil, device: String = "phone-a")
        -> RuntimeOperationContext
    {
        RuntimeOperationContext(
            trustedDeviceID: device, operationID: id, requestFingerprint: String(repeating: "a", count: 64),
            journalReservationID: "durable-" + id, session: session)
    }
    private func codex(_ fake: FakeCodex, directory: URL) -> CodexManagedRuntimeDriver {
        CodexManagedRuntimeDriver(
            configuration: .init(enabled: true, executablePath: "/synthetic/codex", directoryPath: directory.path),
            ledgerURL: directory.appendingPathComponent("ledger.json"), connectNative: { _ in fake })
    }
    func testDefaultDisabledCannotLaunchOrExecute() throws {
        let driver = CodexManagedRuntimeDriver(
            configuration: .init(executablePath: "/synthetic", directoryPath: try directory().path),
            ledgerURL: try directory().appendingPathComponent("ledger.json"),
            connectNative: { _ in
                XCTFail("must not launch")
                return FakeCodex()
            })
        XCTAssertFalse(driver.describe().enabled)
        XCTAssertFalse(driver.describe().available)
        XCTAssertThrowsError(try driver.connect())
        XCTAssertThrowsError(try driver.execute(.create(cwd: "/tmp/project"), context: context("create")))
    }
    func testExactVersionAndSchemaGateFailsClosed() throws {
        let fake = FakeCodex()
        fake.runtimeVersion = "0.160.0"
        let driver = codex(fake, directory: try directory())
        XCTAssertThrowsError(try driver.connect())
        XCTAssertTrue(fake.disconnected)
        XCTAssertThrowsError(
            try CodexManagedRuntimeContract.validateSchemaDirectory(try directory(), runtimeVersion: "0.159.0"))
    }
    func testManagedAccountRefreshDoesNotStartModelOrCopyCredentials() throws {
        let fake = FakeCodex()
        fake.loggedIn = false
        let driver = codex(fake, directory: try directory())
        try driver.connect()
        XCTAssertFalse(driver.describe().available)
        XCTAssertEqual(driver.describe().reason, "managed_account_login_required")
        fake.loggedIn = true
        try driver.refreshAccountStatus()
        XCTAssertTrue(driver.describe().available)
        XCTAssertEqual(fake.methods, ["account/read", "account/read"])
    }
    func testCodexEvidenceAndDuplicateNeverResubmit() throws {
        let fake = FakeCodex()
        let driver = codex(fake, directory: try directory())
        try driver.connect()
        let create = try driver.execute(.create(cwd: "/tmp/project"), context: context("create"))
        let reference = try XCTUnwrap(create.session)
        let submitted = try driver.execute(.submit(text: "test only"), context: context("send", session: reference))
        XCTAssertEqual(submitted.status, .confirmed)
        XCTAssertEqual(submitted.nativeTurnID, "turn-a")
        XCTAssertEqual(
            try driver.execute(.submit(text: "test only"), context: context("send", session: reference)), submitted)
        XCTAssertEqual(fake.methods.filter { $0 == "turn/start" }.count, 1)
        XCTAssertThrowsError(
            try driver.execute(.submit(text: "different"), context: context("send", session: reference)))
        XCTAssertEqual(try driver.reconcile(context("send", session: reference)), submitted)
    }
    func testNativePlanConfigurationPersistsAndCarriesActualModeWithoutChangingPermissions() throws {
        let fake = FakeCodex()
        fake.supportsExecutionModes = true
        let folder = try directory()
        let driver = codex(fake, directory: folder)
        try driver.connect()
        let reference = try XCTUnwrap(
            try driver.execute(.create(cwd: "/tmp/project"), context: context("create")).session)
        XCTAssertEqual(try driver.executionModes(reference), ["default", "plan"])
        let configured = try driver.execute(
            .configureExecutionMode(mode: "plan"), context: context("config", session: reference))
        XCTAssertEqual(configured.status, .confirmed)
        XCTAssertEqual(configured.executionMode, "plan")
        XCTAssertNotNil(configured.nativeSettingsJSON)
        let request = try XCTUnwrap(fake.parameters["thread/settings/update"])
        XCTAssertEqual(Set(request.keys), ["threadId", "collaborationMode"])
        XCTAssertEqual((request["collaborationMode"] as? [String: Any])?["mode"] as? String, "plan")
        let settings = (request["collaborationMode"] as? [String: Any])?["settings"] as? [String: Any]
        XCTAssertEqual(settings?["model"] as? String, "native-model")
        XCTAssertTrue(settings?["developer_instructions"] is NSNull)
        XCTAssertFalse(fake.methods.contains("turn/start"))
        try fake.emitMode(mode: "default")
        var state = try JSONSerialization.jsonObject(with: driver.snapshot(reference).nativeJSON) as! [String: Any]
        XCTAssertEqual(state["executionMode"] as? String, "default")
        try fake.emitMode(mode: "plan")
        state = try JSONSerialization.jsonObject(with: driver.snapshot(reference).nativeJSON) as! [String: Any]
        XCTAssertEqual(state["executionMode"] as? String, "plan")
        driver.disconnect()
        let restored = codex(fake, directory: folder)
        try restored.connect()
        let current = try XCTUnwrap(restored.discover().first?.reference)
        XCTAssertEqual(
            try restored.execute(.submit(text: "unchanged user input"), context: context("send", session: current))
                .status, .confirmed)
        XCTAssertEqual(
            (fake.parameters["turn/start"]?["collaborationMode"] as? [String: Any])?["mode"] as? String, "plan")
        XCTAssertEqual(fake.text, "unchanged user input")
        XCTAssertNil(fake.parameters["turn/start"]?["sandboxPolicy"])
        XCTAssertNil(fake.parameters["turn/start"]?["approvalPolicy"])
    }
    func testMissingSettingsNotificationStaysUnknownAndReconciliationDoesNotResend() throws {
        let fake = FakeCodex()
        fake.supportsExecutionModes = true
        fake.modeNotification = false
        let driver = codex(fake, directory: try directory())
        try driver.connect()
        let reference = try XCTUnwrap(
            try driver.execute(.create(cwd: "/tmp/project"), context: context("create")).session)
        let operation = context("config", session: reference)
        let pending = try driver.execute(.configureExecutionMode(mode: "plan"), context: operation)
        XCTAssertEqual(pending.status, .unknown)
        XCTAssertNil(pending.nativeSettingsJSON)
        XCTAssertEqual(try driver.execute(.configureExecutionMode(mode: "plan"), context: operation), pending)
        XCTAssertThrowsError(try driver.execute(.configureExecutionMode(mode: "default"), context: operation))
        XCTAssertEqual(
            try driver.execute(.submit(text: "blocked"), context: context("send", session: reference)).status, .unknown)
        XCTAssertFalse(fake.methods.contains("turn/start"))
        try fake.emitMode(mode: "default")
        try fake.emitMode(threadID: "other-thread")
        try fake.emitMode(sandbox: "dangerFullAccess")
        XCTAssertEqual(try driver.reconcile(operation).status, .unknown)
        try fake.emitMode()
        XCTAssertEqual(try driver.reconcile(operation).status, .confirmed)
        XCTAssertEqual(fake.methods.filter { $0 == "thread/settings/update" }.count, 1)
    }
    func testPlanRequiresReviewedSchemaAndReliableNativeModel() throws {
        let fake = FakeCodex()
        let driver = codex(fake, directory: try directory())
        try driver.connect()
        XCTAssertFalse(driver.describe().capabilities.contains("session.executionMode.configure"))
        XCTAssertEqual(driver.creationExecutionModes(), [])
        let reference = try XCTUnwrap(
            try driver.execute(.create(cwd: "/tmp/project"), context: context("create")).session)
        XCTAssertEqual(
            try driver.execute(.configureExecutionMode(mode: "plan"), context: context("config", session: reference))
                .status, .unknown)
        XCTAssertFalse(fake.methods.contains("thread/settings/update"))
        let other = FakeCodex()
        other.supportsExecutionModes = true
        other.missingModel = true
        let reviewed = codex(other, directory: try directory())
        try reviewed.connect()
        let otherRef = try XCTUnwrap(
            try reviewed.execute(.create(cwd: "/tmp/project"), context: context("other-create")).session)
        XCTAssertEqual(try reviewed.executionModes(otherRef), [])
        XCTAssertEqual(
            try reviewed.execute(
                .configureExecutionMode(mode: "plan"), context: context("other-config", session: otherRef)
            ).status, .unknown)
        XCTAssertFalse(other.methods.contains("thread/settings/update"))
        XCTAssertThrowsError(
            try CodexManagedRuntimeContract.validateExecutionModeSchemaDirectory(
                try directory(), runtimeVersion: "0.159.0"))
    }
    func testManagedCreationCatalogAllowsPlanAndNativeCompositeReturnsProof() throws {
        let fake = FakeCodex()
        fake.supportsExecutionModes = true
        let directory = try directory()
        let driver = codex(fake, directory: directory)
        try driver.connect()
        let host = AgentRuntimeHost(
            directory: directory, initialSettings: .init(workspaceRoots: ["/tmp/project"]),
            injectedDrivers: [driver], nativeStartupEnabled: false)
        func call(_ request: [String: Any]) throws -> [String: Any] {
            let completed = expectation(description: "managed host")
            let box = JSONReply()
            host.perform(try fake.json(request), adapter: driver.adapterID, client: "phone-a") {
                box.data = $0
                completed.fulfill()
            }
            wait(for: [completed], timeout: 3)
            return try JSONSerialization.jsonObject(with: box.data) as! [String: Any]
        }
        let draft = UUID().uuidString
        let options = try call(["op": "newOptions", "cwd": "/tmp/project", "draftId": draft])
        XCTAssertEqual((options["executionModes"] as? [[String: String]])?.map { $0["id"] ?? "" }, ["default", "plan"])
        let actions = (options["agentCapabilities"] as? [String: Any])?["actions"] as? [String: [String: Any]]
        XCTAssertEqual(actions?["executionMode"]?["available"] as? Bool, true)
        let created = try call([
            "op": "new", "id": "logical-plan-create", "cwd": "/tmp/project", "draftId": draft,
            "executionMode": "plan", "text": "native plan input",
            "agentOperationFingerprint": String(repeating: "a", count: 64),
            "agentJournalReservationID": "phone-a:logical-plan-create",
        ])
        XCTAssertEqual(created["ok"] as? Bool, true)
        XCTAssertEqual(created["executionModeVerified"] as? Bool, true)
        XCTAssertEqual(created["effectiveExecutionMode"] as? String, "plan")
        XCTAssertNotNil(created["nativeSettingsProof"])
        XCTAssertEqual(
            (fake.parameters["turn/start"]?["collaborationMode"] as? [String: Any])?["mode"] as? String, "plan")
        XCTAssertEqual(fake.text, "native plan input")
    }
    func testInitialPlanStopsIfSharedDesktopChangedModeAndReceiptQueriesNeverResend() throws {
        let fake = FakeCodex()
        fake.supportsExecutionModes = true
        let driver = codex(fake, directory: try directory())
        try driver.connect()
        let reference = try XCTUnwrap(
            try driver.execute(.create(cwd: "/tmp/project"), context: context("create")).session)
        let configured = try driver.execute(
            .configureExecutionMode(mode: "plan"), context: context("configure", session: reference))
        XCTAssertEqual(configured.status, .confirmed)
        try fake.emitMode(mode: "default")
        let initial = context("initial", session: reference)
        let outcome = try driver.execute(.submitConfigured(text: "plan input", executionMode: "plan"), context: initial)
        XCTAssertEqual(outcome.status, .unknown)
        XCTAssertFalse(fake.methods.contains("turn/start"))
        try fake.emitMode(mode: "plan")
        XCTAssertEqual(try driver.reconcile(initial).status, .unknown)
        XCTAssertEqual(
            try driver.execute(.submitConfigured(text: "plan input", executionMode: "plan"), context: initial), outcome)
        XCTAssertFalse(fake.methods.contains("turn/start"))
    }
    func testManagedHostNativeDesktopRaceKeepsCreatedSessionAndNeverConfirmsInitialPlan() throws {
        let fake = FakeCodex()
        fake.supportsExecutionModes = true
        fake.changeModeBeforeInitial = true
        let directory = try directory()
        let driver = codex(fake, directory: directory)
        try driver.connect()
        let host = AgentRuntimeHost(
            directory: directory, initialSettings: .init(workspaceRoots: ["/tmp/project"]),
            injectedDrivers: [driver], nativeStartupEnabled: false)
        func call(_ request: [String: Any]) throws -> [String: Any] {
            let completed = expectation(description: "racing managed host")
            let box = JSONReply()
            host.perform(try fake.json(request), adapter: driver.adapterID, client: "phone-a") {
                box.data = $0
                completed.fulfill()
            }
            wait(for: [completed], timeout: 3)
            return try JSONSerialization.jsonObject(with: box.data) as! [String: Any]
        }
        var request: [String: Any] = [
            "op": "new", "id": "racing-plan-create", "cwd": "/tmp/project",
            "executionMode": "plan", "text": "native plan input",
            "agentOperationFingerprint": String(repeating: "a", count: 64),
            "agentJournalReservationID": "phone-a:racing-plan-create",
        ]
        let created = try call(request)
        XCTAssertEqual(created["unknown"] as? Bool, true)
        XCTAssertEqual(created["threadId"] as? String, "native-session")
        XCTAssertEqual(created["cwd"] as? String, "/tmp/project")
        XCTAssertNotEqual(created["executionModeVerified"] as? Bool, true)
        XCTAssertNil(created["nativeSettingsProof"])
        XCTAssertFalse(fake.methods.contains("turn/start"))
        request["op"] = "newReceiptCheck"
        try fake.emitMode(mode: "plan")
        let recovered = try call(request)
        XCTAssertEqual(recovered["unknown"] as? Bool, true)
        XCTAssertNotEqual(recovered["executionModeVerified"] as? Bool, true)
        XCTAssertNil(recovered["nativeSettingsProof"])
        XCTAssertFalse(fake.methods.contains("turn/start"))
    }
    func testInitialModeNeedsFreshSubmissionSettingsProofAndLateNativeReadOnlyReconciliation() throws {
        let fake = FakeCodex()
        fake.supportsExecutionModes = true
        fake.submitModeNotification = false
        let driver = codex(fake, directory: try directory())
        try driver.connect()
        let reference = try XCTUnwrap(
            try driver.execute(.create(cwd: "/tmp/project"), context: context("create")).session)
        _ = try driver.execute(.configureExecutionMode(mode: "plan"), context: context("configure", session: reference))
        let initial = context("initial", session: reference)
        let outcome = try driver.execute(.submitConfigured(text: "plan input", executionMode: "plan"), context: initial)
        XCTAssertEqual(outcome.status, .unknown)
        XCTAssertEqual(outcome.nativeTurnID, "turn-a")
        XCTAssertNil(outcome.nativeSettingsJSON)
        XCTAssertEqual(try driver.reconcile(initial).status, .unknown)
        try fake.emitMode()
        let recovered = try driver.reconcile(initial)
        XCTAssertEqual(recovered.status, .confirmed)
        XCTAssertEqual(recovered.executionMode, "plan")
        XCTAssertNotNil(recovered.nativeSettingsJSON)
        XCTAssertEqual(fake.methods.filter { $0 == "turn/start" }.count, 1)
        XCTAssertThrowsError(
            try driver.execute(.submitConfigured(text: "plan input", executionMode: "default"), context: initial))
    }
    func testCodexTimeoutAndMissingUserEvidenceRemainUnknownAcrossReload() throws {
        let folder = try directory()
        let fake = FakeCodex()
        let driver = codex(fake, directory: folder)
        try driver.connect()
        let reference = try XCTUnwrap(
            try driver.execute(.create(cwd: "/tmp/project"), context: context("create")).session)
        fake.failSubmit = true
        XCTAssertEqual(
            try driver.execute(.submit(text: "one attempt"), context: context("send", session: reference)).status,
            .unknown)
        driver.disconnect()
        let fresh = codex(fake, directory: folder)
        try fresh.connect()
        XCTAssertEqual(
            try fresh.execute(.submit(text: "one attempt"), context: context("send", session: reference)).status,
            .unknown)
        XCTAssertEqual(fake.methods.filter { $0 == "turn/start" }.count, 1)
        XCTAssertTrue(fake.disconnected)
        let other = FakeCodex()
        other.omitMessage = true
        let otherDriver = codex(other, directory: try directory())
        try otherDriver.connect()
        let otherRef = try XCTUnwrap(
            try otherDriver.execute(.create(cwd: "/tmp/project"), context: context("other-create")).session)
        XCTAssertEqual(
            try otherDriver.execute(
                .submit(text: "no native evidence"), context: context("other-send", session: otherRef)
            ).status, .unknown)
    }
    func testCodexInterruptRequiresExactTurnAndNativeInterruptedStatus() throws {
        let fake = FakeCodex()
        let driver = codex(fake, directory: try directory())
        try driver.connect()
        let reference = try XCTUnwrap(
            try driver.execute(.create(cwd: "/tmp/project"), context: context("create")).session)
        _ = try driver.execute(.submit(text: "test"), context: context("send", session: reference))
        XCTAssertEqual(
            try driver.execute(.interrupt(turnID: "wrong"), context: context("wrong-stop", session: reference)).status,
            .unknown)
        XCTAssertFalse(fake.methods.contains("turn/interrupt"))
        XCTAssertEqual(
            try driver.execute(.interrupt(turnID: "turn-a"), context: context("stop", session: reference)).status,
            .confirmed)
        XCTAssertEqual(fake.methods.filter { $0 == "turn/interrupt" }.count, 1)
    }
    func testEventBudgetMarksResyncAndDoesNotCrossSession() {
        let buffer = RuntimeEventBuffer(maxEvents: 2, maxStreamBytes: 1000, maxTotalBytes: 1000, maxStreams: 2)
        let ref = RuntimeSessionReference(adapterID: "test", instanceID: "a", nativeSessionID: "x", ownershipEpoch: "e")
        buffer.append(ref, method: "start", payload: Data("{}".utf8))
        let old = buffer.replay(ref, after: nil).cursor
        for _ in 0..<3 { buffer.append(ref, method: "delta", payload: Data("{}".utf8)) }
        XCTAssertTrue(buffer.replay(ref, after: old).requiresResync)
        let latest = buffer.replay(ref, after: RuntimeCursor(epoch: old.epoch, sequence: 3))
        XCTAssertFalse(latest.requiresResync)
        XCTAssertEqual(latest.events.count, 1)
        buffer.append(ref, method: "oversized", payload: Data(repeating: 0, count: 300001))
        XCTAssertTrue(buffer.replay(ref, after: latest.cursor).requiresResync)
        let other = RuntimeSessionReference(
            adapterID: "test", instanceID: "b", nativeSessionID: "x", ownershipEpoch: "e")
        XCTAssertTrue(buffer.replay(other, after: nil).requiresResync)
    }
    private func mods(_ folder: URL, writes: Bool = false) throws -> (
        ClaudeModsBrokerDriver, ClaudeModsBrokerDriver.Bootstrap, RuntimeSessionReference
    ) {
        let driver = ClaudeModsBrokerDriver(
            configuration: .init(enabled: true, reviewedRuntimeVersions: ["2.1.287"]),
            ledgerURL: folder.appendingPathComponent("mods.json"))
        driver.setTestEndpoint(port: 45678)
        let bootstrap = try driver.issueBinding(
            sessionID: "session-a", cwd: "/tmp/project", runtimeVersion: "2.1.287",
            contractDigest: String(repeating: "b", count: 64), nativeWritesVerified: writes)
        let reply = driver.handle(
            try http(
                bootstrap, path: "/v1/register",
                body: [
                    "sessionID": "session-a", "instanceID": "instance-a",
                    "cwd": "/tmp/project", "runtimeVersion": "2.1.287", "contractDigest": bootstrap.contractDigest,
                ]))
        XCTAssertEqual(reply.status, 200)
        return (driver, bootstrap, try XCTUnwrap(driver.discover().first?.reference))
    }
    private func http(
        _ bootstrap: ClaudeModsBrokerDriver.Bootstrap, path: String, body: [String: Any],
        origin: String? = nil, host: String = "127.0.0.1:45678", token: String? = nil
    ) throws -> ClaudeModsBrokerDriver.HTTPRequest {
        .init(
            remoteAddress: "127.0.0.1", method: "POST", path: path, host: host, origin: origin,
            authorization: "Bearer " + (token ?? bootstrap.token),
            body: try JSONSerialization.data(withJSONObject: body))
    }
    func testModsVersionTokenHostOriginAndInstanceIsolation() throws {
        let (driver, bootstrap, reference) = try mods(try directory())
        XCTAssertThrowsError(
            try driver.issueBinding(
                sessionID: "old", cwd: "/tmp/project", runtimeVersion: "2.1.283",
                contractDigest: bootstrap.contractDigest))
        let body: [String: Any] = [
            "sessionID": reference.nativeSessionID, "instanceID": reference.instanceID,
            "ownershipEpoch": reference.ownershipEpoch, "idle": true,
        ]
        XCTAssertEqual(
            driver.handle(try http(bootstrap, path: "/v1/poll", body: body, origin: "http://hostile.invalid")).status,
            403)
        XCTAssertEqual(
            driver.handle(try http(bootstrap, path: "/v1/poll", body: body, host: "localhost:45678")).status, 403)
        XCTAssertEqual(driver.handle(try http(bootstrap, path: "/v1/poll", body: body, token: "bad-token")).status, 403)
        var bad = body
        bad["instanceID"] = "other-instance"
        XCTAssertEqual(driver.handle(try http(bootstrap, path: "/v1/poll", body: bad)).status, 409)
        XCTAssertFalse(driver.describe().capabilities.contains("message.submit.start"))
    }
    func testModsCommandIsOneShotAndPluginAckCannotConfirm() throws {
        let (driver, bootstrap, reference) = try mods(try directory(), writes: true)
        let body: [String: Any] = [
            "sessionID": reference.nativeSessionID, "instanceID": reference.instanceID,
            "ownershipEpoch": reference.ownershipEpoch, "idle": true,
        ]
        _ = driver.handle(try http(bootstrap, path: "/v1/poll", body: body))
        let operation = context("send", session: reference)
        XCTAssertEqual(try driver.execute(.submit(text: "synthetic only"), context: operation).status, .unknown)
        let response = driver.handle(try http(bootstrap, path: "/v1/poll", body: body))
        let decoded = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        let command = try XCTUnwrap(decoded["command"] as? [String: Any])
        let second = driver.handle(try http(bootstrap, path: "/v1/poll", body: body))
        XCTAssertTrue((try JSONSerialization.jsonObject(with: second.body) as! [String: Any])["command"] is NSNull)
        var result = body
        result["operationKey"] = command["operationKey"]
        result["fingerprint"] = command["fingerprint"]
        result["nativeTurnID"] = "turn-a"
        result["status"] = "confirmed"
        XCTAssertEqual(driver.handle(try http(bootstrap, path: "/v1/result", body: result)).status, 200)
        XCTAssertEqual(try driver.reconcile(operation).status, .unknown)
        _ = try driver.execute(.submit(text: "synthetic only"), context: operation)
        XCTAssertTrue(
            (try JSONSerialization.jsonObject(
                with: driver.handle(try http(bootstrap, path: "/v1/poll", body: body)).body) as! [String: Any])[
                    "command"] is NSNull)
        XCTAssertThrowsError(
            try driver.confirmNativeEvidence(
                context: operation, nativeTurnID: "turn-a", nativeMessageID: "message-a", evidence: Data("{}".utf8),
                verify: { _, _ in false }))
    }
    func testModsSessionEndInvalidatesTokenAndOwner() throws {
        let (driver, bootstrap, reference) = try mods(try directory())
        let body: [String: Any] = [
            "sessionID": reference.nativeSessionID, "instanceID": reference.instanceID,
            "ownershipEpoch": reference.ownershipEpoch,
        ]
        XCTAssertEqual(driver.handle(try http(bootstrap, path: "/v1/end", body: body)).status, 200)
        XCTAssertEqual(driver.handle(try http(bootstrap, path: "/v1/end", body: body)).status, 403)
        XCTAssertTrue(try driver.discover().isEmpty)
        XCTAssertThrowsError(try driver.snapshot(reference))
    }
    func testHTTPParserRejectsAmbiguousFramingAndPipelining() throws {
        let header =
            "POST /v1/poll HTTP/1.1\r\nHost: 127.0.0.1:45678\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNotNil(try RuntimeLoopbackHTTPServer.parse(Data((header + "{}").utf8)))
        XCTAssertNil(try RuntimeLoopbackHTTPServer.parse(Data(header.utf8)))
        XCTAssertThrowsError(try RuntimeLoopbackHTTPServer.parse(Data((header + "{}{}").utf8)))
        XCTAssertThrowsError(
            try RuntimeLoopbackHTTPServer.parse(
                Data(
                    header.replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: 2\r\nContent-Length: 2")
                        .utf8)))
        XCTAssertThrowsError(
            try RuntimeLoopbackHTTPServer.parse(
                Data(
                    header.replacingOccurrences(
                        of: "Content-Length: 2", with: "Transfer-Encoding: chunked\r\nContent-Length: 2"
                    ).utf8)))
    }

    func testTemporaryLoopbackListenerRejectsUnauthenticatedHTTP() throws {
        let driver = ClaudeModsBrokerDriver(
            configuration: .init(enabled: true, reviewedRuntimeVersions: ["2.1.287"]),
            ledgerURL: try directory().appendingPathComponent("mods.json"))
        try driver.start()
        defer { driver.disconnect() }
        let bootstrap = try driver.issueBinding(
            sessionID: "session-a", cwd: "/tmp/project", runtimeVersion: "2.1.287",
            contractDigest: String(repeating: "b", count: 64))
        let endpoint = try XCTUnwrap(URL(string: bootstrap.endpoint))
        let port = try XCTUnwrap(endpoint.port)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var deadline = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let request = Data(
            "POST /v1/poll HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
                .utf8)
        XCTAssertEqual(request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, request.count)
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        XCTAssertGreaterThan(count, 0)
        XCTAssertTrue(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self).hasPrefix("HTTP/1.1 403"))
    }

    func testLateNativeEvidenceIsReconciledWithoutMutation() throws {
        let fake = FakeCodex()
        fake.omitMessage = true
        let driver = codex(fake, directory: try directory())
        try driver.connect()
        let reference = try XCTUnwrap(
            try driver.execute(.create(cwd: "/tmp/project"), context: context("create")).session)
        let operation = context("late", session: reference)
        XCTAssertEqual(try driver.execute(.submit(text: "late synthetic"), context: operation).status, .unknown)
        fake.omitMessage = false
        XCTAssertEqual(try driver.reconcile(operation).status, .confirmed)
        XCTAssertEqual(fake.methods.filter { $0 == "turn/start" }.count, 1)
    }

    func testModsStrictBooleanAndTokenExpiry() throws {
        let (driver, bootstrap, reference) = try mods(try directory())
        let body: [String: Any] = [
            "sessionID": reference.nativeSessionID, "instanceID": reference.instanceID,
            "ownershipEpoch": reference.ownershipEpoch, "idle": 1,
        ]
        XCTAssertEqual(driver.handle(try http(bootstrap, path: "/v1/poll", body: body)).status, 400)
        let clock = Clock()
        let expiring = ClaudeModsBrokerDriver(
            configuration: .init(enabled: true, reviewedRuntimeVersions: ["2.1.287"]),
            ledgerURL: try directory().appendingPathComponent("expiry.json"), now: { clock.value })
        expiring.setTestEndpoint(port: 45678)
        let ticket = try expiring.issueBinding(
            sessionID: "session-a", cwd: "/tmp/project", runtimeVersion: "2.1.287",
            contractDigest: String(repeating: "b", count: 64))
        clock.value = 1601
        XCTAssertEqual(
            expiring.handle(
                try http(
                    ticket, path: "/v1/register",
                    body: [
                        "sessionID": "session-a",
                        "instanceID": "instance-a", "cwd": "/tmp/project", "runtimeVersion": "2.1.287",
                        "contractDigest": ticket.contractDigest,
                    ])
            ).status, 403)
    }

    func testNativeApprovalsBindFingerprintTurnAndScopeAndReplyOnce() throws {
        let fake = FakeCodex()
        let driver = codex(fake, directory: try directory())
        try driver.connect()
        let reference = try XCTUnwrap(
            try driver.execute(.create(cwd: "/tmp/project"), context: context("create")).session)
        _ = try driver.execute(.submit(text: "fake turn"), context: context("send", session: reference))
        let nativeID = Data("42".utf8)
        let native = try fake.json([
            "threadId": "native-session", "turnId": "turn-a", "itemId": "tool-a", "startedAtMs": 1,
            "command": "synthetic only",
        ])
        XCTAssertTrue(fake.onServerRequest?(nativeID, "item/commandExecution/requestApproval", native) == true)
        let approval = try XCTUnwrap(driver.pendingRequests(reference).first)
        XCTAssertEqual(approval.allowedDecisions, ["accept", "decline", "cancel"])
        XCTAssertEqual(
            try driver.execute(
                .resolveApproval(requestID: approval.id, fingerprint: "wrong", decision: "accept"),
                context: context("wrong-fingerprint", session: reference)
            ).status, .unknown)
        XCTAssertTrue(fake.replies.isEmpty)
        _ = try driver.execute(
            .resolveApproval(requestID: approval.id, fingerprint: approval.fingerprint, decision: "acceptForSession"),
            context: context("wrong-scope", session: reference))
        XCTAssertTrue(fake.replies.isEmpty)
        let operation = context("approve", session: reference)
        let command = RuntimeCommand.resolveApproval(
            requestID: approval.id, fingerprint: approval.fingerprint, decision: "accept")
        XCTAssertEqual(try driver.execute(command, context: operation).status, .unknown)
        XCTAssertEqual(fake.replies.count, 1)
        XCTAssertTrue(driver.pendingRequests(reference).isEmpty)
        _ = try driver.execute(command, context: operation)
        _ = try driver.execute(command, context: context("another-phone", session: reference, device: "phone-b"))
        XCTAssertEqual(fake.replies.count, 1)
        XCTAssertEqual(try driver.reconcile(operation).reason, "native_approval_resolution_observed")
    }

    func testNativeQuestionsValidateActualIDsOptionsAndSecretBoundary() throws {
        let fake = FakeCodex()
        let driver = codex(fake, directory: try directory())
        try driver.connect()
        let reference = try XCTUnwrap(
            try driver.execute(.create(cwd: "/tmp/project"), context: context("create")).session)
        _ = try driver.execute(.submit(text: "fake"), context: context("send", session: reference))
        var question: [String: Any] = [
            "id": "choice", "header": "Choice", "question": "Synthetic?", "isOther": false,
            "options": [["label": "yes", "description": "test"]],
        ]
        let body: [String: Any] = [
            "threadId": "native-session", "turnId": "turn-a", "itemId": "question-a", "isBlocking": true,
            "questions": [question],
        ]
        XCTAssertTrue(
            fake.onServerRequest?(Data("\"question-request\"".utf8), "item/tool/requestUserInput", try fake.json(body))
                == true)
        let request = try XCTUnwrap(driver.pendingRequests(reference).first)
        _ = try driver.execute(
            .answerQuestion(requestID: request.id, fingerprint: request.fingerprint, answers: ["choice": ["invalid"]]),
            context: context("wrong-answer", session: reference))
        XCTAssertTrue(fake.replies.isEmpty)
        _ = try driver.execute(
            .answerQuestion(requestID: request.id, fingerprint: request.fingerprint, answers: ["choice": ["yes"]]),
            context: context("answer", session: reference))
        XCTAssertEqual(fake.replies.count, 1)
        question["isSecret"] = true
        var secret = body
        secret["questions"] = [question]
        XCTAssertFalse(
            fake.onServerRequest?(Data("43".utf8), "item/tool/requestUserInput", try fake.json(secret)) == true)
    }
}
