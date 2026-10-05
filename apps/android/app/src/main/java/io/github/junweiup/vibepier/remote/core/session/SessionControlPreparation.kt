package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONArray
import org.json.JSONObject

/** A read-only refresh may renew authority, but must preserve the action the user reviewed. */
internal object SessionControlPreparation {
    class Intent internal constructor(val operation: String, private val original: String, internal val page: String) {
        /** Each caller receives a copy; preparing an action never mutates its displayed page or draft. */
        val fields: JSONObject get() = JSONObject(original)
        val mode: String? get() = fields.optString("submissionMode").takeIf { it in setOf("start", "queue") }
    }

    private val operations = setOf("send", "new", "settings", "interrupt", "approve", "queueSteer", "queueDelete")
    private val choices = listOf("model", "mode", "effort", "executionMode")
    private val approvalSemantics = listOf("id", "fingerprint", "revision", "kind", "method", "title", "details",
        "options", "questions", "allowedDecisions", "decisionScope", "plan", "planApprovalScope", "toolUseId",
        "nativeRequestId", "nativeRequestFingerprint")

    fun capture(op: String, fields: JSONObject, cachedPage: JSONObject?): Intent? = runCatching {
        require(op in operations && cachedPage != null)
        val frozen = JSONObject(fields.toString())
        val page = JSONObject(cachedPage.toString())
        if (op == "new") {
            require(page.opt("creationVersion") == 1 && nonempty(frozen, "draftId") && nonempty(frozen, "cwd"))
            require(page.opt("draftId") == frozen.opt("draftId"))
            if (page.has("cwd")) require(page.opt("cwd") == frozen.opt("cwd"))
            val composer = page.optJSONObject("composer")
            val execution = frozen.opt("executionMode") ?: composer?.opt("executionMode")
            // Freeze actual advertised defaults. A coupled plan's permission mode is resolved by the Mac.
            for (key in choices) if (!frozen.has(key) && composer?.opt(key) is String && composer.optString(key).isNotBlank()) {
                if (key != "mode" || !SessionExecutionModes.coupled(page) || execution != "plan") {
                    frozen.put(key, composer.get(key))
                }
            }
        } else {
            require(nonempty(frozen, "threadId") && page.opt("threadId") == frozen.opt("threadId"))
            require(page.opt("status") in setOf("idle", "active"))
            if (op == "send") {
                val mode = if (frozen.has("submissionMode")) frozen.opt("submissionMode") else {
                    if (page.opt("status") == "active" || rows(page, "queuedMessages").isNotEmpty()) "queue" else "start"
                }
                require(mode in setOf("start", "queue"))
                frozen.put("submissionMode", mode)
            }
        }
        val intent = Intent(op, frozen.toString(), page.toString())
        require(validate(intent, page))
        intent
    }.getOrNull()

    fun validate(intent: Intent, freshPage: JSONObject): Boolean = runCatching {
        val fields = intent.fields
        val before = JSONObject(intent.page)
        if (freshPage.opt("ok") == false || freshPage.opt("event") == "unavailable" ||
            freshPage.has("contentState") && freshPage.opt("contentState") != "complete") return false
        if (intent.operation == "new") return creation(fields, before, freshPage)
        if (freshPage.opt("threadId") != fields.opt("threadId") || freshPage.opt("status") !in setOf("idle", "active")) return false
        if (before.has("owner") && !equivalent(before.opt("owner"), freshPage.opt("owner"))) return false
        when (intent.operation) {
            "send" -> sameComposer(before, freshPage) && if (intent.mode == "start") {
                freshPage.opt("status") == "idle" && rows(freshPage, "queuedMessages").isEmpty()
            } else {
                (freshPage.opt("status") == "active" || rows(freshPage, "queuedMessages").isNotEmpty()) &&
                    sameKnown(before, freshPage, "activeTurnId")
            }
            "settings" -> choices.any(fields::has) && sameComposer(before, freshPage) &&
                sameKnown(before, freshPage, "executionModePermissionCoupled") && options(fields, freshPage, false)
            "interrupt" -> nonempty(fields, "expectedTurnId") && freshPage.opt("status") == "active" &&
                before.opt("activeTurnId") == fields.opt("expectedTurnId") && freshPage.opt("activeTurnId") == fields.opt("expectedTurnId")
            "queueSteer", "queueDelete" -> queue(intent.operation, fields, before, freshPage)
            "approve" -> approval(fields, before, freshPage)
            else -> false
        }
    }.getOrDefault(false)

