package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.os.Looper
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import io.github.junweiup.vibepier.remote.features.sessions.CodexFileUpload
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import android.os.SystemClock
import io.github.junweiup.vibepier.remote.core.files.BinaryFileClient
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Synthetic binary HTTPS interoperability only: no APK install, provider or production trust store. */
object BinaryFileProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val profiles = JSONObject(File("/data/local/tmp/vibepier-binary-probe.json").readText())
        val host = profiles.optString("host", "10.0.2.2")
        val upload = profiles.getJSONObject("upload")
        val file = File.createTempFile("binary-probe", ".dat", test.targetContext.cacheDir)
        val size = upload.getInt("size"); val bytes = ByteArray(size) { (it % 251).toByte() }
        file.writeBytes(bytes)
        try {
            val start = SystemClock.elapsedRealtime()
            var progress = 0L
            BinaryFileClient { true }.upload(upload, host, file) { progress = it }
            val uploadMs = SystemClock.elapsedRealtime() - start
            check(progress == size.toLong())
            val downloaded = MessageDigest.getInstance("SHA-256")
            val download = profiles.getJSONObject("apk")
            val downloadStart = SystemClock.elapsedRealtime(); var count = 0L
            BinaryFileClient { true }.download(download, host, download.getLong("size"), 0) { downloaded.update(it); count += it.size }
            val downloadMs = SystemClock.elapsedRealtime() - downloadStart
            check(count == download.getLong("size"))
            check(downloaded.digest().joinToString("") { "%02x".format(it) } == profiles.getString("apkSHA256"))
            val resume = profiles.getJSONObject("resume"); val resumed = MessageDigest.getInstance("SHA-256"); var resumedBytes = 0L
            BinaryFileClient { true }.download(resume, host, resume.getLong("size"), resume.getLong("offset")) { resumed.update(it); resumedBytes += it.size }
            check(resumedBytes == resume.getLong("size") - resume.getLong("offset"))
            check(resumed.digest().joinToString("") { "%02x".format(it) } == profiles.getString("resumeSHA256"))
            val badPin = JSONObject(upload.toString()).put("pin", "00".repeat(32))
            check(runCatching { BinaryFileClient { true }.upload(badPin, host, file) {} }.isFailure)
            var current = true
            val cancelled = profiles.getJSONObject("cancel")
            check(runCatching { BinaryFileClient { current }.upload(cancelled, host, file) { current = false } }.isFailure)
            val namespace = "binary-composer-${UUID.randomUUID()}"
            val context = object : ContextWrapper(test.targetContext) {
                override fun getApplicationContext(): Context = this
                override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("$namespace-$name", mode)
            }
            val keys = DeviceKeys(context); val root = ByteArray(32) { 31 }; keys.install(root)
            val secret = SecretKeySpec(root, "AES")
            val packets = mutableMapOf<String, MutableMap<Int, String>>()
            var chunks = 0; var complete = 0
            val transport = object : SessionTransport {
                override val mode = "wifi"
                override val binaryHost = host
                override var onSessionFrame: (JSONObject) -> Unit = {}
                override var onSessionPair: (ByteArray?) -> Unit = {}
                override fun requestSessionPair(device: String, name: String) {}
                override fun readSessionPair() {}
                override fun sendBinding(message: JSONObject) {
                    check(Looper.myLooper() != Looper.getMainLooper())
                    val packet = message.getString("packet")
                    val parts = packets.getOrPut(packet) { mutableMapOf() }; parts[message.getInt("part")] = message.getString("data")
                    if (parts.size != message.getInt("parts")) return
                    packets.remove(packet)
                    val box = java.util.Base64.getDecoder().decode((0 until parts.size).joinToString("") { parts.getValue(it) })
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, box.copyOfRange(0, 12)))
                    cipher.updateAAD("vibepier-session-v1|phone|${keys.device}|$packet".toByteArray())
                    val request = JSONObject(String(cipher.doFinal(box, 12, box.size - 12)))
                    val response = JSONObject().put("id", request.getString("id")).put("ok", true)
                    when (request.getString("op")) {
                        "attachmentStart" -> { check(request.getInt("binaryVersion") == 1); response.put("binary", profiles.getJSONObject("composer")) }
                        "attachmentChunk" -> { chunks++; error("Binary upload must bypass session chunks") }
                        "attachmentComplete" -> {
                            complete++
                            check(request.getString("binaryTicket") == profiles.getJSONObject("composer").getString("id"))
                            check(request.getString("sha256") == MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
                            response.put("complete", true).put("attachmentId", request.getString("attachmentId"))
                        }
                        "fileCancel" -> {}
                        else -> error("Unexpected binary upload operation")
                    }
                    val reply = UUID.randomUUID().toString(); cipher.init(Cipher.ENCRYPT_MODE, secret)
                    cipher.updateAAD("vibepier-session-v1|mac|${keys.device}|$reply".toByteArray())
                    val encoded = java.util.Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(response.toString().toByteArray()))
                    onSessionFrame(JSONObject().put("type", "vibepier-session1").put("sender", keys.device).put("device", keys.device)
                        .put("packet", reply).put("part", 0).put("parts", 1).put("data", encoded))
                }
            }
            lateinit var client: SessionClient; val done = CountDownLatch(1); var result = JSONObject()
            val composerStart = SystemClock.elapsedRealtime()
            try {
                test.runOnMainSync {
                    client = SessionClient(context, transport).apply { connectionChanged(true) }
                    CodexFileUpload.upload(context.resources, client, "synthetic-thread", file, "synthetic.dat", "application/octet-stream", {}, done = {
                        result = it; done.countDown()
                    })
                }
                check(done.await(10, TimeUnit.SECONDS) && result.optBoolean("ok") && complete == 1 && chunks == 0)
            } finally { test.runOnMainSync { client.close(); keys.clear() } }
            val composerMs = SystemClock.elapsedRealtime() - composerStart
            return "PASS: pinned TLS binary upload/download, SHA256, exact resumed bytes, invalid pin refused, upload cancellation; uploadBytes=$size uploadMs=$uploadMs downloadBytes=$count downloadMs=$downloadMs composerMs=$composerMs; full composer uploads no session body chunks\n"
        } finally { file.delete() }
    }
}
