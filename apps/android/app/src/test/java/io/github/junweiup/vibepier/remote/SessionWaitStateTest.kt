package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.sessions.SessionWaitState
import org.junit.Assert.*
import org.junit.Test

class SessionWaitStateTest {
    @Test fun diagnosesPreferConnectionAndUnconfirmedReceiptsOverStaleProviderErrors() {
        fun reason(connected: Boolean = true, ready: Boolean = true, unknown: Boolean = false, approvals: Boolean = false) =
            SessionWaitState.reason(connected, ready, unknown, approvals, "rateLimit", "active", 70_000)
        assertEquals(SessionWaitState.Reason.DISCONNECTED, reason(connected = false))
        assertEquals(SessionWaitState.Reason.UNKNOWN, reason(unknown = true))
        assertEquals(SessionWaitState.Reason.LOADING, reason(ready = false))
        assertEquals(SessionWaitState.Reason.APPROVAL, reason(approvals = true))
        assertEquals(SessionWaitState.Reason.RATE_LIMIT, reason())
    }
    @Test fun silenceDoesNotDeclareAFailureAndIdleDoesNotLookBlocked() {
        assertNull(SessionWaitState.reason(true, true, false, false, "", "active", 59_999))
        assertEquals(SessionWaitState.Reason.SLOW, SessionWaitState.reason(true, true, false, false, "", "active", 60_000))
        assertNull(SessionWaitState.reason(true, true, false, false, "", "idle", 99_999))
        assertEquals(SessionWaitState.Reason.API_ERROR, SessionWaitState.reason(true, true, false, false, "apiError", "idle", 0))
    }
    @Test fun stoppingRequiresFreshTargetAndNeverResubmitsAnUnconfirmedStop() {
        assertTrue(SessionWaitState.canStop(true, true, true, true, "turn", false, false))
        assertFalse(SessionWaitState.canStop(true, true, true, true, "", false, false))
        assertFalse(SessionWaitState.canStop(false, true, true, true, "turn", false, false))
        assertFalse(SessionWaitState.canStop(true, false, true, true, "turn", false, false))
        assertFalse(SessionWaitState.canStop(true, true, false, true, "turn", false, false))
        assertFalse(SessionWaitState.canStop(true, true, true, false, "turn", false, false))
        assertFalse(SessionWaitState.canStop(true, true, true, true, "turn", true, false))
        assertFalse(SessionWaitState.canStop(true, true, true, true, "turn", false, true))
    }
}
