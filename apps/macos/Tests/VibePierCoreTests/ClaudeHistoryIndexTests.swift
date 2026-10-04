import Foundation
import XCTest

@testable import VibePierCore

final class ClaudeHistoryIndexTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file: URL
        init() throws {
            file = root.appendingPathComponent("synthetic.jsonl")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func append(_ rows: [[String: Any]], complete: Bool = true) throws {
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            try output.seekToEnd()
            for row in rows {
                try output.write(contentsOf: JSONSerialization.data(withJSONObject: row))
                if complete { try output.write(contentsOf: Data([10])) }
            }
        }
        func overwrite(_ rows: [[String: Any]], atomic: Bool) throws {
            var data = Data()
            for row in rows {
                data.append(try JSONSerialization.data(withJSONObject: row))
                data.append(10)
            }
            if atomic {
                try data.write(to: file, options: .atomic)
            } else {
                let output = try FileHandle(forWritingTo: file)
                defer { try? output.close() }
                try output.truncate(atOffset: 0)
                try output.write(contentsOf: data)
            }
        }
    }
    private func user(_ id: String, _ text: String, cwd: String = "/synthetic") -> [String: Any] {
        ["type": "user", "uuid": id, "cwd": cwd, "message": ["content": text]]
    }
    private func assistant(_ id: String, _ text: String) -> [String: Any] {
        ["type": "assistant", "uuid": id, "message": ["content": [["type": "text", "text": text]]]]
    }
    func testOlderHistoryFullPartsAndImagesRemainReachableOutsideNewestPage() throws {
        let fixture = try Fixture()
        let image: [String: Any] = [
            "type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AQID"],
        ]
        for i in 0..<20 {
            var prompt = user("u\(i)", "Question \(i)")
            if i == 0 { prompt["message"] = ["content": [["type": "text", "text": "Question 0"], image]] }
            var reply = assistant("a\(i)", "Answer \(i)")
            if i == 0 {
                reply["message"] = [
                    "content": [
                        ["type": "text", "text": "Answer 0"],
                        ["type": "tool_use", "id": "old-tool", "name": "Bash", "input": ["command": "synthetic test"]],
                    ]
                ]
            }
            try fixture.append([prompt, reply])
            if i == 0 {
                try fixture.append([
                    [
                        "type": "user", "uuid": "result-0",
                        "message": [
                            "content": [
                                [
                                    "type": "tool_result", "tool_use_id": "old-tool",
                                    "content": [["type": "text", "text": "Complete old result"], image],
                                ]
                            ]
                        ],
                    ]
                ])
            }
        }
        let index = try ClaudeHistoryIndex(url: fixture.file)
        XCTAssertTrue(index.refresh())
        XCTAssertEqual(index.turnCount, 20)
        XCTAssertEqual(try index.latestEntries().compactMap { $0["uuid"] as? String }, ["u19", "a19"])
        let older = try XCTUnwrap(index.older(before: "u19"))
        XCTAssertEqual(older.start, 16)
        XCTAssertEqual(
            older.rows.filter { $0["role"] as? String == "user" }.compactMap { $0["id"] as? String },
            ["u16", "u17", "u18"])
        let old = try index.projected(containing: "reply-u0").flatMap { $0 }
        XCTAssertEqual(ConversationReply.fullText(old, id: "reply-u0"), "Answer 0")
        XCTAssertEqual(ConversationReply.fullText(old, id: "a0-0"), "Answer 0")
        XCTAssertEqual(ConversationReply.fullText(old, id: "old-tool"), "Complete old result")
        XCTAssertNotNil(
            ConversationReply.partPage(
                old, id: "reply-u0", offset: 0, headersOnly: false, sequence: false, before: nil))
        XCTAssertEqual(try index.turn(containing: "u0#0"), 0)
        XCTAssertEqual(try index.turn(containing: "old-tool#0"), 0)
        XCTAssertEqual(
            ConversationReply.image(try index.projected(containing: "u0#0").flatMap { $0 }, id: "u0#0"),
            "data:image/png;base64,AQID")
        XCTAssertEqual(
            ConversationReply.image(try index.projected(containing: "old-tool#0").flatMap { $0 }, id: "old-tool#0"),
            "data:image/png;base64,AQID")
    }
    func testPartialRecordCannotBeUsedAsSubmissionBoundaryOrNewReceiptUntilCompleted() throws {
        let fixture = try Fixture()
        try fixture.append([user("old", "Earlier")])
        let index = try ClaudeHistoryIndex(url: fixture.file)
        XCTAssertTrue(index.refresh())
        let boundary = try index.receiptBoundary()
        try fixture.append([user("already-started", "Target")], complete: false)
        XCTAssertFalse(index.refresh())
        XCTAssertEqual(index.offset, boundary)
        XCTAssertEqual(index.turnCount, 1)
        XCTAssertThrowsError(try index.receiptBoundary())
        XCTAssertNil(index.confirmedMessage(after: boundary, text: "Target"))
        let output = try FileHandle(forWritingTo: fixture.file)
        try output.seekToEnd()
        try output.write(contentsOf: Data([10]))
        try output.close()
        XCTAssertTrue(index.refresh())
        let completeBoundary = try index.receiptBoundary()
        XCTAssertGreaterThan(completeBoundary, boundary)
        XCTAssertNil(index.confirmedMessage(after: completeBoundary, text: "Target"))
        XCTAssertEqual(index.turnCount, 2)
    }
    func testCachedPageRefusesReplacementThenRefreshChangesIncarnation() throws {
        let fixture = try Fixture()
        try fixture.append([user("old", "Earlier"), assistant("old-a", "Old answer")])
        let index = try ClaudeHistoryIndex(url: fixture.file)
        XCTAssertTrue(index.refresh())
        _ = try index.latestEntries()
        let original = index.incarnation
        try fixture.overwrite([user("new", "Replacement"), assistant("new-a", "New answer")], atomic: true)
        XCTAssertThrowsError(try index.latestEntries())
        XCTAssertTrue(index.refresh())
        XCTAssertNotEqual(index.incarnation, original)
        XCTAssertEqual(index.turnCount, 1)
        XCTAssertNil(try index.turn(containing: "old"))
        XCTAssertEqual(try index.latestEntries().first?["uuid"] as? String, "new")
    }
    func testTruncateAndRewriteLargerFileCannotRetainOldOffsetsOrReceiptIncarnation() throws {
        let fixture = try Fixture()
        try fixture.append([user("old", "Earlier")])
        let index = try ClaudeHistoryIndex(url: fixture.file)
        XCTAssertTrue(index.refresh())
        let original = index.incarnation
        let oldNode = index.inode
        try fixture.overwrite(
            [
                user("new", String(repeating: "Replacement", count: 100), cwd: "/replacement"),
                assistant("new-a", "New answer"),
            ], atomic: false)
        XCTAssertTrue(index.refresh())
        XCTAssertEqual(index.inode, oldNode)
        XCTAssertNotEqual(index.incarnation, original)
        XCTAssertEqual(index.turnCount, 1)
        XCTAssertEqual(index.cwd, "/replacement")
        XCTAssertNil(try index.turn(containing: "old"))
    }
    func testCompleteTextAndUniqueNewNativeIDAreRequiredForLateReceipt() throws {
        let fixture = try Fixture()
        try fixture.append([user("old", "Target"), assistant("old-a", "Earlier")])
        let index = try ClaudeHistoryIndex(url: fixture.file)
        XCTAssertTrue(index.refresh())
        let boundary = try index.receiptBoundary()
        try fixture.append([user("new", "Target suffix"), user("new-match", "Target")])
        XCTAssertTrue(index.refresh())
        XCTAssertEqual(index.confirmedMessage(after: boundary, text: "Target"), "new-match")
        try fixture.append([user("second-match", "Target")])
        XCTAssertTrue(index.refresh())
        XCTAssertNil(index.confirmedMessage(after: boundary, text: "Target"))
        XCTAssertNil(index.confirmedMessage(after: boundary, text: ""))
    }
    func testReusedOrInvalidNativeIDNeverConfirmsSubmission() throws {
        for id in ["old", "new\0hidden", "new\nline", String(repeating: "a", count: 513)] {
            let fixture = try Fixture()
            try fixture.append([user("old", "Earlier")])
            let index = try ClaudeHistoryIndex(url: fixture.file)
            XCTAssertTrue(index.refresh())
            let boundary = try index.receiptBoundary()
            try fixture.append([user(id, "Target")])
            XCTAssertTrue(index.refresh())
            XCTAssertNil(index.confirmedMessage(after: boundary, text: "Target"))
        }
    }
    func testMalformedAppendRefusesMutationsAndCanRebuildAfterCorrection() throws {
        let fixture = try Fixture()
        try fixture.append([user("old", "Earlier")])
        let index = try ClaudeHistoryIndex(url: fixture.file)
        XCTAssertTrue(index.refresh())
        let original = index.incarnation
        let output = try FileHandle(forWritingTo: fixture.file)
        try output.seekToEnd()
        try output.write(contentsOf: Data("invalid JSON\n".utf8))
        try output.close()
        XCTAssertFalse(index.refresh())
        XCTAssertNotNil(index.failure)
        XCTAssertThrowsError(try index.latestEntries())
        XCTAssertThrowsError(try index.receiptBoundary())
        try fixture.overwrite([user("fixed", "Corrected")], atomic: false)
        XCTAssertTrue(index.refresh())
        XCTAssertNil(index.failure)
        XCTAssertNotEqual(index.incarnation, original)
        XCTAssertEqual(index.turnCount, 1)
    }
    func testOversizedTurnFailsExplicitlyWhileSourceAndOlderTurnRemainAvailable() throws {
        let fixture = try Fixture()
        try fixture.append([user("old", "Earlier"), assistant("old-a", "Small answer"), user("huge", "Large turn")])
        let text = String(repeating: "x", count: 3 * 1024 * 1024)
        for i in 0..<3 { try fixture.append([assistant("huge-a\(i)", text)]) }
        let originalSize = try fixture.file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let index = try ClaudeHistoryIndex(url: fixture.file)
        XCTAssertTrue(index.refresh())
        XCTAssertNil(index.failure)
        XCTAssertThrowsError(try index.latestEntries()) { XCTAssertEqual($0 as? ClaudeHistoryIndex.Failure, .tooLarge) }
        XCTAssertEqual(try index.readEntries(start: 0, end: 1).first?["uuid"] as? String, "old")
        XCTAssertEqual(try fixture.file.resourceValues(forKeys: [.fileSizeKey]).fileSize, originalSize)
    }
    func testBodyCacheHasOneAggregateBudgetAndEvictedHistoryCanBeReloaded() throws {
        var fixtures: [Fixture] = []
        var indexes: [ClaudeHistoryIndex] = []
        for i in 0..<10 {
            let fixture = try Fixture()
            fixtures.append(fixture)
            try fixture.append([user("u\(i)", "Question"), assistant("a\(i)", String(repeating: "x", count: 700_000))])
            let index = try ClaudeHistoryIndex(url: fixture.file)
            indexes.append(index)
            XCTAssertTrue(index.refresh())
            _ = try index.latestEntries()
            XCTAssertLessThanOrEqual(ClaudeHistoryIndex.cachedBodyBytes, 4 * 1024 * 1024)
        }
        XCTAssertEqual(try indexes[0].latestEntries().first?["uuid"] as? String, "u0")
        XCTAssertLessThanOrEqual(ClaudeHistoryIndex.cachedBodyBytes, 4 * 1024 * 1024)
        XCTAssertEqual(fixtures.count, 10)
    }
    func testIgnoredSidechainDoesNotCreatePhantomMainTurn() throws {
        let fixture = try Fixture()
        var sidechain = assistant("side", "Internal")
        sidechain["isSidechain"] = true
        try fixture.append([sidechain, user("main", "Question"), assistant("answer", "Answer")])
        let index = try ClaudeHistoryIndex(url: fixture.file)
        XCTAssertTrue(index.refresh())
        XCTAssertEqual(index.turnCount, 1)
        XCTAssertEqual(try index.older(before: "main")?.rows.count, 0)
    }
}
