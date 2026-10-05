package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONObject

/** Native desktop preparation takes longer than a read; this changes waiting, never replay behavior. */
internal object SessionRequestTiming {
    fun initial(base: Long, override: Long, op: String, body: JSONObject?): Long {
        if (override > 0) return base
        if (op == "agentRequest") {
            val method = SessionAgentProtocol.Method.parse(body?.opt("method")) ?: return base
            return when {
                // Above the Mac pipeline budgets (unlock, desktop takeover, cold provider start); expiry only triggers a read-only check.
                method == SessionAgentProtocol.Method.CREATE -> maxOf(base, 120_000L)
                method == SessionAgentProtocol.Method.CONFIGURE || method == SessionAgentProtocol.Method.SUBMIT -> maxOf(base, 60_000L)
                method.mutation -> maxOf(base, 30_000L)
                else -> base
            }
        }
        return if (op in listOf("send", "new", "approve", "settings", "interrupt", "queueSteer", "queueDelete", "lockScreen", "unlockScreen")) maxOf(base, 30_000L) else base
    }
}
