package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.ApprovalNotifications
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ApprovalNotificationsTest {
    private fun row(fingerprint: String) = JSONObject().put("fingerprint", fingerprint).put("canDecide", true)
        .put("title", "Run tests").put("revision", "r1").put("allowedDecisions", JSONArray().put("allow").put("deny"))

    @Test fun onlyPlainDecidableRequestsAreOfferedOnTheLockScreen() {
        val page = JSONObject().put("threadId", "thread").put("approvals", JSONArray()
            .put(row("plain"))
            .put(row("question").put("kind", "questions"))
            .put(row("options").put("options", JSONArray().put("Always")))
            .put(row("partial").put("detailsOnDemand", true))
            .put(row("blocked").put("canDecide", false))
            .put(row("once-only").put("allowedDecisions", JSONArray().put("allow"))))
        val offers = ApprovalNotifications.offers("codex", page)
        assertEquals(listOf("plain"), offers.map { it.fingerprint })
        assertEquals("thread", offers.single().thread)
        assertTrue(ApprovalNotifications.offers("other", page).isEmpty())
        assertTrue(ApprovalNotifications.offers("codex", JSONObject(page.toString()).put("threadId", "")).isEmpty())
    }
    @Test fun decisionIsBoundToThePostingAuthorizationAndKeepsTheRevision() {
        val allow = ApprovalNotifications.decision("codex", "thread", "fp", "auth", "auth", true, "r1")!!
        assertEquals(true, allow.getBoolean("allow"))
        assertEquals("r1", allow.getString("expectedApprovalRevision"))
        assertEquals("fp", allow.getString("fingerprint"))
        assertNull(ApprovalNotifications.decision("codex", "thread", "fp", "old", "auth", true, "r1"))
        assertNull(ApprovalNotifications.decision("codex", "thread", "", "auth", "auth", false, null))
        assertNull(ApprovalNotifications.decision("codex", "", "fp", "auth", "auth", false, null))
    }
}
