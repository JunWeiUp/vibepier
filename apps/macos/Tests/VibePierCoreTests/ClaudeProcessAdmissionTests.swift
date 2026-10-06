import Foundation
import XCTest

@testable import VibePierCore

final class ClaudeProcessAdmissionTests: XCTestCase {
    private func makeBridge(
        root: URL, processExecutable: URL, processBudget: SessionWorkBudget? = nil, settingsFile: URL? = nil,
        attachmentRoot: URL? = nil
    ) -> ClaudeBridge {
        ClaudeBridge(
            root: root, processExecutable: processExecutable, processBudget: processBudget,
            settingsFile: settingsFile, attachmentRoot: attachmentRoot,
            modelCatalog: { _, _ in
                [
                    ClaudeModelCatalog.defaultEntry,
                    ["id": "claude-sonnet-5", "name": "Synthetic Sonnet", "efforts": ["default", "high"]],
                    ["id": "haiku", "name": "Synthetic Haiku", "efforts": ["default"]],
                ]
            })
    }

    private final class Reply: @unchecked Sendable {
        let lock = NSLock()
        var bytes = Data()
        func save(_ data: Data) { lock.withLock { bytes = data } }
        func value() throws -> [String: Any] {
            try lock.withLock { try JSONSerialization.jsonObject(with: bytes) as! [String: Any] }
        }
    }
    private func request(_ bridge: ClaudeBridge, project: URL, client: String, options: [String: Any] = [:]) throws
        -> [String: Any]
    {
        let done = expectation(description: "synthetic process admission reply")
        let value = Reply()
        let data = try JSONSerialization.data(
            withJSONObject: [
                "op": "new", "id": UUID().uuidString,
                "cwd": project.path, "text": "synthetic process fixture",
            ].merging(options) { _, new in new })
        bridge.perform(data, client: client) {
            value.save($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try value.value()
    }
    private func fixture() throws -> (root: URL, project: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claude-admission-" + UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(realpath(project.path, nil))
        defer { free(canonical) }
        let physical = URL(fileURLWithPath: String(cString: canonical))
        let seed: [String: Any] = [
            "type": "user", "uuid": "seed", "cwd": physical.path,
            "message": ["content": "Synthetic known project"],
        ]
        var bytes = try JSONSerialization.data(withJSONObject: seed)
        bytes.append(10)
        try bytes.write(to: project.appendingPathComponent(UUID().uuidString + ".jsonl"))
        let executable = root.appendingPathComponent("synthetic-provider")
        // This controlled child only touches the test directory. Nonzero termination prevents desktop adoption.
        let script = """
            #!/usr/bin/env python3
            import json, pathlib, sys, time
            project = pathlib.Path.cwd()
            session = sys.argv[3]
            (project / (session+'.args.json')).write_text(json.dumps(sys.argv[1:]))
            text = sys.stdin.read()
            if '--input-format' in sys.argv:
                envelope = json.loads(text)
                assert envelope['type'] == 'user' and envelope['session_id'] == session
                assert envelope['message']['role'] == 'user'
                text = envelope['message']['content']
            row = {'type':'user', 'uuid':session+'-human', 'sessionId':session,
                   'cwd':str(project), 'message':{'content':text}}
            (project / (session+'.jsonl')).write_text(json.dumps(row)+'\\n')
            until = time.monotonic()+15
            while not (project/'release').exists() and time.monotonic()<until:
                time.sleep(0.02)
            print(json.dumps({'type':'result','is_error':True,'result':'synthetic completion only'}), flush=True)
            sys.exit(2)
            """
        try script.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, physical, executable)
    }

    func testNewDraftImagesAndFilesReachTheConfiguredFirstChildAndNativeReceipt() throws {
        let fixture = try fixture()
        let budget = SessionWorkBudget(limits: .init(perDevice: 1, total: 1, bytesPerDevice: 8192, bytesTotal: 8192))
        let bridge = makeBridge(
            root: fixture.root, processExecutable: fixture.executable, processBudget: budget,
            settingsFile: fixture.root.appendingPathComponent("settings.json"),
            attachmentRoot: fixture.root.appendingPathComponent("attachments"))
        defer {
            try? Data().write(to: fixture.project.appendingPathComponent("release"))
            bridge.stopAll()
            let end = ProcessInfo.processInfo.systemUptime + 5
            var exited = false
            repeat {
                if let tokens = capacity(budget, count: 1) {
                    for token in tokens { budget.finish(token) }
                    exited = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            } while ProcessInfo.processInfo.systemUptime < end
            XCTAssertTrue(exited)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let draft = UUID().uuidString
        func upload(_ bytes: Data, name: String, mime: String) throws -> String {
            let id = UUID().uuidString
            let scope = try SessionCreationDraft(
                ["draftId": draft, "cwd": fixture.project.path], project: fixture.project.path, provider: "claude")
            let start: [String: Any] = [
                "op": "newAttachmentStart", "draftId": draft, "attachmentId": id,
                "name": name, "mime": mime, "size": bytes.count,
            ]
            XCTAssertEqual(
                try request(bridge, project: fixture.project, client: "phone", options: start)["ok"] as? Bool, true)
            // Populate synthetic bytes internally; the retired text-chunk RPC is never used by fixtures.
            let storage = try CodexAttachments(root: fixture.root.appendingPathComponent("attachments"))
            _ = try storage.appendImportedData(bytes, id: id, offset: 0, device: "phone", thread: scope.scope)
            let complete: [String: Any] = [
                "op": "newAttachmentComplete", "draftId": draft, "attachmentId": id,
                "sha256": CodexConversation.dataHash(bytes),
            ]
            XCTAssertEqual(
                try request(bridge, project: fixture.project, client: "phone", options: complete)["ok"] as? Bool, true)
            return id
        }
        let png = try upload(ClaudePromptTests.png(), name: "diagram.png", mime: "image/png")
        let notes = try upload(Data("Selected document".utf8), name: "notes.txt", mime: "text/plain")
        var fields: [String: Any] = [
            "draftId": draft, "attachments": [png, notes], "text": "Inspect these files", "model": "claude-sonnet-5",
            "effort": "high", "mode": "plan",
        ]
        XCTAssertEqual(
            try request(bridge, project: fixture.project, client: "other-phone", options: fields)["ok"] as? Bool, false)
        let result = try request(bridge, project: fixture.project, client: "phone", options: fields)
        XCTAssertEqual(result["ok"] as? Bool, true)
        let session = try XCTUnwrap(result["threadId"] as? String)
        XCTAssertEqual(result["nativeMessageId"] as? String, session + "-human")
        let arguments = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: fixture.project.appendingPathComponent(session + ".args.json")))
        XCTAssertTrue(arguments.contains("--input-format"))
        XCTAssertTrue(arguments.contains("stream-json"))
        let row = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.project.appendingPathComponent(session + ".jsonl"))) as? [String: Any])
        let content = try XCTUnwrap((row["message"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image"])
        XCTAssertTrue((content[0]["text"] as? String ?? "").contains("notes.txt"))
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertNotNil(Data(base64Encoded: source["data"] as? String ?? ""))
        fields["draftId"] = UUID().uuidString
        XCTAssertEqual(
            try request(bridge, project: fixture.project, client: "phone", options: fields)["ok"] as? Bool, false)
    }

    func testCreationConfigurationIsAppliedBeforeFirstInputAndPersistedForContinuation() throws {
        let fixture = try fixture()
        let settings = fixture.root.appendingPathComponent("settings.json")
        let budget = SessionWorkBudget(limits: .init(perDevice: 1, total: 1, bytesPerDevice: 4096, bytesTotal: 4096))
        let bridge = makeBridge(
            root: fixture.root, processExecutable: fixture.executable, processBudget: budget, settingsFile: settings)
        defer {
            try? Data().write(to: fixture.project.appendingPathComponent("release"))
            bridge.stopAll()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var exited = false
            repeat {
                if let tokens = capacity(budget, count: 1) {
                    for token in tokens { budget.finish(token) }
                    exited = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            } while ProcessInfo.processInfo.systemUptime < deadline
            XCTAssertTrue(exited)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let result = try request(
            bridge, project: fixture.project, client: "phone",
            options: [
                "model": "claude-sonnet-5", "effort": "high", "mode": "plan",
            ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        let session = try XCTUnwrap(result["threadId"] as? String)
        let arguments = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: fixture.project.appendingPathComponent(session + ".args.json")))
        func argument(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        XCTAssertEqual(argument("--model"), "claude-sonnet-5")
        XCTAssertEqual(argument("--effort"), "high")
        XCTAssertEqual(argument("--permission-mode"), "plan")
        let saved = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: settings))
        XCTAssertEqual(
            saved[session], ["model": "claude-sonnet-5", "effort": "high", "mode": "plan", "executionMode": "plan"])
    }

    func testInvalidCreationConfigurationCannotLaunchOrWriteSettings() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = fixture.root.appendingPathComponent("settings.json")
        let bridge = makeBridge(root: fixture.root, processExecutable: fixture.executable, settingsFile: settings)
        defer { bridge.stopAll() }
        for options: [String: Any] in [
            ["model": "unrecognized-model"], ["model": "haiku", "effort": "high"],
            ["mode": "bypassPermissions"], ["mode": "bypassPermissions", "confirmFullAccess": 1],
            ["model": 3], ["mode": "unknown"],
        ] {
            XCTAssertEqual(
                try request(bridge, project: fixture.project, client: "phone", options: options)["ok"] as? Bool, false)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.project.path).contains {
                $0.hasSuffix(".args.json")
            })
        let confirmed = try ClaudeSessionConfiguration.resolve(
            ["mode": "bypassPermissions", "confirmFullAccess": true], current: [:])
        XCTAssertEqual(confirmed["mode"], "bypassPermissions")
    }
    private func capacity(_ budget: SessionWorkBudget, count: Int) -> [UUID]? {
        var held: [UUID] = []
        for index in 0..<count {
            guard case .accepted(let token) = budget.begin(device: "probe-\(index)", id: UUID().uuidString, bytes: 0)
            else {
                for token in held { budget.finish(token) }
                return nil
            }
            held.append(token)
        }
        return held
    }
    func testPerPhoneAndGlobalLimitsSurviveReceiptsDisconnectsAndDifferentBridges() throws {
        let fixture = try fixture()
        let budget = SessionWorkBudget(limits: .init(perDevice: 2, total: 3, bytesPerDevice: 4096, bytesTotal: 8192))
        let first = makeBridge(root: fixture.root, processExecutable: fixture.executable, processBudget: budget)
        let second = makeBridge(root: fixture.root, processExecutable: fixture.executable, processBudget: budget)
        defer {
            try? Data().write(to: fixture.project.appendingPathComponent("release"))
            first.stopAll()
            second.stopAll()
            let end = ProcessInfo.processInfo.systemUptime + 5
            var released = false
            repeat {
                if let tokens = capacity(budget, count: 3) {
                    for token in tokens { budget.finish(token) }
                    released = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            } while ProcessInfo.processInfo.systemUptime < end
            XCTAssertTrue(released, "Only actual child termination can restore all process slots")
            try? FileManager.default.removeItem(at: fixture.root)
        }
        XCTAssertEqual(try request(first, project: fixture.project, client: "phone-a")["ok"] as? Bool, true)
        XCTAssertEqual(try request(second, project: fixture.project, client: "phone-a")["ok"] as? Bool, true)
        XCTAssertEqual(try request(first, project: fixture.project, client: "phone-a")["ok"] as? Bool, false)
        XCTAssertEqual(try request(second, project: fixture.project, client: "phone-b")["ok"] as? Bool, true)
        XCTAssertEqual(try request(first, project: fixture.project, client: "phone-c")["ok"] as? Bool, false)
        first.stop("phone-a")
        second.stopAll()
        XCTAssertEqual(try request(first, project: fixture.project, client: "phone-c")["ok"] as? Bool, false)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.project, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        XCTAssertEqual(
            files.count, 4, "Three admitted children plus one seed; rejected requests must never start a child")
    }
    func testFailedProcessStartReleasesAdmissionBeforeReturningFailure() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let budget = SessionWorkBudget(limits: .init(perDevice: 1, total: 1, bytesPerDevice: 4096, bytesTotal: 4096))
        let bridge = makeBridge(
            root: fixture.root, processExecutable: fixture.root.appendingPathComponent("missing"), processBudget: budget
        )
        XCTAssertEqual(try request(bridge, project: fixture.project, client: "phone")["ok"] as? Bool, false)
        let tokens = try XCTUnwrap(capacity(budget, count: 1))
        for token in tokens { budget.finish(token) }
    }
}
