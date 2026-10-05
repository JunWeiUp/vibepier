package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionExecutionModesTest {
    private fun catalog(coupled: Boolean = false) = JSONObject().put("executionModePermissionCoupled", coupled)
        .put("executionModes", JSONArray().put(JSONObject().put("id", "default").put("name", "Execute").put("permissionMode", "default"))
            .put(JSONObject().put("id", "plan").put("name", "Plan").put("permissionMode", "plan")))
        .put("composer", JSONObject().put("executionMode", "plan"))
    @Test fun onlyExplicitFiniteCatalogCanOfferPlanning() {
        assertTrue(SessionExecutionModes.decode(JSONObject().put("provider", "codex")).isEmpty())
        assertEquals("plan", SessionExecutionModes.selected(catalog(), SessionExecutionModes.decode(catalog()))?.id)
        assertTrue(SessionExecutionModes.decode(catalog().apply { getJSONArray("executionModes").getJSONObject(1).put("id", "auto") }).isEmpty())
        assertTrue(SessionExecutionModes.decode(catalog().apply { getJSONArray("executionModes").getJSONObject(1).put("id", "default") }).isEmpty())
        assertTrue(SessionExecutionModes.decode(catalog().apply { getJSONObject("composer").put("executionModePermissionCoupled", "true") }).isEmpty())
    }
    @Test fun CoupledCatalogRequiresExplicitNativeMappings() {
        assertEquals(2, SessionExecutionModes.decode(catalog(true)).size)
        assertTrue(SessionExecutionModes.coupled(catalog(true)))
        assertTrue(SessionExecutionModes.decode(catalog(true).apply { getJSONArray("executionModes").getJSONObject(1).remove("permissionMode") }).isEmpty())
        val advertised = catalog(true).put("permissionModes", JSONArray().put(JSONObject().put("id", "default").put("name", "Synthetic approval policy")))
        assertEquals("Synthetic approval policy", SessionExecutionModes.defaultPermissionLabel(advertised))
        assertNull(SessionExecutionModes.defaultPermissionLabel(advertised.put("executionModePermissionCoupled", false)))
    }
    @Test fun CreationKeepsPlanIntentAndOmitsCoupledPermissionFromWire() {
        val independent = SessionCreationDraft.restore(null, "/fixture", "codex").copy(text = "first", model = "fixture", mode = "auto", executionMode = "plan")
        val request = independent.request(SessionAgentProtocol.id(), JSONArray())
        assertEquals("plan", request.getString("executionMode")); assertEquals("auto", request.getString("mode")); assertTrue(independent.matches(request))
        val coupled = independent.copy(mode = "plan", executionModePermissionCoupled = true)
        val native = coupled.request(SessionAgentProtocol.id(), JSONArray())
        assertFalse(native.has("mode")); assertFalse(native.has("executionModePermissionCoupled")); assertTrue(coupled.matches(native))
        assertEquals(coupled, SessionCreationDraft.restore(coupled.value().toString(), coupled.cwd, coupled.provider))
        assertFalse(SessionCreationDraft.restore(null, "/fixture", "claude").value().has("executionMode"))
    }
    @Test fun ConfigureConfirmationMustReadBackEveryRequestedOption() {
        val target = SessionAgentProtocol.Target.Session("session", "epoch", "revision")
        val options = JSONObject().put("executionMode", "plan").put("model", "fixture").put("mode", "auto").put("confirmation", true)
        val request = SessionAgentProtocol.Request(SessionAgentProtocol.id(), SessionAgentProtocol.Method.CONFIGURE, target,
            JSONObject().put("options", options), SessionAgentProtocol.id(), SessionAgentProtocol.id())
        fun response(effective: JSONObject) = JSONObject().put("id", request.requestId).put("ok", true).put("body", JSONObject()
            .put("agentProtocol", 2).put("requestId", request.requestId).put("operationId", request.operationId).put("status", "confirmed")
            .put("target", target.json()).put("effect", "session.configured").put("result", JSONObject().put("effectiveOptions", effective)))
        assertNotNull(SessionAgentProtocol.reply(response(JSONObject(options.toString()).apply { remove("confirmation") }), request))
        assertNull(SessionAgentProtocol.reply(response(JSONObject(options.toString()).put("executionMode", "default")), request))
        assertNull(SessionAgentProtocol.reply(response(JSONObject(options.toString()).apply { remove("executionMode") }), request))
        assertNull(SessionAgentProtocol.reply(response(JSONObject(options.toString()).put("model", "other")), request))
    }
    @Test fun SharedConfigurePlanFixtureMatchesNativeReadback() {
        val fixture = JSONObject(javaClass.getResourceAsStream("/agent-session-v2.json")!!.bufferedReader().use { it.readText() })
        val vectors = fixture.getJSONArray("vectors")
        val body = (0 until vectors.length()).map { vectors.getJSONObject(it) }.single { it.opt("name") == "configure-plan" }.getJSONObject("request")
        val scope = body.getJSONObject("target")
        val request = SessionAgentProtocol.Request(body.getString("requestId"), SessionAgentProtocol.Method.CONFIGURE,
            SessionAgentProtocol.Target.Session(scope.getString("sessionRef"), scope.getString("ownershipEpoch"), scope.getString("capabilityRevision")),
            body.getJSONObject("params"), body.getString("operationId"), body.getString("controlLease"))
        fun envelope(receipt: JSONObject) = JSONObject().put("id", request.requestId).put("ok", true).put("body", receipt)
        val configured = fixture.getJSONObject("configured")
        assertNotNull(SessionAgentProtocol.reply(envelope(configured), request))
        assertNull(SessionAgentProtocol.reply(envelope(JSONObject(configured.toString()).apply { getJSONObject("result").getJSONObject("effectiveOptions").put("executionMode", "default") }), request))
        assertNull(SessionAgentProtocol.reply(envelope(JSONObject(configured.toString()).apply { getJSONObject("result").getJSONObject("effectiveOptions").remove("executionMode") }), request))
    }
    @Test fun WrongConfiguredModePreservesPendingOriginalWithoutResubmitting() {
        val pending = linkedMapOf<String, String>()
        val store = object : SessionAgentClient.Storage {
            override fun pending() = pending.toMap()
            override fun save(operationId: String, original: String): Boolean { pending[operationId] = original; return true }
            override fun remove(operationId: String): Boolean { pending.remove(operationId); return true }
        }
        var wire = JSONObject(); var callback: ((JSONObject) -> Unit)? = null; var sent = 0
        val client = SessionAgentClient({ "host" }, { value, done -> wire = value; callback = done; sent++ }, store)
        client.discover(JSONObject().put("versions", JSONArray().put(2)).put("minimumClientVersion", 2).put("methods", JSONArray(SessionAgentProtocol.Method.entries.map { it.wire })))
        val target = SessionAgentProtocol.Target.Session("session", "epoch", "revision")
        var reply: SessionAgentProtocol.Reply? = null
        client.mutate(SessionAgentProtocol.Method.CONFIGURE, target, JSONObject().put("options", JSONObject().put("executionMode", "plan")), "lease") { reply = it }
        val original = pending.values.single(); val body = wire.getJSONObject("body")
        callback!!(JSONObject().put("id", body.get("requestId")).put("ok", true).put("body", JSONObject().put("agentProtocol", 2)
            .put("requestId", body.get("requestId")).put("operationId", body.get("operationId")).put("status", "confirmed").put("effect", "session.configured")
            .put("target", target.json()).put("result", JSONObject().put("effectiveOptions", JSONObject().put("executionMode", "default")))))
        assertEquals(SessionAgentProtocol.Status.UNKNOWN, (reply as SessionAgentProtocol.Reply.Mutation).status)
        assertEquals(original, pending.values.single()); assertEquals(1, sent)
    }
    @Test fun CreatedPlanAcceptsUnverifiedModeAsWarningButNotADifferentRequest() {
        val target = SessionAgentProtocol.Target.Creation("adapter", "workspace", SessionAgentProtocol.id(), "options")
        val request = SessionAgentProtocol.Request(SessionAgentProtocol.id(), SessionAgentProtocol.Method.CREATE, target,
            JSONObject().put("options", JSONObject().put("executionMode", "plan")), SessionAgentProtocol.id(), "lease")
        val result = JSONObject().put("sessionCreated", true).put("initialInput", "none").put("executionMode", "plan").put("executionModeState", "confirmed")
            .put("session", JSONObject().put("sessionRef", "new-session").put("nativeThreadId", "new-thread").put("adapterId", "adapter").put("workspaceRef", "workspace"))
        fun envelope(value: JSONObject) = JSONObject().put("id", request.requestId).put("ok", true).put("body", JSONObject().put("agentProtocol", 2)
            .put("requestId", request.requestId).put("operationId", request.operationId).put("status", "confirmed").put("effect", "session.created").put("target", target.json()).put("result", value))
        assertNotNull(SessionAgentProtocol.reply(envelope(result), request))
        assertNull(SessionAgentProtocol.reply(envelope(JSONObject(result.toString()).put("executionMode", "default")), request))
        // The native thread proves creation; an unverified mode readback arrives as a warning on a confirmed result.
        val unverified = JSONObject(result.toString()).put("executionModeState", "unverified")
            .put("warnings", JSONArray().put(JSONObject().put("field", "executionMode").put("requested", "plan")))
        assertNotNull(SessionAgentProtocol.reply(envelope(unverified), request))
        assertNotNull(SessionAgentProtocol.reply(envelope(JSONObject(result.toString()).apply { remove("executionModeState") }), request))
    }
}
