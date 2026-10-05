package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** Freeze the user's action first; acquire and validate current native control evidence separately. */
internal object SessionControlPreparation {
    class Intent internal constructor(val operation: String, private val original: String) {
        val fields: JSONObject get() = JSONObject(original)
        /** Only advanced callers choose a submission mode before the native read. */
        val mode: String? get() = fields.optString("submissionMode").takeIf { it in setOf("start", "queue") }
    }

    private val operations = setOf("send", "new", "settings", "interrupt", "approve", "queueSteer", "queueDelete")
    private val choices = listOf("model", "mode", "effort", "executionMode")

    /** Cached pages are display projections, never admission evidence for a new action. */
    @Suppress("UNUSED_PARAMETER")
    fun capture(op: String, fields: JSONObject, cachedPage: JSONObject? = null): Intent? = runCatching {
        require(op in operations)
        val frozen = JSONObject(fields.toString())
        require(choices.all { !frozen.has(it) || nonempty(frozen, it) })
        require(!frozen.has("confirmFullAccess") || frozen.opt("confirmFullAccess") is Boolean)
        if (op == "new") {
            require(nonempty(frozen, "draftId") && nonempty(frozen, "cwd"))
        } else require(nonempty(frozen, "threadId"))
        when (op) {
            "send" -> require(!frozen.has("submissionMode") || frozen.opt("submissionMode") in setOf("start", "queue"))
            "settings" -> require(choices.any(frozen::has))
            "interrupt" -> require(nonempty(frozen, "expectedTurnId"))
            "queueSteer", "queueDelete" -> {
                require(nonempty(frozen, "messageId"))
                require(!frozen.has("expectedQueueDigest") || nonempty(frozen, "expectedQueueDigest"))
                require(!frozen.has("expectedTurnId") || nonempty(frozen, "expectedTurnId"))
            }
            "approve" -> {
                require(nonempty(frozen, "fingerprint"))
                require(!frozen.has("expectedApprovalRevision") || nonempty(frozen, "expectedApprovalRevision"))
            }
        }
        Intent(op, frozen.toString())
    }.getOrNull()

    fun validate(intent: Intent, freshPage: JSONObject): Boolean = resolvedFields(intent, freshPage) != null

    /** The returned copy is final journal input; resolving defaults never edits the draft or intent. */
    fun resolvedFields(intent: Intent, freshPage: JSONObject): JSONObject? = runCatching {
        val fields = intent.fields
        require(freshPage.opt("ok") != false && freshPage.opt("event") != "unavailable")
        require(!freshPage.has("contentState") || freshPage.opt("contentState") == "complete")
        if (intent.operation == "new") {
            require(freshPage.opt("creationVersion") == 1 && freshPage.opt("draftId") == fields.opt("draftId"))
            require(!freshPage.has("cwd") || freshPage.opt("cwd") == fields.opt("cwd"))
            resolveCreationDefaults(fields, freshPage)
            require(options(fields, freshPage, true))
        } else {
            require(freshPage.opt("threadId") == fields.opt("threadId"))
            when (intent.operation) {
                "send" -> {
                    val active = freshPage.opt("status") == "active"
                    val queued = rows(freshPage, "queuedMessages").isNotEmpty()
                    require(freshPage.opt("status") in setOf("idle", "active"))
                    val mode = intent.mode ?: if (active || queued) "queue" else "start"
                    require(if (mode == "start") !active && !queued else active || queued)
                    fields.put("submissionMode", mode)
                }
                "settings" -> require(options(fields, freshPage, false))
                "interrupt" -> require(freshPage.opt("status") == "active" && freshPage.opt("activeTurnId") == fields.opt("expectedTurnId"))
                "queueSteer", "queueDelete" -> require(queue(intent.operation, fields, freshPage))
                "approve" -> require(approval(fields, freshPage))
            }
        }
        fields
    }.getOrNull()

