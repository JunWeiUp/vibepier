package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionControlPreparation
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionControlPreparationTest {
    private fun copy(value: JSONObject) = JSONObject(value.toString())
    private fun fields() = JSONObject().put("threadId", "thread")
    private fun page(status: String = "idle") = JSONObject().put("threadId", "thread").put("status", status)
        .put("contentState", "complete").put("owner", "desktop").put("activeTurnId", if (status == "active") "turn" else "")
        .put("composer", JSONObject().put("model", "model").put("effort", "medium").put("mode", "auto").put("executionMode", "default"))
        .put("queuedMessages", JSONArray())
    private fun approval() = JSONObject().put("id", "approval").put("fingerprint", "fingerprint").put("revision", "revision")
        .put("kind", "approval").put("title", "Run command").put("details", "Synthetic command")
        .put("canDecide", true).put("allowedDecisions", JSONArray().put("allow").put("deny"))
    private fun withApproval(value: JSONObject) = page().put("approvals", JSONArray().put(value))
    private fun queue() = JSONObject().put("id", "queue").put("text", "Original prompt")
        .put("attachments", JSONArray().put("attachment")).put("canDelete", true).put("canSteer", true)
    private fun creation() = JSONObject().put("creationVersion", 1).put("draftId", "draft").put("cwd", "/synthetic")
        .put("composer", JSONObject().put("model", "model").put("effort", "medium").put("mode", "auto").put("executionMode", "default"))
        .put("models", JSONArray().put(JSONObject().put("id", "model").put("efforts", JSONArray().put("medium")).put("defaultEffort", "medium")))
        .put("permissionModes", JSONArray().put(JSONObject().put("id", "auto")))
        .put("executionModes", JSONArray().put(JSONObject().put("id", "default")).put(JSONObject().put("id", "plan")))
    private fun creationFields() = JSONObject().put("draftId", "draft").put("cwd", "/synthetic").put("text", "prompt")

    @Test fun stalePartialOrMissingCacheCannotRejectBeforeTheNativeRead() {
        val request = fields().put("text", "prompt")
        for (cached in listOf(null, page("active"), page().put("contentState", "partial"), JSONObject())) {
            val intent = SessionControlPreparation.capture("send", request, cached)!!
            assertNull(intent.mode)
            assertEquals("start", SessionControlPreparation.resolvedFields(intent, page())!!.getString("submissionMode"))
        }
    }

    @Test fun standardSendUsesTheFreshNativeQueueState() {
        val intent = SessionControlPreparation.capture("send", fields(), page())!!
        val fresh = page("active").put("activeTurnId", "new-turn")
        assertEquals("queue", SessionControlPreparation.resolvedFields(intent, fresh)!!.getString("submissionMode"))
        val idleWithQueue = page().put("queuedMessages", JSONArray().put(queue()))
        assertEquals("queue", SessionControlPreparation.resolvedFields(intent, idleWithQueue)!!.getString("submissionMode"))
        assertFalse(intent.fields.has("submissionMode"))
    }

    @Test fun ownerAndImplicitComposerPresentationChangesDoNotGateSending() {
        val before = page().put("owner", JSONObject().put("host", "old").put("revision", 1.5)).apply {
            getJSONObject("composer").put("model", "").put("effort", JSONObject.NULL)
        }
        val intent = SessionControlPreparation.capture("send", fields(), before)!!
        val fresh = page().put("owner", JSONObject().put("host", "new").put("revision", 2)).apply {
            getJSONObject("composer").put("model", "newly-resolved-default").put("effort", "high")
        }
        assertTrue(SessionControlPreparation.validate(intent, fresh))
    }

    @Test fun advancedExplicitStartNeverBecomesQueue() {
        val intent = SessionControlPreparation.capture("send", fields().put("submissionMode", "start"), page("active"))!!
        assertEquals("start", intent.mode)
        assertTrue(SessionControlPreparation.validate(intent, page()))
        assertFalse(SessionControlPreparation.validate(intent, page("active")))
        assertFalse(SessionControlPreparation.validate(intent, page().put("queuedMessages", JSONArray().put(queue()))))
        assertNull(SessionControlPreparation.capture("send", fields().put("submissionMode", "steer")))
    }

    @Test fun advancedExplicitQueueRemainsQueueWithoutBindingAnUnrelatedTurn() {
        val intent = SessionControlPreparation.capture("send", fields().put("submissionMode", "queue"), page("active"))!!
        assertEquals("queue", SessionControlPreparation.resolvedFields(intent, page("active").put("activeTurnId", "another-turn"))!!.getString("submissionMode"))
        assertFalse(SessionControlPreparation.validate(intent, page()))
    }

    @Test fun onlyTheFreshPageNeedsToBeCompleteAndCorrectlyScoped() {
        val intent = SessionControlPreparation.capture("send", fields(), null)!!
        assertFalse(SessionControlPreparation.validate(intent, page().put("contentState", "partial")))
        assertFalse(SessionControlPreparation.validate(intent, page().put("threadId", "other")))
        assertFalse(SessionControlPreparation.validate(intent, page().put("ok", false)))
        assertFalse(SessionControlPreparation.validate(intent, page().put("event", "unavailable")))
        assertFalse(SessionControlPreparation.validate(intent, page().put("status", "unknown")))
    }

    @Test fun settingsApplyExplicitDesiredValuesRegardlessOfUnrelatedOldChoices() {
        val request = fields().put("model", "desired-model")
        val intent = SessionControlPreparation.capture("settings", request, page().put("contentState", "partial"))!!
        val fresh = page().put("models", JSONArray().put(JSONObject().put("id", "desired-model"))).apply {
            getJSONObject("composer").put("mode", "custom").put("model", "current-model").put("effort", "high")
        }
        assertTrue(SessionControlPreparation.validate(intent, fresh))
        val resolved = SessionControlPreparation.resolvedFields(intent, fresh)!!
        assertEquals("desired-model", resolved.getString("model"))
        assertFalse(resolved.has("effort")); assertFalse(resolved.has("mode"))
        assertFalse(SessionControlPreparation.validate(intent, copy(fresh).put("models", JSONArray())))
        assertFalse(SessionControlPreparation.validate(intent, copy(fresh).apply { getJSONObject("composer").put("locked", true) }))
    }

    @Test fun fullAccessAlwaysNeedsTheOriginalExplicitConfirmation() {
        val fresh = page().put("permissionModes", JSONArray().put(JSONObject().put("id", "full-access").put("requiresConfirmation", true)))
        val unconfirmed = SessionControlPreparation.capture("settings", fields().put("mode", "full-access"))!!
        assertFalse(SessionControlPreparation.validate(unconfirmed, fresh))
        val intent = SessionControlPreparation.capture("settings", fields().put("mode", "full-access").put("confirmFullAccess", true))!!
        assertTrue(SessionControlPreparation.validate(intent, fresh))
        assertTrue(SessionControlPreparation.resolvedFields(intent, fresh)!!.getBoolean("confirmFullAccess"))
        assertFalse(SessionControlPreparation.validate(intent, copy(fresh).put("permissionModes", JSONArray().put(JSONObject().put("id", "auto")))))
        assertNull(SessionControlPreparation.capture("settings", fields().put("mode", "full-access").put("confirmFullAccess", "true")))
    }

    @Test fun interruptBindsOnlyTheExplicitExpectedTurn() {
        val intent = SessionControlPreparation.capture("interrupt", fields().put("expectedTurnId", "turn"), page())!!
        assertTrue(SessionControlPreparation.validate(intent, page("active")))
        assertFalse(SessionControlPreparation.validate(intent, page("active").put("activeTurnId", "replacement")))
        assertFalse(SessionControlPreparation.validate(intent, page()))
        assertNull(SessionControlPreparation.capture("interrupt", fields()))
    }

    @Test fun queueActionsUseTheFreshExactQueueIdentityAndFlag() {
        val fresh = page().put("queuedMessages", JSONArray().put(queue()))
        for (op in listOf("queueSteer", "queueDelete")) {
            val intent = SessionControlPreparation.capture(op, fields().put("messageId", "queue"), null)!!
            assertTrue(SessionControlPreparation.validate(intent, fresh))
            assertFalse(SessionControlPreparation.validate(intent, copy(fresh).put("queuedMessages", JSONArray())))
            assertFalse(SessionControlPreparation.validate(intent, copy(fresh).apply {
                getJSONArray("queuedMessages").getJSONObject(0).put(if (op == "queueSteer") "canSteer" else "canDelete", false)
            }))
        }
    }

    @Test fun queueDigestBindsTheUserReviewedContentAndAttachments() {
        val selected = queue()
        val intent = SessionControlPreparation.capture("queueDelete", fields().put("messageId", "queue")
            .put("expectedQueueDigest", SessionControlPreparation.queueDigest(selected)))!!
        val fresh = page().put("queuedMessages", JSONArray().put(copy(selected)))
        assertTrue(SessionControlPreparation.validate(intent, fresh))
        for (key in listOf("text", "attachments")) assertFalse(SessionControlPreparation.validate(intent, copy(fresh).apply {
            getJSONArray("queuedMessages").getJSONObject(0).put(key, if (key == "text") "changed" else JSONArray().put("changed"))
        }))
        assertEquals(SessionControlPreparation.queueDigest(JSONObject().put("id", "queue")),
            SessionControlPreparation.queueDigest(JSONObject().put("id", "queue").put("text", "").put("attachments", JSONArray())))
        assertEquals(SessionControlPreparation.queueDigest(JSONObject().put("id", "queue")),
            SessionControlPreparation.queueDigest(JSONObject().put("id", "queue").put("text", JSONObject.NULL).put("attachments", JSONObject.NULL)))
    }

    @Test fun steerBindsTheExplicitTurnWhenProvided() {
        val fresh = page("active").put("queuedMessages", JSONArray().put(queue()))
        val bound = SessionControlPreparation.capture("queueSteer", fields().put("messageId", "queue").put("expectedTurnId", "turn"))!!
        assertTrue(SessionControlPreparation.validate(bound, fresh))
        assertFalse(SessionControlPreparation.validate(bound, copy(fresh).put("activeTurnId", "replacement")))
        assertFalse(SessionControlPreparation.validate(bound, copy(fresh).put("status", "idle")))
        val native = SessionControlPreparation.capture("queueSteer", fields().put("messageId", "queue"))!!
        assertTrue(SessionControlPreparation.validate(native, copy(fresh).put("status", "idle").put("activeTurnId", "")))
        assertTrue(SessionControlPreparation.validate(native, copy(fresh).put("activeTurnId", "new-turn")))
    }

    @Test fun approvalBindsFingerprintAndReviewedRevisionRatherThanCachedProjectionID() {
        val cached = withApproval(approval().put("id", "old-native-id").put("revision", "old-revision"))
        val request = fields().put("fingerprint", "fingerprint").put("allow", true).put("expectedApprovalRevision", "revision")
        val intent = SessionControlPreparation.capture("approve", request, cached)!!
        assertTrue(SessionControlPreparation.validate(intent, withApproval(approval())))
        assertFalse(SessionControlPreparation.validate(intent, withApproval(approval().put("revision", "new"))))
        assertFalse(SessionControlPreparation.validate(intent, withApproval(approval().put("fingerprint", "new"))))
        assertFalse(SessionControlPreparation.validate(intent, withApproval(approval().put("canDecide", false))))
        assertFalse(SessionControlPreparation.validate(intent, withApproval(approval().put("allowedDecisions", JSONArray().put("deny")))))
    }

    @Test fun questionAnswersUseTheCurrentBoundFormAndChoices() {
        val form = approval().put("kind", "questions").put("method", "item/tool/requestUserInput")
            .put("questions", JSONArray().put(JSONObject().put("id", "question").put("question", "Pick one")
                .put("freeform", false).put("options", JSONArray().put(JSONObject().put("label", "A")).put(JSONObject().put("label", "B")))))
        val fresh = withApproval(form)
        val request = fields().put("fingerprint", "fingerprint").put("answers", JSONObject().put("question", "A"))
        assertTrue(SessionControlPreparation.validate(SessionControlPreparation.capture("approve", request)!!, fresh))
        for (answers in listOf(JSONObject().put("question", "C"), JSONObject().put("new-question", "A"), JSONObject())) {
            assertFalse(SessionControlPreparation.validate(SessionControlPreparation.capture("approve", copy(request).put("answers", answers))!!, fresh))
        }
        val freeform = copy(fresh).apply { getJSONArray("approvals").getJSONObject(0).getJSONArray("questions").getJSONObject(0).put("freeform", true) }
        assertTrue(SessionControlPreparation.validate(SessionControlPreparation.capture("approve", copy(request).put("answers", JSONObject().put("question", "C")))!!, freeform))
    }

    @Test fun compactQuestionsAndNativeChoiceLabelsKeepNativeValidation() {
        val compact = withApproval(approval().put("kind", "questions"))
        val answer = SessionControlPreparation.capture("approve", fields().put("fingerprint", "fingerprint").put("answers", JSONObject().put("question", "answer")))!!
        assertTrue(SessionControlPreparation.validate(answer, compact))
        val fresh = withApproval(approval().put("options", JSONArray().put("Continue").put("Cancel")))
        val selected = SessionControlPreparation.capture("approve", fields().put("fingerprint", "fingerprint").put("option", "Continue"))!!
        assertTrue(SessionControlPreparation.validate(selected, fresh))
        assertFalse(SessionControlPreparation.validate(selected, copy(fresh).apply { getJSONArray("approvals").getJSONObject(0).put("options", JSONArray().put("Other")) }))
    }

    @Test fun creationResolvesImplicitDefaultsOnlyFromTheFreshCatalog() {
        val intent = SessionControlPreparation.capture("new", creationFields(), null)!!
        val fresh = creation().apply {
            getJSONObject("composer").put("model", "new-model").put("effort", "high")
            put("models", JSONArray().put(JSONObject().put("id", "new-model").put("efforts", JSONArray().put("high"))))
        }
        val resolved = SessionControlPreparation.resolvedFields(intent, fresh)!!
        assertEquals("new-model", resolved.getString("model")); assertEquals("high", resolved.getString("effort"))
        assertEquals("auto", resolved.getString("mode")); assertEquals("default", resolved.getString("executionMode"))
        assertFalse(intent.fields.has("model"))
        assertFalse(SessionControlPreparation.validate(intent, copy(fresh).put("draftId", "new-draft")))
        assertFalse(SessionControlPreparation.validate(intent, copy(fresh).put("cwd", "/other")))
    }

    @Test fun creationKeepsExplicitChoicesAndNeverConfirmsAnImplicitPermissionUpgrade() {
        val explicit = SessionControlPreparation.capture("new", creationFields().put("model", "model").put("effort", "medium").put("mode", "auto"))!!
        assertTrue(SessionControlPreparation.validate(explicit, creation().apply { getJSONObject("composer").put("model", "other").put("effort", "high") }))
        assertFalse(SessionControlPreparation.validate(explicit, creation().put("models", JSONArray())))
        val defaulted = SessionControlPreparation.capture("new", creationFields())!!
        val full = creation().apply {
            getJSONObject("composer").put("mode", "full-access")
            put("permissionModes", JSONArray().put(JSONObject().put("id", "full-access")))
        }
        assertFalse(SessionControlPreparation.validate(defaulted, full))
    }

    @Test fun creationUsesTheChosenModelsDefaultEffortInsteadOfAnUnrelatedCurrentModel() {
        val intent = SessionControlPreparation.capture("new", creationFields().put("model", "chosen"))!!
        val fresh = creation().apply {
            put("models", JSONArray().put(JSONObject().put("id", "chosen").put("efforts", JSONArray().put("low")).put("defaultEffort", "low")))
        }
        val resolved = SessionControlPreparation.resolvedFields(intent, fresh)!!
        assertEquals("chosen", resolved.getString("model")); assertEquals("low", resolved.getString("effort"))
    }

    @Test fun coupledPlanDefaultsDoNotAddOrEraseAnExplicitPermissionChoice() {
        val fresh = creation().put("executionModePermissionCoupled", true).apply {
            getJSONObject("composer").put("executionMode", "plan").put("mode", "plan")
            getJSONArray("executionModes").getJSONObject(1).put("permissionMode", "plan")
        }
        val resolved = SessionControlPreparation.resolvedFields(SessionControlPreparation.capture("new", creationFields())!!, fresh)!!
        assertEquals("plan", resolved.getString("executionMode")); assertFalse(resolved.has("mode"))
        val incompatible = SessionControlPreparation.capture("new", creationFields().put("mode", "full-access").put("confirmFullAccess", true))!!
        assertFalse(SessionControlPreparation.validate(incompatible, fresh))
        assertEquals("full-access", incompatible.fields.getString("mode"))
    }

    @Test fun captureResolutionAndReturnedCopiesNeverMutateInputs() {
        val cached = page("active").put("contentState", "partial")
        val request = fields().put("text", "original")
        val fresh = page()
        val cachedJSON = cached.toString(); val requestJSON = request.toString(); val freshJSON = fresh.toString()
        val intent = SessionControlPreparation.capture("send", request, cached)!!
        val resolved = SessionControlPreparation.resolvedFields(intent, fresh)!!
        resolved.put("text", "changed"); intent.fields.put("text", "changed")
        assertEquals("original", intent.fields.getString("text"))
        assertFalse(intent.fields.has("submissionMode"))
        assertEquals(cachedJSON, cached.toString()); assertEquals(requestJSON, request.toString()); assertEquals(freshJSON, fresh.toString())
    }
}
