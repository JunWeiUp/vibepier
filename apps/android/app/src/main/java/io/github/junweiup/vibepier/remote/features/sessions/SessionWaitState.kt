package io.github.junweiup.vibepier.remote.features.sessions

/** UI-only waiting classification: never clears a receipt or guesses that remote execution stopped. */
internal object SessionWaitState {
    enum class Reason { DISCONNECTED, UNKNOWN, LOADING, APPROVAL, RATE_LIMIT, API_ERROR, BLOCKED, SLOW }
    fun reason(connected: Boolean, ready: Boolean, unknown: Boolean, approvals: Boolean,
               blocker: String, status: String, waitingMs: Long): Reason? = when {
        !connected -> Reason.DISCONNECTED
        unknown -> Reason.UNKNOWN
        !ready -> Reason.LOADING
        approvals -> Reason.APPROVAL
        blocker == "rateLimit" -> Reason.RATE_LIMIT
        blocker == "apiError" -> Reason.API_ERROR
        status in setOf("blocked", "error", "failed") -> Reason.BLOCKED
        status == "active" && waitingMs >= 60_000 -> Reason.SLOW
        else -> null
    }
    fun canStop(connected: Boolean, ready: Boolean, supported: Boolean, active: Boolean,
                turn: String, submitting: Boolean, stopUnconfirmed: Boolean): Boolean =
        connected && ready && supported && active && turn.isNotBlank() && !submitting && !stopUnconfirmed
}
