package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

/** The first prompt and its configuration share one encrypted, project-scoped draft. */
internal data class SessionCreationDraft(
    val id: String,
    val provider: String,
    val cwd: String,
    val text: String = "",
    val model: String = "",
    val effort: String = "",
    val mode: String = "",
    val confirmFullAccess: Boolean = false
) {
    val attachmentScope get() = "creation:$id"

    fun value() = JSONObject().put("draftId", id).put("provider", provider).put("cwd", cwd)
        .put("text", text).put("model", model).put("effort", effort).put("mode", mode)
        .put("confirmFullAccess", confirmFullAccess)

    fun matches(request: JSONObject) = request.optString("draftId") == id && request.optString("provider") == provider &&
        request.optString("cwd") == cwd && request.optString("text") == text.trim() &&
        request.optString("model") == model && request.optString("effort") == effort && request.optString("mode") == mode &&
        (request.opt("confirmFullAccess") as? Boolean ?: false) == confirmFullAccess

    /** Snapshot all selected values; later editing cannot mutate an unresolved original request. */
    fun request(operation: String, attachments: JSONArray): JSONObject {
        require(validUUID(operation))
        require(text.toByteArray(Charsets.UTF_8).size <= 32_000)
        require(text.isNotBlank() || attachments.length() > 0)
        require(attachments.length() <= 6)
        val ids = (0 until attachments.length()).map { attachments.getString(it) }
        require(ids.all(::validUUID) && ids.map { it.lowercase() }.distinct().size == ids.size)
        return value().apply {
            put("op", "new"); put("id", operation); put("text", text.trim())
            put("attachments", JSONArray(attachments.toString()))
            if (model.isEmpty()) remove("model")
            if (effort.isEmpty()) remove("effort")
            if (mode.isEmpty()) remove("mode")
        }
    }

    companion object {
        fun key(cwd: String) = MessageDigest.getInstance("SHA-256").digest(cwd.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

        private fun validUUID(value: String): Boolean = try {
            UUID.fromString(value).toString().equals(value, ignoreCase = true)
        } catch (_: IllegalArgumentException) { false }

        fun restore(stored: String?, cwd: String, provider: String): SessionCreationDraft {
            require(cwd.startsWith("/") && !cwd.contains('\u0000') && cwd.toByteArray(Charsets.UTF_8).size <= 4096)
            require(provider in setOf("codex", "claude", "zcode"))
            if (stored == null) return SessionCreationDraft(UUID.randomUUID().toString(), provider, cwd)
            require(stored.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
            val value = JSONObject(stored)
            require(value.getString("cwd") == cwd && value.getString("provider") == provider)
            val id = value.getString("draftId"); require(validUUID(id))
            fun string(key: String): String {
                if (!value.has(key)) return ""
                return (value.get(key) as? String) ?: error("Invalid creation draft")
            }
            val confirmed = if (value.has("confirmFullAccess")) value.get("confirmFullAccess") as? Boolean
                ?: error("Invalid creation confirmation") else false
            return SessionCreationDraft(id, provider, cwd, string("text"), string("model"), string("effort"), string("mode"), confirmed)
        }
    }
}
