package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionV1Contract
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** Synthetic authenticated host. Call from the instrumentation thread; never grants authority by reflection. */
internal class SessionProfile2Peer(
    private val test: Instrumentation,
    private val client: () -> SessionClient,
    private val requests: () -> List<JSONObject>,
    private val deliver: (JSONObject) -> Unit,
) {
    fun main(block: () -> Unit) {
        var failure: Throwable? = null
        test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
        failure?.let { throw it }
    }
    fun drain() {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper())
        val queue = SessionClient::class.java.getDeclaredField("transmission").apply { isAccessible = true }
            .get(client()) as java.util.concurrent.ExecutorService
        queue.submit {}.get(2, TimeUnit.SECONDS)
        test.waitForIdleSync()
    }
    fun latest(method: String): JSONObject {
        drain()
        return requests().lastOrNull { it.optJSONObject("body")?.optString("method") == method }
            ?: error("Missing profile-2 request: $method")
    }
    private fun actions() = JSONObject().apply {
        SessionV1Contract.capabilityKeys.forEach { put(it, JSONObject().put("supported", true).put("available", true).put("reason", "available")) }
    }
    fun negotiate() {
        main { client().refreshProviderAccess() }
        drain()
        val request = requests().last { it.optString("op") == "providers" }
        val adapters = JSONArray(listOf("codex", "claude").map { source -> JSONObject().put("id", source)
            .put("provider", source).put("default", true).put("backendKinds", JSONArray().put("desktopAttached")).put("actions", actions()) })
        deliver(JSONObject().put("id", request.getString("id")).put("ok", true)
            .put("providerAccess", io.github.junweiup.vibepier.remote.core.session.SessionProviderAccess(0, setOf("codex", "claude")).json())
            .put("agentCapabilities", JSONObject().put("version", 1).put("revision", "probe-host").put("adapters", adapters))
            .put("agentProfiles", JSONObject().put("versions", JSONArray().put(2)).put("minimumClientVersion", 2)
                .put("methods", JSONArray(listOf("agent.describe", "session.list", "session.open", "session.snapshot", "operation.get",
                    "workspace.list", "session.creationOptions", "session.create", "message.submit", "session.configure", "turn.interrupt")))))
        test.waitForIdleSync()
        main { check(client().agent.negotiated && client().agentCapabilitiesKnown) }
        drain()
    }
    fun row(source: String, thread: String) = JSONObject().put("adapterId", source).put("nativeThreadId", thread)
        .put("sessionRef", "$source:$thread").put("ownershipEpoch", "probe-owner").put("capabilityRevision", "probe-capabilities")
    fun read(request: JSONObject, result: JSONObject) {
        val id = request.getString("id")
        deliver(JSONObject().put("id", id).put("ok", true).put("body", JSONObject().put("agentProtocol", 2)
            .put("requestId", id).put("result", result)))
        test.waitForIdleSync()
    }
    fun discover(source: String, thread: String) {
        main { client().provider = source; client().request("list") { check(it.opt("ok") == true) } }
        read(latest("session.list"), JSONObject().put("sessions", JSONArray().put(row(source, thread))).put("nextOffset", -1))
        main { check(client().agent.session(source, thread) != null) }
    }
    fun submit(source: String, thread: String, text: String, callback: (JSONObject) -> Unit): Pair<String, JSONObject> {
        var operation = ""
        main { client().provider = source; operation = client().request("send", JSONObject().put("threadId", thread).put("text", text)
            .put("attachments", JSONArray((0 until client().attachments(thread).length()).map {
                client().attachments(thread).getJSONObject(it).getString("attachmentId")
            })), callback) }
        val snapshot = latest("session.snapshot")
        read(snapshot, JSONObject().put("session", row(source, thread)).put("controlLease", "probe-lease")
            .put("snapshot", JSONObject().put("threadId", thread).put("provider", source).put("contentState", "complete")
                .put("status", "idle").put("canSend", true).put("agentCapabilities", JSONObject().put("version", 1)
                    .put("provider", source).put("adapterId", source).put("revision", "probe-capabilities").put("actions", actions()))))
        val mutation = latest("message.submit")
        check(mutation.getJSONObject("body").getString("operationId") == operation)
        check(mutation.getJSONObject("body").getString("controlLease") == "probe-lease")
        return operation to mutation
    }
    fun confirmed(request: JSONObject): JSONObject {
        val original = request.getJSONObject("body")
        val id = request.getString("id")
        val evidence = JSONObject().put("nativeMessageId", "probe-message")
            .put("turnId", "probe-turn").put("turnIdentityKind", "nativeTurn")
        val body = JSONObject().put("agentProtocol", 2).put("requestId", id)
            .put("operationId", original.getString("operationId")).put("status", "confirmed")
            .put("target", JSONObject(original.getJSONObject("target").toString()))
            .put("effect", "message.submitted").put("result", evidence)
        return JSONObject().put("id", id).put("ok", true).put("body", body)
    }
}
