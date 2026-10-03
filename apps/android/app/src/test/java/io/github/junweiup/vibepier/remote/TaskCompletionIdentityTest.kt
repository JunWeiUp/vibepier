package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.TaskCompletionIdentity
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class TaskCompletionIdentityTest {
    @Test fun acceptsOnlyCompletionEventsWithKnownProviderAndStableIdentity() {
        for (provider in listOf("codex", "claude", "zcode")) {
            val event = JSONObject().put("event", "taskCompleted").put("eventId", "a".repeat(64)).put("provider", provider)
            assertEquals(provider, TaskCompletionIdentity.parse(event)?.provider)
            assertNull(TaskCompletionIdentity.parse(JSONObject(event.toString()).put("provider", "unknown")))
            assertNull(TaskCompletionIdentity.parse(JSONObject(event.toString()).put("event", "snapshot")))
            assertNull(TaskCompletionIdentity.parse(JSONObject(event.toString()).put("eventId", "")))
        }
    }
    @Test fun repeatedDeliveryAndRestoredHistoryDoNotNotifyAgain() {
        val first = "a".repeat(64)
        val history = TaskCompletionIdentity.remember("", first)!!
        assertNull(TaskCompletionIdentity.remember(history, first))
        val second = TaskCompletionIdentity.remember(history, "b".repeat(64))!!
        assertNull(TaskCompletionIdentity.remember(second, first))
        assertEquals(2, second.lines().size)
    }
    @Test fun boundsPersistentHistory() {
        var history = ""
        repeat(1000) { history = TaskCompletionIdentity.remember(history, it.toString(16).padStart(64, '0'))!! }
        assertEquals(256, history.lines().size)
        assertNull(TaskCompletionIdentity.remember(history, 999.toString(16).padStart(64, '0')))
    }
}
