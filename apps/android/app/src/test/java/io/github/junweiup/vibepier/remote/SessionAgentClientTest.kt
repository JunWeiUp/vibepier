package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionAgentClientTest {
    private class Store : SessionAgentClient.Storage {
        val values = linkedMapOf<String, String>(); var canSave = true; var canRemove = true
        override fun pending() = values.toMap()
        override fun save(operationId: String, original: String): Boolean {
            if (!canSave) return false
            values[operationId] = original; return true
        }
        override fun remove(operationId: String): Boolean { if (!canRemove) return false; values.remove(operationId); return true }
    }
    private val target = SessionAgentProtocol.Target.Session("session", "owner", "revision")
    private fun profile() = JSONObject().put("versions", JSONArray().put(2)).put("minimumClientVersion", 2)
        .put("methods", JSONArray(SessionAgentProtocol.Method.entries.map { it.wire }))
    private fun proof(body: JSONObject, status: String = "confirmed") = JSONObject().put("id", body.getString("requestId")).put("ok", status == "confirmed")
        .put("body", JSONObject().put("agentProtocol", 2).put("requestId", body.getString("requestId")).put("operationId", body.getString("operationId"))
            .put("status", status).put("effect", "message.submitted").put("target", target.json())
            .put("result", JSONObject().put("nativeMessageId", "native").put("turnId", "turn").put("turnIdentityKind", "nativeTurn"))).apply {
            if (status in setOf("accepted", "unknown")) put("unknown", true)
        }
    @Test fun mutationIsReservedBeforeTransportAndMalformedReplyRemainsUnknown() {
        val store = Store(); var sent = 0; var transportReply: ((JSONObject) -> Unit)? = null
        val client = SessionAgentClient({ "host" }, { _, callback -> check(store.values.size == 1); sent++; transportReply = callback }, store)
        var reply: SessionAgentProtocol.Reply? = null
        client.mutate(SessionAgentProtocol.Method.SUBMIT, target, JSONObject().put("mode", "start"), "lease") { reply = it }
        assertEquals(0, sent); assertTrue(reply is SessionAgentProtocol.Reply.Failure)
        client.discover(profile())
        client.mutate(SessionAgentProtocol.Method.SUBMIT, target, JSONObject().put("mode", "start"), "lease") { reply = it }
        assertEquals(1, sent)
        val original = store.values.values.single()
        transportReply!!(JSONObject().put("ok", false).put("unknown", true))
        assertEquals(SessionAgentProtocol.Status.UNKNOWN, (reply as SessionAgentProtocol.Reply.Mutation).status)
        assertEquals(original, store.values.values.single()); assertEquals(1, sent)
    }
    @Test fun failedLocalJournalSavePreventsSendingAndCleanupFailurePreservesOriginal() {
        val store = Store(); var sent = 0; var wire = JSONObject(); var callback: ((JSONObject) -> Unit)? = null
        val client = SessionAgentClient({ "host" }, { request, reply -> wire = request; callback = reply; sent++ }, store); client.discover(profile())
        store.canSave = false
        client.mutate(SessionAgentProtocol.Method.SUBMIT, target, JSONObject().put("mode", "start"), "lease") { }
        assertEquals(0, sent)
        store.canSave = true; store.canRemove = false
        var result: SessionAgentProtocol.Reply? = null
        client.mutate(SessionAgentProtocol.Method.SUBMIT, target, JSONObject().put("mode", "start"), "lease") { result = it }
        val original = store.values.values.single(); callback!!(proof(wire.getJSONObject("body")))
        assertEquals(SessionAgentProtocol.Status.UNKNOWN, (result as SessionAgentProtocol.Reply.Mutation).status)
        assertEquals(original, store.values.values.single())
    }
    @Test fun acceptedAndReconnectNeverResubmitAndReconciliationUsesOnlyOperationGet() {
        val store = Store(); var identity = "host"; val sent = mutableListOf<JSONObject>(); var callback: ((JSONObject) -> Unit)? = null
        val client = SessionAgentClient({ identity }, { request, reply -> sent.add(JSONObject(request.toString())); callback = reply }, store)
        client.discover(profile())
        val operation = SessionAgentProtocol.id()
        client.mutate(SessionAgentProtocol.Method.SUBMIT, target, JSONObject().put("mode", "start"), "lease", operation) { }
        val request = sent.single().getJSONObject("body"); callback!!(proof(request, "accepted"))
        val original = store.values.getValue(operation)
        client.clearConnection(); assertEquals(1, sent.size); assertEquals(original, store.values.getValue(operation))
        client.discover(profile()); client.reconcile(operation) { }
        assertEquals("operation.get", sent.last().getJSONObject("body").getString("method"))
        val lookup = sent.last().getJSONObject("body")
        callback!!(JSONObject().put("id", lookup.getString("requestId")).put("ok", true).put("body", JSONObject().put("agentProtocol", 2)
            .put("requestId", lookup.getString("requestId")).put("result", JSONObject().put("operation", proof(request).getJSONObject("body")))))
        assertFalse(store.values.containsKey(operation)); assertEquals(2, sent.size)
        identity = "different-host"; assertFalse(client.negotiated)
    }
    @Test fun sameLogicalOperationCannotBeSubmittedAgainWithAnotherTarget() {
        val store = Store(); var sent = 0
        val client = SessionAgentClient({ "host" }, { _, _ -> sent++ }, store); client.discover(profile())
        val operation = SessionAgentProtocol.id()
        client.mutate(SessionAgentProtocol.Method.SUBMIT, target, JSONObject().put("mode", "start"), "lease", operation) { }
        client.mutate(SessionAgentProtocol.Method.SUBMIT, target.copy(ownershipEpoch = "another"), JSONObject().put("mode", "start"), "lease", operation) { assertTrue(it is SessionAgentProtocol.Reply.Failure) }
        assertEquals(1, sent); assertEquals(1, store.values.size)
    }
}
