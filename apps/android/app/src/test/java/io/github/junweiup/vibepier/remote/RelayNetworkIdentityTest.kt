package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.RelayNetworkIdentity
import org.junit.Assert.*
import org.junit.Test

class RelayNetworkIdentityTest {
    @Test fun initialAndDuplicateAvailabilityDoNotRestartAHealthyConnection() {
        val state = RelayNetworkIdentity("wifi")
        assertFalse(state.available("wifi"))
        assertFalse(state.available("wifi"))
        assertTrue(state.available("mobile"))
        assertFalse(state.available("mobile"))
    }
    @Test fun lateLossOfOldWifiCannotInvalidateNewCellularNetwork() {
        val state = RelayNetworkIdentity("wifi")
        assertTrue(state.available("mobile"))
        assertFalse(state.lost("wifi"))
        assertFalse(state.available("mobile"))
        assertTrue(state.lost("mobile"))
        assertFalse(state.lost("mobile"))
        assertTrue(state.available("mobile"))
    }
    @Test fun offlineStartAndReturningNetworkAreRecognized() {
        val state = RelayNetworkIdentity<String>(null)
        assertFalse(state.lost("old"))
        assertTrue(state.available("mobile"))
        assertTrue(state.lost("mobile"))
        assertTrue(state.available("wifi"))
    }
}
