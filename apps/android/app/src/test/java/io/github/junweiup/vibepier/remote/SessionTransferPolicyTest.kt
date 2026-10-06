package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionTransferPolicy
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionTransferPolicyTest {
    @Test fun retiredChunkRPCsAndNegotiationHintsAreRejected() {
        for (op in listOf("apkChunk", "attachmentChunk", "newAttachmentChunk")) {
            assertFalse(SessionTransferPolicy.accepts(op, JSONObject()))
        }
        for (field in listOf("downloadVersion", "downloadToken", "uploadVersion", "uploadFragmentChars")) {
            assertFalse(field, SessionTransferPolicy.accepts("attachmentStart", JSONObject().put(field, 1)))
        }
    }
    @Test fun binaryMetadataAndOrdinarySessionControlStillUseCurrentEnvelope() {
        for (op in listOf("apkOffer", "apkBinary", "apkStatus", "apkProgress", "attachmentStart", "attachmentComplete",
            "newAttachmentStart", "newAttachmentComplete", "fileCancel", "agentRequest", "lockScreen", "resend")) {
            assertTrue(op, SessionTransferPolicy.accepts(op, JSONObject().put("binaryVersion", 1)))
        }
    }
}
