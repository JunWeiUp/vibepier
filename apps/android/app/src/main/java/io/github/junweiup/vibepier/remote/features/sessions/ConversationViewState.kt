package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.core.session.SessionProvider
import org.json.JSONObject

/** Non-content navigation only. The authorization epoch rejects state from a replaced Mac. */
internal data class ConversationViewState(val source: String, val provider: String, val drawer: Boolean,
                                         val thread: String, val title: String, val scrollY: Int) {
    fun json() = JSONObject().put("source", source).put("provider", provider).put("drawer", drawer)
        .put("thread", thread).put("title", title).put("scrollY", scrollY)
    fun sameConversation(other: ConversationViewState) = !drawer && !other.drawer &&
        source == other.source && provider == other.provider && thread == other.thread
    companion object {
        fun read(value: JSONObject, authorization: String): ConversationViewState? {
            val provider = value.optString("provider")
            val drawer = value.optBoolean("drawer", true)
            val thread = value.optString("thread")
            if (authorization.isBlank() || value.optString("source") != authorization || provider !in SessionProvider.ids ||
                (!drawer && thread.isBlank()) || thread.length > 512 || value.optString("title").length > 4096) return null
            return ConversationViewState(authorization, provider, drawer, thread, value.optString("title"),
                value.optInt("scrollY").coerceIn(0, 10_000_000))
        }
    }
}

/** A picker belongs to one live creation dialog, even if another dialog opens for the same project. */
internal object ConversationPickerTarget {
    fun matchesCreation(expected: JSONObject, current: JSONObject, authorization: String): Boolean {
        val old = ConversationViewState.read(expected, authorization) ?: return false
        val now = ConversationViewState.read(current, authorization) ?: return false
        val token = expected.optString("creationPickerToken")
        return expected.optBoolean("creationAttachment") && current.optBoolean("creationAttachment") &&
            token.isNotBlank() && token == current.optString("creationPickerToken") && old.source == now.source &&
            old.provider == now.provider && old.drawer == now.drawer && old.thread == now.thread
    }
}

internal data class ConversationRenderScope(val source: String, val provider: String, val thread: String, val generation: Int)
