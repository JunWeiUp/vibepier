package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import io.github.junweiup.vibepier.remote.features.sessions.CodexFileUpload
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Real phone file/Keystore/encryption/UI path with an isolated synthetic, delayed host. Never submits a turn. */
object AttachmentUploadProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val namespace = "attachment-upload-${UUID.randomUUID()}"
        val context = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("$namespace-$name", mode)
        }
        val keys = DeviceKeys(context)
        val root = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        keys.install(root)
        val key = SecretKeySpec(root, "AES")
        val sample = ByteArray(4 * 1024 * 1024 + 17) { (it % 251).toByte() }
        val file = File(context.filesDir, "$namespace.bin").apply { writeBytes(sample) }
        val main = Handler(Looper.getMainLooper())
        val delays = mutableListOf<Long>()
        var watching = true
        var lastTick = SystemClock.elapsedRealtime()
        val tick = object : Runnable {
            override fun run() { val now = SystemClock.elapsedRealtime(); delays.add(now - lastTick); lastTick = now; if (watching) main.postDelayed(this, 16) }
        }
        fun runUpload(fast: Boolean, cancel: Boolean = false): JSONObject {
            val server = Executors.newSingleThreadScheduledExecutor()
            val packets = mutableMapOf<String, MutableMap<Int, String>>()
            val received = ByteArray(sample.size)
            val coverage = mutableSetOf<Int>()
            var frames = 0; var completeRequests = 0
            val transport = object : SessionTransport {
                override val mode = "relay"
                override var onSessionFrame: (JSONObject) -> Unit = {}
                override var onSessionPair: (ByteArray?) -> Unit = {}
                override fun requestSessionPair(device: String, name: String) {}
                override fun readSessionPair() {}
                override fun sendBinding(message: JSONObject) {
                    check(Looper.myLooper() != Looper.getMainLooper()) { "Encryption/transmission is on the UI thread" }
                    frames++
                    val packet = message.getString("packet")
                    val pieces = packets.getOrPut(packet) { mutableMapOf() }
                    pieces[message.getInt("part")] = message.getString("data")
                    if (pieces.size != message.getInt("parts")) return
                    packets.remove(packet)
                    val box = Base64.getDecoder().decode((0 until pieces.size).joinToString("") { pieces.getValue(it) })
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, box.copyOfRange(0, 12)))
                    cipher.updateAAD("vibepier-session-v1|phone|${keys.device}|$packet".toByteArray())
                    val request = JSONObject(String(cipher.doFinal(box, 12, box.size - 12)))
                    val response = JSONObject().put("id", request.getString("id")).put("ok", true)
                    val id = request.optString("attachmentId")
                    var delay = 100L
                    when (request.optString("op")) {
                        "attachmentStart" -> if (fast) response.put("upload", JSONObject().put("version", 1).put("token", id).put("fragmentChars", 7200).put("chunkBytes", 64 * 1024).put("window", 3))
                        "attachmentChunk" -> {
                            val offset = request.getInt("offset")
                            val bytes = Base64.getDecoder().decode(request.getString("data"))
                            bytes.copyInto(received, offset); coverage.add(offset)
                            response.put("attachmentId", id).put("offset", offset + bytes.size)
                            if (fast) delay = if (offset % (3 * 64 * 1024) == 0) 100 else 60 // Reorder real callbacks.
                            check(message.has("upload") == fast)
                        }
                        "attachmentComplete" -> {
                            completeRequests++
                            check(received.contentEquals(sample) && coverage.size == (sample.size + (if (fast) 65535 else 131071)) / (if (fast) 65536 else 131072))
                            val digest = MessageDigest.getInstance("SHA-256").digest(received).joinToString("") { "%02x".format(it) }
                            check(request.getString("sha256") == digest)
                            response.put("attachmentId", id).put("complete", true)
                        }
                    }
                    server.schedule({
                        val replyPacket = UUID.randomUUID().toString()
                        val outgoing = Cipher.getInstance("AES/GCM/NoPadding")
                        outgoing.init(Cipher.ENCRYPT_MODE, key)
                        outgoing.updateAAD("vibepier-session-v1|mac|${keys.device}|$replyPacket".toByteArray())
                        val text = Base64.getEncoder().encodeToString(outgoing.iv + outgoing.doFinal(response.toString().toByteArray()))
                        onSessionFrame(JSONObject().put("type", "vibepier-session1").put("sender", keys.device).put("device", keys.device).put("packet", replyPacket).put("part", 0).put("parts", 1).put("data", text))
                    }, delay, TimeUnit.MILLISECONDS)
                }
            }
            lateinit var client: SessionClient
            val latch = CountDownLatch(1)
            var result = JSONObject(); var cancelled = false
            val progress = mutableListOf<Int>()
            val started = SystemClock.elapsedRealtime()
            test.runOnMainSync {
                client = SessionClient(context, transport).apply { connectionChanged(true) }
                CodexFileUpload.upload(context.resources, client, UUID.randomUUID().toString(), file, "fixture.bin", "application/octet-stream",
                    { progress.add(it.getInt("progress")) }, cancelled = { cancelled }) { result = it; latch.countDown() }
                if (cancel) main.postDelayed({ cancelled = true }, 180)
            }
            try {
                check(latch.await(25, TimeUnit.SECONDS)) { "Upload did not finish" }
                val elapsed = SystemClock.elapsedRealtime() - started
                test.waitForIdleSync()
                if (cancel) { check(!result.optBoolean("ok") && completeRequests == 0) }
                else {
                    check(result.optBoolean("ok") && result.optBoolean("complete") && completeRequests == 1)
                    check(progress.first() == 0 && progress.last() == 100 && progress.zipWithNext().all { it.second >= it.first })
                }
                return JSONObject().put("elapsedMs", elapsed).put("frames", frames).put("progressUpdates", progress.size)
            } finally { test.runOnMainSync { client.close() }; server.shutdownNow() }
        }
        fun outerAuthentication(capabilities: String): Long {
            val software = io.github.junweiup.vibepier.remote.core.security.SecureControlKeys.fromRoot(root)
            val client = io.github.junweiup.vibepier.remote.core.security.SecureControlClient(keys.device, keys::controlKeys)
            val hello = client.hello()!!.split(' ')
            val fields = listOf(io.github.junweiup.vibepier.remote.core.security.SecureControlClient.READY, keys.device, hello[2], UUID.randomUUID().toString(), "1", capabilities)
            check(client.receive((fields + io.github.junweiup.vibepier.remote.core.security.SecureControlKeys.hex(software.signature(fields))).joinToString(" ")) is io.github.junweiup.vibepier.remote.core.security.SecureControlClient.Result.Ready)
            val payload = JSONObject().put("type", "vibepier-session1").put("sender", keys.device).put("device", keys.device)
                .put("packet", UUID.randomUUID().toString()).put("part", 0).put("parts", 2).put("upload", UUID.randomUUID().toString()).put("data", "a".repeat(7200)).toString().toByteArray()
            val started = SystemClock.elapsedRealtimeNanos()
            repeat(128) { check(client.seal(payload)!!.startsWith(if (capabilities == "31") "vibepier-bulk1 " else "vibepier-secure1 ")) }
            client.disconnect()
            return (SystemClock.elapsedRealtimeNanos() - started) / 1_000_000
        }
        try {
            main.post(tick)
            val legacy = runUpload(false); val fast = runUpload(true); val cancel = runUpload(true, true)
            check(fast.getInt("frames") * 6 < legacy.getInt("frames"))
            check(fast.getLong("elapsedMs") < legacy.getLong("elapsedMs"))
            val sorted = delays.sorted()
            val aesMs = outerAuthentication("15"); val macMs = outerAuthentication("31")
            check(macMs < aesMs)
            val result = JSONObject().put("legacy", legacy).put("fast", fast).put("cancel", cancel)
                .put("outer128FramesAesMs", aesMs).put("outer128FramesMacMs", macMs)
                .put("speedup", legacy.getDouble("elapsedMs") / fast.getDouble("elapsedMs"))
                .put("mainTickP95Ms", sorted[(sorted.size * 95 / 100).coerceAtMost(sorted.lastIndex)])
                .put("mainTickMaxMs", sorted.last())
            File(test.targetContext.getExternalFilesDir(null), "attachment-upload-validation.json").writeText(result.toString(2))
            return "PASS: encrypted 4MiB upload, reordered acknowledgements, SHA256, off-main transmission, monotonic progress and cancellation; $result\n"
        } finally {
            watching = false; main.removeCallbacks(tick); keys.clear(); file.delete()
            context.getSharedPreferences("device-identity", Context.MODE_PRIVATE).edit().clear().commit()
            context.getSharedPreferences("sessions", Context.MODE_PRIVATE).edit().clear().commit()
        }
    }
}
