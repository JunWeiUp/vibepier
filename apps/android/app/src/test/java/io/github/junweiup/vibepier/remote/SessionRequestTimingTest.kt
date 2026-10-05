package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionAgentProtocol
import io.github.junweiup.vibepier.remote.core.session.SessionRequestTiming
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class SessionRequestTimingTest {
    @Test fun nativeProfileMutationsHavePreparationTimeWhileReadsKeepTheirDeadline() {
        for (method in SessionAgentProtocol.Method.entries) {
            val body = JSONObject().put("method", method.wire)
            val expected = when (method) {
                SessionAgentProtocol.Method.CREATE -> 120_000L
                SessionAgentProtocol.Method.CONFIGURE, SessionAgentProtocol.Method.SUBMIT -> 60_000L
                else -> if (method.mutation) 30_000L else 12_000L
            }
            assertEquals(method.wire, expected, SessionRequestTiming.initial(12_000, 0, "agentRequest", body))
            assertEquals(4_000L, SessionRequestTiming.initial(4_000, 4_000, "agentRequest", body))
        }
        assertEquals(60_000L, SessionRequestTiming.initial(45_000, 0, "agentRequest", JSONObject().put("method", "message.submit")))
        assertEquals(12_000L, SessionRequestTiming.initial(12_000, 0, "agentRequest", JSONObject()))
        assertEquals(30_000L, SessionRequestTiming.initial(12_000, 0, "new", null))
    }
}
