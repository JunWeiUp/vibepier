package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionAgentProtocolTest {
    private val target = SessionAgentProtocol.Target.Session("session", "owner", "capabilities")
    private fun request() = SessionAgentProtocol.Request(SessionAgentProtocol.id(), SessionAgentProtocol.Method.SUBMIT, target,
        JSONObject().put("mode", "start").put("content", JSONArray().put(JSONObject().put("type", "text").put("text", "Synthetic"))),
        SessionAgentProtocol.id(), SessionAgentProtocol.id())
    private fun result() = JSONObject().put("nativeMessageId", "native-message").put("turnId", "native-turn").put("turnIdentityKind", "nativeTurn")
    private fun response(request: SessionAgentProtocol.Request, status: String = "confirmed", proof: JSONObject = result()): JSONObject {
        val body = JSONObject().put("agentProtocol", 2).put("requestId", request.requestId).put("operationId", request.operationId)
            .put("status", status).put("effect", "message.submitted").put("target", target.json()).put("result", proof)
        return JSONObject().put("id", request.requestId).put("ok", status == "confirmed").put("body", body).apply {
            if (status in setOf("accepted", "unknown")) put("unknown", true)
        }
    }
    @Test fun speedOptionIsEncodedAndInvalidTiersAreRejected() {
        fun configure(tier: Any) = SessionAgentProtocol.Request(SessionAgentProtocol.id(), SessionAgentProtocol.Method.CONFIGURE, target,
            JSONObject().put("options", JSONObject().put("serviceTier", tier)), SessionAgentProtocol.id(), SessionAgentProtocol.id())
        for (tier in listOf("standard", "priority")) assertEquals(tier, configure(tier).json().getJSONObject("params").getJSONObject("options").getString("serviceTier"))
        assertThrows(IllegalArgumentException::class.java) { configure("unknown") }
        assertThrows(IllegalArgumentException::class.java) { configure(true) }
    }

    @Test fun submissionConfirmationRequiresNativeProofAndOriginalScope() {
        val request = request(); assertNotNull(SessionAgentProtocol.reply(response(request), request))
        assertNull(SessionAgentProtocol.reply(response(request, proof = JSONObject().put("accepted", true)), request))
        assertNull(SessionAgentProtocol.reply(response(request).apply { getJSONObject("body").getJSONObject("target").put("ownershipEpoch", "changed") }, request))
        assertNull(SessionAgentProtocol.reply(response(request).apply { getJSONObject("body").put("operationId", SessionAgentProtocol.id()) }, request))
        assertNull(SessionAgentProtocol.reply(response(request).put("unknown", true), request))
        assertNull(SessionAgentProtocol.reply(response(request, proof = result().put("turnIdentityKind", "guessed")), request))
    }
    @Test fun acceptedReservationIsPendingAndNeverRenderedAsSuccessfulSubmission() {
        val request = request()
        assertEquals(SessionAgentProtocol.Status.ACCEPTED, (SessionAgentProtocol.reply(response(request, "accepted"), request) as SessionAgentProtocol.Reply.Mutation).status)
        assertNull(SessionAgentProtocol.reply(response(request, "accepted").put("ok", true), request))
        assertNull(SessionAgentProtocol.reply(response(request, "unexpected"), request))
    }
    @Test fun profileNegotiationRejectsMissingMethodsNewMinimumAndWrongTypes() {
        val good = JSONObject().put("versions", JSONArray().put(2)).put("minimumClientVersion", 2)
            .put("methods", JSONArray(SessionAgentProtocol.Method.entries.map { it.wire }))
        assertNotNull(SessionAgentProtocol.Profile.decode(good))
        assertNull(SessionAgentProtocol.Profile.decode(JSONObject(good.toString()).put("minimumClientVersion", 3)))
        assertNull(SessionAgentProtocol.Profile.decode(JSONObject(good.toString()).put("versions", JSONArray().put("2"))))
        assertNull(SessionAgentProtocol.Profile.decode(JSONObject(good.toString()).put("methods", JSONArray().put("session.open"))))
    }
    @Test fun requestIdentityAndUnknownCommandsAreRefusedBeforeSending() {
        assertThrows(IllegalArgumentException::class.java) { SessionAgentProtocol.Request("invalid", SessionAgentProtocol.Method.OPEN, target, JSONObject()) }
        assertThrows(IllegalArgumentException::class.java) { SessionAgentProtocol.Request(SessionAgentProtocol.id(), SessionAgentProtocol.Method.OPEN, target, JSONObject().put("script", "arbitrary")) }
        assertThrows(IllegalArgumentException::class.java) { SessionAgentProtocol.Request(SessionAgentProtocol.id(), SessionAgentProtocol.Method.SUBMIT, target, JSONObject()) }
    }
    @Test fun hostReadsIncludeTheRequiredEmptyTargetObjectWithoutWriteAuthority() {
        for (method in listOf(SessionAgentProtocol.Method.DESCRIBE, SessionAgentProtocol.Method.OPERATION)) {
            val params = JSONObject().apply { if (method == SessionAgentProtocol.Method.OPERATION) put("operationId", SessionAgentProtocol.id()) }
            val body = SessionAgentProtocol.Request(SessionAgentProtocol.id(), method, null, params).json()
            assertEquals(0, body.getJSONObject("target").length())
            assertFalse(body.has("operationId")); assertFalse(body.has("controlLease"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            SessionAgentProtocol.Request(SessionAgentProtocol.id(), SessionAgentProtocol.Method.CONFIGURE, null,
                JSONObject().put("options", JSONObject().put("executionMode", "plan")), SessionAgentProtocol.id(), SessionAgentProtocol.id())
        }
    }
    @Test fun freshDiscoveryPreservesEmptySearchInTheSharedProfileTwoRequest() {
        val fixture = JSONObject(javaClass.getResourceAsStream("/agent-session-v2.json")!!.bufferedReader().use { it.readText() })
        val vectors = fixture.getJSONArray("vectors")
        val vector = (0 until vectors.length()).map { vectors.getJSONObject(it) }.single { it.opt("name") == "empty-search-list" }
        val shared = vector.getJSONObject("request")
        for (provider in SessionV1Contract.providers) for (method in listOf(SessionAgentProtocol.Method.LIST, SessionAgentProtocol.Method.WORKSPACES)) {
            val request = SessionAgentProtocol.Request(shared.getString("requestId"), method,
                SessionAgentProtocol.Target.Adapter("$provider.currentV1"), shared.getJSONObject("params"))
            assertEquals("", request.json().getJSONObject("params").get("search"))
            assertEquals("$provider.currentV1", request.json().getJSONObject("target").get("adapterId"))
            assertFalse(request.json().has("operationId")); assertFalse(request.json().has("controlLease"))
            if (provider == "codex" && method == SessionAgentProtocol.Method.LIST) {
                assertEquals(vector.getString("fingerprint"), SessionAgentProtocol.fingerprint(request.json()))
                assertEquals(vector.getString("canonical"), SessionAgentProtocol.canonical(JSONObject(request.json().toString()).apply { remove("requestId") }))
            }
        }
    }
    @Test fun fingerprintIgnoresTransportAttemptAndLeaseButBindsSemanticIntent() {
        val original = request().json()
        val renewed = JSONObject(original.toString()).put("requestId", SessionAgentProtocol.id()).put("controlLease", SessionAgentProtocol.id())
        assertEquals(SessionAgentProtocol.fingerprint(original), SessionAgentProtocol.fingerprint(renewed))
        assertNotEquals(SessionAgentProtocol.fingerprint(original), SessionAgentProtocol.fingerprint(JSONObject(original.toString()).apply { getJSONObject("target").put("ownershipEpoch", "other") }))
        assertEquals("{\"a\":1,\"z\":\"/\",\"😀\":true}", SessionAgentProtocol.canonical(JSONObject().put("😀", true).put("z", "/").put("a", 1)))
        assertThrows(IllegalArgumentException::class.java) { SessionAgentProtocol.canonical(JSONObject().put("n", 1.5)) }
    }
    @Test fun eventGapsOldRevisionsAndWrongSubscriptionsDoNotChangeState() {
        val observation = SessionAgentObservation("sub", "session")
        fun event(sequence: Long, revision: Long = sequence, epoch: String = "stream", sub: String = "sub") =
            SessionAgentProtocol.Event(sub, "session", epoch, sequence, "item.updated", revision, JSONObject().put("itemId", "item"))
        assertEquals(SessionAgentObservation.Decision.RESYNC, observation.accept(event(1)))
        assertTrue(observation.snapshot("stream", 1, true))
        assertEquals(SessionAgentObservation.Decision.APPLY, observation.accept(event(2)))
        assertEquals(SessionAgentObservation.Decision.IGNORE, observation.accept(event(2)))
        assertEquals(SessionAgentObservation.Decision.IGNORE, observation.accept(event(3, 1)))
        assertEquals(SessionAgentObservation.Decision.IGNORE, observation.accept(event(4, sub = "other")))
        assertEquals(SessionAgentObservation.Decision.RESYNC, observation.accept(event(5)))
        assertFalse(observation.snapshot("stream", 5, false))
        assertTrue(observation.snapshot("stream", 5, true))
        assertEquals(SessionAgentObservation.Decision.RESYNC, observation.accept(event(6, epoch = "restarted")))
    }
    @Test fun partialProjectionPreservesLoadedHistoryAndDisablesWrites() {
        val previous = JSONObject().put("messages", JSONArray().put(JSONObject().put("id", "older")).put(JSONObject().put("id", "latest").put("text", "old")))
        val next = JSONObject().put("contentState", "partial").put("canSend", true).put("agentCapabilities", JSONObject())
            .put("messages", JSONArray().put(JSONObject().put("id", "latest").put("text", "updated")))
        val merged = SessionAgentConversation.mergePartial(previous, next)
        assertEquals(2, merged.getJSONArray("messages").length()); assertEquals("older", merged.getJSONArray("messages").getJSONObject(0).getString("id"))
        assertFalse(merged.getBoolean("canSend")); assertFalse(merged.has("agentCapabilities"))
    }
    @Test fun sharedProfileTwoVectorsMatchCanonicalHashesReceiptsAndEvents() {
        val fixture = JSONObject(javaClass.getResourceAsStream("/agent-session-v2.json")!!.bufferedReader().use { it.readText() })
        val vectors = fixture.getJSONArray("vectors")
        for (index in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(index); val body = vector.getJSONObject("request")
            val semantic = JSONObject(body.toString()).apply { remove("requestId"); remove("controlLease") }
            assertEquals(vector.getString("canonical"), SessionAgentProtocol.canonical(semantic))
            assertEquals(vector.getString("fingerprint"), SessionAgentProtocol.fingerprint(body))
        }
        val body = (0 until vectors.length()).map { vectors.getJSONObject(it) }.single { it.getString("name") == "submit" }.getJSONObject("request")
        val scope = body.getJSONObject("target")
        val request = SessionAgentProtocol.Request(body.getString("requestId"), SessionAgentProtocol.Method.SUBMIT,
            SessionAgentProtocol.Target.Session(scope.getString("sessionRef"), scope.getString("ownershipEpoch"), scope.getString("capabilityRevision")),
            body.getJSONObject("params"), body.getString("operationId"), body.getString("controlLease"))
        assertNotNull(SessionAgentProtocol.reply(JSONObject().put("id", request.requestId).put("ok", true).put("body", fixture.getJSONObject("confirmed")), request))
        assertNotNull(SessionAgentProtocol.reply(JSONObject().put("id", request.requestId).put("ok", false).put("unknown", true).put("body", fixture.getJSONObject("unknown")), request))
        assertNotNull(SessionAgentProtocol.event(JSONObject().put("event", "agentEvent").put("body", fixture.getJSONObject("event"))))
    }
}
