package io.github.junweiup.vibepier.remote.core.transport

import android.util.Log
import java.io.IOException
import java.net.SocketTimeoutException
import javax.net.ssl.SSLException
import org.json.JSONException

/** Persist only fixed event/error categories, never peer payloads, URLs, addresses or exception text. */
internal object TransportLog {
    enum class Event(val label: String) {
        BLUETOOTH_STATUS("invalid Bluetooth status"), RELAY_STATUS("invalid relay status"),
        UDP_STATUS("UDP status receive failed"), UDP_CONTROL("UDP control send failed"),
        UDP_SEND("UDP send failed"), STUN("STUN failed"), DIRECT_OFFER("direct offer prepared"),
        DIRECT_ANSWER("direct answer received"), DIRECT_CONNECTED("direct path connected"),
        DIRECT_STATUS("invalid direct status"), DIRECT_LOST("direct path lost, back to relay"),
        DIRECT_SEND("direct send failed"), RELAY_SEND("relay send failed"), RELAY_CONNECTION("relay connection failed"),
        RELAY_QUEUE("relay send queue full"),
        RELAY_NETWORK("relay network monitoring unavailable"),
        DNS_RECOVERY("relay retrying with validated HTTPS DNS"),
    }

    fun warning(event: Event, error: Exception? = null) { Log.w("VibePier", message(event, error)) }
    fun info(event: Event) { Log.i("VibePier", message(event)) }

    internal fun message(event: Event, error: Exception? = null): String {
        if (error == null) return event.label
        val category = when (error) {
            is JSONException -> "invalid-payload"
            is SocketTimeoutException -> "timeout"
            is SSLException -> "tls-failed"
            is IOException -> "io-failed"
            is SecurityException -> "permission-denied"
            else -> "unexpected-error"
        }
        return "${event.label}: $category"
    }
}
