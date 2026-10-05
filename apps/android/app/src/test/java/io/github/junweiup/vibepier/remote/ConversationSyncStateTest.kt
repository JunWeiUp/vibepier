package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.sessions.ConversationSyncState
import org.junit.Assert.*
import org.junit.Test

class ConversationSyncStateTest {
    @Test fun dirtyDuringReadIsCoalescedAndForceReadIsPreserved() {
        val state = ConversationSyncState()
        state.request(true)
        val first = state.begin()!!
        repeat(10) { state.request(true) }
        state.request(false)
        assertNull(state.begin())
        assertTrue(state.finish(first, true))
        val next = state.begin()!!
        assertFalse(next.withCache)
        assertFalse(state.finish(next, true))
        assertNull(state.begin())
    }
    @Test fun failedReadsRetryTwiceAndStopEvenWithDirtyInFlight() {
        val state = ConversationSyncState()
        state.request(true)
        repeat(3) { attempt ->
            val read = state.begin()!!
            state.request(true)
            assertEquals(attempt < 2, state.finish(read, false))
        }
        assertNull(state.begin())
        state.request(false)
        assertNotNull(state.begin())
    }
    @Test fun leavingConversationInvalidatesLateCompletionAndQueuedWork() {
        val state = ConversationSyncState()
        state.request(true)
        val old = state.begin()!!
        state.request(false); state.reset()
        assertFalse(state.current(old))
        assertFalse(state.finish(old, false))
        assertNull(state.begin())
        state.request(true)
        val current = state.begin()!!
        assertFalse(state.finish(old, true))
        assertTrue(state.inFlight)
        assertTrue(state.current(current))
        assertFalse(state.current(old))
        assertFalse(state.finish(current, true))
    }
}
