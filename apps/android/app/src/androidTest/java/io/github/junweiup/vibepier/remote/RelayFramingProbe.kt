package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.os.SystemClock
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.transport.RelayLink
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/** Actual RelayLink sockets/Keystore against a disposable loopback relay+Mac fixture. No real controls. */
object RelayFramingProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW && android.os.Build.MODEL.contains("sdk", ignoreCase = true))
        val keys = DeviceKeys(test.targetContext)
        check(!keys.authorized) { "Use an unenrolled review emulator" }
        val root = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        val hosts = List(3) { SecureTestHost(keys.device, root) { "1" to 7 } }
        val secret = RelayLink.hex(RelayLink.randomBytes(16))
        val server = ServerSocket(0, 2, InetAddress.getByName("127.0.0.1")).apply { soTimeout = 10_000 }
        val activeSocket = AtomicReference<Socket?>()
        val running = AtomicBoolean(true)
        val failure = AtomicReference<Throwable?>()
        val finished = CountDownLatch(1)
        val received = CopyOnWriteArrayList<String>()
        fun writeFrame(out: OutputStream, opcode: Int, bytes: ByteArray, fin: Boolean = true) {
            out.write((if (fin) 0x80 else 0) or opcode)
            check(bytes.size <= 65535)
            if (bytes.size < 126) out.write(bytes.size) else { out.write(126); out.write(bytes.size shr 8); out.write(bytes.size and 255) }
            out.write(bytes); out.flush()
        }
        fun headers(input: BufferedInputStream): String {
            val out = ByteArrayOutputStream()
            while (out.size() < 16384) {
                val b = input.read(); check(b >= 0); out.write(b)
                val text = out.toString("UTF-8")
                if (text.endsWith("\r\n\r\n")) return text
            }
            error("fixture HTTP headers too large")
        }
        val worker = Thread {
            try {
                for (attempt in 0..2) server.accept().use { socket ->
                    activeSocket.set(socket); socket.soTimeout = 6000
                    val input = BufferedInputStream(socket.getInputStream()); val out = socket.getOutputStream()
                    val request = headers(input)
                    check(request.startsWith("GET /relay HTTP/1.1\r\n"))
                    val key = request.lineSequence().single { it.startsWith("Sec-WebSocket-Key:", true) }.substringAfter(':').trim()
                    out.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                        "Sec-WebSocket-Accept: ${RelayLink.acceptKey(key)}\r\n\r\n").toByteArray()); out.flush()
                    val hello = String(RelayLink.readFrame(input, masked = true).third)
                    val fields = hello.split(' ')
                    check(fields.size == 7 && hello == RelayLink.hello("client", "fixture", secret, fields[4].toLong(), fields[5]))
                    writeFrame(out, 1, "vibepier-relay1 ok".toByteArray())
                    writeFrame(out, 1, "vibepier-relay1 peer up".toByteArray())
                    var replied = false
                    while (!replied) {
                        val (opcode, _, payload) = RelayLink.readFrame(input, masked = true)
                        if (opcode != 1) continue
                        val reply = hosts[attempt].receive(String(payload)) { clear ->
                            check(clear == "vibepier-watch1 ${keys.device}")
                            replied = true
                            JSONObject().put("type", "vibepier-app1").put("sender", keys.device)
                                .put("name", "Fixture € $attempt").toString()
                        } ?: continue
                        val bytes = reply.toByteArray(); val split = bytes.size / 2
                        writeFrame(out, 1, bytes.copyOfRange(0, split), fin = false)
                        writeFrame(out, 9, "ping".toByteArray())
                        writeFrame(out, 0, bytes.copyOfRange(split, bytes.size))
                    }
                    if (attempt == 0) {
                        // A fragmented ping must retire this connection, then normal reconnect renegotiates crypto.
                        out.write(byteArrayOf(0x09, 0)); out.flush()
                    } else if (attempt == 1) {
                        // The network-change event below must cancel a healthy but obsolete read.
                        while (input.read() >= 0) { /* Drain only synthetic fixture traffic until EOF. */ }
                    } else finished.await(10, TimeUnit.SECONDS)
                }
            } catch (error: Throwable) { if (running.get()) failure.set(error) }
        }.apply { isDaemon = true }
        lateinit var link: RelayLink
        var linkCreated = false
        try {
            keys.install(root); root.fill(0)
            link = RelayLink(test.targetContext, { received += JSONObject(it).getString("name") }, {
                if (link.peerOnline) link.send("vibepier-watch1 ${keys.device}")
            })
            linkCreated = true
            worker.start()
            link.start(RelayLink.Settings("ws://127.0.0.1:${server.localPort}/relay", "fixture", secret))
            fun awaitReplies(count: Int) {
                val deadline = SystemClock.elapsedRealtime() + 12_000
                while (received.size < count && failure.get() == null && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(50)
                failure.get()?.let { throw it }
                check(received.size == count) { "Missing authenticated reply after recovery: $count / ${received.size}" }
            }
            fun field(name: String) = link.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(link)
            val reconnect = link.javaClass.getDeclaredMethod("networkChanged", Long::class.javaPrimitiveType).apply { isAccessible = true }
            awaitReplies(2)
            val epoch = field("networkEpoch") as Long
            val obsolete = field("worker") as Thread
            reconnect.invoke(link, epoch)
            obsolete.join(1000)
            check(!obsolete.isAlive) { "Old socket read did not stop after network changed" }
            awaitReplies(3)
            check(received == listOf("Fixture € 0", "Fixture € 1", "Fixture € 2"))
            val latest = field("worker") as Thread
            reconnect.invoke(link, epoch - 1)
            check(field("worker") === latest) { "A stale network lifecycle restarted the new connection" }
            link.stop()
            latest.join(1000)
            check(!latest.isAlive)
            reconnect.invoke(link, epoch)
            check(field("worker") == null && !link.peerOnline) { "A late network callback restarted a stopped link" }
            return "PASS: real RelayLink/Keystore admission; fragmented authenticated messages with interleaved ping; malformed-frame recovery; network change cancels an obsolete socket and reauthenticates; stale callbacks cannot replace a newer lifecycle or restart a stopped link\n"
        } finally {
            running.set(false)
            if (linkCreated) link.stop()
            finished.countDown(); activeSocket.get()?.close(); server.close(); worker.join(1000)
            keys.clear(); root.fill(0)
        }
    }
}
