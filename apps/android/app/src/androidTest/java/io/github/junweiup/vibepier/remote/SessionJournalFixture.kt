package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.core.session.*
import org.json.JSONObject
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Isolated current-profile journal, with real encrypted discovery; no device or production preferences. */
internal class SessionJournalFixture(private val test: Instrumentation) : AutoCloseable {
    private val namespace = "current-journal-${UUID.randomUUID()}"
    val context = object : ContextWrapper(test.targetContext) {
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("$namespace-$name", mode)
    }
    val prefs = PrivatePreferences.open(context, "sessions")
    private val keyBytes = ByteArray(32) { 47 }
    private val key = SecretKeySpec(keyBytes, "AES")
    private val frames = CopyOnWriteArrayList<JSONObject>()
    private val transport = object : SessionTransport {
        override val mode = "bluetooth"
        override val enrollmentReady = true
        override var onSessionFrame: (JSONObject) -> Unit = {}
        override var onSessionPair: (ByteArray?) -> Unit = {}
        override fun requestSessionPair(device: String, name: String) {}
        override fun readSessionPair() {}
        override fun sendBinding(message: JSONObject) { frames.add(JSONObject(message.toString())) }
    }
    lateinit var client: SessionClient; private set
    private val peer = SessionProfile2Peer(test, { client }, ::requests, ::deliver)
    init {
        peer.main {
            client = SessionClient(context, transport, 60_000)
            check(!client.providerAccessKnown && client.enabledProviders.isEmpty() && !client.agent.negotiated)
            client.connectionChanged(true); client.pair()
            transport.onSessionPair(JSONObject().put("state", "approved").put("device", client.device)
                .put("key", Base64.getEncoder().encodeToString(keyBytes)).toString().toByteArray())
        }
        peer.negotiate()
    }
    private fun requests() = frames.groupBy { it.getString("packet") }.mapNotNull { (packet, parts) ->
        if (parts.size != parts.first().getInt("parts")) return@mapNotNull null
        val bytes = Base64.getDecoder().decode(parts.sortedBy { it.getInt("part") }.joinToString("") { it.getString("data") })
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD("vibepier-session-v1|phone|${client.device}|$packet".toByteArray())
        JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
    }
    private fun deliver(value: JSONObject) {
        val packet = UUID.randomUUID().toString(); val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD("vibepier-session-v1|mac|${client.device}|$packet".toByteArray())
        val parts = Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray())).chunked(900)
        parts.forEachIndexed { i, part -> transport.onSessionFrame(JSONObject().put("type", "vibepier-session1")
            .put("sender", client.device).put("device", client.device).put("packet", packet).put("part", i).put("parts", parts.size).put("data", part)) }
    }
    /** Serialize exactly the current writer's body and UI projection (the persisted field is named legacy). */
    fun seed(original: JSONObject): JSONObject {
        val id = original.getString("id"); val source = original.optString("provider", client.provider)
        val adapter = checkNotNull(client.selectedAgentAdapter(source)).id
        val projection = JSONObject(original.toString()).put("provider", source).put("agentAdapterId", adapter).put("agentOperationId", id)
        val method = when (original.getString("op")) {
            "new" -> SessionAgentProtocol.Method.CREATE
            "settings" -> SessionAgentProtocol.Method.CONFIGURE
            "send" -> SessionAgentProtocol.Method.SUBMIT
            else -> error("Unsupported synthetic journal intent")
        }
        val target = if (method == SessionAgentProtocol.Method.CREATE)
            SessionAgentProtocol.Target.Creation(adapter, "fixture-workspace", id, "fixture-options")
        else SessionAgentProtocol.Target.Session("$adapter:${original.getString("threadId")}", "fixture-owner", "fixture-capabilities")
        if (method == SessionAgentProtocol.Method.CREATE) projection.put("draftId", id)
        val params = when (method) {
            SessionAgentProtocol.Method.CREATE -> JSONObject().put("initialMessage", JSONObject().put("text", original.optString("text")))
            SessionAgentProtocol.Method.CONFIGURE -> JSONObject().put("options", JSONObject().put("mode", original.optString("mode", "auto")))
            else -> JSONObject().put("mode", "send").put("content", JSONObject().put("text", original.optString("text")))
        }
        val body = SessionAgentProtocol.Request(SessionAgentProtocol.id(), method, target, params, id, "fixture-lease").json()
        check(prefs.edit().putString("agentPending.$id", JSONObject().put("identity", client.authorizationIdentity)
            .put("body", body).put("legacy", projection).toString()).commit())
        check(client.agent.hasPendingOperation(id))
        return projection
    }
    fun settleCreation(id: String) {
        val body = JSONObject(prefs.getString("agentPending.$id", null)!!).getJSONObject("body")
        val result = JSONObject().put("sessionCreated", true).put("initialInput", "confirmed")
            .put("session", peer.row("codex", "00000000-0000-4000-8000-000000000004")
                .put("workspaceRef", "fixture-workspace").put("cwd", client.agent.context(id)!!.getString("cwd")))
            .put("nativeMessageId", "fixture-message").put("turnId", "fixture-turn").put("turnIdentityKind", "nativeTurn")
        deliver(JSONObject().put("id", body.getString("requestId")).put("ok", true).put("body", JSONObject()
            .put("agentProtocol", 2).put("requestId", body.getString("requestId")).put("operationId", id)
            .put("status", "confirmed").put("target", body.getJSONObject("target")).put("effect", "session.created").put("result", result)))
    }
    override fun close() {
        peer.main { client.close(); DeviceKeys(context).clear(); check(prefs.edit().clear().commit()) }
        keyBytes.fill(0)
    }
}
