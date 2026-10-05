import Darwin
import Foundation
import XCTest

@testable import VibePierCore

final class SessionProjectFilesTests: XCTestCase {
    private func fixture() throws -> (parent: URL, root: URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("project-files-" + UUID().uuidString)
        let root = parent.appendingPathComponent("vibed")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Audio"), withIntermediateDirectories: true)
        return (
            parent, URL(fileURLWithPath: String(cString: realpath(parent.path, nil)!)).appendingPathComponent("vibed")
        )
    }
    private func git(_ arguments: [String], _ root: URL) throws {
        _ = try SessionProjectFiles.Git.run(arguments, in: root, limit: 1 << 20)
    }
    private func reply(
        _ op: String, _ request: [String: Any], _ root: URL, rows: [[String: Any]] = [],
        reader: SessionMarkdownFiles = SessionMarkdownFiles()
    ) throws -> [String: Any] {
        try SessionProjectFiles.reply(
            op, request, cwd: root.path, rows: { rows }, reader: reader, device: "phone", thread: "thread")
    }

    func testVideoRepairsRepeatedWorkspaceSuffixWithoutEscaping() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("movie.mp4"))
        let result = try reply("readVideoFile", ["path": "vibed/movie.mp4"], root)
        XCTAssertEqual(result["size"] as? Int, 3)
        let nested = root.appendingPathComponent(".local/promo-video")
        try FileManager.default.createDirectory(
            at: nested.appendingPathComponent("out"), withIntermediateDirectories: true)
        try Data([1, 2]).write(to: nested.appendingPathComponent("out/vibepier-intro.mp4"))
        let repeated = try reply("readVideoFile", ["path": ".local/promo-video/out/vibepier-intro.mp4"], nested)
        XCTAssertEqual(repeated["size"] as? Int, 2)
        try FileManager.default.createDirectory(
            at: nested.appendingPathComponent(".local/promo-video/out"),
            withIntermediateDirectories: true)
        try Data([9]).write(to: nested.appendingPathComponent(".local/promo-video/out/vibepier-intro.mp4"))
        let exact = try reply("readVideoFile", ["path": ".local/promo-video/out/vibepier-intro.mp4"], nested)
        XCTAssertEqual(exact["size"] as? Int, 1)
        XCTAssertThrowsError(try reply("readVideoFile", ["path": "other/movie.mp4"], root))
        XCTAssertThrowsError(try reply("readVideoFile", ["path": "vibed/../movie.mp4"], root))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.mp4"),
            withDestinationURL: parent.appendingPathComponent("outside.mp4"))
        try Data([4]).write(to: parent.appendingPathComponent("outside.mp4"))
        XCTAssertThrowsError(try reply("readVideoFile", ["path": "vibed/escape.mp4"], root))
    }

    func testVideoChunksAreBoundedVersionedAndWorkspaceScoped() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let video = root.appendingPathComponent("demo.MP4")
        let original = Data((0..<(SessionVideoFiles.chunkBytes + 17)).map { UInt8($0 % 251) })
        try original.write(to: video)
        let first = try reply("readVideoFile", ["path": "demo.MP4"], root)
        let revision = try XCTUnwrap(first["version"] as? String)
        XCTAssertEqual(first["size"] as? Int, original.count)
        XCTAssertEqual(first["nextOffset"] as? Int, SessionVideoFiles.chunkBytes)
        var bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(first["video"] as? String)))
        let last = try reply("readVideoFile", ["path": "demo.MP4", "offset": bytes.count, "version": revision], root)
        bytes.append(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(last["video"] as? String))))
        XCTAssertEqual(bytes, original)
        XCTAssertEqual(last["nextOffset"] as? Int, -1)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: first).count, 300_000)
        XCTAssertThrowsError(try reply("readVideoFile", ["path": "demo.MP4", "offset": 1], root))
        XCTAssertThrowsError(try reply("readVideoFile", ["path": "demo.MP4", "offset": -1], root))
        try Data([1, 2]).write(to: video, options: .atomic)
        XCTAssertThrowsError(try reply("readVideoFile", ["path": "demo.MP4", "offset": 1, "version": revision], root))
        let outside = parent.appendingPathComponent("private.mp4")
        try Data([1]).write(to: outside)
        XCTAssertThrowsError(try reply("readVideoFile", ["path": outside.path], root))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.mp4"), withDestinationURL: outside)
        XCTAssertThrowsError(try reply("readVideoFile", ["path": "escape.mp4"], root))
        XCTAssertThrowsError(try reply("readVideoFile", ["path": "../private.mp4"], root))
        let large = root.appendingPathComponent("large.mp4")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(SessionVideoFiles.maximumBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try reply("readVideoFile", ["path": "large.mp4"], root))
    }

    func testBrowseReportsSizesGitStateAndChangedFolders() throws {
        guard SessionProjectFiles.Git.binary != nil else { throw XCTSkip("git is not installed") }
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        try "let a = 1\n".write(
            to: root.appendingPathComponent("Sources/Audio/Mic.swift"), atomically: true, encoding: .utf8)
        try "# readme\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], root)
        try git(["add", "."], root)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], root)
        try "let a = 2\nlet b = 3\n".write(
            to: root.appendingPathComponent("Sources/Audio/Mic.swift"), atomically: true, encoding: .utf8)
        try "new".write(to: root.appendingPathComponent("NOTES.txt"), atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 3.1)  // Past the status cache from the commit above.

        let top = try SessionProjectFiles.browse("", cwd: root.path)
        XCTAssertEqual(top["root"] as? String, "vibed")
        XCTAssertEqual(top["branch"] as? String, "main")
        let entries = top["entries"] as? [[String: Any]] ?? []
        XCTAssertEqual(entries.first { $0["name"] as? String == "Sources" }?["changed"] as? Bool, true)
        XCTAssertEqual(entries.first { $0["name"] as? String == "NOTES.txt" }?["status"] as? String, "A")
        XCTAssertNil(entries.first { $0["name"] as? String == "README.md" }?["status"])
        XCTAssertEqual(entries.first { $0["name"] as? String == "README.md" }?["size"] as? Int, 9)

        let diff = try reply("fileDiff", ["path": "Sources/Audio/Mic.swift"], root)
        XCTAssertEqual(diff["status"] as? String, "M")
        XCTAssertEqual(diff["added"] as? Int, 2)
        XCTAssertEqual(diff["removed"] as? Int, 1)
        XCTAssertTrue((diff["diff"] as? String ?? "").contains("+let b = 3"))
        XCTAssertEqual(try reply("fileDiff", ["path": "NOTES.txt"], root)["untracked"] as? Bool, true)

        let found = try reply("searchFiles", ["query": "mic"], root)["results"] as? [[String: Any]] ?? []
        XCTAssertEqual(found.map { $0["path"] as? String }, ["Sources/Audio/Mic.swift"])
        XCTAssertEqual(found.first?["status"] as? String, "M")
    }

    func testReadFileReportsBinaryLargeAndImagesInsteadOfFailing() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        try "func main() {}\n".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try Data([0x00, 0x01, 0x02]).write(to: root.appendingPathComponent("lib.dylib"))
        try Data(repeating: 0x61, count: SessionMarkdownFiles.maximumBytes + 1).write(
            to: root.appendingPathComponent("big.log"))
        try Data([0x89, 0x50]).write(to: root.appendingPathComponent("shot.png"))
        let text = try reply("readFile", ["path": "main.swift", "offset": 0], root)
        XCTAssertEqual(text["text"] as? String, "func main() {}\n")
        XCTAssertEqual(text["nextOffset"] as? Int, -1)
        XCTAssertEqual(
            try reply("readFile", ["path": "lib.dylib", "offset": 0], root)["unavailable"] as? String, "binary")
        XCTAssertEqual(
            try reply("readFile", ["path": "big.log", "offset": 0], root)["unavailable"] as? String, "tooLarge")
        XCTAssertEqual(
            try reply("readFile", ["path": "shot.png", "offset": 0], root)["unavailable"] as? String, "image")
    }

    func testEveryOperationStaysInsideTheWorkspace() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        try "secret".write(to: parent.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.txt"),
            withDestinationURL: parent.appendingPathComponent("secret.txt"))
        for op in ["readFile", "fileDiff", "openFile", "readImageFile"] {
            for path in ["../secret.txt", parent.appendingPathComponent("secret.txt").path, "escape.txt"] {
                XCTAssertThrowsError(try reply(op, ["path": path, "offset": 0], root), "\(op) \(path)")
            }
        }
    }

    func testTurnChangesTakeOnlyTheNewestTurnAndMergePaths() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        try "x".write(to: root.appendingPathComponent("Sources/Audio/Mic.swift"), atomically: true, encoding: .utf8)
        func reply(_ files: [(String, Int, Int)]) -> [String: Any] {
            [
                "role": "assistant",
                "parts": [
                    [
                        "kind": "file",
                        "files": files.map { ["path": $0.0, "kind": "update", "added": $0.1, "removed": $0.2] },
                    ]
                ],
            ]
        }
        let rows: [[String: Any]] = [
            ["role": "user", "text": "earlier"], reply([("old.swift", 1, 0)]),
            ["role": "user", "text": "now"],
            reply([(root.appendingPathComponent("Sources/Audio/Mic.swift").path, 3, 1), ("/etc/hosts", 1, 1)]),
            reply([("Sources/Audio/Mic.swift", 2, 0), ("docs/removed.md", 0, 4)]),
        ]
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let files = SessionProjectFiles.changes(rows, root: root)["files"] as? [[String: Any]] ?? []
        XCTAssertEqual(files.map { $0["path"] as? String }, ["Sources/Audio/Mic.swift", "docs/removed.md"])
        XCTAssertEqual(files.first?["added"] as? Int, 5)
        XCTAssertEqual(files.first?["removed"] as? Int, 1)
    }

    func testOpeningRefusesAnythingThatCouldRunCode() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let script = root.appendingPathComponent("run")
        let command = root.appendingPathComponent("go.command")
        try "echo hi".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        try "echo hi".write(to: command, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SessionProjectFiles.ensureInert(script, mode: 0o100755))
        XCTAssertThrowsError(try SessionProjectFiles.ensureInert(command, mode: 0o100644))
        XCTAssertThrowsError(try reply("openFile", ["path": "Sources"], root))
    }
    func testDeletedDiffAndRevokedQueuedTextRead() throws {
        guard SessionProjectFiles.Git.binary != nil else { throw XCTSkip("git is not installed") }
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = root.appendingPathComponent("removed.swift")
        try "let old = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], root)
        try git(["add", "."], root)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], root)
        try FileManager.default.removeItem(at: file)
        let diff = try reply("fileDiff", ["path": "removed.swift"], root)
        XCTAssertEqual(diff["removed"] as? Int, 1)
        XCTAssertTrue((diff["diff"] as? String ?? "").contains("-let old = 1"))
        try "let current = 2".write(to: file, atomically: true, encoding: .utf8)
        let reader = SessionMarkdownFiles()
        let queued = try SessionProjectFiles.request(
            "readFile", ["path": "removed.swift"], cwd: root.path,
            rows: [], reader: reader, device: "phone", thread: "thread")
        reader.remove(device: "phone")
        XCTAssertThrowsError(try queued.read())
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: parent)
        XCTAssertNil(SessionProjectFiles.workspacePath("escape/missing.txt", root: root))
    }

}
