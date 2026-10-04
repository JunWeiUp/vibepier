package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.os.SystemClock
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.SecureControlClient
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import io.github.junweiup.vibepier.remote.features.sessions.CodexFileUpload
import org.json.JSONObject
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Real UDP to an explicit loopback Mac test host. Isolated keys/data; never talks to a production provider. */
object AttachmentNetworkUploadProbe {
    fun run(test: Instrumentation, port: Int): String {
        check(BuildConfig.DESIGN_REVIEW && port in 1024..65535)
        val namespace = "attachment-network-${UUID.randomUUID()}"
        val context = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("$namespace-$name", mode)
        }
        val keys = DeviceKeys(context).apply { install(ByteArray(32) { 0x31 }) }
        val file = File(context.filesDir, "$namespace.bin").apply { writeBytes(ByteArray(4 * 1024 * 1024 + 17) { (it % 251).toByte() }) }
        val host = InetAddress.getByName("10.0.2.2")
        val results = JSONObject()
        try {
            for (fast in listOf(false, true)) {
                val socket = DatagramSocket().apply { soTimeout = 1000; receiveBufferSize = 1024 * 1024 }
                val secure = SecureControlClient(keys.device, keys::controlKeys)
                val repeats = java.util.concurrent.Executors.newSingleThreadScheduledExecutor()
                val ready = CountDownLatch(1)
                var running = true; var frames = 0
                fun send(line: String) { val data = line.toByteArray(); socket.send(DatagramPacket(data, data.size, host, port)) }
                val transport = object : SessionTransport {
                    override val mode = "wifi"
                    override var onSessionFrame: (JSONObject) -> Unit = {}
                    override var onSessionPair: (ByteArray?) -> Unit = {}
                    override fun requestSessionPair(device: String, name: String) {}
                    override fun readSessionPair() {}
                    override fun sendBinding(message: JSONObject) {
                        val frame = JSONObject(message.toString()).put("sender", keys.device)
                        frames++
                        val wire = secure.seal(frame.toString().toByteArray()) ?: error("Unauthenticated network frame")
                        send(wire)
                        for (delay in listOf(40L, 120L)) repeats.schedule({ if (!socket.isClosed) runCatching { send(wire) } }, delay, TimeUnit.MILLISECONDS)
                    }
                }
                val receiver = Thread {
                    while (running) try {
                        val packet = DatagramPacket(ByteArray(16385), 16385); socket.receive(packet)
                        when (val received = secure.receive(String(packet.data, 0, packet.length))) {
                            SecureControlClient.Result.Ready -> ready.countDown()
                            is SecureControlClient.Result.Message -> transport.onSessionFrame(JSONObject(String(received.payload)))
                            else -> {}
                        }
                    } catch (_: Exception) {}
                }.apply { isDaemon = true; start() }
                var client: SessionClient? = null
                try {
                    send(secure.hello()!!); check(ready.await(10, TimeUnit.SECONDS))
                    val done = CountDownLatch(1); var result = JSONObject()
                    val started = SystemClock.elapsedRealtime()
                    test.runOnMainSync {
                        client = SessionClient(context, transport).apply { connectionChanged(true) }
                        CodexFileUpload.upload(context.resources, client!!, UUID.randomUUID().toString(), file,
                            if (fast) "fast.bin" else "legacy.bin", "application/octet-stream", {}) { result = it; done.countDown() }
                    }
                    check(done.await(90, TimeUnit.SECONDS)) { "Network upload timed out" }
                    check(result.optBoolean("ok") && result.optBoolean("complete")) { result.toString() }
                    results.put(if (fast) "fast" else "legacy", JSONObject().put("elapsedMs", SystemClock.elapsedRealtime() - started).put("frames", frames))
                    if (fast) send(secure.seal("probe-finish".toByteArray())!!)
                } finally { test.runOnMainSync { client?.close() }; running = false; repeats.shutdownNow(); socket.close(); receiver.join(1500) }
            }
            File(test.targetContext.getExternalFilesDir(null), "attachment-network-validation.json").writeText(results.toString(2))
            return "PASS: 4MiB real UDP, production phone crypto/upload and Mac assembly/storage/SHA256; $results\n"
        } finally { keys.clear(); file.delete() }
    }
}
