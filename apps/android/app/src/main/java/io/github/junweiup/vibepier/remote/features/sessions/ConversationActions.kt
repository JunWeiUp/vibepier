package io.github.junweiup.vibepier.remote.features.sessions

/** View action policy: sending, interruption and read-only receipt recovery remain distinct. */
internal object ConversationActions {
    data class Submit(val queued: Boolean, val enabled: Boolean)
    fun approvalReceiptEnabled(connected: Boolean, authorized: Boolean, inFlight: Boolean,
                               retryOriginal: Boolean, canDecide: Boolean): Boolean =
        connected && authorized && !inFlight && (!retryOriginal || canDecide)
    fun submit(active: Boolean, queueSupported: Boolean, ready: Boolean, canSend: Boolean,
               submitting: Boolean, uploading: Boolean, unresolved: Boolean,
               changingSettings: Boolean, hasContent: Boolean): Submit = Submit(
        queued = active && queueSupported,
        enabled = ready && canSend && !submitting && !uploading && !unresolved && !changingSettings && hasContent,
    )
}
