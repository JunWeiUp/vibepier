package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionWaitingPolicy
import io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionWaitingPolicyTest {
    @Test fun stoppedCreationRetainsDuplicateProtectionButAllowsDifferentMessagesAndProjects() {
        val pending = JSONObject().put("id", "operation-a").put("op", "new").put("cwd", "/project").put("text", "hello").put("attachments", JSONArray().put("file-1"))
        assertTrue(SessionWaitingPolicy.duplicateCreation(listOf(pending), "/project", " hello ", JSONArray()))
        assertTrue(SessionWaitingPolicy.duplicateCreation(listOf(pending), "/project", "different", JSONArray().put("file-1")))
        assertFalse(SessionWaitingPolicy.duplicateCreation(listOf(pending), "/project", "different", JSONArray()))
        assertFalse(SessionWaitingPolicy.duplicateCreation(listOf(pending), "/other", "hello", JSONArray()))
        assertFalse(SessionWaitingPolicy.duplicateCreation(listOf(pending), "/project", "hello", JSONArray(), "operation-a"))
    }
    @Test fun stoppingProjectWaitIncludesEveryOldCreationButIsolatesOtherProjectsAndProviders() {
        fun pending(id: String, provider: String = "zcode", cwd: String = "/project", op: String = "new") =
            JSONObject().put("id", id).put("provider", provider).put("cwd", cwd).put("op", op)
        val operations = listOf(pending("old"), pending("new"), pending("other", cwd = "/other"),
            pending("claude", provider = "claude"), pending("send", op = "send"))
        assertEquals(listOf("old", "new"), SessionWaitingPolicy.creationWaits(operations, "zcode", "/project").map { it.getString("id") })
        assertEquals(5, operations.size)
    }
    @Test fun legacyCreationWithoutDraftIdReleasesOldTextAndKeepsReceipt() {
        val draft = SessionCreationDraft("draft", "zcode", "/project", "hi")
        val old = JSONObject().put("id", "old").put("provider", "zcode").put("cwd", "/project").put("op", "new").put("text", "hi")
        val fresh = SessionWaitingPolicy.freshCreationDraft(draft, listOf(old))
        assertNotEquals(draft.id, fresh.id)
        assertEquals("", fresh.text)
        assertTrue(SessionWaitingPolicy.duplicateCreation(listOf(old), "/project", "hi", JSONArray()))
        old.put("draftId", "other-draft")
        assertEquals(draft, SessionWaitingPolicy.freshCreationDraft(draft, listOf(old)))
        old.put("draftId", draft.id)
        assertEquals("", SessionWaitingPolicy.freshCreationDraft(draft, listOf(old)).text)
    }
    private val send = JSONObject().put("op", "send").put("text", "hello").put("attachments", JSONArray().put("file-1"))
    @Test fun stoppedWaitStillPreventsRepeatingTextOrAttachments() {
        assertTrue(SessionWaitingPolicy.duplicateSend(listOf(send), " hello ", JSONArray()))
        assertTrue(SessionWaitingPolicy.duplicateSend(listOf(send), "different", JSONArray().put("file-1")))
        assertFalse(SessionWaitingPolicy.duplicateSend(listOf(send), "different", JSONArray().put("file-2")))
        assertFalse(SessionWaitingPolicy.duplicateSend(emptyList(), "hello", JSONArray().put("file-1")))
    }
    @Test fun unrelatedOperationsAndEmptyDraftsDoNotBlockANewMessage() {
        assertFalse(SessionWaitingPolicy.duplicateSend(listOf(JSONObject().put("op", "settings").put("text", "hello")), "hello", JSONArray()))
        assertFalse(SessionWaitingPolicy.duplicateSend(listOf(send), "", JSONArray()))
    }
}
