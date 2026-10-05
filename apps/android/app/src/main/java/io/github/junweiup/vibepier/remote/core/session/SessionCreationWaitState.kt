package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONObject

/** Local callbacks never own the durable creation intent or authorize another submission. */
internal class SessionCreationWaitState {
    class CallbackToken internal constructor(internal val generation: Long, internal val operation: String)
    class DraftToken internal constructor(internal val generation: Long, internal val draft: String)
    private var generation = 0L
    private var operation: String? = null

    fun begin(original: JSONObject): CallbackToken {
        require(original.optString("op") == "new" && original.optString("id").isNotBlank())
        generation++
        operation = original.getString("id")
        return CallbackToken(generation, operation!!)
    }
    fun stop() { generation++; operation = null }
    fun accepts(token: CallbackToken): Boolean = token.generation == generation && token.operation == operation
    fun draftToken(draft: String) = DraftToken(generation, draft)
    fun accepts(token: DraftToken, draft: String): Boolean =
        token.generation == generation && token.draft == draft && operation == null

    companion object {
        /** Only discard the read callback; the original mutation and its journal remain intact. */
        fun isReceiptRead(request: JSONObject, operation: String): Boolean {
            if (operation.isBlank()) return false
            return request.optString("op") == "receipt" && request.optString("operation") == operation ||
                request.optString("op") == "agentRequest" &&
                request.optJSONObject("body")?.let {
                    it.optString("method") == "operation.get" && it.optJSONObject("params")?.optString("operationId") == operation
                } == true
        }
    }
}
