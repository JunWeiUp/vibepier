import Darwin
import XCTest

@testable import VibePierCore

final class CodexBackgroundNativeTests: XCTestCase {
    func testExistingNativeServerReconnectsReadOnlyAfterDesktopUpdate() throws {
        guard ProcessInfo.processInfo.environment["VIBEPIER_CODEX_EXISTING_SERVER_READ"] == "1" else {
            throw XCTSkip("Opt-in existing native server read-only reconnect")
        }
        let directory = Paths.supportDirectory.appendingPathComponent("codex-background")
        let file = directory.appendingPathComponent("server.json")
        let before = try RuntimePrivateStorage.read(file, limit: 4096)
        let known = try JSONDecoder().decode(CodexSocketRuntimeConnection.Metadata.self, from: before)
        let connection = try CodexSocketRuntimeConnection(
            configuration: .init(enabled: true, executablePath: known.executablePath, directoryPath: directory.path),
            nativeHome: URL(fileURLWithPath: known.codexHomePath))
        defer { connection.disconnect() }
        XCTAssertEqual(connection.instanceID, known.instanceID)
        let response = try connection.request("collaborationMode/list", params: Data("{}".utf8))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(try CodexExecutionMode.catalog(value).count, 2)
        XCTAssertEqual(try RuntimePrivateStorage.read(file, limit: 4096), before)
        print(
            "Existing native server identity and read-only catalog verified; no creation, submission or server replacement"
        )
    }

