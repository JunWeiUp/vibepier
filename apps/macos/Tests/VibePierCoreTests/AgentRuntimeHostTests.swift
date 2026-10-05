import XCTest

@testable import VibePierCore

final class AgentRuntimeHostTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var data = Data()
        var failure: String?
    }
    private final class Driver: AgentRuntimeDriver, @unchecked Sendable {
        let adapterID = "codex.managedAppServer"
        let reference = RuntimeSessionReference(
            adapterID: "codex.managedAppServer", instanceID: "test-instance", nativeSessionID: "test-session",
            ownershipEpoch: "test-owner")
        private let lock = NSLock()
        private var records: [String: RuntimeReceipt] = [:]
        private var active = false
        var executions = 0
        var failInitial = false
        var failConfigure = false
        var changedModeBeforeInitial = false
        var executionMode = "default"
        var commands: [RuntimeCommand] = []
        func describe() -> RuntimeDriverDescriptor {
            RuntimeDriverDescriptor(
                adapterID: adapterID, backendKind: "managedRuntime", enabled: true, available: true,
                reason: "",
                capabilities: [
                    "session.create", "message.submit.start", "turn.interrupt", "session.observe",
                    "session.executionMode.configure",
                ])
        }
        func discover() throws -> [RuntimeSession] {
            lock.lock()
            defer { lock.unlock() }
            return [
                RuntimeSession(
                    reference: reference, cwd: "/tmp/project", runtimeVersion: "test",
                    activeTurnID: active ? "turn-a" : nil, writable: true)
            ]
        }
        func snapshot(_ session: RuntimeSessionReference) throws -> RuntimeSnapshot {
            let current = try discover()[0]
            let turns: [[String: Any]] = (1...3).map { index in
                [
                    "id": "turn-\(index)", "status": "completed",
                    "items": [
                        [
                            "type": "userMessage", "id": "user-\(index)",
                            "content": [["type": "text", "text": "prompt \(index)"]],
                        ],
                        ["type": "agentMessage", "id": "reply-\(index)", "text": "reply body \(index)"],
                    ],
                ]
            }
            return RuntimeSnapshot(
                session: current, cursor: .init(epoch: "test", sequence: 0),
                nativeJSON: AgentSessionProfile.data([
                    "thread": ["id": reference.nativeSessionID, "turns": turns],
                    "executionModes": ["default", "plan"], "executionMode": executionMode,
                    "executionModeVerified": true,
                ]),
                partial: true)
        }
        func execute(_ command: RuntimeCommand, context: RuntimeOperationContext) throws -> RuntimeReceipt {
            lock.lock()
            defer { lock.unlock() }
            executions += 1
            commands.append(command)
            if case .submit = command, failInitial { throw RuntimeDriverError.timeout }
            if case .submitConfigured = command, failInitial { throw RuntimeDriverError.timeout }
            if case .submitConfigured(_, let mode) = command {
                if changedModeBeforeInitial { executionMode = "default" }
                let status: RuntimeReceipt.Status = executionMode == mode ? .confirmed : .unknown
                let result = RuntimeReceipt(
                    operationID: context.operationID, status: status, session: reference,
                    nativeTurnID: status == .confirmed ? "turn-a" : nil,
                    nativeMessageID: status == .confirmed ? "message-a" : nil, executionMode: mode,
                    nativeSettingsJSON: status == .confirmed
                        ? AgentSessionProfile.data([
                            "threadId": reference.nativeSessionID,
                            "threadSettings": [
                                "collaborationMode": ["mode": mode, "settings": ["model": "native-model"]]
                            ],
                        ]) : nil)
                records[context.operationID] = result
                return result
            }
            if case .configureExecutionMode(let mode) = command {
                let status: RuntimeReceipt.Status = failConfigure ? .unknown : .confirmed
                if !failConfigure { executionMode = mode }
                let proof =
                    failConfigure
                    ? nil
                    : AgentSessionProfile.data([
                        "threadId": reference.nativeSessionID,
                        "threadSettings": ["collaborationMode": ["mode": mode, "settings": ["model": "native-model"]]],
                    ])
                let receipt = RuntimeReceipt(
                    operationID: context.operationID, status: status, session: reference,
                    executionMode: mode, nativeSettingsJSON: proof)
                records[context.operationID] = receipt
                return receipt
            }
            let result = RuntimeReceipt(
                operationID: context.operationID, status: .confirmed, session: reference,
                nativeTurnID: "turn-a", nativeMessageID: "message-a")
            records[context.operationID] = result
            return result
        }
        func reconcile(_ context: RuntimeOperationContext) throws -> RuntimeReceipt {
            lock.lock()
            defer { lock.unlock() }
            return records[context.operationID]
                ?? RuntimeReceipt(operationID: context.operationID, status: .unknown, session: context.session)
        }
        func replay(_ session: RuntimeSessionReference, after: RuntimeCursor?) -> RuntimeReplay {
            RuntimeReplay(cursor: .init(epoch: "test", sequence: 0), events: [], requiresResync: false)
        }
        func disconnect() {}
        func setActive() {
            lock.lock()
            active = true
            lock.unlock()
        }
        func recordInitial(_ operation: String) {
            lock.lock()
            defer { lock.unlock() }
            records[operation + ".initial"] = RuntimeReceipt(
                operationID: operation + ".initial", status: .confirmed,
                session: reference, nativeTurnID: "turn-a", nativeMessageID: "message-a")
        }
    }
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vibepier-host-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func host(_ driver: Driver) throws -> AgentRuntimeHost {
        AgentRuntimeHost(
            directory: try folder(), initialSettings: .init(workspaceRoots: ["/tmp/project"]),
            injectedDrivers: [driver], nativeStartupEnabled: false)
    }
    private func invoke(_ host: AgentRuntimeHost, _ value: [String: Any], local: Bool = false) -> [String: Any] {
        let done = expectation(description: "host callback")
        let box = Box()
        let callback: @Sendable (Data) -> Void = {
            box.data = $0
            done.fulfill()
        }
        if local {
            host.localCommand(value, completion: callback)
        } else {
            host.perform(
                AgentSessionProfile.data(value), adapter: "codex.managedAppServer", client: "phone-a",
                completion: callback)
        }
        wait(for: [done], timeout: 3)
        return (try? JSONSerialization.jsonObject(with: box.data) as? [String: Any]) ?? [:]
    }
    private func mutation(_ op: String, id: String) -> [String: Any] {
        [
            "id": id, "op": op, "threadId": "test-session",
            "agentOperationFingerprint": String(repeating: "a", count: 64),
            "agentJournalReservationID": "phone-a:" + id,
        ]
    }
    func testCorruptSettingsPreservedAndWriteRejected() throws {
        let directory = try folder()
        let file = directory.appendingPathComponent("settings.json")
        let corrupt = Data("invalid configuration".utf8)
        try RuntimePrivateStorage.write(corrupt, to: file)
        let host = AgentRuntimeHost(directory: directory, nativeStartupEnabled: false)
        let status = invoke(host, ["action": "status"], local: true)
        XCTAssertEqual((status["errors"] as? [String: String])?["configuration"], "configuration_unavailable")
        let disabled = invoke(host, ["action": "disable", "adapter": "codex"], local: true)
        XCTAssertEqual(disabled["ok"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testCompoundCreationPreservesPartialIdentityAndReconcilesChildOnly() throws {
        let driver = Driver()
        driver.failInitial = true
        let host = try host(driver)
        var request = mutation("new", id: "logical-new")
        request["cwd"] = "/tmp/project"
        request["text"] = "initial"
        let result = invoke(host, request)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["unknown"] as? Bool, true)
        XCTAssertEqual(result["threadId"] as? String, "test-session")
        XCTAssertEqual(result["cwd"] as? String, "/tmp/project")
        request["op"] = "newReceiptCheck"
        XCTAssertEqual(invoke(host, request)["unknown"] as? Bool, true)
        driver.recordInitial("logical-new")
        XCTAssertEqual(invoke(host, request)["accepted"] as? Bool, true)
        XCTAssertEqual(driver.executions, 2)
    }
    func testNativeSettingsProofProjectsSeparateExecutionModeAndFutureComposer() throws {
        let driver = Driver()
        let host = try host(driver)
        var request = mutation("settings", id: "configure")
        request["executionMode"] = "plan"
        request["mode"] = "default"
        let configured = invoke(host, request)
        XCTAssertEqual(configured["ok"] as? Bool, true)
        XCTAssertEqual(configured["executionModeVerified"] as? Bool, true)
        XCTAssertNotNil(configured["nativeSettingsProof"])
        let composer = try XCTUnwrap(configured["composer"] as? [String: Any])
        XCTAssertEqual(composer["executionMode"] as? String, "plan")
        XCTAssertEqual(composer["mode"] as? String, "default")
        request["op"] = "settingsReceiptCheck"
        let recovered = invoke(host, request)
        XCTAssertEqual(recovered["executionModeVerified"] as? Bool, true)
        XCTAssertEqual(driver.executions, 1)
        let page = invoke(host, ["op": "open", "threadId": "test-session", "viewVersion": 7])
        XCTAssertEqual((page["composer"] as? [String: Any])?["executionMode"] as? String, "plan")
        XCTAssertEqual((page["executionModes"] as? [[String: String]])?.map { $0["id"] ?? "" }, ["default", "plan"])
    }
    func testPlanCreationWaitsForNativeConfigBeforeInitialAndKeepsPartialIdentity() throws {
        let driver = Driver()
        let host = try host(driver)
        driver.failConfigure = true
        var request = mutation("new", id: "plan-create")
        request["cwd"] = "/tmp/project"
        request["executionMode"] = "plan"
        request["text"] = "initial prompt"
        let result = invoke(host, request)
        XCTAssertEqual(result["unknown"] as? Bool, true)
        XCTAssertEqual(result["executionModeVerified"] as? Bool, false)
        XCTAssertEqual(result["threadId"] as? String, "test-session")
        XCTAssertEqual(result["cwd"] as? String, "/tmp/project")
        XCTAssertEqual(driver.commands.count, 2)
        XCTAssertEqual(driver.commands[1], .configureExecutionMode(mode: "plan"))
        request["op"] = "newReceiptCheck"
        XCTAssertEqual(invoke(host, request)["unknown"] as? Bool, true)
        XCTAssertEqual(driver.commands.count, 2)
    }
    func testPlanCreateDoesNotReuseSetterProofForChangedInitialModeOrLateReceipt() throws {
        let driver = Driver()
        driver.changedModeBeforeInitial = true
        let host = try host(driver)
        var request = mutation("new", id: "racing-plan-create")
        request["cwd"] = "/tmp/project"
        request["executionMode"] = "plan"
        request["text"] = "initial prompt"
        let result = invoke(host, request)
        XCTAssertEqual(result["unknown"] as? Bool, true)
        XCTAssertEqual(result["executionModeVerified"] as? Bool, false)
        XCTAssertNil(result["nativeSettingsProof"])
        XCTAssertEqual(result["threadId"] as? String, "test-session")
        XCTAssertEqual(driver.commands.last, .submitConfigured(text: "initial prompt", executionMode: "plan"))
        request["op"] = "newReceiptCheck"
        let recovered = invoke(host, request)
        XCTAssertEqual(recovered["unknown"] as? Bool, true)
        XCTAssertEqual(recovered["executionModeVerified"] as? Bool, false)
        XCTAssertNil(recovered["nativeSettingsProof"])
        XCTAssertEqual(driver.commands.count, 3)
    }
    func testHistoryAndFullMessageStayReadOnlyAndDoNotHideOlderTurns() throws {
        let driver = Driver()
        let host = try host(driver)
        let opened = invoke(host, ["op": "open", "threadId": "test-session", "viewVersion": 1])
        XCTAssertEqual(opened["hasOlder"] as? Bool, true)
        let history = invoke(host, ["op": "history", "threadId": "test-session", "before": "user-3"])
        XCTAssertFalse((history["messages"] as? [[String: Any]] ?? []).isEmpty)
        let message = invoke(host, ["op": "message", "threadId": "test-session", "messageId": "reply-3"])
        XCTAssertEqual(message["text"] as? String, "reply body 3")
        XCTAssertEqual(driver.executions, 0)
    }
    func testFreshGateRejectsLiveTurnChangeAndOtherPhoneAndOwnerEpochIsStable() throws {
        let driver = Driver()
        let host = try host(driver)
        let opened = invoke(host, ["op": "open", "threadId": "test-session", "viewVersion": 1])
        let fresh = invoke(host, ["op": "sync", "threadId": "test-session"])
        XCTAssertEqual(opened["nativeOwnerEpoch"] as? String, fresh["nativeOwnerEpoch"] as? String)
        var request = mutation("send", id: "send")
        request["viewVersion"] = 1
        request["agentCapabilityVersion"] = 1
        request["agentAdapterId"] = driver.adapterID
        request["nativeOwnerEpoch"] = opened["nativeOwnerEpoch"]
        request["agentCapabilityRevision"] = (opened["agentCapabilities"] as? [String: Any])?["revision"]
        func gate(_ client: String) -> String? {
            let done = expectation(description: "gate")
            let box = Box()
            host.freshMutationFailure(AgentSessionProfile.data(request), client: client) {
                box.failure = $0
                done.fulfill()
            }
            wait(for: [done], timeout: 3)
            return box.failure
        }
        XCTAssertNil(gate("phone-a"))
        XCTAssertNotNil(gate("phone-b"))
        driver.setActive()
        XCTAssertNotNil(gate("phone-a"))
        XCTAssertEqual(driver.executions, 0)
        host.stop(client: "phone-a")
    }
    func testDefaultsAndStatusNeverActivateSavedNativeConfiguration() throws {
        let directory = try folder()
        let configuration = CodexManagedRuntimeConfiguration(
            enabled: true, executablePath: "/does/not/exist",
            directoryPath: directory.appendingPathComponent("codex").path)
        let host = AgentRuntimeHost(
            directory: directory, initialSettings: .init(codex: configuration), nativeStartupEnabled: false)
        host.restoreExplicitConfiguration()
        let status = invoke(host, ["action": "status"], local: true)
        XCTAssertEqual(status["codexHomePath"] as? String, configuration.codexHomePath)
        XCTAssertEqual((status["drivers"] as? [Any])?.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.directoryPath))
    }
    func testCloseRequiresExactNativeViewAndNeverInterrupts() throws {
        let driver = Driver()
        let host = try host(driver)
        _ = invoke(host, ["op": "open", "threadId": "test-session", "viewVersion": 2])
        XCTAssertEqual(
            invoke(host, ["op": "close", "threadId": "test-session", "viewVersion": 1])["released"] as? Bool, false)
        XCTAssertEqual(
            invoke(host, ["op": "close", "threadId": "test-session", "viewVersion": 2])["released"] as? Bool, true)
        XCTAssertEqual(driver.executions, 0)
    }
}
