package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.ConnectionLifetime
import org.junit.Assert.*
import org.junit.Test

class ConnectionLifetimeTest {
    private class Transport { var pauses = 0; var detached = 0; var closes = 0 }
    private fun lifetime() = ConnectionLifetime(create = { Transport() }, pause = { it.pauses++ }, detachUI = { it.detached++ }, dispose = { it.closes++ })

    @Test fun backgroundAndActivityRecreationReuseServiceConnection() {
        val state = lifetime(); val original = Any(); val recreated = Any()
        val first = state.acquire(original)
        assertSame(first, state.retainService())
        state.release(original)
        assertEquals(0, first.pauses); assertEquals(0, first.closes); assertEquals(1, first.detached)
        assertSame(first, state.acquire(recreated))
        assertEquals(0, first.closes)
    }

    @Test fun notificationDisconnectPausesAndWaitsForActivityBeforeDisposal() {
        val state = lifetime(); val owner = Any(); val value = state.acquire(owner)
        state.retainService(); state.releaseService()
        assertEquals(1, value.pauses); assertEquals(0, value.closes)
        assertSame(value, state.acquire(owner))
        state.release(owner)
        assertEquals(1, value.closes)
        state.releaseService(); state.release(owner)
        assertEquals(1, value.closes)
    }

    @Test fun stopAfterActivityDestroyedClosesExactlyOnce() {
        val state = lifetime(); val owner = Any(); val value = state.acquire(owner)
        state.retainService(); state.release(owner); state.releaseService(); state.releaseService()
        assertEquals(1, value.closes)
        assertEquals(1, value.pauses)
        assertNull(state.retainService())
    }

    @Test fun oldActivityCannotClearNewActivityCallbacks() {
        val state = lifetime(); val old = Any(); val new = Any()
        val value = state.acquire(old); state.retainService(); state.acquire(new)
        state.release(old)
        assertEquals(0, value.detached); assertEquals(0, value.closes)
        state.release(new)
        assertEquals(1, value.detached)
    }

    @Test fun noUnpromptedServiceStartAndNewOpenCreatesFreshTransport() {
        val state = lifetime(); assertNull(state.retainService())
        val owner = Any(); val value = state.acquire(owner)
        state.release(owner)
        assertEquals(1, value.closes)
        assertNotSame(value, state.acquire(Any()))
    }
}
