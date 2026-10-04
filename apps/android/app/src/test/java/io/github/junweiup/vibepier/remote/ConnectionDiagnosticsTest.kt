package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.ConnectionDiagnostics
import io.github.junweiup.vibepier.remote.core.transport.TransportLog
import org.junit.Assert.*
import org.junit.Test

class ConnectionDiagnosticsTest {
    @Test fun restorationCountsActualTransitionsAndKeepsFixedCategories() {
        val diagnostics = ConnectionDiagnostics()
        diagnostics.observe("relay", true, true, true)
        diagnostics.observe("relay", true, true, true)
        assertEquals(0, diagnostics.snapshot().restorations)
        diagnostics.observe("relay", false, false, true)
        diagnostics.record(TransportLog.Event.RELAY_CONNECTION, "tls-failed", true)
        diagnostics.observe("relay", false, true, true)
        val result = diagnostics.snapshot()
        assertEquals(1, result.restorations)
        assertEquals("relay", result.path)
        assertEquals("tls-failed", result.recentError)
        assertEquals("relay_connection", result.recentEvent)
    }
    @Test fun unknownInputsCannotEnterDiagnosticSnapshot() {
        val diagnostics = ConnectionDiagnostics()
        diagnostics.observe("wss://private-host/secret", false, false, false)
        diagnostics.record(TransportLog.Event.RELAY_CONNECTION, "sensitive exception text", true)
        val result = diagnostics.snapshot()
        assertEquals("unknown", result.mode)
        assertEquals("unspecified", result.recentError)
        assertFalse(result.toString().contains("secret"))
        assertFalse(result.toString().contains("sensitive"))
    }
}
