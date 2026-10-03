package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import io.github.junweiup.vibepier.remote.core.transport.RemoteConnectionService
import io.github.junweiup.vibepier.remote.core.transport.RemoteSender
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.SecureControlClient
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject

/** Explicit emulator-only test. A loopback fake Mac never sends controls to the user's desktop. */
object BackgroundConnectionProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW && android.os.Build.MODEL.contains("sdk", ignoreCase = true))
        val deviceKeys = DeviceKeys(test.targetContext)
        check(!deviceKeys.authorized) { "Use an unenrolled, disposable review app for this probe" }
        val root = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        val secureHost = SecureTestHost(deviceKeys.device, root)
        val preferenceName = MainActivity::class.java.name.removePrefix(test.targetContext.packageName + ".")
        val prefs = io.github.junweiup.vibepier.remote.core.security.PrivatePreferences.open(test.targetContext, preferenceName)
        val oldHost = prefs.getString("host", null); val oldMode = prefs.getString("transport", null)
        val oldLastMac = prefs.getString("lastMac", null)
        prefs.edit().putString("host", "127.0.0.1").putString("transport", "wifi").commit()
        val fake = DatagramSocket(RemoteSender.PORT, InetAddress.getByName("127.0.0.1"))
        val watches = AtomicInteger()
        val identities = java.util.Collections.synchronizedSet(mutableSetOf<String>())
        val worker = Thread {
            val bytes = ByteArray(SecureControlClient.MAX_FRAME)
            while (!fake.isClosed) try {
                val packet = DatagramPacket(bytes, bytes.size); fake.receive(packet)
                val line = String(packet.data, 0, packet.length)
                val response = secureHost.receive(line) { plaintext ->
                    if (plaintext != "vibepier-watch1 ${deviceKeys.device}") return@receive null
                    identities.add(deviceKeys.device); watches.incrementAndGet()
                    JSONObject().put("type", "vibepier-app1").put("sender", deviceKeys.device)
                        .put("stamp", SystemClock.elapsedRealtime()).put("bundleID", "qa.loopback").put("name", "Background QA").toString()
                } ?: continue
                val body = response.toByteArray()
                fake.send(DatagramPacket(body, body.size, packet.address, packet.port))
            } catch (_: Exception) { }
        }.apply { isDaemon = true; start() }
        fun launch() = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("backgroundConnectionProbe", true)) as MainActivity
        fun sender(activity: MainActivity): RemoteSender = activity.javaClass.getDeclaredMethod("getSender").apply { isAccessible = true }.invoke(activity) as RemoteSender
        var activity: MainActivity? = null
        try {
            deviceKeys.install(root)
            root.fill(0)
            activity = launch()
            val first = sender(activity)
            val deadline = SystemClock.elapsedRealtime() + 6_000
            while (first.connectedHost == null && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(100)
            check(first.connectedHost == "127.0.0.1") { "Loopback not connected: host=${first.host}, watches=${watches.get()}" }
            test.runOnMainSync { check(activity!!.moveTaskToBack(true)) }
            test.waitForIdleSync()
            val before = watches.get()
            SystemClock.sleep(14_000) // Longer than the 12-second peer timeout.
            check(watches.get() >= before + 3) { "Background heartbeat stopped" }
            check(first.connectedHost == "127.0.0.1")
            test.runOnMainSync { activity!!.finish() }
            test.waitForIdleSync(); SystemClock.sleep(300)
            activity = launch()
            check(sender(activity) === first) { "Activity recreated the transport" }
            check(identities.size == 1) { "Peer identity changed across background/recreation" }
            test.runOnMainSync { test.targetContext.stopService(Intent(test.targetContext, RemoteConnectionService::class.java)) }
            test.waitForIdleSync(); SystemClock.sleep(300)
            check(first.connectedHost == null) { "Explicit disconnect did not clear connection" }
            return "PASS: authenticated encrypted loopback connected; background heartbeats >12s; stable peer identity; Activity recreation reuses transport; explicit stop disconnects\n"
        } finally {
            test.runOnMainSync {
                activity?.finish()
                test.targetContext.stopService(Intent(test.targetContext, RemoteConnectionService::class.java))
            }
            fake.close(); worker.join(1000)
            deviceKeys.clear(); root.fill(0)
            prefs.edit().putString("host", oldHost).putString("transport", oldMode).putString("lastMac", oldLastMac).commit()
        }
    }
}
