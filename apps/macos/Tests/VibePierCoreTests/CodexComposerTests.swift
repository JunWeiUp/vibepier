import CryptoKit
import Darwin
import XCTest

@testable import VibePierCore

final class CodexComposerTests: XCTestCase {
    func testReadOnlyDesktopSpeedWhenExplicitlyRequested() throws {
        guard let thread = ProcessInfo.processInfo.environment["VIBEPIER_CODEX_SPEED_READ_THREAD"] else {
            throw XCTSkip("Read-only native speed probe is opt-in")
        }
        let view = try CodexConfiguredCreation.freshView(thread)
        let selection = CodexComposer.selection(view.state)
        let tier = try XCTUnwrap(selection["serviceTier"] as? String)
        XCTAssertTrue(["standard", "priority"].contains(tier))
        let models = try CodexComposer().models()
        let model = try XCTUnwrap(models.first { $0["id"] as? String == selection["model"] as? String })
        XCTAssertTrue((model["serviceTiers"] as? [String] ?? []).contains("priority"))
        print("Read-only native service tier: \(tier); model advertises fast mode")
    }

    func testServiceTierRequiresKnownStateAndSupportedModelAndVerifiedReadback() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let rows: [[String: Any]] = [
            ["slug": "fast-model", "visibility": "list", "service_tiers": [["id": "priority"]]],
            ["slug": "standard-model", "visibility": "list"],
        ]
        try JSONSerialization.data(withJSONObject: ["models": rows]).write(to: url)
        let composer = CodexComposer(catalogURL: url)
        let standard: [String: Any] = ["latestThreadSettings": ["model": "fast-model", "serviceTier": NSNull()]]
        let fast: [String: Any] = ["latestThreadSettings": ["model": "fast-model", "serviceTier": "priority"]]
        XCTAssertNil(CodexComposer.selection([:])["serviceTier"])
        XCTAssertEqual(CodexComposer.selection(standard)["serviceTier"] as? String, "standard")
        XCTAssertEqual(CodexComposer.selection(fast)["serviceTier"] as? String, "priority")
        XCTAssertEqual(
            try composer.settings(["serviceTier": "priority"], state: standard)["serviceTier"] as? String, "priority")
        XCTAssertTrue(try composer.settings(["serviceTier": "standard"], state: fast)["serviceTier"] is NSNull)
        XCTAssertThrowsError(try composer.settings(["serviceTier": "priority"], state: [:]))
        XCTAssertThrowsError(try composer.settings(["serviceTier": true], state: standard))
        XCTAssertThrowsError(try composer.settings(["serviceTier": "ultrafast"], state: standard))
        XCTAssertThrowsError(
            try composer.settings(
                ["serviceTier": "priority"],
                state: ["latestThreadSettings": ["model": "standard-model", "serviceTier": NSNull()]]))
        XCTAssertThrowsError(try CodexExecutionMode.verifiedComposer(standard, request: ["serviceTier": "priority"]))
        XCTAssertEqual(
            try CodexExecutionMode.verifiedComposer(fast, request: ["serviceTier": "priority"])["serviceTier"]
                as? String, "priority")
    }

    func testCatalogFiltersHiddenModelsAndValidatesEffort() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data: [String: Any] = [
            "models": [
                [
                    "slug": "visible", "visibility": "list", "display_name": "Visible",
                    "supported_reasoning_levels": [["effort": "medium"], ["effort": "high"]],
                    "default_reasoning_level": "medium",
                ], ["slug": "hidden", "visibility": "hide"],
            ]
        ]
        try JSONSerialization.data(withJSONObject: data).write(to: url)
        let composer = CodexComposer(catalogURL: url)
        XCTAssertEqual(try composer.models().count, 1)
        XCTAssertEqual(
            try composer.settings(["model": "visible", "effort": "high"], state: [:])["effort"] as? String, "high")
        XCTAssertThrowsError(try composer.settings(["model": "hidden"], state: [:]))
        XCTAssertThrowsError(try composer.settings(["model": "visible", "effort": "ultra"], state: [:]))
    }
    func testPermissionModesMatchDesktopAndRequireFullAccessConfirmation() throws {
        let composer = CodexComposer()
        let manual = try composer.settings(["mode": "auto"], state: [:])
        XCTAssertEqual(manual["permissions"] as? String, ":workspace")
        XCTAssertEqual(manual["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(manual["approvalsReviewer"] as? String, "user")
        XCTAssertEqual(
            try composer.settings(["mode": "guardian-approvals"], state: [:])["approvalsReviewer"] as? String,
            "guardian_subagent")
        XCTAssertThrowsError(try composer.settings(["mode": "full-access"], state: [:]))
        let full = try composer.settings(["mode": "full-access", "confirmFullAccess": true], state: [:])
        XCTAssertEqual(full["permissions"] as? String, ":danger-full-access")
        XCTAssertEqual(full["approvalPolicy"] as? String, "never")
        XCTAssertThrowsError(try composer.settings(["mode": "made-up"], state: [:]))
        XCTAssertNil(manual["model"])
    }
    func testPendingThreadSettingsOverrideOldRuntimeSelection() {
        let state: [String: Any] = [
            "currentPermissions": [
                "activePermissionProfile": ["id": ":danger-full-access"], "approvalsReviewer": "user",
            ],
            "latestThreadSettings": [
                "permissions": ":workspace", "approvalsReviewer": "guardian_subagent", "model": "selected",
                "effort": "high",
            ],
        ]
        let selected = CodexComposer.selection(state)
        XCTAssertEqual(selected["mode"] as? String, "guardian-approvals")
        XCTAssertEqual(selected["model"] as? String, "selected")
    }
    func testAttachmentUploadReplayHashAndDeviceThreadIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var attachments = try CodexAttachments(root: root)
        let id = UUID().uuidString
        let bytes = Data("file contents".utf8)
        let start: [String: Any] = ["attachmentId": id, "name": "notes.txt", "mime": "text/plain", "size": bytes.count]
        _ = try attachments.start(start, device: "a", thread: "t")
        XCTAssertThrowsError(try attachments.start(start, device: "b", thread: "t"))
        XCTAssertThrowsError(try attachments.selected([id], device: "a", thread: "t"))
        let chunk: [String: Any] = ["attachmentId": id, "offset": 0, "data": bytes.base64EncodedString()]
        _ = try attachments.chunk(chunk, device: "a", thread: "t")
        _ = try attachments.chunk(chunk, device: "a", thread: "t")
        XCTAssertThrowsError(
            try attachments.chunk(
                ["attachmentId": id, "offset": 0, "data": Data("DIFFERENT".utf8).base64EncodedString()], device: "a",
                thread: "t"))
        XCTAssertThrowsError(
            try attachments.complete(["attachmentId": id, "sha256": "wrong"], device: "a", thread: "t"))
        _ = try attachments.complete(
            ["attachmentId": id, "sha256": CodexConversation.dataHash(bytes)], device: "a", thread: "t")
        attachments = try CodexAttachments(root: root)
        XCTAssertThrowsError(try attachments.selected([id], device: "a", thread: "other"))
        let selected = try attachments.selected([id], device: "a", thread: "t")
        XCTAssertEqual(selected.files.first?["label"] as? String, "notes.txt")
        try attachments.remove(id, device: "a", thread: "t")
        // Sent files remain readable for the desktop even when removed from the mobile draft.
        XCTAssertFalse(try attachments.selected([id], device: "a", thread: "t").input.isEmpty)
    }
    func testPipelinedAttachmentReordersAndRejectsMissingConflictingOrRestartedChunks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = try CodexAttachments(root: root)
        let id = UUID().uuidString.lowercased()
        let content = Data((0..<(3 * 64 * 1024 + 17)).map { UInt8($0 % 251) })
        let start = try attachments.start(
            ["attachmentId": id, "name": "test.bin", "size": content.count, "uploadVersion": 1], device: "owner",
            thread: "thread")
        XCTAssertEqual((start["upload"] as? [String: Any])?["window"] as? Int, 3)
        func chunk(_ offset: Int, device: String = "owner", bytes: Data? = nil) throws -> [String: Any] {
            try attachments.chunk(
                [
                    "attachmentId": id, "offset": offset, "uploadVersion": 1,
                    "data": (bytes ?? content.subdata(in: offset..<min(offset + 64 * 1024, content.count)))
                        .base64EncodedString(),
                ], device: device, thread: "thread")
        }
        let completion: [String: Any] = [
            "attachmentId": id, "uploadVersion": 1, "sha256": CodexConversation.dataHash(content),
        ]
        XCTAssertEqual(try chunk(2 * 64 * 1024)["durable"] as? Bool, false)
        XCTAssertThrowsError(try chunk(0, device: "other"))
        XCTAssertThrowsError(try attachments.complete(completion, device: "owner", thread: "thread"))
        _ = try chunk(0)
        _ = try chunk(0)
        XCTAssertThrowsError(try chunk(0, bytes: Data(repeating: 0xff, count: 64 * 1024)))
        _ = try chunk(3 * 64 * 1024)
        _ = try chunk(64 * 1024)
        let restarted = try CodexAttachments(root: root)
        XCTAssertThrowsError(try restarted.complete(completion, device: "owner", thread: "thread"))
        XCTAssertThrowsError(
            try restarted.chunk(
                [
                    "attachmentId": id, "offset": 0, "uploadVersion": 1,
                    "data": content.prefix(64 * 1024).base64EncodedString(),
                ], device: "owner", thread: "thread"))
        _ = try attachments.complete(completion, device: "owner", thread: "thread")
        let selected = try CodexAttachments(root: root).selected([id], device: "owner", thread: "thread")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(selected.files.first?["path"] as? String))), content
        )
    }

    func testAttachmentUUIDCaseAliasesCannotOverwriteAnotherPhoneOrCountTwice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var attachments = try CodexAttachments(root: root)
        let id = "ABCDEF00-1111-4222-8333-444444444444"
        let content = Data("original owner data".utf8)
        var start: [String: Any] = [
            "attachmentId": id, "name": "fixture.txt", "size": content.count, "mime": "text/plain",
        ]
        _ = try attachments.start(start, device: "owner", thread: "draft")
        _ = try attachments.chunk(
            ["attachmentId": id, "offset": 0, "data": content.base64EncodedString()], device: "owner", thread: "draft")
        start["attachmentId"] = id.lowercased()
        XCTAssertThrowsError(try attachments.start(start, device: "other-phone", thread: "draft"))
        _ = try attachments.complete(
            ["attachmentId": id.lowercased(), "sha256": CodexConversation.dataHash(content)], device: "owner",
            thread: "draft")
        attachments = try CodexAttachments(root: root)
        XCTAssertThrowsError(try attachments.selected([id, id.lowercased()], device: "owner", thread: "draft"))
        let selected = try attachments.selected([id], device: "owner", thread: "draft")
        let path = try XCTUnwrap(selected.files.first?["path"] as? String)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), content)
    }

    func testUnindexedAttachmentDirectoryIsNeverReusedOrTruncated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.txt")
        try Data("retained".utf8).write(to: file)
        let attachments = try CodexAttachments(root: root)
        XCTAssertThrowsError(
            try attachments.start(
                ["attachmentId": id, "name": "fixture.txt", "size": 1], device: "phone", thread: "draft"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "retained")
    }
    func testWorkspaceReferencesCannotEscapeThroughTraversalOrSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertThrowsError(try CodexAttachments.workspaceFile("../outside", cwd: root.path))
        XCTAssertThrowsError(try CodexAttachments.workspaceFile("escape/private", cwd: root.path))
        XCTAssertThrowsError(try CodexAttachments.workspaceFile("/etc/passwd", cwd: root.path))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dangling"),
            withDestinationURL: root.appendingPathComponent("missing-destination"))
        XCTAssertThrowsError(try CodexAttachments.workspaceFile("dangling/private", cwd: root.path))
        let actualRoot = try XCTUnwrap(realpath(root.path, nil))
        defer { free(actualRoot) }
        let canonicalRoot = URL(fileURLWithPath: String(cString: actualRoot))
        XCTAssertEqual(
            try CodexAttachments.workspaceFile("notes.txt", cwd: root.path).path,
            canonicalRoot.appendingPathComponent("notes.txt").path)
        XCTAssertEqual(
            try CodexAttachments.workspaceFile("missing/subfolder/notes.txt", cwd: root.path).path,
            canonicalRoot.appendingPathComponent("missing/subfolder/notes.txt").path)
    }
    func testWorkspaceAttachmentUsesPrivateSnapshotAfterSourceReplacement() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = parent.appendingPathComponent("project")
        let storage = parent.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let original = project.appendingPathComponent("notes.txt")
        let bytes = Data("selected content".utf8)
        try bytes.write(to: original)
        let attachments = try CodexAttachments(root: storage)
        let id = UUID().uuidString
        _ = try attachments.reference("notes.txt", cwd: project.path, id: id, device: "phone", thread: "thread")
        let outside = parent.appendingPathComponent("private.txt")
        try Data("outside content".utf8).write(to: outside)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        let selected = try attachments.selected([id], device: "phone", thread: "thread")
        let copy = URL(fileURLWithPath: try XCTUnwrap(selected.files.first?["fsPath"] as? String))
        XCTAssertNotEqual(copy.path, original.path)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        let reloaded = try CodexAttachments(root: storage)
        XCTAssertEqual(
            try reloaded.selected([id], device: "phone", thread: "thread").files.first?["fsPath"] as? String, copy.path)
        XCTAssertThrowsError(
            try attachments.reference(
                "notes.txt", cwd: project.path, id: UUID().uuidString, device: "phone", thread: "thread"))
        XCTAssertThrowsError(try attachments.selected([id], device: "other", thread: "thread"))
    }

    func testAttachmentOverflowAndSpecialFilesAreRefused() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let attachments = try CodexAttachments(root: parent.appendingPathComponent("attachments"))
        let id = UUID().uuidString
        _ = try attachments.start(
            ["attachmentId": id, "name": "test.txt", "size": 4], device: "phone", thread: "thread")
        XCTAssertThrowsError(
            try attachments.chunk(
                ["attachmentId": id, "offset": Int.max, "data": "YQ=="], device: "phone", thread: "thread"))
        let fifo = parent.appendingPathComponent("pipe.txt")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(
            try attachments.reference(
                "pipe.txt", cwd: parent.path, id: UUID().uuidString, device: "phone", thread: "thread"))
    }
}
