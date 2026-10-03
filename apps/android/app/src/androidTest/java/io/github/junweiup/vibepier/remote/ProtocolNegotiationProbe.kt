package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.core.security.SecureControlClient
import io.github.junweiup.vibepier.remote.core.transport.RemoteConnectionService
import io.github.junweiup.vibepier.remote.core.transport.RemoteSender
import io.github.junweiup.vibepier.remote.features.remote.Pad
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/** Real phone Keystore + transport + UI against a loopback host; no desktop controls or audio capture. */
object ProtocolNegotiationProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW && android.os.Build.MODEL.contains("sdk", ignoreCase = true))
        val keys = DeviceKeys(test.targetContext)
        check(!keys.authorized) { "Use an unenrolled review emulator" }
        val root = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        val profile = AtomicReference("2" to 15)
        val host = SecureTestHost(keys.device, root) { profile.get() }
        val preferenceName = MainActivity::class.java.name.removePrefix(test.targetContext.packageName + ".")
        val prefs = PrivatePreferences.open(test.targetContext, preferenceName)
        val saved = listOf("host", "transport", "lastMac", "microphoneSource").associateWith { prefs.getString(it, null) }
        check(prefs.edit().putString("host", "127.0.0.1").putString("transport", "wifi").putString("microphoneSource", "phone").commit())
        val socket = DatagramSocket(RemoteSender.PORT, InetAddress.getByName("127.0.0.1"))
        val downs = AtomicInteger(); val ups = AtomicInteger(); val microphoneRequests = AtomicInteger()
        val worker = Thread {
            val buffer = ByteArray(SecureControlClient.MAX_FRAME)
            while (!socket.isClosed) try {
                val packet = DatagramPacket(buffer, buffer.size); socket.receive(packet)
                val response = host.receive(String(packet.data, 0, packet.length)) { clear ->
                    when {
                        clear == "vibepier-watch1 ${keys.device}" -> JSONObject().put("type", "vibepier-app1").put("sender", keys.device)
                            .put("stamp", SystemClock.elapsedRealtime()).put("bundleID", "qa.protocol").put("name", "Protocol QA").toString()
                        clear.startsWith("vibepier1 ") -> {
                            if (clear.contains(" talk down")) downs.incrementAndGet()
                            if (clear.contains(" talk up")) ups.incrementAndGet()
                            null
                        }
                        clear.contains("vibepier-mic1") -> { microphoneRequests.incrementAndGet(); null }
                        else -> null
                    }
                } ?: continue
                val bytes = response.toByteArray()
                socket.send(DatagramPacket(bytes, bytes.size, packet.address, packet.port))
            } catch (_: Exception) { }
        }.apply { isDaemon = true; start() }
        var activity: MainActivity? = null
        var pad: Pad? = null
        fun awaitState(message: String, condition: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 8_000
            while (!condition() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(50)
            check(condition()) { message }
        }
        try {
            keys.install(root); root.fill(0)
            activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("backgroundConnectionProbe", true)) as MainActivity
            val sender = activity.javaClass.getDeclaredMethod("getSender").apply { isAccessible = true }.invoke(activity) as RemoteSender
            val incompatible = test.targetContext.getString(R.string.transport_incompatible)
            awaitState("No incompatibility notice") { sender.wifiStatus == incompatible }
            check(sender.connectedHost == null && !sender.phoneAudioSupported)
            test.runOnMainSync {
                val subtitle = activity!!.javaClass.getDeclaredField("subtitle").apply { isAccessible = true }.get(activity) as CanvasLabel
                check(subtitle.text.toString() == incompatible) { "UI did not show the localized incompatibility notice" }
            }
            profile.set("1" to 7)
            test.runOnMainSync { sender.watch(true) }
            awaitState("Baseline handshake did not recover") { sender.connectedHost == "127.0.0.1" }
            check(!sender.phoneAudioSupported)
            test.runOnMainSync {
                val pads = activity!!.javaClass.getDeclaredField("pads").apply { isAccessible = true }.get(activity) as Map<*, *>
                pad = pads["talk"] as Pad
                pad!!.onPress()
            }
            awaitState("No Mac-microphone hold") { downs.get() > 0 }
            profile.set("1" to 15)
            test.runOnMainSync { sender.watch(true) }
            awaitState("Audio capability did not recover") { sender.connectedHost == "127.0.0.1" && sender.phoneAudioSupported }
            val beforeRelease = ups.get()
            test.runOnMainSync { pad!!.onRelease() }
            awaitState("Capability change lost the original key-up") { ups.get() > beforeRelease }
            check(microphoneRequests.get() == 0) { "A Mac-microphone hold must not turn into phone recording" }
            return "PASS: authenticated incompatibility shown; baseline reconnects without phone audio; optional audio recovers; mid-hold capability change still releases original Mac key\n"
        } finally {
            test.runOnMainSync {
                pad?.onRelease()
                activity?.finish()
                test.targetContext.stopService(Intent(test.targetContext, RemoteConnectionService::class.java))
            }
            socket.close(); worker.join(1000)
            keys.clear(); root.fill(0)
            val edit = prefs.edit(); saved.forEach { (key, value) -> edit.putString(key, value) }; check(edit.commit())
        }
    }
}
