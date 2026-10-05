package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionAgentCapabilitiesTest {
    private fun actions() = JSONObject().put("send", JSONObject().put("supported", true).put("available", true).put("reason", "available"))
    private fun host(revision: String = "host-one") = JSONObject().put("version", 1).put("revision", revision).put("adapters", JSONArray().put(
        JSONObject().put("id", "codex.currentV1").put("provider", "codex").put("default", true).put("backendKinds", JSONArray().put("desktopAttached")).put("actions", actions())))
    private fun target() = JSONObject().put("version", 1).put("adapterId", "codex.currentV1").put("provider", "codex").put("revision", "target-one").put("actions", actions())
    private fun request(thread: String = "thread", view: Long = 1) = JSONObject().put("provider", "codex").put("threadId", thread).put("viewVersion", view)

    @Test fun targetRequiresFreshDiscoveryAndExactSessionView() {
        val negotiation = SessionAgentNegotiation()
        assertFalse(negotiation.remember(request(), target()))
        assertTrue(negotiation.discover(host()))
        assertTrue(negotiation.remember(request(), target()))
        assertTrue(negotiation.permits(request(), "send"))
        assertFalse(negotiation.permits(request("other"), "send"))
        assertFalse(negotiation.permits(request(view = 2), "send"))
        assertFalse(negotiation.permits(request(), "interrupt"))
        assertEquals("target-one", negotiation.target(request())!!.fields().getString("agentCapabilityRevision"))
        negotiation.clear(); assertFalse(negotiation.permits(request(), "send"))
    }
    @Test fun hostChangeAndMalformedDeclarationsNeverKeepPriorWriteAuthority() {
        val negotiation = SessionAgentNegotiation(); negotiation.discover(host()); negotiation.remember(request(), target())
        negotiation.discover(host("host-two")); assertFalse(negotiation.permits(request(), "send"))
        negotiation.remember(request(), target())
        val bad = target().apply { getJSONObject("actions").getJSONObject("send").put("available", 1) }
        assertFalse(negotiation.remember(request(), bad)); assertFalse(negotiation.permits(request(), "send"))
        assertFalse(negotiation.discover(host().put("version", "1")))
    }
    @Test fun contradictoryActionsAndForeignAdaptersAreRejected() {
        val wrong = host().apply { getJSONArray("adapters").getJSONObject(0).getJSONObject("actions").getJSONObject("send").put("supported", false) }
        assertNull(SessionAgentCapabilities.decode(wrong))
        assertNull(SessionAgentTargetCapabilities.decode(target().put("adapterId", "claude.currentV1"), SessionAgentCapabilities.decode(host())))
        assertNull(SessionAgentCapabilities.decode(host().apply { getJSONArray("adapters").put(getJSONArray("adapters").getJSONObject(0)) }))
        assertFalse(SessionAgentCapabilities.decode(host())!!.adapter("codex")!!.actions.containsKey("new"))
    }
    @Test fun creationScopeCannotAuthorizeAnExistingSessionOrAnotherDraft() {
        val negotiation = SessionAgentNegotiation(); negotiation.discover(host())
        val creation = JSONObject().put("provider", "codex").put("cwd", "/fixture").put("draftId", SessionAgentProtocol.id())
        assertTrue(negotiation.remember(creation, target()))
        assertTrue(negotiation.permits(creation, "send"))
        assertFalse(negotiation.permits(request(), "send"))
        assertFalse(negotiation.permits(JSONObject(creation.toString()).put("cwd", "/other"), "send"))
        assertFalse(negotiation.permits(JSONObject(creation.toString()).put("draftId", SessionAgentProtocol.id()), "send"))
    }
    @Test fun sharedManifestVectorsKeepClassificationAndV1ReceiptsAligned() {
        val fixture = JSONObject(javaClass.getResourceAsStream("/session-v1.json")!!.bufferedReader().use { it.readText() })
        fun strings(name: String) = fixture.getJSONArray(name).let { values -> (0 until values.length()).map { values.getString(it) }.toSet() }
        assertEquals(strings("durableMutations"), SessionV1Contract.operations.filter { it.durableMutation }.map { it.name }.toSet())
        assertEquals(strings("timeoutUnknownOnly"), SessionV1Contract.operations.filter { it.uncertainOnTimeout && !it.durableMutation }.map { it.name }.toSet())
        assertEquals(strings("providerPolicyExempt"), SessionV1Contract.operations.filter { it.providerPolicyExempt }.map { it.name }.toSet())
        assertEquals(strings("reads"), SessionV1Contract.operations.filter { it.cacheableRead }.map { it.name }.toSet())
        val request = fixture.getJSONArray("requests").getJSONObject(0)
        val receipts = fixture.getJSONArray("receipts")
        for (index in 0 until receipts.length()) assertTrue(SessionResponseInbox.confirms(receipts.getJSONObject(index), request))
    }
    @Test fun runtimeAdapterRequiresExplicitChoiceAndDoesNotReplaceTheDefault() {
        val discovery = host()
        discovery.getJSONArray("adapters").put(JSONObject().put("id", "codex.managed").put("provider", "codex").put("default", false)
            .put("backendKinds", JSONArray().put("managedRuntime")).put("actions", actions()))
        val decoded = SessionAgentCapabilities.decode(discovery)!!
        assertEquals("codex.currentV1", decoded.adapter("codex")!!.id)
        assertEquals("codex.managed", decoded.adapter("codex", "codex.managed")!!.id)
        assertNull(decoded.adapter("codex", "removed-runtime"))
        assertNotNull(SessionAgentTargetCapabilities.decode(target().put("adapterId", "codex.managed"), decoded))
    }
}
