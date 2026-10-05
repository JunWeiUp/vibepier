package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionProviderAccess
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionProviderAccessTest {
    @Test fun disabledProviderDoesNotExposeListsOrExecuteButReceiptsSurvive() {
        val policy = SessionProviderAccess(4, setOf("claude"))
        assertEquals(listOf("claude"), policy.ids)
        for (op in listOf("list", "projects", "open", "send", "new", "approve", "readImageFile")) {
            assertFalse(op, policy.permits("codex", op))
            assertTrue(op, policy.permits("claude", op))
        }
        for (op in listOf("receipt", "newReceiptCheck", "close", "applications", "lockScreen", "notificationSubscribe")) {
            assertTrue(op, policy.permits("codex", op))
        }
        assertFalse(policy.permits("claude", "codexUsage"))
        assertFalse(policy.permits("future-agent", "send"))
    }

    @Test fun staleOrConflictingPolicyCannotRestoreDisabledProviders() {
        val disabled = SessionProviderAccess(5, emptySet())
        assertFalse(SessionProviderAccess.legacy.replaces(disabled))
        assertFalse(SessionProviderAccess(5, setOf("codex")).replaces(disabled))
        assertTrue(SessionProviderAccess(6, setOf("claude")).replaces(disabled))
        assertTrue(disabled.replaces(disabled))
        assertTrue(disabled.ids.isEmpty())
        assertEquals(disabled, SessionProviderAccess.decode(disabled.json()))
    }

    @Test fun malformedFlagsAndRevisionFailClosed() {
        val valid = SessionProviderAccess(1, setOf("codex")).json()
        for (revision in listOf(-1, true, "1", 1.5, "9223372036854775808")) {
            assertNull(SessionProviderAccess.decode(JSONObject(valid.toString()).put("revision", revision)))
        }
        assertNull(SessionProviderAccess.decode(JSONObject(valid.toString()).apply { getJSONObject("enabled").put("claude", "false") }))
        assertNull(SessionProviderAccess.decode(JSONObject(valid.toString()).apply { getJSONObject("enabled").remove("zcode") }))
        assertEquals(listOf("codex"), SessionProviderAccess.decode(valid)?.ids)
    }
}
