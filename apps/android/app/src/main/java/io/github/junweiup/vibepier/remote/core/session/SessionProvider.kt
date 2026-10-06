package io.github.junweiup.vibepier.remote.core.session

/** Provider identity is shared by navigation, durable drafts and request routing. */
internal object SessionProvider {
    val ids = SessionV1Contract.providers
    // Keep retired persisted identities opaque: never reinterpret their threads or receipts as Codex.
    fun normalize(value: String?) = value ?: "codex"
    /** Navigation may select a supported tab, but must never migrate its predecessor's state. */
    fun selection(value: String, enabled: List<String>): String? =
        value.takeIf { it in ids && it in enabled } ?: ids.firstOrNull { it in enabled }
    fun name(value: String) = when (value) { "claude" -> "Claude Code"; "codex" -> "Codex"; else -> value }
    fun mark(value: String) = when (value) { "claude" -> "✻"; "codex" -> "C"; else -> "?" }
    fun supports(value: String, explicit: Boolean?) =
        value in ids && explicit == true
    fun scope(value: String, thread: String) = "$value:$thread"
}
