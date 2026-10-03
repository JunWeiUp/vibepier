package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.os.SystemClock
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import org.json.JSONObject
import java.security.KeyStore
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

/** Actual Android JSON/Keystore/client path, isolated preferences and a synthetic host; no desktop actions. */
object SessionResponseProbe {
    private class Transport : SessionTransport {
        override val mode = "bluetooth"
        override val enrollmentReady = true
        override var onSessionFrame: (JSONObject) -> Unit = {}
        override var onSessionPair: (ByteArray?) -> Unit = {}
        val frames = CopyOnWriteArrayList<JSONObject>()
        override fun sendBinding(message: JSONObject) { frames.add(JSONObject(message.toString())) }
        override fun requestSessionPair(device: String, name: String) {}
        override fun readSessionPair() {}
        fun packets() = frames.map { it.getString("packet") }.distinct().size
    }
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val namespace = "session-response-${UUID.randomUUID()}"
        val context = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("$namespace-$name", mode)
        }
        val prefs = PrivatePreferences.open(context, "sessions")
        val transport = Transport()
        var client: SessionClient? = null
        val keyBytes = ByteArray(32) { 23 }; val key = SecretKeySpec(keyBytes, "AES")
        val codecDiagnostics = mutableListOf<String>()
        val events = CopyOnWriteArrayList<JSONObject>()
        val replies = CopyOnWriteArrayList<JSONObject>()
        fun create(timeout: Long = 80) {
            client?.close(); client = SessionClient(context, transport, timeout).apply { onEvent = { events.add(it) }; connectionChanged(true) }
        }
        fun send(value: JSONObject, reverse: Boolean = false) {
            val packet = UUID.randomUUID().toString(); val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key); cipher.updateAAD("vibepier-session-v1|mac|${client!!.device}|$packet".toByteArray())
            val chunks = Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray())).chunked(900)
            val parts = chunks.mapIndexed { i, text -> JSONObject().put("type", "vibepier-session1").put("sender", client!!.device).put("device", client!!.device)
                .put("packet", packet).put("part", i).put("parts", chunks.size).put("data", text) }
            (if (reverse) parts.reversed() else parts).forEach(transport.onSessionFrame)
        }
        fun waitReply() { SystemClock.sleep(180); test.waitForIdleSync() }
        try {
            for ((name, sample) in listOf("ascii" to "a+/=".repeat(50_000), "unicode" to "界".repeat(90_000))) {
                val bytes = sample.toByteArray(Charsets.UTF_8)
                check(io.github.junweiup.vibepier.remote.core.security.StrictUtf8.decode(bytes) == sample)
                val legacy = runCatching { Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString() }.getOrNull()
                codecDiagnostics.add("$name legacyExact=${legacy == sample} expectedChars=${sample.length} actualChars=${legacy?.length}")
            }
            test.runOnMainSync { create(); client!!.pair(); transport.onSessionPair(JSONObject().put("state", "approved").put("device", client!!.device).put("key", Base64.getEncoder().encodeToString(keyBytes)).toString().toByteArray()) }
            test.waitForIdleSync(); check(client!!.paired)
            var operation = ""
            test.runOnMainSync { client!!.saveDraft("fixture", "keep"); operation = client!!.request("send", JSONObject().put("threadId", "fixture").put("text", "keep")) { replies.add(it) } }
            send(JSONObject().put("id", operation).put("ok", "true").put("accepted", true).put("threadId", "fixture"))
            waitReply(); check(replies.last().optBoolean("unknown") && client!!.uncertain("fixture").size == 1)
            send(JSONObject().put("id", operation).put("ok", true).put("accepted", true).put("threadId", "different"))
            test.waitForIdleSync(); check(client!!.draft("fixture") == "keep" && client!!.uncertain("fixture").size == 1)
            send(JSONObject().put("id", operation).put("ok", true).put("accepted", true).put("threadId", "fixture"))
            test.waitForIdleSync(); check(client!!.draft("fixture").isEmpty() && client!!.uncertain("fixture").isEmpty())
            test.runOnMainSync { operation = client!!.request("new", JSONObject().put("cwd", "/fixture").put("text", "synthetic")) { replies.add(it) } }
            waitReply(); send(JSONObject().put("id", operation).put("ok", true).put("cwd", "/fixture").put("threadId", "native-created"))
            test.waitForIdleSync(); check(events.last().getString("threadId") == "native-created")
            val large = "界".repeat(90_000)
            test.runOnMainSync { send(JSONObject().put("event", "probe").put("text", large), reverse = true) }
            test.waitForIdleSync(); check(events.last().getString("text") == large) { "Large event mismatch: actualChars=${events.last().getString("text").length}, expectedChars=${large.length}" }

            test.runOnMainSync {
                create(100_000); transport.frames.clear(); replies.clear()
                repeat(65) { client!!.request("list", JSONObject().put("search", "fixture-$it")) { value -> replies.add(value) } }
                check(transport.packets() == 64 && replies.size == 1 && !replies[0].getBoolean("ok"))
                client!!.cancelPageReads(); transport.frames.clear(); replies.clear()
                var coalescedID = ""
                repeat(17) { coalescedID = client!!.request("list", JSONObject().put("search", "coalesced")) { value -> replies.add(value) } }
                check(transport.packets() == 1 && replies.size == 1)
                client!!.request("send", JSONObject().put("id", coalescedID).put("threadId", "fixture").put("text", "conflicting")) { replies.add(it) }
                check(transport.packets() == 1 && replies.size == 2 && client!!.uncertain("fixture").isEmpty())
                client!!.cancelPageReads(); transport.frames.clear(); replies.clear()
                repeat(11) { client!!.request("fixture-read", JSONObject().put("padding", "x".repeat(200_000))) { value -> replies.add(value) } }
                check(transport.packets() == 10 && replies.size == 1)
                val before = transport.packets()
                client!!.request("send", JSONObject().put("threadId", "fixture").put("text", "x".repeat(300_001))) { replies.add(it) }
                check(transport.packets() == before && !replies.last().getBoolean("ok"))
                create(100_000); transport.frames.clear(); replies.clear()
                val editor = prefs.edit()
                repeat(128) {
                    val id = UUID.randomUUID().toString()
                    editor.putString("pending.$id", JSONObject().put("id", id).put("provider", "codex").put("op", "send").put("threadId", "full").put("text", "unconfirmed").toString())
                }
                check(editor.commit())
                client!!.request("send", JSONObject().put("threadId", "full").put("text", "new")) { replies.add(it) }
                check(transport.frames.isEmpty() && !replies.last().getBoolean("ok") && client!!.uncertain("full").size == 128)
                val saved = client!!.uncertain("full").first()
                client!!.request("send", JSONObject(saved.toString()).put("text", "conflicting")) { replies.add(it) }
                check(transport.frames.isEmpty() && JSONObject(prefs.getString("pending.${saved.getString("id")}", null)!!).getString("text") == "unconfirmed")
                val clear = prefs.edit(); prefs.all.keys.filter { it.startsWith("pending.") }.forEach(clear::remove); check(clear.commit())
                val bytesEditor = prefs.edit()
                repeat(32) {
                    val id = UUID.randomUUID().toString()
                    bytesEditor.putString("pending.$id", JSONObject().put("id", id).put("provider", "codex").put("op", "send").put("threadId", "byte-full").put("text", "x".repeat(260_000)).toString())
                }
                check(bytesEditor.commit())
                check(prefs.all.filterKeys { it.startsWith("pending.") }.values.sumOf { (it as String).toByteArray().size.toLong() } < 8L * 1024 * 1024)
                client!!.request("send", JSONObject().put("threadId", "byte-full").put("text", "x".repeat(90_000))) { replies.add(it) }
                check(transport.frames.isEmpty() && !replies.last().getBoolean("ok") && client!!.uncertain("byte-full").size == 32)
                val removeBytes = prefs.edit(); prefs.all.keys.filter { it.startsWith("pending.") }.forEach(removeBytes::remove); check(removeBytes.commit())
                val id = UUID.randomUUID().toString(); prefs.edit().putString("pending.$id", "invalid-json").commit()
                client!!.retryPending(id) { replies.add(it) }; check(replies.last().getBoolean("unknown") && prefs.contains("pending.$id"))
                prefs.edit().remove("pending.$id").commit()
                create(); transport.frames.clear(); replies.clear()
                client!!.request("unlockPassword", JSONObject().put("password", "synthetic-test-only")) { replies.add(it) }
            }
            SystemClock.sleep(360); test.waitForIdleSync()
            check(transport.packets() == 1 && replies.single().getBoolean("unknown"))
            check(prefs.all.keys.none { it.startsWith("pending.") })
            test.runOnMainSync { client!!.close(); val before = transport.packets(); client!!.request("list") {}; check(transport.packets() == before) }
            return "PASS: real Keystore/JSON encrypted replies; malformed flags and foreign receipts retain uncertainty/draft; valid receipt clears once; late creation preserves native ID; 270KB out-of-order burst; pending request/byte/callback/durable receipt count+8MiB bounds; conflicting IDs/corrupt receipt preserved; password timeout sends once without phone persistence; closed client refuses new work\nSynthetic UTF-8 diagnostics: ${codecDiagnostics.joinToString("; ")}\n"
        } finally {
            test.runOnMainSync { client?.close() }
            client?.let { KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("vibepier.codex.${it.device}") } }
            prefs.edit().clear().commit(); keyBytes.fill(0)
        }
    }
}
