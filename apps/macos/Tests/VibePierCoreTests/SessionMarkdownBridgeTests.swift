import Foundation
import XCTest

@testable import VibePierCore

final class SessionMarkdownBridgeTests: XCTestCase {
    private final class Value: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: Any] = [:]
        var value: [String: Any] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
    private func request(_ perform: (Data, @escaping @Sendable (Data) -> Void) -> Void, _ source: [String: Any]) throws
        -> [String: Any]
    {
        let value = Value()
        let done = expectation(description: "markdown RPC reply")
        perform(try JSONSerialization.data(withJSONObject: source)) { data in
            value.value = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        return value.value
    }
    func testClaudeReadAndBrowseUseTranscriptCwdNotClientCwdAndRequireOpenView() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-markdown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("workspace")
        let sessions = root.appendingPathComponent("sessions/project")
        let thread = UUID().uuidString
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try "# Claude 文档".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "private".write(to: root.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        var transcript = try JSONSerialization.data(withJSONObject: [
            "type": "user", "uuid": "user", "cwd": project.path, "message": ["content": "test"],
        ])
        transcript.append(10)
        try transcript.write(to: sessions.appendingPathComponent(thread + ".jsonl"))
        let bridge = ClaudeBridge(root: root.appendingPathComponent("sessions"))
        let perform: (Data, @escaping @Sendable (Data) -> Void) -> Void = { data, completion in
            bridge.perform(data, client: "phone", completion: completion)
        }
        let read: [String: Any] = [
            "op": "readMarkdownFile", "threadId": thread, "viewVersion": 1, "path": "README.md", "cwd": root.path,
        ]
        XCTAssertEqual(try request(perform, read)["ok"] as? Bool, false)
        let page = try request(perform, ["op": "open", "threadId": thread, "viewVersion": 1])
        XCTAssertEqual(page["ok"] as? Bool, true)
        XCTAssertEqual((page["capabilities"] as? [String: Bool])?["markdownFiles"], true)
        XCTAssertEqual(try request(perform, read)["text"] as? String, "# Claude 文档")
        var outside = read
        outside["path"] = "../outside.md"
        XCTAssertEqual(try request(perform, outside)["ok"] as? Bool, false)
        var stale = read
        stale["viewVersion"] = 0
        XCTAssertEqual(try request(perform, stale)["ok"] as? Bool, false)
        var unknown = read
        unknown["threadId"] = UUID().uuidString
        XCTAssertEqual(try request(perform, unknown)["ok"] as? Bool, false)
        let browse = try request(perform, ["op": "browseFiles", "threadId": thread, "viewVersion": 1, "folder": ""])
        XCTAssertEqual((browse["entries"] as? [[String: Any]])?.compactMap { $0["path"] as? String }, ["README.md"])
        XCTAssertEqual((page["capabilities"] as? [String: Bool])?["projectFiles"], true)
        var projectRead = read
        projectRead["op"] = "readFile"
        XCTAssertEqual(try request(perform, projectRead)["text"] as? String, "# Claude 文档")
        projectRead["path"] = "../outside.md"
        XCTAssertEqual(try request(perform, projectRead)["ok"] as? Bool, false)
        _ = try request(perform, ["op": "close", "viewVersion": 2])
        XCTAssertEqual(try request(perform, read)["ok"] as? Bool, false)
        bridge.stopAll()
    }
    func testCodexRejectsUnopenedThreadForBothReadOnlyFileOperations() throws {
        let bridge = CodexBridge(executionModeCatalog: { [] })
        let thread = UUID().uuidString
        let perform: (Data, @escaping @Sendable (Data) -> Void) -> Void = { data, completion in
            bridge.perform(data, client: "phone", completion: completion)
        }
        for op in ["readMarkdownFile", "browseFiles"] + SessionProjectFiles.operations.sorted() {
            let result = try request(
                perform, ["op": op, "threadId": thread, "viewVersion": 1, "path": "/etc/hosts.md", "cwd": "/"])
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertNil(result["text"])
            XCTAssertNil(result["entries"])
        }
        bridge.stopAll()
    }
    func testClaudeExternalSkillReferenceIsTakenOnlyFromTheSelectedTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claude-referenced-skill-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("workspace")
        let sessions = root.appendingPathComponent("sessions/project")
        let skill = root.appendingPathComponent("plugin cache/SKILL.md")
        let secret = root.appendingPathComponent("plugin cache/secret.md")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# 外部技能".write(to: skill, atomically: true, encoding: .utf8)
        try "private".write(to: secret, atomically: true, encoding: .utf8)
        let first = UUID().uuidString
        let second = UUID().uuidString
        for (thread, text) in [(first, "[设计流程](<\(skill.path):10>)"), (second, "未引用外部文件")] {
            let entries: [[String: Any]] = [
                ["type": "user", "uuid": "user", "cwd": project.path, "message": ["content": "test"]],
                [
                    "type": "assistant", "uuid": "assistant", "cwd": project.path,
                    "message": ["content": [["type": "text", "text": text]]],
                ],
            ]
            var bytes = Data()
            for entry in entries {
                bytes.append(try JSONSerialization.data(withJSONObject: entry))
                bytes.append(10)
            }
            try bytes.write(to: sessions.appendingPathComponent(thread + ".jsonl"))
        }
        let bridge = ClaudeBridge(root: root.appendingPathComponent("sessions"))
        let perform: (Data, @escaping @Sendable (Data) -> Void) -> Void = { data, completion in
            bridge.perform(data, client: "phone", completion: completion)
        }
        _ = try request(perform, ["op": "open", "threadId": first, "viewVersion": 1])
        let read: [String: Any] = ["op": "readMarkdownFile", "threadId": first, "viewVersion": 1, "path": skill.path]
        let opened = try request(perform, read)
        XCTAssertEqual(opened["text"] as? String, "# 外部技能")
        var sibling = read
        sibling["path"] = secret.path
        XCTAssertEqual(try request(perform, sibling)["ok"] as? Bool, false)
        _ = try request(perform, ["op": "open", "threadId": second, "viewVersion": 2])
        var other = read
        other["threadId"] = second
        other["viewVersion"] = 2
        other["referencedPaths"] = [skill.path]
        other["cwd"] = root.path
        XCTAssertEqual(
            try request(perform, other)["ok"] as? Bool, false,
            "selected transcript is the sole source of external authorization")
        XCTAssertEqual(try request(perform, read)["ok"] as? Bool, false)
        bridge.stopAll()
    }
    func testRealCodexReferencedSkillWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let thread = environment["VIBEPIER_CODEX_REFERENCED_MD_THREAD"],
            let path = environment["VIBEPIER_REFERENCED_MARKDOWN_PATH"]
        else { throw XCTSkip("Real Codex external Markdown read is opt-in") }
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var taken = false
            func take() -> Bool {
                lock.withLock {
                    if taken { return false }
                    taken = true
                    return true
                }
            }
        }
        let bridge = CodexBridge(executionModeCatalog: { [] })
        let client = "readonly-md-qa-" + UUID().uuidString
        let once = Once()
        let ready = expectation(description: "native Codex snapshot ready")
        bridge.event = { recipient, data in
            guard recipient == client, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                value["event"] as? String == "snapshot", value["threadId"] as? String == thread, once.take()
            else { return }
            ready.fulfill()
        }
        defer { bridge.stopAll() }
        let perform: (Data, @escaping @Sendable (Data) -> Void) -> Void = { data, completion in
            bridge.perform(data, client: client, completion: completion)
        }
        let opened = try request(perform, ["op": "open", "threadId": thread, "viewVersion": 1])
        XCTAssertEqual(opened["ok"] as? Bool, true, "\(opened["error"] ?? "no reply")")
        guard opened["ok"] as? Bool == true else { return }
        wait(for: [ready], timeout: 15)
        var read = try request(perform, ["op": "readMarkdownFile", "threadId": thread, "viewVersion": 1, "path": path])
        XCTAssertEqual(read["ok"] as? Bool, true, "\(read["error"] ?? "no reply")")
        XCTAssertEqual(read["name"] as? String, "SKILL.md")
        XCTAssertFalse((read["text"] as? String ?? "").isEmpty)
        guard let version = read["version"] as? String else { return }
        var text = read["text"] as? String ?? ""
        while let offset = read["nextOffset"] as? Int, offset >= 0 {
            read = try request(
                perform,
                [
                    "op": "readMarkdownFile", "threadId": thread, "viewVersion": 1, "path": read["path"] ?? path,
                    "offset": offset, "version": version,
                ])
            XCTAssertEqual(read["ok"] as? Bool, true, "\(read["error"] ?? "no reply")")
            guard read["ok"] as? Bool == true else { break }
            text += read["text"] as? String ?? ""
        }
        XCTAssertEqual(Data(text.utf8), try Data(contentsOf: URL(fileURLWithPath: path)))
    }
}
