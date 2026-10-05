package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONArray
import org.json.JSONObject

/** Ending a local wait must never make an unconfirmed send safe to repeat. */
internal object SessionWaitingPolicy {
    fun duplicateSend(operations: List<JSONObject>, text: String, attachments: JSONArray): Boolean {
        val ids = (0 until attachments.length()).map { attachments.optString(it) }.filter { it.isNotBlank() }.toSet()
        return operations.any { operation ->
            operation.optString("op") == "send" && (
                (text.isNotBlank() && text.trim() == operation.optString("text").trim()) ||
                    operation.optJSONArray("attachments")?.let { original ->
                        (0 until original.length()).any { original.optString(it) in ids }
                    } == true)
        }
    }
}
