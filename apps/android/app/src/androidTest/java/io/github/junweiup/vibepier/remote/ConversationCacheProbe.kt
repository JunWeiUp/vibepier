package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.ConversationCache

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal object ConversationCacheProbe {
    fun run(context: Context) {
        val prefs = context.getSharedPreferences("content-probe-${UUID.randomUUID()}", Context.MODE_PRIVATE)
        try {
            val cache = ConversationCache(prefs)
            val text = "x".repeat(240 * 1024)
            repeat(12) { cache.put("page:$it", JSONObject().put("text", text)) }
            check(cache.get("page:0") == null && cache.get("page:11")?.optString("text") == text)
            cache.put("oversized", JSONObject().put("text", "x".repeat(400 * 1024)))
            check(cache.get("oversized") == null)
            cache.flush()
            val saved = JSONArray(prefs.getString("conversationContentV1", "[]"))
            check(saved.length() <= 96 && (0 until saved.length()).sumOf { saved.getJSONObject(it).getString("value").toByteArray().size } <= 2 * 1024 * 1024)
            val restored = ConversationCache(prefs)
            check(restored.get("page:11")?.optString("text") == text)
            restored.put("read:codex:thread:image:one", JSONObject().put("image", "AQID"))
            restored.put("read:claude:thread:image:one", JSONObject().put("image", "different"))
            restored.removePrefix("read:codex:thread:image:")
            check(restored.get("read:codex:thread:image:one") == null && restored.get("read:claude:thread:image:one") != null)
            restored.flush()
            prefs.edit().putString("conversationContentV1", "broken").commit()
            check(ConversationCache(prefs).get("page:11") == null)
        } finally { prefs.edit().clear().commit() }
    }
}
