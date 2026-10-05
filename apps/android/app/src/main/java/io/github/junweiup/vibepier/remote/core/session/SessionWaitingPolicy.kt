package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONArray
import org.json.JSONObject

/** Ending a local wait must never make an unconfirmed send safe to repeat. */
internal object SessionWaitingPolicy {
    /** End all existing creation waits in this project, without removing any receipt. */
    fun creationWaits(operations: List<JSONObject>, provider: String, cwd: String): List<JSONObject> =
        operations.filter { it.optString("op") == "new" && it.optString("provider") == provider && it.optString("cwd") == cwd }

    fun freshCreationDraft(previous: SessionCreationDraft, operations: List<JSONObject>): SessionCreationDraft =
        if (creationWaits(operations, previous.provider, previous.cwd).any {
                it.optString("draftId").isBlank() || it.optString("draftId") == previous.id
            }) SessionCreationDraft(java.util.UUID.randomUUID().toString(), previous.provider, previous.cwd) else previous

    fun duplicateCreation(operations: List<JSONObject>, cwd: String, text: String, attachments: JSONArray, operation: String = ""): Boolean =
        duplicateSend(operations.filter { it.optString("op") == "new" && it.optString("cwd") == cwd && it.optString("id") != operation }
            .map { JSONObject(it.toString()).put("op", "send") }, text, attachments)
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
