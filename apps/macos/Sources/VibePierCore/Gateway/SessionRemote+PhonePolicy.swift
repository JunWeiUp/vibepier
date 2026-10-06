import Foundation

extension SessionRemote {
    /// These auxiliary RPCs still use the authenticated session1 envelope. Conversation operations use profile 2.
    static func requiresProfileTwo(_ operation: String) -> Bool {
        guard SessionV1Contract.descriptor(operation)?.routeDomain == "session" else { return false }
        return ![
            "appshot", "appshotApps", "attachmentComplete", "attachmentPreview",
            "attachmentReference", "attachmentRemove", "attachmentStart", "browseFiles",
            "fileChanges", "fileDiff", "image", "newAttachmentComplete",
            "newAttachmentRemove", "newAttachmentStart", "openFile", "readFile", "readImageFile",
            "readMarkdownFile", "readVideoFile", "searchFiles",
        ].contains(operation)
    }

    static func rejectedPhoneSession(
        _ request: [String: Any], recorded: Bool, journalReliable: Bool
    ) -> [String: Any]? {
        let operation = request["op"] as? String ?? ""
        // Retired text chunks must remain rejected even after their internal descriptors are removed.
        let retiredTransfer = ["apkChunk", "attachmentChunk", "newAttachmentChunk"].contains(operation)
        guard requiresProfileTwo(operation) || retiredTransfer else { return nil }
        var reply: [String: Any] = [
            "id": request["id"] ?? "", "ok": false, "code": "agent_upgrade_required",
            "error": L10n.text("agent.upgrade_required"),
        ]
        // Rejection is not proof that an earlier operation was never executed. Do not reserve or overwrite its ID.
        if SessionV1Contract.descriptor(operation)?.durableMutation == true && (recorded || !journalReliable) {
            reply["unknown"] = true
        }
        return reply
    }

    /// Old session receipts remain readable, but cannot reopen a retired provider execution/reconciliation path.
    /// Account reset is still a current envelope RPC with its own verified read-only receipt operation.
    static func canReconcileEnvelopeReceipt(_ original: [String: Any]) -> Bool {
        original["op"] as? String == "codexUsageReset"
    }
}
