import Darwin
import Foundation
import XCTest

@testable import VibePierCore

final class CodexBackgroundTurnEvidenceTests: XCTestCase {
    private let thread = UUID().uuidString
    private let turn = UUID().uuidString
    private let cwd = "/synthetic/project"
    private let marker = "vibepier_fixture_marker"
    private var input: [[String: Any]] {
        [
            ["type": "text", "text": "Synthetic first message", "text_elements": []],
            ["type": "localImage", "path": "/synthetic/first.png"],
            ["type": "localImage", "path": "/synthetic/second.png"],
        ]
    }
    private var inputDigest: String {
        CodexConversation.dataHash(CodexConfiguredCreation.Observation.canonicalInput(input)!)
    }
    private func mode(_ name: String = "default", instructions: Any = "native bundled preset") -> [String: Any] {
        [
            "mode": name,
            "settings": [
                "model": "fixture-model", "reasoning_effort": "low",
                "developer_instructions": instructions,
            ],
        ]
    }
    private func settings(_ name: String = "default", tier: String = "default") -> [String: Any] {
        [
            "type": "event_msg",
            "payload": [
                "type": "thread_settings_applied", "thread_id": thread,
                "thread_settings": [
                    "cwd": cwd, "model": "fixture-model", "reasoning_effort": "low",
                    "collaboration_mode": mode(name), "service_tier": tier,
                ],
            ],
        ]
    }
    private func records(_ name: String = "default", tier: String = "default") -> [[String: Any]] {
        [
            [
                "type": "session_meta",
                "payload": [
                    "id": thread, "cwd": cwd, "originator": "vibepier",
                    "cli_version": "0.160.0",
                ],
            ],
            settings(name, tier: tier),
            ["type": "event_msg", "payload": ["type": "task_started", "turn_id": turn, "root_turn_id": turn]],
            [
                "type": "turn_context",
                "payload": [
                    "turn_id": turn, "root_turn_id": turn, "cwd": cwd,
                    "model": "fixture-model", "effort": "low", "collaboration_mode": mode(name),
                ],
            ],
            [
                "type": "event_msg",
                "payload": [
                    "type": "item_completed", "thread_id": thread, "turn_id": turn,
                    "item": ["type": "UserMessage", "id": "native-item", "client_id": marker, "content": input],
                ],
            ],
        ]
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turn-evidence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func encoded(_ records: [[String: Any]]) throws -> Data {
        var bytes = Data()
        for record in records {
            bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            bytes.append(0x0a)
        }
        return bytes
    }
    private func write(_ records: [[String: Any]]) throws -> URL {
        let file = try directory().appendingPathComponent("native.jsonl")
        try encoded(records).write(to: file)
        return file
    }
    private func proof(_ file: URL, inputHash: String? = nil) -> CodexBackgroundTurnEvidence.Proof? {
        CodexBackgroundTurnEvidence.read(
            file: file, thread: thread, cwd: cwd, turn: turn, marker: marker,
            inputHash: inputHash ?? inputDigest)
    }

    func testNativeTaskContextAndExactUserItemRecoverModeAndTier() throws {
        for (name, tier, expected) in [("default", "default", "standard"), ("plan", "priority", "priority")] {
            let result = try XCTUnwrap(proof(write(records(name, tier: tier))))
            XCTAssertEqual(result.serviceTier, expected)
            XCTAssertTrue(NSDictionary(dictionary: result.mode).isEqual(to: mode(name)))
        }
    }

    func testLatestSettingsBeforeTaskAreBoundAndFutureSettingsCannotRewriteTurn() throws {
        var rows = records("plan", tier: "priority")
        rows.insert(settings("default", tier: "default"), at: 1)
        rows.append(settings("default", tier: "default"))
        let result = try XCTUnwrap(proof(write(rows)))
        XCTAssertEqual(result.serviceTier, "priority")
        XCTAssertEqual(result.mode["mode"] as? String, "plan")
        var late = records()
        let applied = late.remove(at: 1)
        late.insert(applied, at: 3)
        XCTAssertNil(proof(try write(late)))
    }

    func testWrongMetaThreadCwdOriginOrVersionFailsClosed() throws {
        for (key, value) in [
            ("id", UUID().uuidString), ("cwd", "/foreign"), ("originator", "Codex Desktop"),
            ("cli_version", "0.161.0"),
        ] {
            var rows = records()
            var meta = rows[0]["payload"] as! [String: Any]
            meta[key] = value
            rows[0]["payload"] = meta
            XCTAssertNil(proof(try write(rows)))
        }
    }

    func testWrongTargetIDsBodyAndAttachmentsCannotRecover() throws {
        for failure in ["thread", "turn", "root", "context-cwd", "text", "attachment", "inputDigest"] {
            var rows = records()
            if failure == "root" || failure == "context-cwd" {
                var context = rows[3]["payload"] as! [String: Any]
                context[failure == "root" ? "root_turn_id" : "cwd"] = failure == "root" ? UUID().uuidString : "/foreign"
                rows[3]["payload"] = context
            } else {
                var completed = rows[4]["payload"] as! [String: Any]
                if failure == "thread" { completed["thread_id"] = UUID().uuidString }
                if failure == "turn" { completed["turn_id"] = UUID().uuidString }
                if failure == "text" || failure == "attachment" {
                    var item = completed["item"] as! [String: Any]
                    var changed = input
                    if failure == "text" { changed[0]["text"] = "different" }
                    if failure == "attachment" { changed[2]["path"] = "/foreign.png" }
                    item["content"] = changed
                    completed["item"] = item
                }
                rows[4]["payload"] = completed
            }
            XCTAssertNil(
                proof(try write(rows), inputHash: failure == "inputDigest" ? String(repeating: "a", count: 64) : nil))
        }
    }

    func testDuplicateMetaTaskContextAndUserItemStayAmbiguous() throws {
        for index in [0, 2, 3, 4] {
            var rows = records()
            rows.append(rows[index])
            XCTAssertNil(proof(try write(rows)))
        }
    }

    func testModeModelEffortAndInstructionsMustMatchTheBoundNativeTuple() throws {
        for key in ["model", "effort", "collaboration_mode"] {
            var rows = records()
            var context = rows[3]["payload"] as! [String: Any]
            context[key] = key == "collaboration_mode" ? mode("plan") as Any : "different"
            rows[3]["payload"] = context
            XCTAssertNil(proof(try write(rows)))
        }
        var rows = records()
        var context = rows[3]["payload"] as! [String: Any]
        context["collaboration_mode"] = mode(instructions: "different native instructions")
        rows[3]["payload"] = context
        XCTAssertNil(proof(try write(rows)))
    }

    func testOnlyCompletedNewlineRecordsCountAndMalformedRecordsFailClosed() throws {
        let file = try write(records())
        let original = try Data(contentsOf: file)
        var partial = original
        partial.append(Data("{\"type\":\"event_msg\",\"payload\":".utf8))
        try partial.write(to: file)
        XCTAssertNotNil(proof(file))
        try original.dropLast().write(to: file)
        XCTAssertNil(proof(file))
        var malformed = original
        malformed.append(Data("not-json\n".utf8))
        try malformed.write(to: file)
        XCTAssertNil(proof(file))
    }

    func testSymlinksDirectoriesOversizedFileAndOversizedLineAreRejected() throws {
        let file = try write(records())
        let root = file.deletingLastPathComponent()
        let link = root.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(proof(link))
        XCTAssertNil(proof(root))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(8 * 1024 * 1024 + 1))
        try handle.close()
        XCTAssertNil(proof(file))
        var largeLine = try encoded(records())
        largeLine.append(Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1))
        largeLine.append(0x0a)
        try largeLine.write(to: file)
        XCTAssertNil(proof(file))
    }
}
