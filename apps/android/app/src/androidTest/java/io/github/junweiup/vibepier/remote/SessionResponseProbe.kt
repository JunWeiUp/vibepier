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
import javax.crypto.spec.GCMParameterSpec
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
            client?.let { old ->
                val executor = old.javaClass.getDeclaredField("transmission").apply { isAccessible = true }.get(old) as java.util.concurrent.ExecutorService
                old.close(); check(executor.awaitTermination(2, java.util.concurrent.TimeUnit.SECONDS))
            }
            client = SessionClient(context, transport, timeout).apply { onEvent = { events.add(it) }; connectionChanged(true) }
        }
        fun pendingRequests(): Int = (client!!.javaClass.getDeclaredField("pending").apply { isAccessible = true }.get(client) as Map<*, *>).size
        fun send(value: JSONObject, reverse: Boolean = false) {
            val packet = UUID.randomUUID().toString(); val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key); cipher.updateAAD("vibepier-session-v1|mac|${client!!.device}|$packet".toByteArray())
            val chunks = Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray())).chunked(900)
            val parts = chunks.mapIndexed { i, text -> JSONObject().put("type", "vibepier-session1").put("sender", client!!.device).put("device", client!!.device)
                .put("packet", packet).put("part", i).put("parts", chunks.size).put("data", text) }
            (if (reverse) parts.reversed() else parts).forEach(transport.onSessionFrame)
        }
        fun requests(): List<JSONObject> = transport.frames.map { it.getString("packet") }.distinct().mapNotNull { packet ->
            val parts = transport.frames.filter { it.getString("packet") == packet }.sortedBy { it.getInt("part") }
            if (parts.size != parts.first().getInt("parts")) return@mapNotNull null
            val bytes = Base64.getDecoder().decode(parts.joinToString("") { it.getString("data") })
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            cipher.updateAAD("vibepier-session-v1|phone|${client!!.device}|$packet".toByteArray())
            JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
        }
        val peer = SessionProfile2Peer(test, { client!! }, ::requests, { send(it) })
        fun reset(timeout: Long = 80) {
            peer.main { create(timeout) }
            peer.drain()
            // Reconnection now performs discovery. Finish it before measuring the isolated wire budgets.
            val discovery = requests().last { it.optString("op") == "providers" }
            send(JSONObject().put("id", discovery.getString("id")).put("ok", false).put("code", "probe_no_profile"))
            test.waitForIdleSync()
            peer.main { check(pendingRequests() == 0); transport.frames.clear(); replies.clear() }
        }
        fun waitReply() { SystemClock.sleep(2_100); test.waitForIdleSync() }
        try {
            for ((name, sample) in listOf("ascii" to "a+/=".repeat(50_000), "unicode" to "界".repeat(90_000))) {
                val bytes = sample.toByteArray(Charsets.UTF_8)
                check(io.github.junweiup.vibepier.remote.core.security.StrictUtf8.decode(bytes) == sample)
                val legacy = runCatching { Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString() }.getOrNull()
                codecDiagnostics.add("$name legacyExact=${legacy == sample} expectedChars=${sample.length} actualChars=${legacy?.length}")
            }
            peer.main { create(2_000); client!!.pair(); transport.onSessionPair(JSONObject().put("state", "approved").put("device", client!!.device).put("key", Base64.getEncoder().encodeToString(keyBytes)).toString().toByteArray()) }
            test.waitForIdleSync(); check(client!!.paired)
            // Pairing alone never authorizes a write and must not reserve a receipt.
            peer.main {
                client!!.request("send", JSONObject().put("threadId", "fixture").put("text", "keep")) {
                    check(it.optString("code") == "agent_state_not_ready")
                }
                check(client!!.uncertain("fixture").isEmpty())
                client!!.saveDraft("fixture", "keep")
            }
            peer.drain()
            val noPolicy = requests().last { it.optString("op") == "providers" }
            send(JSONObject().put("id", noPolicy.getString("id")).put("ok", true))
            test.waitForIdleSync()
            peer.main { check(!client!!.providerAccessKnown && !client!!.agent.negotiated && client!!.enabledProviders.isEmpty()) }
            peer.negotiate(); peer.discover("codex", "fixture")
            val (_, mutation) = peer.submit("codex", "fixture", "keep") { replies.add(it) }
            send(peer.confirmed(mutation).put("ok", "true"))
            waitReply(); check(replies.last().optBoolean("unknown") && client!!.uncertain("fixture").size == 1)
            val foreign = peer.confirmed(mutation)
            foreign.getJSONObject("body").getJSONObject("target").put("sessionRef", "foreign-session")
            send(foreign)
            test.waitForIdleSync(); check(client!!.draft("fixture") == "keep" && client!!.uncertain("fixture").size == 1)
            val missingEvidence = peer.confirmed(mutation)
            missingEvidence.getJSONObject("body").getJSONObject("result").remove("nativeMessageId")
            send(missingEvidence)
            test.waitForIdleSync(); check(client!!.draft("fixture") == "keep" && client!!.uncertain("fixture").size == 1)
            send(peer.confirmed(mutation))
            test.waitForIdleSync(); check(client!!.draft("fixture").isEmpty() && client!!.uncertain("fixture").isEmpty())
            val beforeOldPush = events.size
            send(JSONObject().put("event", "snapshot").put("provider", "codex").put("viewVersion", client!!.viewVersion)
                .put("threadId", "fixture").put("canSend", true))
            test.waitForIdleSync(); check(events.size == beforeOldPush)
            // A pre-upgrade session record is retained but neither resumed nor settled by old wire replies.
            val operation = UUID.randomUUID().toString()
            peer.main {
                check(prefs.edit().putString("pending.$operation", JSONObject().put("id", operation).put("provider", "codex")
                    .put("op", "new").put("cwd", "/fixture").put("text", "synthetic").toString()).commit())
            }
            val eventCount = events.size
            send(JSONObject().put("id", operation).put("ok", true).put("cwd", "/fixture").put("threadId", "native-created"))
            test.waitForIdleSync(); check(events.size == eventCount && prefs.contains("pending.$operation"))
            peer.main {
                val before = transport.frames.size
                client!!.retryPending(operation) { check(it.optBoolean("unknown")) }
                client!!.clearReceipt(operation)
                check(!client!!.abandonSettings(operation))
                check(transport.frames.size == before && prefs.contains("pending.$operation") && client!!.uncertain("").isEmpty())
                check(prefs.edit().remove("pending.$operation").commit()) // Own isolated fixture only.
            }
            val large = "界".repeat(90_000)
            peer.main { send(JSONObject().put("event", "probe").put("text", large), reverse = true) }
            test.waitForIdleSync(); check(events.last().getString("text") == large) { "Large event mismatch: actualChars=${events.last().getString("text").length}, expectedChars=${large.length}" }

            reset(100_000)
            peer.main {
                for (op in listOf("apkChunk", "attachmentChunk", "newAttachmentChunk")) {
                    client!!.request(op) { check(it.optString("code") == "unsupported") }
                }
                client!!.request("apkOffer", JSONObject().put("downloadVersion", 1)) { check(it.optString("code") == "unsupported") }
                client!!.request("attachmentStart", JSONObject().put("uploadVersion", 1)) { check(it.optString("code") == "unsupported") }
            }
            peer.drain(); check(transport.frames.isEmpty())
            val control = UUID.randomUUID().toString()
            var controlLookup = ""
            peer.main {
                val original = JSONObject().put("id", control).put("provider", "codex").put("op", "codexUsageReset")
                    .put("accountId", "fixture-account").put("creditId", "fixture-credit")
                check(prefs.edit().putString("pending.$control", original.toString()).commit())
                controlLookup = client!!.request("receipt", JSONObject().put("operation", control)) { check(it.optString("state") == "unknown") }
            }
            peer.drain()
            check(requests().single().optString("op") == "receipt")
            send(JSONObject().put("id", controlLookup).put("ok", true).put("state", "unknown"))
            test.waitForIdleSync()
            peer.main { check(prefs.contains("pending.$control")); client!!.clearReceipt(control); check(!prefs.contains("pending.$control")); transport.frames.clear() }
            peer.main {
                repeat(65) { client!!.request("readMarkdownFile", JSONObject().put("search", "fixture-$it")) { value -> replies.add(value) } }
                check(pendingRequests() == 64 && replies.size == 1 && !replies[0].getBoolean("ok")) {
                    "request bound: pending=${pendingRequests()} rejected=${replies.size}"
                }
                client!!.cancelPageReads(); transport.frames.clear(); replies.clear()
                var coalescedID = ""
                repeat(17) { coalescedID = client!!.request("readMarkdownFile", JSONObject().put("search", "coalesced")) { value -> replies.add(value) } }
                check(pendingRequests() == 1 && replies.size == 1)
                client!!.request("lockScreen", JSONObject().put("id", coalescedID).put("threadId", "fixture").put("text", "conflicting")) { replies.add(it) }
                check(pendingRequests() == 1 && replies.size == 2 && client!!.uncertain("fixture").isEmpty())
                check(replies.last().optString("error") == context.getString(R.string.client_request_id_conflict))
                client!!.cancelPageReads(); transport.frames.clear(); replies.clear()
                repeat(11) { client!!.request("fixture-read", JSONObject().put("padding", "x".repeat(200_000))) { value -> replies.add(value) } }
                check(pendingRequests() == 10 && replies.size == 1)
                val before = pendingRequests()
                client!!.request("lockScreen", JSONObject().put("threadId", "fixture").put("text", "x".repeat(300_001))) { replies.add(it) }
                check(pendingRequests() == before && !replies.last().getBoolean("ok"))
                check(replies.last().optString("error") == context.getString(R.string.client_request_too_large))
            }
            reset(100_000)
            peer.main {
                // Independent durable controls exercise wire/journal limits without a session capability refusal masking them.
                // Transport is synthetic: no desktop control action is delivered.
                val editor = prefs.edit()
                repeat(128) {
                    val id = UUID.randomUUID().toString()
                    editor.putString("pending.$id", JSONObject().put("id", id).put("provider", "codex").put("op", "lockScreen").put("threadId", "full").put("text", "unconfirmed").toString())
                }
                check(editor.commit())
                client!!.request("lockScreen", JSONObject().put("threadId", "full").put("text", "new")) { replies.add(it) }
                check(transport.frames.isEmpty() && !replies.last().getBoolean("ok") && client!!.uncertain("full").size == 128)
                check(replies.last().optString("error") == context.getString(R.string.client_receipt_storage_full))
                val saved = client!!.uncertain("full").first()
                client!!.request("lockScreen", JSONObject(saved.toString()).put("text", "conflicting")) { replies.add(it) }
                check(transport.frames.isEmpty() && JSONObject(prefs.getString("pending.${saved.getString("id")}", null)!!).getString("text") == "unconfirmed")
                val clear = prefs.edit(); prefs.all.keys.filter { it.startsWith("pending.") }.forEach(clear::remove); check(clear.commit())
                val bytesEditor = prefs.edit()
                repeat(32) {
                    val id = UUID.randomUUID().toString()
                    bytesEditor.putString("pending.$id", JSONObject().put("id", id).put("provider", "codex").put("op", "lockScreen").put("threadId", "byte-full").put("text", "x".repeat(260_000)).toString())
                }
                check(bytesEditor.commit())
                check(prefs.all.filterKeys { it.startsWith("pending.") }.values.sumOf { (it as String).toByteArray().size.toLong() } < 8L * 1024 * 1024)
                client!!.request("lockScreen", JSONObject().put("threadId", "byte-full").put("text", "x".repeat(90_000))) { replies.add(it) }
                check(transport.frames.isEmpty() && !replies.last().getBoolean("ok") && client!!.uncertain("byte-full").size == 32)
                check(replies.last().optString("error") == context.getString(R.string.client_receipt_storage_full))
                val removeBytes = prefs.edit(); prefs.all.keys.filter { it.startsWith("pending.") }.forEach(removeBytes::remove); check(removeBytes.commit())
                val id = UUID.randomUUID().toString(); prefs.edit().putString("pending.$id", "invalid-json").commit()
                client!!.retryPending(id) { replies.add(it) }; check(replies.last().getBoolean("unknown") && prefs.contains("pending.$id"))
                prefs.edit().remove("pending.$id").commit()
            }
            reset()
            peer.main {
                client!!.request("unlockPassword", JSONObject().put("password", "synthetic-test-only")) { replies.add(it) }
            }
            SystemClock.sleep(360); test.waitForIdleSync()
            check(transport.packets() == 1 && replies.single().getBoolean("unknown"))
            check(prefs.all.keys.none { it.startsWith("pending.") })
            peer.main { client!!.close(); val before = transport.packets(); client!!.request("list") {}; check(transport.packets() == before) }
            return "PASS: real Keystore/JSON encrypted profile-2 replies and leases; pre-negotiation writes refused; malformed flags and foreign receipts retain uncertainty/draft; valid receipt clears once; old session records cannot resend or settle; 270KB out-of-order burst; pending request/byte/callback/durable receipt count+8MiB bounds; conflicting IDs/corrupt receipt preserved; password timeout sends once without phone persistence; closed client refuses new work\nSynthetic UTF-8 diagnostics: ${codecDiagnostics.joinToString("; ")}\n"
        } finally {
            peer.main { client?.close() }
            client?.let { KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("vibepier.codex.${it.device}") } }
            prefs.edit().clear().commit(); keyBytes.fill(0)
        }
    }
}