    /// Explicit read-only acceptance of an existing phone operation. Never calls
    /// perform/new/turn-start, touches the desktop or prints user message bodies.
    func testExistingNativeCreationReceiptRecoversWithoutResubmission() throws {
        guard let client = ProcessInfo.processInfo.environment["VIBEPIER_CODEX_RECOVERY_CLIENT"],
            UUID(uuidString: client) != nil
        else { throw XCTSkip("Opt-in existing native receipt readback") }
        let root = Paths.supportDirectory
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("codex-background/server.json").path)
        else { throw XCTSkip("No existing registered native server") }
        let bytes = try RuntimePrivateStorage.read(
            root.appendingPathComponent("codex-receipts.json"), limit: 16 * 1024 * 1024)
        let records = try JSONDecoder().decode([String: SessionReceiptJournal.Receipt].self, from: bytes)
        let background = CodexBackgroundSessions()
        var checked = 0
        for (key, entry) in records.sorted(by: { $0.value.created > $1.value.created })
        where key.hasPrefix(client + ":") && entry.result == nil {
            guard let intent = entry.intent,
                var request = try JSONSerialization.jsonObject(with: intent) as? [String: Any],
                request["op"] as? String == "new", request["provider"] as? String == "codex",
                let text = request["text"] as? String, !text.isEmpty,
                (request["attachments"] as? [String] ?? []).isEmpty
            else { continue }
            request["operation"] = String(key.dropFirst(client.count + 1))
            request["op"] = "newReceiptCheck"
            let input = [["type": "text", "text": text]]
            guard let receipt = try background.creationReceipt(request: request, client: client, expectedInput: input)
            else { continue }
            XCTAssertEqual(receipt["accepted"] as? Bool, true)
            XCTAssertNil(receipt["unknown"])
            XCTAssertNotNil(receipt["nativeTurnId"] as? String)
            print(
                "Existing native creation readback: verified thread/turn/input and historical settings; no submission")
            checked += 1
            if checked == 3 { break }
        }
        XCTAssertGreaterThan(checked, 0, "Expected an existing matching native creation receipt")
    }

    /// Explicit opt-in: a synthetic home/project, no account, prompt or model turn.
    func testNativeEmptyThreadPersistsAndResumesWithoutDesktop() throws {
        guard let path = ProcessInfo.processInfo.environment["VIBEPIER_CODEX_BACKGROUND_NATIVE"] else {
            throw XCTSkip("Opt-in native App Server contract probe")
        }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(
            "vp-native-" + String(UUID().uuidString.prefix(12)))
        try RuntimePrivateStorage.ensureDirectory(root)
        let home = root.appendingPathComponent("home")
        let runtime = root.appendingPathComponent("runtime")
        let projectURL = root.appendingPathComponent("project")
        try RuntimePrivateStorage.ensureDirectory(home)
        try RuntimePrivateStorage.ensureDirectory(projectURL)
        var native: CodexSocketRuntimeConnection?
        defer {
            native?.disconnect()
            // Stop only this explicitly created fixture server, after checking
            // its process birth and executable against its private metadata.
            let metadataURL = runtime.appendingPathComponent("server.json")
            if FileManager.default.fileExists(atPath: metadataURL.path),
                let bytes = try? RuntimePrivateStorage.read(metadataURL, limit: 4096),
                let metadata = try? JSONDecoder().decode(CodexSocketRuntimeConnection.Metadata.self, from: bytes)
            {
                var info = proc_bsdinfo()
                var executable = [UInt8](repeating: 0, count: 4096)
                if proc_pidinfo(metadata.processID, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                    == MemoryLayout<proc_bsdinfo>.size,
                    info.pbi_uid == getuid(), info.pbi_start_tvsec == metadata.processBirthSeconds,
                    info.pbi_start_tvusec == metadata.processBirthMicroseconds,
                    proc_pidpath(metadata.processID, &executable, UInt32(executable.count)) > 0,
                    String(decoding: executable.prefix(while: { $0 != 0 }), as: UTF8.self) == metadata.executablePath
                {
                    _ = kill(metadata.processID, SIGTERM)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        print("Native fixture: connecting reviewed transport")
        native = try CodexSocketRuntimeConnection(
            configuration: .init(enabled: true, executablePath: path, directoryPath: runtime.path), nativeHome: home)
        let connection = try XCTUnwrap(native)
        print("Native fixture: transport initialized")
        func request(_ method: String, _ parameters: [String: Any]) throws -> [String: Any] {
            print("Native fixture RPC: " + method)
            let bytes = try connection.request(method, params: JSONSerialization.data(withJSONObject: parameters))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        }
        let project = try registerFixtureProject(executable: path, home: home, cwd: projectURL.path)
        let settings: [String: Any] = [
            "permissions": ":workspace", "approvalPolicy": "on-request", "approvalsReviewer": "user",
        ]
        let reply = try CodexThreadBootstrap.startPersisted(
            parameters: CodexThreadBootstrap.parameters(project: project, settings: settings),
            project: project, settings: settings, title: "Synthetic empty contract probe", request: request)
        let created = try CodexThreadBootstrap.verified(reply, project: project, settings: settings)
        let resumed = try request(
            "thread/resume",
            CodexBackgroundSessions.resumeParameters(
                thread: created.id, cwd: project.cwd, creationSettings: settings))
        XCTAssertEqual(try CodexThreadBootstrap.verified(resumed, project: project, settings: settings), created)
        let read = try request("thread/read", ["threadId": created.id, "includeTurns": true])
        let thread = try XCTUnwrap(read["thread"] as? [String: Any])
        XCTAssertEqual(thread["id"] as? String, created.id)
        XCTAssertEqual((thread["turns"] as? [Any])?.count, 0)
        connection.disconnect()
        native = try CodexSocketRuntimeConnection(
            configuration: .init(enabled: true, executablePath: path, directoryPath: runtime.path), nativeHome: home)
        let recovered = try XCTUnwrap(native)
        XCTAssertEqual(recovered.instanceID, connection.instanceID)
        let recoveredBytes = try recovered.request(
            "thread/resume",
            params: JSONSerialization.data(withJSONObject: ["threadId": created.id, "cwd": project.cwd]))
        let recoveredReply = try XCTUnwrap(JSONSerialization.jsonObject(with: recoveredBytes) as? [String: Any])
        XCTAssertEqual(try CodexThreadBootstrap.verified(recoveredReply, project: project, settings: [:]), created)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
        print("Native background contract: empty thread persisted/resumed/reconnected; no model turn or desktop action")
    }

    /// The production adapter only uses existing native projects. Register this
    /// synthetic project through a separate opt-in stdio process, without adding
    /// project mutation authority to the production transport.
    private func registerFixtureProject(executable: String, home: URL, cwd: String) throws -> CodexCreationProject {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        environment["HOME"] = home.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        var buffered = Data()
        func call(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            var bytes = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < deadline {
                while let end = buffered.firstIndex(of: 10) {
                    let line = Data(buffered[..<end])
                    buffered.removeSubrange(...end)
                    let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
                    if reply["id"] as? Int == id {
                        return try XCTUnwrap(reply["result"] as? [String: Any])
                    }
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 100)
                var chunk = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0, buffered.count + count <= 2_097_152 else { throw RuntimeDriverError.unavailable }
                buffered.append(contentsOf: chunk.prefix(count))
            }
            throw RuntimeDriverError.timeout
        }
        _ = try call(
            1, "initialize",
            [
                "clientInfo": ["name": "vibepier_fixture", "version": "1"],
                "capabilities": ["experimentalApi": true, "explicitGatewayOauth": true],
            ])
        var initialized = try JSONSerialization.data(withJSONObject: ["method": "initialized"])
        initialized.append(10)
        try input.fileHandleForWriting.write(contentsOf: initialized)
        let result = try call(
            2, "project/create",
            [
                "idempotencyKey": UUID().uuidString, "name": "Synthetic App Server probe", "roots": [["path": cwd]],
            ])
        let project = try XCTUnwrap(result["project"] as? [String: Any])
        return CodexCreationProject(
            id: try XCTUnwrap(project["id"] as? String), name: "Synthetic App Server probe", cwd: cwd)
    }
}