    private fun creation(fields: JSONObject, before: JSONObject, fresh: JSONObject): Boolean {
        if (fresh.opt("creationVersion") != 1 || fresh.opt("draftId") != fields.opt("draftId") ||
            fresh.has("cwd") && fresh.opt("cwd") != fields.opt("cwd")) return false
        if (!sameKnown(before, fresh, "executionModePermissionCoupled")) return false
        // Unknown omitted defaults must not become a different implicit choice during renewal.
        for (key in choices) if (!fields.has(key) && !equivalent(before.optJSONObject("composer")?.opt(key), fresh.optJSONObject("composer")?.opt(key))) return false
        if (SessionExecutionModes.coupled(before) && fields.opt("executionMode") == "plan") {
            val original = rows(before, "executionModes").singleOrNull { it.opt("id") == "plan" }
            val current = rows(fresh, "executionModes").singleOrNull { it.opt("id") == "plan" }
            if (!equivalent(original?.opt("permissionMode"), current?.opt("permissionMode"))) return false
        }
        return options(fields, fresh, true)
    }

    private fun options(fields: JSONObject, page: JSONObject, requireCatalog: Boolean): Boolean {
        val composer = page.optJSONObject("composer")
        if (fields.has("confirmFullAccess") && fields.opt("confirmFullAccess") !is Boolean) return false
        for (key in choices) {
            if (!fields.has(key)) continue
            if (!nonempty(fields, key)) return false
            val locked = when (key) { "model", "effort" -> "locked"; "mode" -> "modeLocked"; else -> "executionModeLocked" }
            if (composer?.opt(locked) == true && composer.opt(key) != fields.opt(key)) return false
            val catalog = when (key) {
                "model" -> page.optJSONArray("models")
                "mode" -> page.optJSONArray("permissionModes") ?: page.optJSONArray("modes")
                "executionMode" -> page.optJSONArray("executionModes")
                else -> null
            }
            if (key != "effort" && (requireCatalog || catalog != null) && !contains(catalog, fields.opt(key))) return false
            if (key == "mode") {
                val row = rows(catalog).singleOrNull { it.opt("id") == fields.opt(key) }
                if ((fields.opt(key) in setOf("full-access", "bypassPermissions") || row?.opt("requiresConfirmation") == true) &&
                    fields.opt("confirmFullAccess") != true) return false
            }
            if (key == "effort") {
                val model = fields.opt("model") ?: composer?.opt("model")
                val selected = rows(page, "models").singleOrNull { it.opt("id") == model }
                val modelEfforts = selected?.optJSONArray("efforts")
                val sharedEfforts = page.optJSONArray("efforts")
                if ((requireCatalog || modelEfforts != null || sharedEfforts != null) &&
                    !contains(modelEfforts, fields.opt(key)) && !contains(sharedEfforts, fields.opt(key))) return false
            }
        }
        if (fields.opt("executionMode") == "plan" && SessionExecutionModes.coupled(page) && fields.has("mode")) {
            val plan = rows(page, "executionModes").singleOrNull { it.opt("id") == "plan" }
            if (plan?.opt("permissionMode") != fields.opt("mode")) return false
        }
        return true
    }

    private fun queue(op: String, fields: JSONObject, before: JSONObject, fresh: JSONObject): Boolean {
        if (!nonempty(fields, "messageId")) return false
        val original = rows(before, "queuedMessages").singleOrNull { it.opt("id") == fields.opt("messageId") } ?: return false
        val current = rows(fresh, "queuedMessages").singleOrNull { it.opt("id") == fields.opt("messageId") } ?: return false
        if (!listOf("id", "text", "attachments").all { equivalent(original.opt(it), current.opt(it)) }) return false
        val flag = if (op == "queueSteer") "canSteer" else "canDelete"
        if (original.opt(flag) != true || current.opt(flag) != true) return false
        if (op != "queueSteer") return true
        if (before.opt("status") != fresh.opt("status")) return false
        return if (before.opt("status") == "active") nonempty(before, "activeTurnId") && fresh.opt("activeTurnId") == before.opt("activeTurnId")
            else sameKnown(before, fresh, "activeTurnId")
    }

