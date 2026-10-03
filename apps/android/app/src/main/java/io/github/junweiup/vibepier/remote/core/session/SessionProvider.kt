package io.github.junweiup.vibepier.remote.core.session

/** Provider identity is shared by navigation, durable drafts and request routing. */
internal object SessionProvider {
    val ids = listOf("codex", "claude", "zcode")
    fun normalize(value: String?) = value?.takeIf { it in ids } ?: "codex"
    fun name(value: String) = when (value) { "claude" -> "Claude Code"; "zcode" -> "ZCode"; else -> "Codex" }
    fun mark(value: String) = when (value) { "claude" -> "✻"; "zcode" -> "Z"; else -> "C" }
    fun supports(value: String, explicit: Boolean?, legacyDefault: Boolean = true) =
        explicit ?: (value != "zcode" && legacyDefault)
    fun scope(value: String, thread: String) = "$value:$thread"
}
