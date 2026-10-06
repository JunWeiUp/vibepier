import XCTest

@testable import VibePierCore

final class SessionPhonePolicyTests: XCTestCase {
    func testOldSessionBusinessRPCsAreRejectedEvenWithCapabilityOneFields() throws {
        for op in [
            "list", "projects", "open", "close", "sync", "history", "parts", "message", "newOptions",
            "composerOptions", "new", "send", "settings", "interrupt", "approve", "approvalDetails",
            "queueSteer", "queueDelete", "receiptCheck", "newReceiptCheck", "settingsReceiptCheck",
            "contextUsage", "interruptReceiptCheck", "queueReceiptCheck", "apkChunk", "attachmentChunk",
            "newAttachmentChunk",
        ] {
            let response = try XCTUnwrap(
                SessionRemote.rejectedPhoneSession(
                    [
                        "id": "operation", "op": op, "provider": "codex", "agentCapabilityVersion": 1,
                        "agentAdapterId": "codex.currentV1", "agentCapabilityRevision": "previous",
                    ], recorded: false, journalReliable: true), op)
            XCTAssertEqual(response["ok"] as? Bool, false, op)
            XCTAssertEqual(response["code"] as? String, "agent_upgrade_required", op)
        }
    }

    func testTextTransferOperationsHaveNoCurrentContractDescriptor() {
        for op in ["apkChunk", "attachmentChunk", "newAttachmentChunk"] {
            XCTAssertNil(SessionV1Contract.descriptor(op))
            XCTAssertNotNil(SessionRemote.rejectedPhoneSession(["op": op], recorded: false, journalReliable: true))
        }
        for op in [
            "attachmentStart", "attachmentComplete", "attachmentReference", "newAttachmentStart",
            "newAttachmentComplete", "apkBinary",
        ] {
            XCTAssertNotNil(SessionV1Contract.descriptor(op))
        }
    }

    func testCurrentAuxiliaryEnvelopeAndProfileTwoEntryAreNotBlocked() {
        for op in [
            "agentRequest", "providers", "notificationSubscribe", "receipt", "appshot", "appshotApps",
            "attachmentComplete", "attachmentPreview", "attachmentReference",
            "attachmentRemove", "attachmentStart", "browseFiles", "fileChanges", "fileDiff",
            "image", "newAttachmentComplete", "newAttachmentRemove", "newAttachmentStart",
            "openFile", "readFile", "readImageFile", "readMarkdownFile", "readVideoFile", "searchFiles",
            "applications", "applicationShortcutSet", "lockScreen", "unlockScreen", "unlockStatus",
            "unlockPassword", "codexUsage", "codexUsageReset", "apkOffer", "apkStatus",
        ] {
            XCTAssertNil(
                SessionRemote.rejectedPhoneSession(
                    ["id": "operation", "op": op], recorded: false,
                    journalReliable: true), op)
        }
    }

    func testRejectedOldMutationDoesNotClaimKnownOrUnreadableJournalIsSafeToRetry() throws {
        for op in ["new", "send", "settings", "interrupt", "approve", "queueDelete", "queueSteer"] {
            for (recorded, reliable) in [(true, true), (false, false), (false, true)] {
                let reply = try XCTUnwrap(
                    SessionRemote.rejectedPhoneSession(
                        ["op": op, "id": "operation"],
                        recorded: recorded, journalReliable: reliable))
                XCTAssertEqual(reply["unknown"] as? Bool == true, recorded || !reliable)
            }
        }
    }

    func testEnvelopeReceiptCannotReconcileOldSessionOperations() {
        for op in ["new", "send", "approve", "settings", "interrupt", "queueDelete", "queueSteer", "", "unknown"] {
            XCTAssertFalse(SessionRemote.canReconcileEnvelopeReceipt(["op": op]))
        }
        XCTAssertTrue(SessionRemote.canReconcileEnvelopeReceipt(["op": "codexUsageReset"]))
    }
}
