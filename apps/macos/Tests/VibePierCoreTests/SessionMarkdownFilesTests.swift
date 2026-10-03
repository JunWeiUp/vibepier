import Darwin
import Foundation
import XCTest

@testable import VibePierCore

final class SessionMarkdownFilesTests: XCTestCase {
    func testPreparedReadCannotRepopulateSnapshotsAfterClosingDevice() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        try "fixture".write(to: root.appendingPathComponent("test.md"), atomically: true, encoding: .utf8)
        let files = SessionMarkdownFiles()
        let old = try files.request(
            ["path": "test.md"], cwd: root.path, device: "phone", thread: "thread", referencedPaths: [])
        files.remove(device: "phone")
        XCTAssertThrowsError(try old.read())
        let fresh = try files.request(
            ["path": "test.md"], cwd: root.path, device: "phone", thread: "new", referencedPaths: [])
        let result = try JSONSerialization.jsonObject(with: fresh.read()) as? [String: Any]
        XCTAssertEqual(result?["text"] as? String, "fixture")
        XCTAssertEqual(result?["threadId"] as? String, "new")
    }

    private func fixture() throws -> (parent: URL, root: URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "markdown-files-" + UUID().uuidString)
        let root = parent.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        return (parent, root)
    }
    private func read(
        _ files: SessionMarkdownFiles, _ path: String, _ root: URL, offset: Int = 0, version: String? = nil,
        device: String = "phone", thread: String = "thread", references: Set<String> = []
    ) throws -> [String: Any] {
        var request: [String: Any] = ["path": path, "offset": offset, "cwd": "/"]
        if let version { request["version"] = version }
        return try files.reply(request, cwd: root.path, device: device, thread: thread, referencedPaths: references)
    }
    func testRelativeAbsoluteNormalizedCaseInsensitiveAndEmptyFiles() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = SessionMarkdownFiles()
        let source = root.appendingPathComponent("docs/ReadMe.MD")
        try "# 标题\n正常 👩🏽‍💻".write(to: source, atomically: true, encoding: .utf8)
        let relative = try read(files, "./docs/../docs/ReadMe.MD", root)
        let absolute = try read(files, source.path, root)
        XCTAssertEqual(relative["text"] as? String, absolute["text"] as? String)
        XCTAssertEqual(relative["path"] as? String, "docs/ReadMe.MD")
        XCTAssertEqual(relative["nextOffset"] as? Int, -1)
        try Data().write(to: root.appendingPathComponent("empty.MarkDown"))
        let empty = try read(files, "empty.MarkDown", root)
        XCTAssertEqual(empty["text"] as? String, "")
        XCTAssertEqual(empty["size"] as? Int, 0)
        XCTAssertEqual(empty["nextOffset"] as? Int, -1)
    }
    func testOutsideTraversalSymlinksAndMissingTrustedDirectoryAreRejected() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("secret.md")
        let sibling = parent.appendingPathComponent("project-other")
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "sibling".write(to: sibling.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        try "inside".write(to: root.appendingPathComponent("docs/inside.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.md"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape-dir"), withDestinationURL: parent)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("inside.md"),
            withDestinationURL: root.appendingPathComponent("docs/inside.md"))
        let files = SessionMarkdownFiles()
        for path in [
            "../secret.md", outside.path, sibling.appendingPathComponent("secret.md").path, "escape.md",
            "escape-dir/secret.md", "docs/a\0.md",
        ] {
            XCTAssertThrowsError(try read(files, path, root), "must reject \(path)")
        }
        XCTAssertEqual(try read(files, "inside.md", root)["text"] as? String, "inside")
        for cwd in ["", "relative/project", parent.appendingPathComponent("missing").path] {
            XCTAssertThrowsError(
                try files.reply(
                    ["path": outside.path, "cwd": parent.path], cwd: cwd, device: "phone", thread: "thread"))
        }
        XCTAssertThrowsError(try SessionMarkdownFiles.browse("escape-dir", cwd: root.path))
    }
    func testOnlyRegularUTF8MarkdownWithinSizeLimitCanBeRead() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = SessionMarkdownFiles()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder.md"), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe.md").path, 0o600), 0)
        try Data([0xff, 0xfe, 0x80]).write(to: root.appendingPathComponent("invalid.md"))
        try Data(repeating: 0x61, count: SessionMarkdownFiles.maximumBytes + 1).write(
            to: root.appendingPathComponent("huge.md"))
        try "not markdown".write(to: root.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
        for path in ["folder.md", "pipe.md", "invalid.md", "huge.md", "code.swift", "missing.md"] {
            XCTAssertThrowsError(try read(files, path, root))
        }
        try Data(repeating: 0x61, count: SessionMarkdownFiles.maximumBytes).write(
            to: root.appendingPathComponent("limit.md"))
        let limit = try read(files, "limit.md", root)
        XCTAssertEqual(limit["size"] as? Int, SessionMarkdownFiles.maximumBytes)
        XCTAssertEqual((limit["text"] as? String)?.count, 8_000)
    }
    func testMultibyteChunksKeepOneImmutableSnapshotWhenFileChanges() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = SessionMarkdownFiles()
        let original = String(repeating: "中文👩🏽‍💻e\u{301}\n", count: 4_000)
        let source = root.appendingPathComponent("long.md")
        try original.write(to: source, atomically: true, encoding: .utf8)
        var page = try read(files, "long.md", root)
        var combined = try XCTUnwrap(page["text"] as? String)
        let version = try XCTUnwrap(page["version"] as? String)
        XCTAssertLessThanOrEqual(combined.unicodeScalars.count, 8_000)
        XCTAssertLessThanOrEqual(combined.utf8.count, SessionMarkdownFiles.chunkBytes)
        try "# New version".write(to: source, atomically: true, encoding: .utf8)
        var pages = 1
        while let offset = page["nextOffset"] as? Int, offset >= 0 {
            page = try read(files, "long.md", root, offset: offset, version: version)
            let chunk = try XCTUnwrap(page["text"] as? String)
            XCTAssertFalse(chunk.unicodeScalars.contains("\u{fffd}"))
            XCTAssertLessThanOrEqual(chunk.unicodeScalars.count, 8_000)
            XCTAssertLessThanOrEqual(chunk.utf8.count, SessionMarkdownFiles.chunkBytes)
            combined += chunk
            pages += 1
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(combined, original)
        let fresh = try read(files, "long.md", root)
        XCTAssertEqual(fresh["text"] as? String, "# New version")
        XCTAssertNotEqual(fresh["version"] as? String, version)
        XCTAssertThrowsError(
            try read(files, "long.md", root, offset: 1, version: version), "byte offset must be a UTF8 scalar boundary")
        XCTAssertThrowsError(try read(files, "long.md", root, offset: original.utf8.count + 1, version: version))
        XCTAssertThrowsError(
            try read(files, "long.md", root, offset: 8_000), "continuation cannot silently mix a new file version")
    }
    func testSnapshotTokensAreBoundToDeviceSessionRootPathAndExpire() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        var now = 0.0
        let files = SessionMarkdownFiles(clock: { now })
        for path in ["one.md", "two.md"] {
            try "text".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let version = try XCTUnwrap(read(files, "one.md", root)["version"] as? String)
        XCTAssertThrowsError(try read(files, "one.md", root, version: version, device: "another-phone"))
        XCTAssertThrowsError(try read(files, "one.md", root, version: version, thread: "another-thread"))
        XCTAssertThrowsError(try read(files, "two.md", root, version: version))
        XCTAssertThrowsError(try read(files, "project/one.md", parent, version: version))
        now = 301
        XCTAssertThrowsError(try read(files, "one.md", root, version: version))
        let next = try XCTUnwrap(read(files, "one.md", root)["version"] as? String)
        files.remove(device: "phone")
        XCTAssertThrowsError(try read(files, "one.md", root, version: next))
    }
    func testBrowseKeepsCanonicalPathsAndSkipsHiddenOutsideAndSpecialFiles() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        try "visible".write(to: root.appendingPathComponent("file.md"), atomically: true, encoding: .utf8)
        try "hidden".write(to: root.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        try "outside".write(to: parent.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside.md"),
            withDestinationURL: parent.appendingPathComponent("outside.md"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe.md").path, 0o600), 0)
        let page = try SessionMarkdownFiles.browse("docs/..", cwd: root.path)
        let entries = try XCTUnwrap(page["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["path"] as? String }, ["docs", "file.md"])
        XCTAssertEqual(entries.first?["directory"] as? Bool, true)
        XCTAssertEqual(page["folder"] as? String, "")
    }
    func testExplicitExternalReferencePermitsOnlyOneFileAndDoesNotEnlargeBrowse() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let skills = parent.appendingPathComponent("plugin cache/skills/ideate")
        let source = skills.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try "# 设计流程\n外部引用".write(to: source, atomically: true, encoding: .utf8)
        try "private".write(to: skills.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        let references = SessionMarkdownFiles.referencedPaths(in: [
            ["role": "assistant", "text": "[设计流程](<\(source.path):12>)"]
        ])
        XCTAssertEqual(references, [source.path])
        let files = SessionMarkdownFiles()
        let result = try read(files, source.path, root, references: references)
        XCTAssertEqual(result["text"] as? String, "# 设计流程\n外部引用")
        XCTAssertEqual(result["name"] as? String, "SKILL.md")
        let canonical = try XCTUnwrap(realpath(source.path, nil))
        defer { free(canonical) }
        XCTAssertEqual(result["path"] as? String, String(cString: canonical))
        XCTAssertThrowsError(
            try read(files, source.path, root), "another session without the reference cannot access the skill")
        XCTAssertThrowsError(
            try read(files, skills.appendingPathComponent("secret.md").path, root, references: references))
        XCTAssertThrowsError(
            try SessionMarkdownFiles.browse(skills.path, cwd: root.path),
            "a file reference never authorizes directory browsing")
        XCTAssertThrowsError(
            try files.reply(
                ["path": source.path, "referencedPaths": [source.path], "cwd": parent.path], cwd: root.path,
                device: "phone", thread: "thread"), "RPC allowlist and cwd cannot enlarge scope")
    }
    func testExternalSnapshotsRemainBoundToSessionAndCurrentReference() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("external.md")
        let original = String(repeating: "文档👩🏽‍💻", count: 6_000)
        try original.write(to: source, atomically: true, encoding: .utf8)
        let files = SessionMarkdownFiles()
        let references: Set<String> = [source.path]
        let first = try read(files, source.path, root, thread: "session-a", references: references)
        let version = try XCTUnwrap(first["version"] as? String)
        let offset = try XCTUnwrap(first["nextOffset"] as? Int)
        XCTAssertGreaterThan(offset, 0)
        XCTAssertThrowsError(
            try read(
                files, source.path, root, offset: offset, version: version, thread: "session-b", references: references)
        )
        XCTAssertThrowsError(
            try read(files, source.path, root, offset: offset, version: version, thread: "session-a"),
            "revoking the reference must revoke existing snapshots too")
        try "replacement".write(to: source, atomically: true, encoding: .utf8)
        let second = try read(
            files, source.path, root, offset: offset, version: version, thread: "session-a", references: references)
        let text = try XCTUnwrap(second["text"] as? String)
        XCTAssertEqual(Data(text.utf8), Data(original.utf8).subdata(in: offset..<(offset + text.utf8.count)))
    }
    func testReferenceProjectionIgnoresToolCodeImagesURLsAndUnrelatedMetadata() throws {
        let rows: [[String: Any]] = [
            [
                "role": "assistant",
                "text": """
                [Skill](</external/plugin%20cache/SKILL.md#L12>)
                [Nested](/external/a\\(b\\).markdown:3:8)
                ![Image](/external/image.md)
                `[Code](/external/inline.md)`
                ```md
                [Code](/external/fenced.md)
                ```
                [Web](https://example.test/README.md)
                [File URL](file:///external/README.md)
                """, "secret": "/external/metadata.md",
                "parts": [
                    ["kind": "tool", "text": "[Result](/external/tool.md)"],
                    ["kind": "command", "text": "[Command](/external/command.md)"],
                    ["kind": "text", "text": "[Reply](/external/reply.md)"],
                    ["kind": "file", "files": [["path": "/external/edited.md"]]],
                ],
            ]
        ]
        XCTAssertEqual(
            SessionMarkdownFiles.referencedPaths(in: rows),
            ["/external/plugin cache/SKILL.md", "/external/a(b).markdown", "/external/reply.md", "/external/edited.md"])
    }
    func testRealReferencedSkillWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["VIBEPIER_REFERENCED_MARKDOWN_PATH"],
            let cwd = environment["VIBEPIER_REFERENCED_MARKDOWN_CWD"]
        else { throw XCTSkip("Real external skill read is opt-in") }
        let files = SessionMarkdownFiles()
        let references = SessionMarkdownFiles.referencedPaths(in: [["role": "assistant", "text": "[设计流程](<\(path)>)"]])
        XCTAssertThrowsError(try files.reply(["path": path], cwd: cwd, device: "readonly-qa", thread: "skill-qa"))
        var page = try files.reply(
            ["path": path], cwd: cwd, device: "readonly-qa", thread: "skill-qa", referencedPaths: references)
        let version = try XCTUnwrap(page["version"] as? String)
        var text = try XCTUnwrap(page["text"] as? String)
        while let offset = page["nextOffset"] as? Int, offset >= 0 {
            page = try files.reply(
                ["path": page["path"] ?? path, "offset": offset, "version": version], cwd: cwd, device: "readonly-qa",
                thread: "skill-qa", referencedPaths: references)
            text += try XCTUnwrap(page["text"] as? String)
        }
        XCTAssertEqual(Data(text.utf8), try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(page["name"] as? String, "SKILL.md")
    }
}
