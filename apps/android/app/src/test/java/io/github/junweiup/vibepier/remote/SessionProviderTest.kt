package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.*
import io.github.junweiup.vibepier.remote.features.sessions.ConversationViewState
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class SessionProviderTest {
    @Test fun retiredIdentityNeverBecomesASupportedProviderOrRestoredConversation() {
        val retired = "retired-provider"
        assertEquals(listOf("codex", "claude"), SessionProvider.ids)
        assertEquals(retired, SessionProvider.normalize(retired))
        assertEquals("codex", SessionProvider.normalize(null))
        for (provider in SessionProvider.ids) {
            assertNotEquals(SessionProvider.scope(retired, "same"), SessionProvider.scope(provider, "same"))
        }
        assertFalse(SessionProvider.supports(retired, true))
        val navigation = JSONObject().put("source", "mac").put("provider", retired).put("thread", "same").put("drawer", false)
        assertNull(ConversationViewState.read(navigation, "mac"))
        val draft = SessionCreationDraft(UUID.randomUUID().toString(), retired, "/project", "hello")
        assertThrows(IllegalArgumentException::class.java) { SessionCreationDraft.restore(draft.value().toString(), draft.cwd, retired) }
        assertThrows(IllegalArgumentException::class.java) { SessionCreationDraft.restore(draft.value().toString(), draft.cwd, "codex") }
        assertThrows(IllegalArgumentException::class.java) { draft.request(UUID.randomUUID().toString(), JSONArray()) }
    }

    @Test fun retiredSelectionLeavesOldTabWhenPolicyIsKnownWithoutRewritingIdentity() {
        val persisted = SessionProvider.normalize("retired-provider")
        assertEquals("codex", SessionProvider.selection(persisted, listOf("codex", "claude")))
        assertEquals("claude", SessionProvider.selection(persisted, listOf("claude")))
        assertNull(SessionProvider.selection(persisted, emptyList()))
        assertNull(SessionProvider.selection(persisted, listOf("retired-provider")))
        assertEquals("claude", SessionProvider.selection("claude", listOf("codex", "claude")))
        assertEquals("retired-provider", persisted)
    }

    @Test fun everyProviderRequiresAnExplicitCapability() {
        for (provider in SessionProvider.ids) {
            assertFalse(SessionProvider.supports(provider, null))
            assertTrue(SessionProvider.supports(provider, true))
            assertFalse(SessionProvider.supports(provider, false))
        }
    }
}
