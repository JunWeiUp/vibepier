package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.util.Base64
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import org.json.JSONObject
import java.util.UUID

/** Real Keystore enrollment, with no desktop connection and isolated preferences. */
object EnrollmentProbe {
    private class Transport : SessionTransport {
        override var mode = "bluetooth"
        override var enrollmentReady = false
        var connection = "first"
        override val enrollmentConnectionID get() = connection.takeIf { enrollmentReady }
        override var onSessionFrame: (JSONObject) -> Unit = {}
        override var onSessionPair: (ByteArray?) -> Unit = {}
        var requests = 0
        var resets = 0
        override fun requestSessionPair(device: String, name: String) { requests++ }
        override fun readSessionPair() {}
        override fun sendBinding(message: JSONObject) = error("No private RPC before enrollment")
        override fun authorizationChanged() { resets++ }
    }

    fun run(test: Instrumentation): String {
        val namespace = "enrollment-probe-${UUID.randomUUID()}"
        val context = object : ContextWrapper(test.targetContext) {
            override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("$namespace-$name", mode)
        }
        val transport = Transport()
        lateinit var client: SessionClient
        var created = false
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
        }
        try {
            main {
                client = SessionClient(context, transport); created = true
                client.requestAuthorizationIfNeeded(); check(transport.requests == 0)
                transport.enrollmentReady = true
                transport.mode = "wifi"; client.requestAuthorizationIfNeeded(); check(transport.requests == 0)
                transport.mode = "bluetooth"
                repeat(10) { client.requestAuthorizationIfNeeded() }
                check(transport.requests == 1 && !client.online && !client.paired)
                transport.onSessionPair("{\"state\":\"denied\"}".toByteArray())
            }
            test.waitForIdleSync()
            main {
                repeat(10) { client.connectionChanged(false); client.requestAuthorizationIfNeeded() }
                check(transport.requests == 1 && client.authorizationMessage == context.getString(R.string.client_authorization_denied))
                transport.enrollmentReady = false; client.connectionChanged(false)
                transport.connection = "second"; transport.enrollmentReady = true
                client.requestAuthorizationIfNeeded(); check(transport.requests == 2)
                // Discovery updates during pending approval must not discard the response.
                client.connectionChanged(false)
                transport.onSessionPair(JSONObject().put("state", "approved").put("device", client.device)
                    .put("key", Base64.encodeToString(ByteArray(32) { 7 }, Base64.NO_WRAP)).toString().toByteArray())
            }
            test.waitForIdleSync()
            main {
                check(client.paired && !client.online && transport.resets == 1)
                transport.connection = "third"; client.requestAuthorizationIfNeeded()
                check(transport.requests == 2) // Existing authorization survives later connections.
                val first = DeviceKeys(context).nextSequence()
                check(DeviceKeys(context).nextSequence() > first)
                check(DeviceKeys(context).controlKeys() != null)
            }
            return "PASS: automatic BLE enrollment before private connection, no Wi-Fi enrollment, one prompt per connection, denial does not repeat, reconnect retries, discovery preserves pending approval, Keystore authorization and monotonic event IDs\n"
        } finally {
            main { if (created) client.close() }
            DeviceKeys(context).clear()
            for (name in listOf("sessions", "device-identity")) test.targetContext.deleteSharedPreferences("$namespace-$name")
        }
    }
}
