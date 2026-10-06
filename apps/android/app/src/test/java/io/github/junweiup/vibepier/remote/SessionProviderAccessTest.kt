package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionProviderAccess
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionProviderAccessTest {
    @Test fun freshInitAndMissingPolicyNeverGrantProfileAuthority() {
        assertNull(SessionProviderAccess.decode(null))
        val profileOnly = JSONObject().put("ok", true).put("agentProfiles", JSONObject().put("versions", org.json.JSONArray().put(2)))
        assertFalse(SessionProviderAccess.acceptsProfile(profileOnly, null))
        val previous = SessionProviderAccess(3, setOf("codex"))
        assertFalse(SessionProviderAccess.acceptsProfile(profileOnly, previous))
        assertTrue(SessionProviderAccess.acceptsProfile(profileOnly.put("providerAccess", previous.json()), previous))
        assertFalse(SessionProviderAccess.acceptsProfile(profileOnly.put("ok", "true"), previous))
        profileOnly.put("ok", true).put("providerAccess", SessionProviderAccess(2, setOf("codex", "claude")).json())
        assertFalse(SessionProviderAccess.acceptsProfile(profileOnly, previous))
    }

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

    @Test fun retiredPersistedPolicyFlagsCannotRestoreAnEntryOrAuthorizeIt() {
        val saved = SessionProviderAccess(4, setOf("claude")).json()
        saved.getJSONObject("enabled").put("retired-provider", true)
        val restored = SessionProviderAccess.decode(saved)!!
        assertEquals(listOf("claude"), restored.ids)
        assertFalse(restored.permits("retired-provider", "send"))
        assertTrue(restored.permits("retired-provider", "receiptCheck"))
    }

    @Test fun staleOrConflictingPolicyCannotRestoreDisabledProviders() {
        val disabled = SessionProviderAccess(5, emptySet())
        assertFalse(SessionProviderAccess(0, setOf("codex", "claude")).replaces(disabled))
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
        assertNull(SessionProviderAccess.decode(JSONObject(valid.toString()).apply { getJSONObject("enabled").remove("claude") }))
        assertEquals(listOf("codex"), SessionProviderAccess.decode(valid)?.ids)
    }
}
