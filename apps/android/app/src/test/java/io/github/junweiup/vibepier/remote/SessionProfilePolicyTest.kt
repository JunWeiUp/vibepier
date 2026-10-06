package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.*
import org.junit.Assert.*
import org.junit.Test

class SessionProfilePolicyTest {
    @Test fun independentJournalNeverExecutesSessionMutations() {
        for (op in listOf("send", "new", "settings", "interrupt", "approve", "queueSteer", "queueDelete")) {
            assertTrue(op in SessionProfilePolicy.operations)
            assertFalse(SessionProfilePolicy.independentMutation(op))
        }
        for (op in listOf("lockScreen", "unlockScreen", "codexUsageReset")) {
            assertTrue(SessionProfilePolicy.independentMutation(op))
            assertTrue(SessionV1Contract.operation(op)!!.durableMutation)
            assertFalse(op in SessionProfilePolicy.operations)
        }
        assertFalse(SessionProfilePolicy.independentMutation("unknown"))
    }
    @Test fun binaryMediaFilesAndControlAreNotMistakenForOldSessionWire() {
        for (op in listOf("agentRequest", "providers", "resend", "notificationSubscribe", "fileCancel", "image", "readFile",
            "readImageFile", "readVideoFile", "readMarkdownFile", "browseFiles", "openFile", "fileChanges", "fileDiff",
            "searchFiles", "attachmentStart", "attachmentComplete", "attachmentRemove", "attachmentPreview", "attachmentReference",
            "newAttachmentStart", "newAttachmentComplete", "newAttachmentRemove", "codexUsageResetReceipt", "screenLockPassword")) {
            assertFalse(op, op in SessionProfilePolicy.operations)
        }
        assertTrue("contextUsage" in SessionProfilePolicy.operations)
    }
}
