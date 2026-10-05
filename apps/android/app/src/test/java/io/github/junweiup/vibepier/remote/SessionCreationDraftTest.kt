package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class SessionCreationDraftTest {
    @Test fun originalRequestKeepsAllSelectionsAfterDraftChanges() {
        val draft = SessionCreationDraft.restore(null, "/fixture", "codex").copy(
            text = " Inspect this picture ", model = "fixture-model", effort = "high", mode = "auto", serviceTier = "priority")
        val id = UUID.randomUUID().toString()
        val attachment = UUID.randomUUID().toString()
        val attachments = JSONArray().put(attachment)
        val request = draft.request(id, attachments)
        attachments.put(UUID.randomUUID().toString())
        val changed = draft.copy(model = "different", text = "new draft")
        assertEquals("fixture-model", request.getString("model"))
        assertEquals("Inspect this picture", request.getString("text"))
        assertEquals(1, request.getJSONArray("attachments").length())
        assertEquals(draft.id, request.getString("draftId"))
        assertEquals("priority", request.getString("serviceTier"))
        assertTrue(draft.matches(request))
        assertFalse(draft.copy(serviceTier = "standard").matches(request))
        assertNotEquals(changed.model, request.getString("model"))
        assertEquals(draft, SessionCreationDraft.restore(draft.value().toString(), "/fixture", "codex"))
    }

    @Test fun storedDraftCannotCrossProjectsProvidersOrTurnTextIntoConfirmation() {
        val draft = SessionCreationDraft.restore(null, "/fixture", "claude")
        assertThrows(IllegalArgumentException::class.java) { SessionCreationDraft.restore(draft.value().toString(), "/other", "claude") }
        assertThrows(IllegalArgumentException::class.java) { SessionCreationDraft.restore(draft.value().toString(), "/fixture", "codex") }
        assertThrows(IllegalStateException::class.java) { SessionCreationDraft.restore(draft.value().put("confirmFullAccess", "true").toString(), "/fixture", "claude") }
        assertNotEquals(SessionCreationDraft.key("/a/b"), SessionCreationDraft.key("/a.b"))
    }

    @Test fun firstMessageAcceptsImagesWithoutTextButRejectsDuplicateOrOversizedInput() {
        val draft = SessionCreationDraft.restore(null, "/fixture", "codex")
        val id = UUID.randomUUID().toString()
        val attachment = UUID.randomUUID().toString()
        assertEquals("", draft.request(id, JSONArray().put(attachment)).getString("text"))
        assertThrows(IllegalArgumentException::class.java) { draft.request(id, JSONArray()) }
        assertThrows(IllegalArgumentException::class.java) { draft.request(id, JSONArray().put(attachment).put(attachment.uppercase())) }
        assertThrows(IllegalArgumentException::class.java) { draft.copy(text = "字".repeat(11_000)).request(id, JSONArray()) }
    }
}
