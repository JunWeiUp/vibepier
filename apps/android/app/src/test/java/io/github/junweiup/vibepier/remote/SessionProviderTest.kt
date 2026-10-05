package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionProvider

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionProviderTest {
    @Test fun zcodeKeepsItsIdentityAndSeparateThreadScope() {
        assertEquals("zcode", SessionProvider.normalize("zcode"))
        assertEquals("ZCode", SessionProvider.name("zcode"))
        assertFalse(SessionProvider.scope("zcode", "same") == SessionProvider.scope("codex", "same"))
        assertFalse(SessionProvider.scope("zcode", "same") == SessionProvider.scope("claude", "same"))
        assertEquals("codex", SessionProvider.normalize("unknown"))
    }

    @Test fun everyProviderRequiresAnExplicitCapability() {
        assertFalse(SessionProvider.supports("zcode", null))
        assertTrue(SessionProvider.supports("zcode", true))
        assertFalse(SessionProvider.supports("zcode", false))
        assertFalse(SessionProvider.supports("codex", null))
        assertFalse(SessionProvider.supports("claude", null))
        assertFalse(SessionProvider.supports("claude", null, legacyDefault = false))
        assertFalse(SessionProvider.supports("codex", false))
    }
}
