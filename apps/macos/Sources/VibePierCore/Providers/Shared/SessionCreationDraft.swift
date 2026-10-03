import Foundation

/// A creation draft has no native thread yet. Bind uploads to the verified native
/// project and a phone-generated draft UUID instead of pretending a thread is open.
struct SessionCreationDraft: Sendable {
    static let attachmentOperations: Set<String> = [
        "newAttachmentStart", "newAttachmentChunk", "newAttachmentComplete", "newAttachmentRemove",
    ]
    let id: String
    let cwd: String
    let scope: String

    /// The provider must resolve `project` from its own known-project catalog first.
    init(_ request: [String: Any], project: String, provider: String) throws {
        guard ["codex", "claude", "zcode"].contains(provider),
            let raw = request["draftId"] as? String, let uuid = UUID(uuidString: raw),
            request["cwd"] as? String == project, project.hasPrefix("/"),
            project.utf8.count <= 4096, !project.contains("\0")
        else { throw CLIError(L10n.text("core.invalid_request")) }
        id = uuid.uuidString.lowercased()
        cwd = project
        scope = "new:" + provider + ":" + id + ":" + CodexConversation.dataHash(Data(project.utf8))
    }

    func attachment(_ request: [String: Any], storage: CodexAttachments, device: String) throws -> [String: Any] {
        switch request["op"] as? String {
        case "newAttachmentStart": return try storage.start(request, device: device, thread: scope)
        case "newAttachmentChunk": return try storage.chunk(request, device: device, thread: scope)
        case "newAttachmentComplete": return try storage.complete(request, device: device, thread: scope)
        case "newAttachmentRemove":
            try storage.remove(request["attachmentId"] as? String ?? "", device: device, thread: scope)
            return [:]
        default: throw CLIError(L10n.text("session.unsupported_attachment_operation"))
        }
    }
}
