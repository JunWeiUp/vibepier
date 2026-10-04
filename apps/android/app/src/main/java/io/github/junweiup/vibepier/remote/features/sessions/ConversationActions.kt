package io.github.junweiup.vibepier.remote.features.sessions

/** Sending never doubles as an interrupt; waiting and remote execution have separate actions. */
internal object ConversationActions {
    data class Submit(val queued: Boolean, val enabled: Boolean)
    fun submit(active: Boolean, queueSupported: Boolean, ready: Boolean, canSend: Boolean,
               submitting: Boolean, uploading: Boolean, unresolved: Boolean,
               changingSettings: Boolean, hasContent: Boolean): Submit = Submit(
        queued = active && queueSupported,
        enabled = ready && canSend && !submitting && !uploading && !unresolved && !changingSettings && hasContent,
    )
}
