package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionPageReadCancellationTest {
    private fun request(method: String) = JSONObject().put("op", "agentRequest")
        .put("body", JSONObject().put("method", method))

    @Test fun pageCancellationKeepsMutationPreparationAndReceiptCallbacks() {
        for (method in listOf("session.snapshot", "session.creationOptions", "workspace.list", "operation.get")) {
            val pending = linkedMapOf("preserved" to request(method), "ordinary" to request("session.list"))
            pending.entries.removeAll { shouldCancelSessionPageRead(it.value, it.key == "preserved") }
            assertEquals("$method preparation/receipt must finish after leaving page", setOf("preserved"), pending.keys)
        }
    }
    @Test fun pageCancellationRemovesOrdinaryReadsButNeverMutationTransports() {
        assertTrue(shouldCancelSessionPageRead(request("session.snapshot"), false))
        assertTrue(shouldCancelSessionPageRead(JSONObject().put("op", "newOptions"), false))
        assertFalse(shouldCancelSessionPageRead(JSONObject().put("op", "newOptions"), true))
        for (method in listOf("session.create", "message.submit", "session.configure")) {
            assertFalse(shouldCancelSessionPageRead(request(method), false))
        }
    }
}
