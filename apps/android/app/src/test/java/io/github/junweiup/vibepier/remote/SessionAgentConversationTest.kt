package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionAgentConversationTest {
    @Test fun restoredProjectOptionsResolveMissingWorkspaceWithoutReturningToProjectList() {
        val harness = Harness()
        assertNull(harness.client.workspace("codex", "/another-project"))
        var result: JSONObject? = null
        harness.conversation.request("newOptions", harness.creationFields().put("cwd", "/another-project")) { result = it }
        assertTrue(result!!.getBoolean("ok"))
        assertEquals("discovered-workspace", harness.client.workspace("codex", "/another-project"))
        assertEquals(listOf("workspace.list", "session.creationOptions"), harness.methods())
        harness.conversation.request("newOptions", harness.creationFields().put("cwd", "/another-project")) { }
        assertEquals(1, harness.methods().count { it == "workspace.list" })
        assertTrue(harness.store.rows.isEmpty())
    }
    @Test fun restoredProjectListResolvesBeforeReadingItsSessionsAndLateTabResultsStayIsolated() {
        val harness = Harness()
        var result: JSONObject? = null
        harness.conversation.request("list", JSONObject().put("cwd", "/another-project")) { result = it }
        assertTrue(result!!.getBoolean("ok"))
        assertEquals(listOf("workspace.list", "session.list"), harness.methods())
        val changed = Harness(); changed.holdReads = true
        changed.conversation.request("newOptions", changed.creationFields().put("cwd", "/another-project")) { result = it }
        changed.provider = "zcode"
        val held = changed.held.single(); changed.answer(held.first, held.second)
        assertEquals("stale_state", result!!.getString("code"))
        assertNull(changed.client.workspace("codex", "/another-project"))
        assertEquals(listOf("workspace.list"), changed.methods())
        assertTrue(changed.store.rows.isEmpty())
    }

    @Test fun nativeReadFailureKeepsAValidDiagnosticAndRejectsUnsafeDetails() {
        val conversation = Harness().conversation
        assertEquals("Unlock failed", conversation.legacyReply(SessionAgentProtocol.Reply.Failure("agent_native_unavailable", "Unlock failed"), JSONObject()).getString("error"))
        assertEquals("agent_native_unavailable", conversation.legacyReply(SessionAgentProtocol.Reply.Failure("agent_native_unavailable", "unsafe\u0000text"), JSONObject()).getString("error"))
    }
    @Test fun nativeRejectionKeepsItsActualCodeAndPlainDiagnosticAcrossAllOperations() {
        val conversation = Harness().conversation
        val detail = "上次解锁未成功，请手动解锁 Mac"
        for (op in listOf("new", "send", "settings", "interrupt")) {
            val result = JSONObject().put("code", "agent_native_rejected").put("error", detail)
            val response = conversation.legacyReply(SessionAgentProtocol.Reply.Mutation(SessionAgentProtocol.Status.REJECTED, "operation", null, result, JSONObject()), JSONObject().put("op", op))
            assertEquals("agent_native_rejected", response.getString("code"))
            assertEquals(detail, response.getString("error"))
            assertFalse(response.getBoolean("ok")); assertFalse(response.getBoolean("unknown"))
        }
    }
    @Test fun malformedDiagnosticFallsBackWhileUnknownReceiptNeverBecomesAConfirmedFailure() {
        val conversation = Harness().conversation
        for (detail: Any in listOf(42, "", "unsafe\u0000text", "x".repeat(4_097))) {
            val result = JSONObject().put("code", "agent_native_rejected").put("error", detail)
            val reply = SessionAgentProtocol.Reply.Mutation(SessionAgentProtocol.Status.REJECTED, "operation", null, result, JSONObject())
            assertEquals("agent_native_rejected", conversation.legacyReply(reply, JSONObject().put("op", "new")).getString("error"))
        }
        val reply = SessionAgentProtocol.Reply.Mutation(SessionAgentProtocol.Status.UNKNOWN, "operation", null, JSONObject().put("error", "Native acknowledgement lost"), JSONObject())
        val response = conversation.legacyReply(reply, JSONObject().put("op", "send"))
        assertTrue(response.getBoolean("unknown")); assertFalse(response.getBoolean("ok"))
        assertTrue(response.getString("error").startsWith("receipt_unknown"))
    }

    private class Store : SessionAgentClient.Storage {
        val rows = linkedMapOf<String, String>()
        override fun pending() = rows.toMap()
        override fun save(operationId: String, original: String): Boolean {
            if (rows.containsKey(operationId)) return false
            rows[operationId] = original
            return true
        }
        override fun remove(operationId: String) = rows.remove(operationId) != null
    }
    private class Harness {
        var identity = "host"
        var provider = "codex"
        var view = 7L
        var adapter = "codex.currentV1"
        val store = Store()
        val wires = mutableListOf<JSONObject>()
        val held = mutableListOf<Pair<JSONObject, (JSONObject) -> Unit>>()
        var holdReads = false
        var holdObservation = false
        var capabilityRemembered: () -> Unit = {}
        var permission: (JSONObject, String) -> Boolean = { _, _ -> true }
        var dirtyNotifications = 0
        var contentNotifications = 0
        var clock = 0L
        val scheduledDelays = mutableListOf<Long>()
        var beforeScheduledRead: (() -> Unit)? = null
        var snapshotLease: String? = "fresh-lease"
        var snapshotFailure: String? = null
        var rawApprovalAuthority = false
        var beforeSnapshot: (() -> Unit)? = null
        val draft = "00000000-0000-4000-8000-000000000099"
        var creationOptions = JSONObject().put("creationVersion", 1).put("draftId", draft).put("cwd", "/synthetic")
            .put("composer", JSONObject().put("model", "model-a").put("mode", "auto").put("effort", "medium").put("executionMode", "default"))
            .put("models", JSONArray().put(JSONObject().put("id", "model-a").put("efforts", JSONArray().put("medium"))))
            .put("permissionModes", JSONArray().put(JSONObject().put("id", "auto")))
            .put("executionModes", JSONArray().put(JSONObject().put("id", "default")).put(JSONObject().put("id", "plan")))
        var page = JSONObject().put("provider", "codex").put("threadId", "thread").put("contentState", "complete")
            .put("status", "idle").put("canSend", true).put("messages", JSONArray()).put("approvals", JSONArray())
            .put("queuedMessages", JSONArray()).put("composer", JSONObject().put("model", "model-a").put("mode", "auto")
                .put("effort", "medium").put("executionMode", "default"))
            .put("agentCapabilities", JSONObject().put("actions", JSONObject().put("queue", JSONObject().put("available", true))))
        val client = SessionAgentClient({ identity }, { wire, done ->
            val copy = JSONObject(wire.toString()); wires.add(copy)
            val method = copy.getJSONObject("body").getString("method")
            if (holdReads && method in setOf("session.list", "workspace.list", "session.snapshot", "session.open", "session.creationOptions") || holdObservation && method == "session.observe") held.add(copy to done)
            else answer(copy, done)
        }, store, { source, selected -> source == "codex" && selected == adapter }, { adapter })
        val conversation = SessionAgentConversation(client, { provider }, { view }, { ++view }, { adapter },
            { _, _ -> capabilityRemembered() }, { fields, key -> permission(fields, key) }, { it },
            { delay, work -> scheduledDelays.add(delay); clock += delay; beforeScheduledRead?.invoke(); work() }, { clock })
        init {
            client.discover(JSONObject().put("versions", JSONArray().put(2)).put("minimumClientVersion", 2)
                .put("methods", JSONArray(SessionAgentProtocol.Method.entries.map { it.wire })))
            client.rememberSession("codex", descriptor("old-owner", "old-caps"), "expired-lease")
            client.rememberSnapshot("codex", "thread", page)
            client.rememberWorkspace("codex", JSONObject().put("adapterId", adapter).put("cwd", "/synthetic").put("workspaceRef", "workspace"))
            client.onDirty = { dirtyNotifications++; client.invalidateControl(it) }
            client.onContentChanged = { contentNotifications++ }
        }
        fun descriptor(owner: String = "new-owner", caps: String = "new-caps") = JSONObject()
            .put("adapterId", adapter).put("nativeThreadId", "thread").put("sessionRef", "session")
            .put("ownershipEpoch", owner).put("capabilityRevision", caps)
        fun readReply(wire: JSONObject, result: JSONObject): JSONObject {
            val body = wire.getJSONObject("body")
            return JSONObject().put("id", body.getString("requestId")).put("ok", true)
                .put("body", JSONObject().put("agentProtocol", 2).put("requestId", body.getString("requestId")).put("result", result))
        }
        var operationNotFound = false
        fun answer(wire: JSONObject, done: (JSONObject) -> Unit) {
            val body = wire.getJSONObject("body")
            when (body.getString("method")) {
                "session.list" -> done(readReply(wire, JSONObject().put("sessions", JSONArray().put(descriptor("old-owner", "old-caps")))))
                "workspace.list" -> done(readReply(wire, JSONObject().put("workspaces", JSONArray().put(JSONObject().put("adapterId", adapter)
                    .put("cwd", "/another-project").put("workspaceRef", "discovered-workspace")))))
                "session.observe" -> done(readReply(wire, JSONObject().put("streamEpoch", "stream").put("throughSequence", 1)
                    .put("resyncRequired", true).put("events", JSONArray())))
                "session.snapshot", "session.open" -> {
                    beforeSnapshot?.invoke()
                    if (snapshotFailure != null) done(JSONObject().put("id", body.getString("requestId")).put("ok", false).put("code", snapshotFailure)
                        .put("body", JSONObject().put("agentProtocol", 2).put("requestId", body.getString("requestId")).put("code", snapshotFailure)))
                    else done(readReply(wire, JSONObject().put("session", descriptor()).apply { snapshotLease?.let { put("controlLease", it) } }
                        .put("snapshot", JSONObject(page.toString()))))
                }
                "operation.get" -> {
                    val original = wires.first { it.getJSONObject("body").optString("operationId").isNotBlank() }.getJSONObject("body")
                    if (operationNotFound) done(readReply(wire, JSONObject().put("operation", JSONObject()
                        .put("operationId", original.getString("operationId")).put("status", "notFound"))))
                    else done(readReply(wire, JSONObject().put("operation", unknownBody(original))))
                }
                "session.creationOptions" -> done(readReply(wire, JSONObject().put("options", JSONObject(creationOptions.toString()))
                    .put("creationLease", JSONObject().put("target", JSONObject().put("adapterId", adapter).put("workspaceRef", "workspace")
                        .put("draftId", draft).put("optionsRevision", "fresh-options")).put("controlLease", "fresh-creation-lease"))))
                "session.items" -> {
                    val params = body.getJSONObject("params")
                    val result = JSONObject().put("threadId", "thread").put("consistency", "partial").put("contentState", "partial")
                    if (params.opt("kind") == "composerOptions") result.put("models", creationOptions.getJSONArray("models")).put("composer", page.getJSONObject("composer"))
                    else result.put("approval", JSONObject().put("id", "native-approval").put("fingerprint", "fingerprint")
                        .put("details", "complete native details").put("questions", JSONArray()).apply {
                            if (rawApprovalAuthority) put("canDecide", true).put("allowedDecisions", JSONArray().put("allow-always"))
                                .put("decisionScope", "always").put("kind", "questions").put("reason", "available").put("plan", true)
                        })
                    done(readReply(wire, result))
                }
                else -> done(JSONObject().put("id", body.getString("requestId")).put("ok", false).put("unknown", true)
                    .put("body", unknownBody(body)))
            }
        }
        private fun unknownBody(original: JSONObject) = JSONObject().put("agentProtocol", 2)
            .put("requestId", original.getString("requestId")).put("operationId", original.getString("operationId"))
            .put("status", "unknown").put("target", original.getJSONObject("target")).put("result", JSONObject())
        fun fields() = JSONObject().put("provider", "codex").put("threadId", "thread").put("text", "same intended message")
        fun creationFields() = JSONObject().put("provider", "codex").put("cwd", "/synthetic").put("draftId", draft).put("text", "original first message")
        fun methods() = wires.map { it.getJSONObject("body").getString("method") }
    }

    @Test fun transientNativeAdmissionOnlyRetriesReadsBeforeOneSubmission() {
        for (op in listOf("new", "send", "settings")) {
            val harness = Harness()
            var reads = 0
            harness.capabilityRemembered = { reads++ }
            harness.permission = { _, _ -> reads >= 3 }
            val fields = if (op == "new") harness.creationFields() else harness.fields()
            if (op == "settings") fields.put("model", "model-a")
            harness.conversation.request(op, fields) { }
            val read = if (op == "new") "session.creationOptions" else "session.snapshot"
            val write = when(op) { "new" -> "session.create"; "settings" -> "session.configure"; else -> "message.submit" }
            assertEquals(3, harness.methods().count { it == read })
            assertEquals(1, harness.methods().count { it == write })
            assertEquals(1, harness.store.rows.size)
        }
    }
    @Test fun notFoundReceiptKeepsIntentAndResendReusesOperationIdentity() {
        val harness = Harness()
        var created: JSONObject? = null
        val id = harness.conversation.request("new", harness.creationFields()) { created = it }!!
        assertTrue(created!!.optBoolean("unknown"))
        harness.operationNotFound = true
        var receipt: JSONObject? = null
        harness.conversation.request("receipt", JSONObject().put("operation", id)) { receipt = it }
        assertEquals("notFound", receipt!!.optString("state"))
        assertEquals(1, harness.store.rows.size)
        val first = harness.wires.first { it.getJSONObject("body").optString("method") == "session.create" }.getJSONObject("body")
        harness.client.resend(id) { }
        val resent = harness.wires.last().getJSONObject("body")
        assertEquals("session.create", resent.getString("method"))
        assertEquals(first.getString("operationId"), resent.getString("operationId"))
        assertEquals(first.getJSONObject("params").toString(), resent.getJSONObject("params").toString())
        assertNotEquals(first.getString("requestId"), resent.getString("requestId"))
    }
    @Test fun settledOperationReceiptNeverFallsBackToLegacyLookup() {
        val harness = Harness()
        harness.conversation.rememberSettled("op-1", JSONObject().put("ok", true).put("provider", "codex").put("threadId", "thread"))
        val before = harness.wires.size
        var receipt: JSONObject? = null
        assertNotNull(harness.conversation.request("receipt", JSONObject().put("operation", "op-1")) { receipt = it })
        assertEquals("complete", receipt!!.optString("state"))
        assertEquals("thread", receipt!!.getJSONObject("receipt").optString("threadId"))
        assertEquals(before, harness.wires.size)
    }
    @Test fun permanentlyUnavailableNativeAdmissionNeverJournalsOrSubmits() {
        val harness = Harness()
        harness.permission = { _, _ -> false }
        var response: JSONObject? = null
        harness.conversation.request("new", harness.creationFields()) { response = it }
        assertEquals("agent_state_not_ready", response!!.optString("code"))
        assertTrue(harness.methods().all { it == "session.creationOptions" })
        assertTrue(harness.store.rows.isEmpty())
    }
    @Test fun expiredLeaseIsRenewedBeforeOnlyOneFirstSubmissionAndReadonlyPreparationDoesNotJournal() {
        val harness = Harness()
        var prepared: JSONObject? = null
        harness.conversation.prepareSessionControl(harness.fields()) { prepared = it }
        assertTrue(prepared!!.optBoolean("ok"))
        assertEquals(listOf("session.snapshot"), harness.methods())
        assertTrue(harness.store.rows.isEmpty())
        assertEquals("fresh-lease", harness.client.session("codex", "thread")!!.controlLease)
        var response: JSONObject? = null
        harness.conversation.request("send", harness.fields()) { response = it }
        assertEquals(listOf("session.snapshot", "session.snapshot", "message.submit"), harness.methods())
        val body = harness.wires.last().getJSONObject("body")
        assertEquals("fresh-lease", body.getString("controlLease"))
        assertEquals("new-owner", body.getJSONObject("target").getString("ownershipEpoch"))
        assertEquals("start", body.getJSONObject("params").getString("mode"))
        assertTrue(response!!.optBoolean("unknown"))
        assertEquals(1, harness.store.rows.size)
    }
    @Test fun dirtyDuringPreparationIsRereadOnceAndRevokesOnlyControlNotReadIdentity() {
        val harness = Harness()
        var reads = 0
        harness.beforeSnapshot = { if (++reads == 1) harness.client.invalidateControl("session") }
        harness.conversation.request("send", harness.fields()) { }
        assertEquals(listOf("session.snapshot", "session.snapshot", "message.submit"), harness.methods())
        harness.client.invalidateControl("session")
        assertEquals("session", harness.client.session("codex", "thread")!!.target.sessionRef)
        assertNull(harness.client.session("codex", "thread")!!.controlLease)
        assertFalse(harness.client.controlReady("codex", "thread"))
    }
    @Test fun constantlyDirtyPreparationIsBoundedAndNeverReservesOrSubmits() {
        val harness = Harness()
        harness.beforeSnapshot = { harness.client.invalidateControl("session") }
        var response: JSONObject? = null
        harness.conversation.request("send", harness.fields()) { response = it }
        assertEquals(List(7) { "session.snapshot" }, harness.methods())
        assertFalse(response!!.optBoolean("ok"))
        assertTrue(harness.store.rows.isEmpty())
    }
    @Test fun olderViewSyncReplyCannotReplaceCurrentTypedLeaseSnapshotOrAuthorizeAMutation() {
        val harness = Harness(); harness.holdReads = true
        var response: JSONObject? = null
        harness.conversation.request("sync", harness.fields()) { response = it }
        harness.view++
        val current = harness.descriptor("current-owner", "current-caps")
        harness.client.rememberSession("codex", current, "current-lease")
        harness.client.rememberSnapshot("codex", "thread", JSONObject(harness.page.toString()).put("status", "active"))
        val held = harness.held.single(); harness.answer(held.first, held.second)
        assertEquals("stale_state", response!!.getString("code"))
        assertEquals("current-lease", harness.client.session("codex", "thread")!!.controlLease)
        assertEquals("active", harness.client.snapshot("codex", "thread")!!.getString("status"))
        assertTrue(harness.store.rows.isEmpty())
    }
    @Test fun originalUnknownOperationOnlyQueriesReceiptWithoutAnotherPreparationOrSubmission() {
        val harness = Harness(); val id = SessionAgentProtocol.id()
        val fields = harness.fields().put("id", id)
        harness.conversation.request("send", fields) { }
        val original = harness.store.rows.getValue(id)
        harness.conversation.request("send", fields) { }
        assertEquals(listOf("session.snapshot", "message.submit", "operation.get"), harness.methods())
        assertEquals(original, harness.store.rows.getValue(id))
    }
    @Test fun freshDifferentTurnAndDifferentStartModeCannotExecuteOldIntent() {
        for (op in listOf("send", "interrupt")) {
            val harness = Harness(); harness.holdReads = true
            harness.page.put("status", if (op == "send") "idle" else "active").put("activeTurnId", "original-turn")
            harness.client.rememberSnapshot("codex", "thread", harness.page)
            var response: JSONObject? = null
            harness.conversation.request(op, harness.fields().put("submissionMode", "start").put("expectedTurnId", "original-turn")) { response = it }
            harness.page.put("status", "active").put("activeTurnId", "another-turn")
            val held = harness.held.single(); harness.answer(held.first, held.second)
            assertFalse(response!!.optBoolean("ok"))
            assertEquals(listOf("session.snapshot"), harness.methods())
            assertTrue(harness.store.rows.isEmpty())
        }
    }
    @Test fun prepareCannotContinueAfterAuthorizationProviderAdapterOrViewChanges() {
        for (change in 0..3) {
            val harness = Harness(); harness.holdReads = true
            var response: JSONObject? = null
            harness.conversation.request("send", harness.fields()) { response = it }
            when (change) { 0 -> harness.identity = "another-host"; 1 -> harness.provider = "claude"; 2 -> harness.adapter = "codex.managed"; else -> harness.view++ }
            val held = harness.held.single(); harness.answer(held.first, held.second)
            assertFalse(response!!.optBoolean("ok"))
            assertEquals(listOf("session.snapshot"), harness.methods())
            assertTrue(harness.store.rows.isEmpty())
        }
    }
    @Test fun everyExistingSessionMutationPreparesBeforeExactlyOneWriteAndKeepsItsOriginalObject() {
        for ((op, method) in mapOf("settings" to "session.configure", "interrupt" to "turn.interrupt", "approve" to "approval.resolve", "queueDelete" to "queue.cancel")) {
            val harness = Harness()
            val fields = harness.fields()
            when (op) {
                "settings" -> fields.put("model", "model-a")
                "interrupt" -> { harness.page.put("status", "active").put("activeTurnId", "original-turn"); fields.put("expectedTurnId", "original-turn") }
                "approve" -> {
                    harness.page.put("approvals", JSONArray().put(JSONObject().put("id", "approval").put("fingerprint", "fingerprint")
                        .put("revision", "revision").put("canDecide", true).put("allowedDecisions", JSONArray().put("allow").put("deny"))))
                    fields.put("fingerprint", "fingerprint").put("expectedApprovalRevision", "revision").put("allow", true)
                }
                "queueDelete" -> {
                    harness.page.put("queuedMessages", JSONArray().put(JSONObject().put("id", "original-queue").put("text", "original body").put("canDelete", true)))
                    fields.put("messageId", "original-queue")
                }
            }
            harness.client.rememberSnapshot("codex", "thread", harness.page)
            harness.conversation.request(op, fields) { }
            assertEquals(listOf("session.snapshot", method), harness.methods())
            assertEquals(1, harness.store.rows.size)
            val params = harness.wires.last().getJSONObject("body").getJSONObject("params")
            when (op) {
                "settings" -> assertEquals("model-a", params.getJSONObject("options").getString("model"))
                "interrupt" -> assertEquals("original-turn", params.getString("expectedTurnId"))
                "approve" -> assertEquals("revision", params.getString("revision"))
                "queueDelete" -> assertEquals("original-queue", params.getString("queueId"))
            }
        }
    }
    @Test fun newerApprovalComposerOrQueueContentCannotAuthorizeTheEarlierClick() {
        for (op in listOf("settings", "approve", "queueDelete")) {
            val harness = Harness(); harness.holdReads = true
            val fields = harness.fields().put("model", "model-a")
            harness.page.put("approvals", JSONArray().put(JSONObject().put("id", "approval").put("fingerprint", "fingerprint")
                .put("revision", "old-revision").put("canDecide", true).put("allowedDecisions", JSONArray().put("allow"))))
                .put("queuedMessages", JSONArray().put(JSONObject().put("id", "queue").put("text", "reviewed text").put("canDelete", true)))
            if (op == "approve") fields.put("fingerprint", "fingerprint").put("expectedApprovalRevision", "old-revision").put("allow", true)
            if (op == "queueDelete") fields.put("messageId", "queue").put("expectedQueueDigest", SessionControlPreparation.queueDigest(harness.page.getJSONArray("queuedMessages").getJSONObject(0)))
            harness.client.rememberSnapshot("codex", "thread", harness.page)
            var response: JSONObject? = null
            harness.conversation.request(op, fields) { response = it }
            when (op) {
                "settings" -> harness.page.put("models", JSONArray().put(JSONObject().put("id", "other-model")))
                "approve" -> harness.page.getJSONArray("approvals").getJSONObject(0).put("revision", "new-revision")
                "queueDelete" -> harness.page.getJSONArray("queuedMessages").getJSONObject(0).put("text", "unreviewed replacement")
            }
            val held = harness.held.single(); harness.answer(held.first, held.second)
            assertFalse(response!!.optBoolean("ok"))
            assertEquals(listOf("session.snapshot"), harness.methods())
            assertTrue(harness.store.rows.isEmpty())
        }
    }
    @Test fun newSessionRenewsCreationAuthorityAndUsesFreshNativeDefaultsForOmittedChoices() {
        val harness = Harness()
        harness.conversation.request("newOptions", harness.creationFields()) { }
        harness.creationOptions.getJSONObject("composer").put("model", "model-b")
        harness.creationOptions.getJSONArray("models").put(JSONObject().put("id", "model-b").put("efforts", JSONArray().put("medium")))
        harness.conversation.request("new", harness.creationFields()) { }
        assertEquals(listOf("session.creationOptions", "session.creationOptions", "session.create"), harness.methods())
        val body = harness.wires.last().getJSONObject("body")
        assertEquals("fresh-creation-lease", body.getString("controlLease"))
        assertEquals(harness.draft, body.getJSONObject("target").getString("draftId"))
        assertEquals("model-b", body.getJSONObject("params").getJSONObject("options").getString("model"))
        assertEquals("auto", body.getJSONObject("params").getJSONObject("options").getString("mode"))
    }
    @Test fun removedCreationChoiceAndObsoleteCreationReplyNeverCreateOrReplaceDefaults() {
        val harness = Harness()
        harness.conversation.request("newOptions", harness.creationFields()) { }
        harness.creationOptions.put("models", JSONArray().put(JSONObject().put("id", "other-model").put("efforts", JSONArray().put("medium"))))
        var response: JSONObject? = null
        harness.conversation.request("new", harness.creationFields().put("model", "model-a")) { response = it }
        assertFalse(response!!.optBoolean("ok"))
        assertEquals(listOf("session.creationOptions", "session.creationOptions"), harness.methods())
        assertTrue(harness.store.rows.isEmpty())
        harness.holdReads = true
        harness.conversation.request("newOptions", harness.creationFields()) { response = it }
        harness.view++
        val held = harness.held.single(); harness.answer(held.first, held.second)
        assertEquals("stale_state", response!!.getString("code"))
        assertTrue(harness.store.rows.isEmpty())
    }
    @Test fun sameViewLateDiscoveryCannotReplaceTheVerifiedControlDescriptorOrLease() {
        val harness = Harness(); harness.holdReads = true
        harness.conversation.request("list", JSONObject().put("provider", "codex")) { }
        harness.holdReads = false
        harness.conversation.prepareSessionControl(harness.fields()) { assertTrue(it.optBoolean("ok")) }
        val held = harness.held.single(); harness.answer(held.first, held.second)
        val session = harness.client.session("codex", "thread")!!
        assertEquals("new-owner", session.target.ownershipEpoch)
        assertEquals("new-caps", session.target.capabilityRevision)
        assertEquals("fresh-lease", session.controlLease)
        assertTrue(harness.client.controlReady("codex", "thread"))
        assertTrue(harness.store.rows.isEmpty())
    }
    @Test fun olderViewDiscoveryCannotPopulateSessionsOrWorkspaces() {
        for (op in listOf("list", "projects")) {
            val harness = Harness(); harness.holdReads = true
            var response: JSONObject? = null
            harness.conversation.request(op, JSONObject().put("provider", "codex")) { response = it }
            harness.view++
            harness.client.rememberSession("codex", harness.descriptor("current-owner", "current-caps"), "current-lease")
            val held = harness.held.single(); harness.answer(held.first, held.second)
            assertEquals("stale_state", response!!.getString("code"))
            assertEquals("current-lease", harness.client.session("codex", "thread")!!.controlLease)
            assertNull(harness.client.workspace("codex", "/another-project"))
        }
    }
    @Test fun obsoleteObservationCallbacksCannotNotifyDirtyOrRecreateObservers() {
        for (clear in listOf(false, true)) {
            val harness = Harness(); harness.holdObservation = true
            harness.conversation.request("open", harness.fields()) { }
            val held = harness.held.single()
            if (clear) harness.conversation.clearConnection() else harness.view++
            harness.answer(held.first, held.second)
            assertEquals(0, harness.dirtyNotifications)
            assertEquals(listOf("session.open", "session.observe"), harness.methods())
        }
    }
    @Test fun preparingControlCannotSubmitWhenFreshCapabilityDeliveryChangesTheView() {
        val harness = Harness()
        harness.capabilityRemembered = { harness.view++ }
        var response: JSONObject? = null
        harness.conversation.request("send", harness.fields()) { response = it }
        assertEquals("stale_state", response!!.getString("code"))
        assertEquals(listOf("session.snapshot"), harness.methods())
        assertTrue(harness.store.rows.isEmpty())
    }
    @Test fun explicitlyObsoleteRequestedViewCannotStartPreparation() {
        val harness = Harness()
        var response: JSONObject? = null
        harness.conversation.request("send", harness.fields().put("viewVersion", 6)) { response = it }
        assertEquals("stale_state", response!!.getString("code"))
        assertTrue(harness.wires.isEmpty())
        assertTrue(harness.store.rows.isEmpty())
    }
    @Test fun staleTypedActiveStateDoesNotBlockTheFirstStandardSendWhenNativeIsIdle() {
        val harness = Harness()
        harness.client.rememberSnapshot("codex", "thread", JSONObject(harness.page.toString()).put("status", "active")
            .put("activeTurnId", "old-turn").put("composer", JSONObject().put("model", "old-model").put("mode", "custom")))
        harness.conversation.request("send", harness.fields()) { }
        assertEquals(listOf("session.snapshot", "message.submit"), harness.methods())
        assertEquals("start", harness.wires.last().getJSONObject("body").getJSONObject("params").getString("mode"))
        assertEquals(1, harness.store.rows.size)
    }
    @Test fun standardSendChoosesCurrentQueueWithoutConvertingAnExplicitStartIntent() {
        val harness = Harness()
        harness.page.put("status", "active").put("activeTurnId", "current-turn")
        harness.conversation.request("send", harness.fields()) { }
        assertEquals(listOf("session.snapshot", "message.submit"), harness.methods())
        assertEquals("queue", harness.wires.last().getJSONObject("body").getJSONObject("params").getString("mode"))
    }
    @Test fun continuousContentEventsDuringPreparationDoNotRevokeLeaseOrTriggerAnotherSnapshot() {
        val harness = Harness()
        val target = harness.client.session("codex", "thread")!!.target
        assertTrue(harness.client.observe("observer", target, "stream", 0, true))
        harness.beforeSnapshot = {
            for (sequence in 1..10) assertTrue(harness.client.event(JSONObject().put("event", "agentEvent").put("body", JSONObject()
                .put("agentProtocol", 2).put("subscriptionId", "observer").put("sessionRef", "session").put("streamEpoch", "stream")
                .put("sequence", sequence).put("entityRevision", sequence).put("event", "item.updated")
                .put("data", JSONObject().put("itemId", "native-text").put("controlDirty", false)))))
        }
        harness.conversation.request("send", harness.fields()) { }
        assertEquals(listOf("session.snapshot", "message.submit"), harness.methods())
        assertEquals(10, harness.contentNotifications)
        assertEquals(0, harness.dirtyNotifications)
        assertEquals(0L, harness.client.controlGeneration("session"))
        assertEquals("fresh-lease", harness.client.session("codex", "thread")!!.controlLease)
    }
    @Test fun contentFlagCannotSuppressControlInvalidationWhenTheEventStreamHasAGap() {
        val harness = Harness()
        val target = harness.client.session("codex", "thread")!!.target
        assertTrue(harness.client.observe("observer", target, "stream", 0, true))
        harness.client.event(JSONObject().put("event", "agentEvent").put("body", JSONObject().put("agentProtocol", 2)
            .put("subscriptionId", "observer").put("sessionRef", "session").put("streamEpoch", "stream")
            .put("sequence", 2).put("entityRevision", 2).put("event", "item.updated")
            .put("data", JSONObject().put("itemId", "native-text").put("controlDirty", false))))
        assertEquals(0, harness.contentNotifications)
        assertEquals(1, harness.dirtyNotifications)
        assertNull(harness.client.session("codex", "thread")!!.controlLease)
    }
    @Test fun nativeOwnerOpeningGetsBoundedReadBackoffBeforeItsFirstWrite() {
        val harness = Harness(); var reads = 0
        harness.beforeSnapshot = {
            if (++reads < 3) harness.page.put("contentState", "partial").put("opening", true)
            else { harness.page.put("contentState", "complete"); harness.page.remove("opening") }
        }
        harness.conversation.request("send", harness.fields()) { }
        assertEquals(listOf("session.snapshot", "session.snapshot", "session.snapshot", "message.submit"), harness.methods())
        assertEquals(listOf(250L, 500L), harness.scheduledDelays)
        assertEquals(1, harness.store.rows.size)
    }
    @Test fun scopeChangeDuringBackoffAndUnsupportedNativeMethodNeverRetryWrites() {
        val harness = Harness()
        harness.page.put("contentState", "partial").put("opening", true)
        harness.beforeScheduledRead = { harness.view++ }
        var response: JSONObject? = null
        harness.conversation.request("send", harness.fields()) { response = it }
        assertEquals("stale_state", response!!.getString("code"))
        assertEquals(listOf("session.snapshot"), harness.methods())
        assertTrue(harness.store.rows.isEmpty())
        val unsupported = Harness(); unsupported.snapshotFailure = "agent_method_unsupported"
        unsupported.conversation.request("send", unsupported.fields()) { response = it }
        assertEquals("agent_method_unsupported", response!!.getString("code"))
        assertEquals(listOf("session.snapshot"), unsupported.methods())
        assertTrue(unsupported.scheduledDelays.isEmpty())
    }
    @Test fun readCatalogAndApprovalDetailsUseTypedItemsOnTheSameAdapterWithoutAWriteLease() {
        for (op in listOf("composerOptions", "approvalDetails")) {
            val harness = Harness(); harness.snapshotLease = null
            harness.page.put("approvals", JSONArray().put(JSONObject().put("id", "normalized-approval").put("fingerprint", "fingerprint")
                .put("revision", "expected-revision").put("canDecide", true)))
            val fields = harness.fields().put("fingerprint", "fingerprint").put("expectedApprovalRevision", "expected-revision")
            var response: JSONObject? = null
            harness.conversation.request(op, fields) { response = it }
            assertTrue(response!!.optBoolean("ok"))
            assertEquals(listOf("session.snapshot", "session.items"), harness.methods())
            val body = harness.wires.last().getJSONObject("body")
            assertEquals("session", body.getJSONObject("target").getString("sessionRef"))
            assertEquals(op, body.getJSONObject("params").getString("kind"))
            assertTrue(harness.store.rows.isEmpty())
            assertNull(harness.client.session("codex", "thread")!!.controlLease)
            if (op == "approvalDetails") {
                assertEquals("normalized-approval", body.getJSONObject("params").getString("messageId"))
                assertEquals("normalized-approval", response!!.getJSONObject("approval").getString("id"))
                assertEquals("expected-revision", response!!.getJSONObject("approval").getString("revision"))
            }
        }
    }
    @Test fun changedApprovalRevisionRejectsDetailsBeforeReadingAnotherNativeObject() {
        val harness = Harness()
        harness.page.put("approvals", JSONArray().put(JSONObject().put("id", "normalized-approval").put("fingerprint", "fingerprint")
            .put("revision", "new-revision")))
        var response: JSONObject? = null
        harness.conversation.request("approvalDetails", harness.fields().put("fingerprint", "fingerprint").put("expectedApprovalRevision", "old-revision")) { response = it }
        assertEquals("approval_expired", response!!.getString("code"))
        assertEquals(listOf("session.snapshot"), harness.methods())
        assertTrue(harness.store.rows.isEmpty())
    }
    @Test fun rawApprovalDetailsCannotReenableAuthorityDeniedByTheNormalizedSummary() {
        for (withDecisions in listOf(false, true)) {
            val harness = Harness(); harness.rawApprovalAuthority = true
            val pending = JSONObject().put("id", "normalized-approval").put("fingerprint", "fingerprint").put("revision", "revision")
                .put("canDecide", false).put("kind", "permissions").put("reason", "permission_scope_unsupported")
            if (withDecisions) pending.put("allowedDecisions", JSONArray())
            harness.page.put("approvals", JSONArray().put(pending))
            var response: JSONObject? = null
            harness.conversation.request("approvalDetails", harness.fields().put("fingerprint", "fingerprint").put("expectedApprovalRevision", "revision")) { response = it }
            val details = response!!.getJSONObject("approval")
            assertFalse(details.getBoolean("canDecide"))
            assertEquals(0, details.getJSONArray("allowedDecisions").length())
            assertEquals("permissions", details.getString("kind"))
            assertEquals("permission_scope_unsupported", details.getString("reason"))
            assertFalse(details.has("decisionScope"))
            assertFalse(details.has("plan"))
            assertEquals("complete native details", details.getString("details"))
            assertTrue(details.has("questions"))
            assertTrue(harness.store.rows.isEmpty())
        }
    }
}
