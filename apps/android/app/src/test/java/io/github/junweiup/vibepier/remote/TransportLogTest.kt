package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.TransportLog
import java.io.IOException
import java.net.SocketTimeoutException
import javax.net.ssl.SSLException
import org.json.JSONException
import org.junit.Assert.*
import org.junit.Test

class TransportLogTest {
    @Test fun peerContentAndExceptionCausesNeverEnterDiagnostics() {
        val secret = "fixture-private-prompt-and-pairing-secret"
        val errors = listOf(JSONException("Bad JSON: $secret"), IOException("https://example.com/?token=$secret"),
            SecurityException(secret), object : RuntimeException(secret, IOException(secret)) {
                override fun toString(): String = error("Must not format exceptions")
            })
        for (event in TransportLog.Event.values()) for (error in errors) {
            error.addSuppressed(IOException(secret))
            val line = TransportLog.message(event, error)
            assertFalse(line.contains(secret))
            assertFalse(line.contains("https://"))
            assertTrue(line.startsWith(event.label + ": "))
        }
    }

    @Test fun safeCategoriesStillDistinguishOperationalFailures() {
        val event = TransportLog.Event.RELAY_CONNECTION
        assertEquals("relay connection failed: timeout", TransportLog.message(event, SocketTimeoutException("private")))
        assertEquals("relay connection failed: tls-failed", TransportLog.message(event, SSLException("private")))
        assertEquals("relay connection failed: io-failed", TransportLog.message(event, IOException("private")))
        assertEquals("relay connection failed: invalid-payload", TransportLog.message(event, JSONException("private")))
    }
}