    /** Bind the selected queue content while ignoring presentation defaults for an absent body/attachments. */
    fun queueDigest(item: JSONObject): String {
        val body = JSONObject().put("id", item.opt("id")).put("text", item.opt("text")?.takeUnless { it == JSONObject.NULL } ?: "")
            .put("attachments", item.opt("attachments")?.takeUnless { it == JSONObject.NULL } ?: JSONArray())
        return MessageDigest.getInstance("SHA-256").digest(SessionAgentProtocol.canonical(body).toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    private fun resolveCreationDefaults(fields: JSONObject, page: JSONObject) {
        val composer = page.optJSONObject("composer")
        val execution = fields.opt("executionMode") ?: composer?.opt("executionMode")
        for (key in choices) if (!fields.has(key) && composer?.opt(key) is String && composer.optString(key).isNotBlank()) {
            if (key == "effort" && fields.opt("model") != composer.opt("model")) continue
            if (key != "mode" || !SessionExecutionModes.coupled(page) || execution != "plan") fields.put(key, composer.get(key))
        }
        if (!fields.has("executionMode") && rows(page, "executionModes").any { it.opt("id") == "default" }) fields.put("executionMode", "default")
        if (!fields.has("effort")) {
            val selected = rows(page, "models").singleOrNull { it.opt("id") == fields.opt("model") }
            val defaultEffort = selected?.opt("defaultEffort") as? String
            if (!defaultEffort.isNullOrBlank()) fields.put("effort", defaultEffort)
        }
        // A creation catalog supplies its initial selection. Do not invent an unknown model or permissions.
        require(nonempty(fields, "model"))
        require(SessionExecutionModes.coupled(page) && fields.opt("executionMode") == "plan" || nonempty(fields, "mode"))
    }

    private fun options(fields: JSONObject, page: JSONObject, requireCatalog: Boolean): Boolean {
        val composer = page.optJSONObject("composer")
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
                if ((fields.opt(key) in setOf("full-access", "bypassPermissions") || row?.opt("requiresConfirmation") == true) && fields.opt("confirmFullAccess") != true) return false
            }
            if (key == "effort") {
                val model = fields.opt("model") ?: composer?.opt("model")
                val selected = rows(page, "models").singleOrNull { it.opt("id") == model }
                val modelEfforts = selected?.optJSONArray("efforts")
                val sharedEfforts = page.optJSONArray("efforts")
                if ((requireCatalog || modelEfforts != null || sharedEfforts != null) && !contains(modelEfforts, fields.opt(key)) && !contains(sharedEfforts, fields.opt(key))) return false
            }
        }
        if (fields.opt("executionMode") == "plan" && SessionExecutionModes.coupled(page) && fields.has("mode")) {
            val plan = rows(page, "executionModes").singleOrNull { it.opt("id") == "plan" }
            if (plan?.opt("permissionMode") != fields.opt("mode")) return false
        }
        return true
    }

    private fun queue(op: String, fields: JSONObject, fresh: JSONObject): Boolean {
        val current = rows(fresh, "queuedMessages").singleOrNull { it.opt("id") == fields.opt("messageId") } ?: return false
        if (current.opt(if (op == "queueSteer") "canSteer" else "canDelete") != true) return false
        if (fields.has("expectedQueueDigest") && queueDigest(current) != fields.opt("expectedQueueDigest")) return false
        return op != "queueSteer" || !fields.has("expectedTurnId") || fresh.opt("status") == "active" && fresh.opt("activeTurnId") == fields.opt("expectedTurnId")
    }

    private fun approval(fields: JSONObject, fresh: JSONObject): Boolean {
        val current = rows(fresh, "approvals").singleOrNull { it.opt("fingerprint") == fields.opt("fingerprint") } ?: return false
        if (current.opt("canDecide") != true) return false
        if (fields.has("expectedApprovalRevision") && fields.opt("expectedApprovalRevision") != current.opt("revision")) return false
        val answers = fields.optJSONObject("answers")
        if (fields.has("answers") && answers == null) return false
        if (answers != null) {
            if (current.opt("kind") != "questions" || answers.length() == 0 || answers.keys().asSequence().any { !nonempty(answers, it) }) return false
            val questions = rows(current, "questions")
            // Compact cards still bind the native full-form validation through their fingerprint/revision.
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
        if (fields.has("option") && current.optJSONArray("options") != null) return nonempty(fields, "option") && contains(current.optJSONArray("options"), fields.opt("option"))
        val decision = if (fields.has("option")) fields.opt("option") else when (fields.opt("allow")) { true -> "allow"; false -> "deny"; else -> null }
        return decision in setOf("allow", "deny") && (current.optJSONArray("allowedDecisions") == null || contains(current.optJSONArray("allowedDecisions"), decision))
    }

    private fun nonempty(value: JSONObject, key: String) = (value.opt(key) as? String)?.isNotBlank() == true
    private fun rows(page: JSONObject, key: String) = rows(page.optJSONArray(key))
    private fun rows(value: JSONArray?) = (0 until (value?.length() ?: 0)).mapNotNull { value?.optJSONObject(it) }
    private fun contains(values: JSONArray?, choice: Any?) = choice != null && (0 until (values?.length() ?: 0)).any { values?.opt(it) == choice || values?.optJSONObject(it)?.opt("id") == choice }
    private fun containsLabels(values: JSONArray?, choice: Any?) = choice != null && (0 until (values?.length() ?: 0)).any { values?.opt(it) == choice || values?.optJSONObject(it)?.opt("label") == choice }
}
