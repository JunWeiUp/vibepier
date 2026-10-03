import Foundation
import XCTest

@testable import VibePierCore

final class SessionCreationDraftTests: XCTestCase {
    func testDraftScopeBindsProviderProjectAndUUIDAndCannotMasqueradeAsNativeThread() throws {
        let id = UUID().uuidString
        let request: [String: Any] = ["draftId": id, "cwd": "/fixture/project", "threadId": "caller-chosen-thread"]
        let first = try SessionCreationDraft(request, project: "/fixture/project", provider: "codex")
        XCTAssertNil(UUID(uuidString: first.scope))
        XCTAssertEqual(first.id, id.lowercased())
        XCTAssertNotEqual(first.scope, try SessionCreationDraft(request, project: first.cwd, provider: "claude").scope)
        XCTAssertNotEqual(
            first.scope,
            try SessionCreationDraft(["draftId": id, "cwd": "/other"], project: "/other", provider: "codex").scope)
        XCTAssertThrowsError(try SessionCreationDraft(request, project: "/other", provider: "codex"))
        XCTAssertThrowsError(
            try SessionCreationDraft(
                ["draftId": "not-a-draft", "cwd": first.cwd], project: first.cwd, provider: "codex"))
    }

    func testDraftUploadCannotBeReadByAnotherPhoneProjectOrNativeThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try CodexAttachments(root: root)
        let draft = try SessionCreationDraft(
            ["draftId": UUID().uuidString, "cwd": "/fixture"], project: "/fixture", provider: "claude")
        let attachment = UUID().uuidString
        let body = Data("selected fixture".utf8)
        _ = try draft.attachment(
            ["op": "newAttachmentStart", "attachmentId": attachment, "name": "note.txt", "size": body.count],
            storage: storage, device: "phone")
        _ = try draft.attachment(
            ["op": "newAttachmentChunk", "attachmentId": attachment, "offset": 0, "data": body.base64EncodedString()],
            storage: storage, device: "phone")
        _ = try draft.attachment(
            ["op": "newAttachmentComplete", "attachmentId": attachment, "sha256": CodexConversation.dataHash(body)],
            storage: storage, device: "phone")
        XCTAssertThrowsError(try storage.selected([attachment], device: "other", thread: draft.scope))
        XCTAssertThrowsError(try storage.selected([attachment], device: "phone", thread: draft.id))
        let other = try SessionCreationDraft(
            ["draftId": draft.id, "cwd": "/other"], project: "/other", provider: "claude")
        XCTAssertThrowsError(try storage.selected([attachment], device: "phone", thread: other.scope))
        XCTAssertEqual(try storage.selected([attachment], device: "phone", thread: draft.scope).files.count, 1)
        XCTAssertThrowsError(
            try draft.attachment(["op": "send", "text": "not an upload"], storage: storage, device: "phone"))
    }
}