    private fun approval(fields: JSONObject, before: JSONObject, fresh: JSONObject): Boolean {
        if (!nonempty(fields, "fingerprint")) return false
        val original = rows(before, "approvals").singleOrNull { it.opt("fingerprint") == fields.opt("fingerprint") } ?: return false
        val current = rows(fresh, "approvals").singleOrNull { it.opt("fingerprint") == fields.opt("fingerprint") } ?: return false
        if (original.opt("canDecide") != true || current.opt("canDecide") != true ||
            !approvalSemantics.all { equivalent(original.opt(it), current.opt(it)) }) return false
        if (fields.has("expectedApprovalRevision") && fields.opt("expectedApprovalRevision") != current.opt("revision")) return false
        val answers = fields.optJSONObject("answers")
        if (fields.has("answers") && answers == null) return false
        if (answers != null) {
            if (current.opt("kind") != "questions" || answers.length() == 0 ||
                answers.keys().asSequence().any { !nonempty(answers, it) }) return false
            val questions = rows(current, "questions")
            // Compact native cards omit the full form; its fingerprint/revision still binds the native validation.
            if (questions.isEmpty()) return true
            val ids = questions.map { it.optString("id") }
            if (ids.any { it.isBlank() } || ids.distinct().size != ids.size || answers.keys().asSequence().any { it !in ids }) return false
            if (current.opt("method") == "item/tool/requestUserInput" && questions.any { !answers.has(it.optString("id")) }) return false
            return questions.all { question ->
                val answer = answers.opt(question.optString("id")) ?: return@all true
                question.opt("freeform") == true || containsLabels(question.optJSONArray("options"), answer)
            }
        }
        if (current.opt("kind") == "questions") return nonempty(fields, "option") && contains(current.optJSONArray("options"), fields.opt("option"))
        if (fields.has("option") && current.optJSONArray("options") != null) {
            return nonempty(fields, "option") && contains(current.optJSONArray("options"), fields.opt("option"))
        }
        val decision = if (fields.has("option")) fields.opt("option") else when (fields.opt("allow")) { true -> "allow"; false -> "deny"; else -> null }
        if (decision !in setOf("allow", "deny")) return false
        val allowed = current.optJSONArray("allowedDecisions")
        return allowed == null || contains(allowed, decision)
    }

    private fun sameComposer(before: JSONObject, fresh: JSONObject) = choices.all {
        sameKnown(before.optJSONObject("composer"), fresh.optJSONObject("composer"), it)
    }
    private fun sameKnown(before: JSONObject?, fresh: JSONObject?, key: String) = before?.has(key) != true || equivalent(before?.opt(key), fresh?.opt(key))
    private fun nonempty(value: JSONObject, key: String) = (value.opt(key) as? String)?.isNotBlank() == true
    private fun rows(page: JSONObject, key: String) = rows(page.optJSONArray(key))
    private fun rows(value: JSONArray?) = (0 until (value?.length() ?: 0)).mapNotNull { value?.optJSONObject(it) }
    private fun contains(values: JSONArray?, choice: Any?) = choice != null && (0 until (values?.length() ?: 0)).any {
        values?.opt(it) == choice || values?.optJSONObject(it)?.opt("id") == choice
    }
    private fun containsLabels(values: JSONArray?, choice: Any?) = choice != null && (0 until (values?.length() ?: 0)).any {
        values?.opt(it) == choice || values?.optJSONObject(it)?.opt("label") == choice
    }
    private fun equivalent(left: Any?, right: Any?) = SessionAgentProtocol.canonical(left) == SessionAgentProtocol.canonical(right)
}
