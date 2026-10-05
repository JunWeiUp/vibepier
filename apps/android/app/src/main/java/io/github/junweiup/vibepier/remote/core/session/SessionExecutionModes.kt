package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONObject

/** Plan/execute choices are supplied by a verified Mac catalog, independently of permission mode. */
internal data class SessionExecutionMode(val id: String, val name: String, val description: String, val permissionMode: String? = null)

internal object SessionExecutionModes {
    val ids = setOf("default", "plan")
    fun decode(value: JSONObject): List<SessionExecutionMode> = runCatching {
        val rows = value.optJSONArray("executionModes") ?: return emptyList()
        require(rows.length() in 1..2)
        if (value.has("executionModePermissionCoupled")) require(value.opt("executionModePermissionCoupled") is Boolean)
        value.optJSONObject("composer")?.let { composer ->
            if (composer.has("executionModePermissionCoupled")) require(composer.opt("executionModePermissionCoupled") is Boolean)
        }
        val choices = (0 until rows.length()).map { index ->
            val row = rows.getJSONObject(index)
            val id = row.opt("id") as? String ?: error("Invalid execution mode")
            val name = row.opt("name") as? String ?: error("Invalid execution label")
            require(id in ids && name.isNotBlank() && name.length <= 256 && '\u0000' !in name)
            val description = if (row.has("description")) row.opt("description") as? String ?: error("Invalid execution description") else ""
            require(description.length <= 2048 && '\u0000' !in description)
            val permission = if (row.has("permissionMode")) (row.opt("permissionMode") as? String)?.takeIf {
                it.isNotBlank() && it.length <= 256 && '\u0000' !in it
            } ?: error("Invalid native permission mode") else null
            if (coupled(value)) require(permission != null)
            SessionExecutionMode(id, name, description, permission)
        }
        require(choices.map { it.id }.distinct().size == choices.size)
        choices
    }.getOrDefault(emptyList())
    fun selected(value: JSONObject, choices: List<SessionExecutionMode>) = choices.singleOrNull {
        it.id == value.optJSONObject("composer")?.opt("executionMode")
    }
    fun coupled(value: JSONObject) = value.opt("executionModePermissionCoupled") == true ||
        value.optJSONObject("composer")?.opt("executionModePermissionCoupled") == true
    fun defaultPermissionLabel(value: JSONObject, choices: List<SessionExecutionMode> = decode(value)): String? {
        if (!coupled(value)) return null
        val permission = choices.singleOrNull { it.id == "default" }?.permissionMode ?: return null
        val modes = value.optJSONArray("permissionModes") ?: value.optJSONArray("modes")
        val row = (0 until (modes?.length() ?: 0)).mapNotNull { modes?.optJSONObject(it) }.singleOrNull { it.opt("id") == permission }
        return (row?.opt("name") as? String)?.takeIf { it.isNotBlank() && it.length <= 256 && '\u0000' !in it } ?: permission
    }
}
