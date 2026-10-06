package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft
import io.github.junweiup.vibepier.remote.core.session.SessionCreationWaitState
import io.github.junweiup.vibepier.remote.core.session.SessionWaitingPolicy
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionCreationWaitStateTest {
    private fun original(id: String = "original", draft: String = "old-draft") = JSONObject()
        .put("id", id).put("op", "new").put("provider", "codex").put("cwd", "/project")
        .put("draftId", draft).put("text", "old prompt").put("attachments", JSONArray().put("old-file"))

    @Test fun stoppedWaitReleasesComposerAndRejectsLateSendAndReceiptReplies() {
        val pending = original()
        val encoded = pending.toString()
        val waits = SessionCreationWaitState()
        val sent = waits.begin(pending)
        val query = waits.begin(pending)
        assertFalse(waits.accepts(sent))
        assertTrue(waits.accepts(query))

        val oldDraft = SessionCreationDraft("old-draft", "codex", "/project", "old prompt")
        val fresh = SessionWaitingPolicy.freshCreationDraft(oldDraft, listOf(pending))
        waits.stop()
        assertFalse(waits.accepts(sent))
        assertFalse(waits.accepts(query))
        assertTrue(waits.accepts(waits.draftToken(fresh.id), fresh.id))
        assertNotEquals(oldDraft.id, fresh.id)
        assertEquals("", fresh.text)
        assertEquals(encoded, pending.toString())
        assertTrue(SessionWaitingPolicy.duplicateCreation(listOf(pending), "/project", "old prompt", JSONArray()))
        assertTrue(SessionWaitingPolicy.duplicateCreation(listOf(pending), "/project", "different", JSONArray().put("old-file")))
        assertFalse(SessionWaitingPolicy.duplicateCreation(listOf(pending), "/project", "different", JSONArray()))
    }

    @Test fun oldRepliesCannotChangeASecondCreationOrItsWaitingState() {
        val waits = SessionCreationWaitState()
        val first = waits.begin(original())
        waits.stop()
        val second = waits.begin(original("second", "new-draft"))
        assertFalse(waits.accepts(first))
        assertTrue(waits.accepts(second))
        assertFalse(waits.accepts(waits.draftToken("new-draft"), "new-draft"))
    }

    @Test fun checkingTheOriginalAgainGetsANewCallbackIdentity() {
        val waits = SessionCreationWaitState()
        val old = waits.begin(original())
        waits.stop()
        val checking = waits.begin(original())
        assertFalse(waits.accepts(old))
        assertTrue(waits.accepts(checking))
    }

    @Test fun lateOptionOrAttachmentRepliesCannotUnlockOrWriteIntoTheNewDraft() {
        val waits = SessionCreationWaitState()
        val oldRead = waits.draftToken("old-draft")
        assertTrue(waits.accepts(oldRead, "old-draft"))
        assertFalse(waits.accepts(oldRead, "different-draft"))
        waits.begin(original())
        assertFalse(waits.accepts(oldRead, "old-draft"))
        waits.stop()
        assertFalse(waits.accepts(oldRead, "old-draft"))
        val fresh = waits.draftToken("new-draft")
        assertTrue(waits.accepts(fresh, "new-draft"))
    }

    @Test fun stoppingAnEarlierReceiptPreservesAnExistingIndependentDraft() {
        val pending = original()
        val fresh = SessionCreationDraft("new-draft", "codex", "/project", "different")
        assertEquals(fresh, SessionWaitingPolicy.freshCreationDraft(fresh, listOf(pending)))
        assertFalse(fresh.matches(pending))
    }

    @Test fun cancellingReceiptQueriesNeverCancelsOriginalMutationsOrUnrelatedReads() {
        val operation = "original"
        val legacyRead = JSONObject().put("op", "receipt").put("operation", operation)
        fun agent(method: String, id: String) = JSONObject().put("op", "agentRequest")
            .put("body", JSONObject().put("method", method).put("params", JSONObject().put("operationId", id)))
        assertFalse(SessionCreationWaitState.isReceiptRead(legacyRead, operation))
        assertTrue(SessionCreationWaitState.isReceiptRead(agent("operation.get", operation), operation))
        assertFalse(SessionCreationWaitState.isReceiptRead(original(), operation))
        assertFalse(SessionCreationWaitState.isReceiptRead(agent("session.create", operation), operation))
        assertFalse(SessionCreationWaitState.isReceiptRead(agent("operation.get", "other"), operation))
        assertFalse(SessionCreationWaitState.isReceiptRead(legacyRead, ""))
        assertFalse(SessionCreationWaitState.isReceiptRead(JSONObject().put("op", "newOptions").put("operation", operation), operation))
    }
}
