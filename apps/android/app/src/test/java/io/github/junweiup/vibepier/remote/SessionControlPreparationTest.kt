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
    private fun withApproval(approval: JSONObject) = page().put("approvals", JSONArray().put(approval))
    private fun queue() = JSONObject().put("id", "queue").put("text", "Original prompt")
        .put("attachments", JSONArray().put("attachment")).put("canDelete", true).put("canSteer", true)
    private fun creation() = JSONObject().put("creationVersion", 1).put("draftId", "draft").put("cwd", "/synthetic")
        .put("composer", JSONObject().put("model", "model").put("effort", "medium").put("mode", "auto").put("executionMode", "default"))
        .put("models", JSONArray().put(JSONObject().put("id", "model").put("efforts", JSONArray().put("medium"))))
        .put("permissionModes", JSONArray().put(JSONObject().put("id", "auto")))
        .put("executionModes", JSONArray().put(JSONObject().put("id", "default")).put(JSONObject().put("id", "plan")))

    @Test fun sendRefreshCannotBecomeQueueOrChangeComposer() {
        val before = page()
        val intent = SessionControlPreparation.capture("send", fields().put("text", "prompt"), before)!!
        assertEquals("start", intent.mode)
        assertTrue(SessionControlPreparation.validate(intent, copy(before).put("revision", 12)))
        assertFalse(SessionControlPreparation.validate(intent, page("active")))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).apply { getJSONObject("composer").put("mode", "full-access") }))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).put("contentState", "partial")))
    }

    @Test fun queuedSendRemainsBoundToTheSameTurn() {
        val before = page("active")
        val intent = SessionControlPreparation.capture("send", fields(), before)!!
        assertEquals("queue", intent.mode)
        assertTrue(SessionControlPreparation.validate(intent, copy(before)))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).put("activeTurnId", "another-turn")))
        assertFalse(SessionControlPreparation.validate(intent, page()))
        assertNull(SessionControlPreparation.capture("send", fields().put("submissionMode", "start"), before))
    }

    @Test fun interruptNeverMovesToANewTurn() {
        val before = page("active")
        val intent = SessionControlPreparation.capture("interrupt", fields().put("expectedTurnId", "turn"), before)!!
        assertTrue(SessionControlPreparation.validate(intent, copy(before)))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).put("activeTurnId", "replacement")))
        assertNull(SessionControlPreparation.capture("interrupt", fields().put("expectedTurnId", "replacement"), before))
    }

    @Test fun queueActionsCheckOriginalContentAndActionFlags() {
        val before = page("active").put("queuedMessages", JSONArray().put(queue()))
        for (op in listOf("queueSteer", "queueDelete")) {
            val intent = SessionControlPreparation.capture(op, fields().put("messageId", "queue"), before)!!
            assertTrue(SessionControlPreparation.validate(intent, copy(before)))
            assertFalse(SessionControlPreparation.validate(intent, copy(before).apply { getJSONArray("queuedMessages").getJSONObject(0).put("text", "replacement") }))
            assertFalse(SessionControlPreparation.validate(intent, copy(before).apply { getJSONArray("queuedMessages").getJSONObject(0).put("attachments", JSONArray().put("new")) }))
            assertFalse(SessionControlPreparation.validate(intent, copy(before).apply { getJSONArray("queuedMessages").getJSONObject(0).put(if (op == "queueSteer") "canSteer" else "canDelete", false) }))
        }
        val steer = SessionControlPreparation.capture("queueSteer", fields().put("messageId", "queue"), before)!!
        assertFalse(SessionControlPreparation.validate(steer, copy(before).put("activeTurnId", "replacement")))
    }

    @Test fun idleQueueCanBeSentNowWithoutChangingToSteeringAnActiveTurn() {
        val before = page().put("queuedMessages", JSONArray().put(queue()))
        val intent = SessionControlPreparation.capture("queueSteer", fields().put("messageId", "queue"), before)!!
        assertTrue(SessionControlPreparation.validate(intent, copy(before)))
        assertFalse(SessionControlPreparation.validate(intent, page("active").put("queuedMessages", JSONArray().put(queue()))))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).put("activeTurnId", "unexpected-turn")))
    }

    @Test fun approvalBindsTheReviewedRevisionAndFullSemantics() {
        val before = withApproval(approval())
        val request = fields().put("fingerprint", "fingerprint").put("allow", true).put("expectedApprovalRevision", "revision")
        val intent = SessionControlPreparation.capture("approve", request, before)!!
        assertTrue(SessionControlPreparation.validate(intent, copy(before)))
        for (key in listOf("revision", "id", "details", "kind")) {
            assertFalse(SessionControlPreparation.validate(intent, copy(before).apply { getJSONArray("approvals").getJSONObject(0).put(key, "changed") }))
        }
        assertNull(SessionControlPreparation.capture("approve", copy(request).put("expectedApprovalRevision", "old"), before))
        assertNull(SessionControlPreparation.capture("approve", copy(request).put("option", "allow-always"), before))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).apply { getJSONArray("approvals").getJSONObject(0).put("allowedDecisions", JSONArray().put("deny")) }))
    }

    @Test fun questionAnswersRemainBoundToTheOriginalFormAndChoices() {
        val form = approval().put("kind", "questions").put("method", "item/tool/requestUserInput")
            .put("questions", JSONArray().put(JSONObject().put("id", "question").put("question", "Pick one")
                .put("freeform", false).put("options", JSONArray().put(JSONObject().put("label", "A")).put(JSONObject().put("label", "B")))))
        val before = withApproval(form)
        val request = fields().put("fingerprint", "fingerprint").put("answers", JSONObject().put("question", "A"))
        val intent = SessionControlPreparation.capture("approve", request, before)!!
        assertTrue(SessionControlPreparation.validate(intent, copy(before)))
        assertNull(SessionControlPreparation.capture("approve", copy(request).put("answers", JSONObject().put("question", "C")), before))
        assertNull(SessionControlPreparation.capture("approve", copy(request).put("answers", JSONObject().put("new-question", "A")), before))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).apply {
            getJSONArray("approvals").getJSONObject(0).getJSONArray("questions").getJSONObject(0).put("question", "Changed question")
        }))
    }

    @Test fun compactQuestionCardsLeaveNativeAnswerValidationIntact() {
        val before = withApproval(approval().put("kind", "questions"))
        assertNotNull(SessionControlPreparation.capture("approve", fields().put("fingerprint", "fingerprint")
            .put("answers", JSONObject().put("question", "synthetic answer")), before))
    }

    @Test fun legacyNativeChoiceLabelsRemainValidOnlyForTheSameOptions() {
        val before = withApproval(approval().put("options", JSONArray().put("Continue").put("Cancel")))
        val intent = SessionControlPreparation.capture("approve", fields().put("fingerprint", "fingerprint").put("option", "Continue"), before)!!
        assertTrue(SessionControlPreparation.validate(intent, copy(before)))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).apply {
            getJSONArray("approvals").getJSONObject(0).put("options", JSONArray().put("Other"))
        }))
        assertNull(SessionControlPreparation.capture("approve", fields().put("fingerprint", "fingerprint").put("option", "Other"), before))
    }

    @Test fun structuredOwnersCompareByTheirContent() {
        val before = page().put("owner", JSONObject().put("kind", "managed").put("id", "owner"))
        val intent = SessionControlPreparation.capture("send", fields(), before)!!
        assertTrue(SessionControlPreparation.validate(intent, copy(before)))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).put("owner", JSONObject().put("kind", "managed").put("id", "changed"))))
    }

    @Test fun settingsPreserveTheRequestedChoiceAndFullAccessConfirmation() {
        val before = page().put("permissionModes", JSONArray().put(JSONObject().put("id", "full-access").put("requiresConfirmation", true)))
        assertNull(SessionControlPreparation.capture("settings", fields().put("mode", "full-access"), before))
        val request = fields().put("mode", "full-access").put("confirmFullAccess", true)
        val intent = SessionControlPreparation.capture("settings", request, before)!!
        assertEquals("full-access", intent.fields.getString("mode"))
        assertTrue(intent.fields.getBoolean("confirmFullAccess"))
        assertFalse(intent.fields.has("model"))
        assertTrue(SessionControlPreparation.validate(intent, copy(before)))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).apply { getJSONObject("composer").put("model", "changed") }))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).put("permissionModes", JSONArray().put(JSONObject().put("id", "auto")))))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).apply { getJSONObject("composer").put("modeLocked", true) }))
    }

    @Test fun creationFreezesKnownDefaultsAndChecksTheRenewedCatalog() {
        val before = creation()
        val request = JSONObject().put("draftId", "draft").put("cwd", "/synthetic").put("text", "prompt")
        val intent = SessionControlPreparation.capture("new", request, before)!!
        assertEquals("model", intent.fields.getString("model"))
        assertEquals("medium", intent.fields.getString("effort"))
        assertEquals("auto", intent.fields.getString("mode"))
        assertEquals("default", intent.fields.getString("executionMode"))
        assertTrue(SessionControlPreparation.validate(intent, copy(before).apply { getJSONObject("composer").put("model", "new-default") }))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).put("models", JSONArray())))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).put("draftId", "new-draft")))
        assertFalse(SessionControlPreparation.validate(intent, copy(before).put("cwd", "/other")))
        assertFalse(request.has("model"))
    }

    @Test fun creationUnknownDefaultChangesAndUnconfirmedPermissionAreRejected() {
        val before = creation().apply { getJSONObject("composer").remove("effort") }
        val request = JSONObject().put("draftId", "draft").put("cwd", "/synthetic")
        val intent = SessionControlPreparation.capture("new", request, before)!!
        assertTrue(SessionControlPreparation.validate(intent, copy(before)))
        // A previously unspecified default cannot acquire a different value during refresh.
        assertFalse(SessionControlPreparation.validate(intent, copy(before).apply { getJSONObject("composer").put("effort", "high") }))
        val full = creation().apply {
            getJSONObject("composer").put("mode", "full-access")
            put("permissionModes", JSONArray().put(JSONObject().put("id", "full-access")))
        }
        assertNull(SessionControlPreparation.capture("new", request, full))
    }

    @Test fun coupledPlanCreationDoesNotAddAConflictingPermissionMode() {
        val before = creation().put("executionModePermissionCoupled", true).apply {
            getJSONObject("composer").put("executionMode", "plan").put("mode", "plan")
            getJSONArray("executionModes").getJSONObject(1).put("permissionMode", "plan")
        }
        val intent = SessionControlPreparation.capture("new", JSONObject().put("draftId", "draft").put("cwd", "/synthetic"), before)!!
        assertEquals("plan", intent.fields.getString("executionMode"))
        assertFalse(intent.fields.has("mode"))
        assertTrue(SessionControlPreparation.validate(intent, copy(before)))
        assertNull(SessionControlPreparation.capture("new", JSONObject().put("draftId", "draft").put("cwd", "/synthetic")
            .put("mode", "full-access").put("confirmFullAccess", true), before))
    }

    @Test fun captureAndValidationNeverMutateInputsOrExposeTheirFrozenCopies() {
        val before = page()
        val request = fields().put("text", "original")
        val pageJSON = before.toString(); val requestJSON = request.toString()
        val intent = SessionControlPreparation.capture("send", request, before)!!
        intent.fields.put("text", "mutated")
        before.getJSONObject("composer").put("model", "edited")
        request.put("text", "edited")
        assertEquals("original", intent.fields.getString("text"))
        assertTrue(SessionControlPreparation.validate(intent, JSONObject(pageJSON)))
        assertFalse(JSONObject(requestJSON).has("submissionMode"))
        assertNull(SessionControlPreparation.capture("send", fields(), null))
        assertNull(SessionControlPreparation.capture("send", fields().put("threadId", "foreign"), JSONObject(pageJSON)))
    }
}
