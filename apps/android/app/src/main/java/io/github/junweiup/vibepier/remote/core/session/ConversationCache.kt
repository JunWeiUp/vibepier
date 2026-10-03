package io.github.junweiup.vibepier.remote.core.session

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Private, bounded content cache. Its entries can display content, never authorize a desktop action. */
internal class ConversationCache(private val prefs: SharedPreferences) {
    private data class Entry(val text: String, val savedAt: Long, val bytes: Int)
    private val lock = Any()
    private val entries = linkedMapOf<String, Entry>()
    private var task: ScheduledFuture<*>? = null
    private var revision = 0
    init {
        try {
            val saved = JSONArray(prefs.getString("conversationContentV1", "[]"))
            for (i in 0 until minOf(saved.length(), 96)) {
                val item = saved.getJSONObject(i); val text = item.getString("value"); val bytes = text.toByteArray().size
                if (bytes <= 384 * 1024) entries[item.getString("key")] = Entry(text, item.optLong("at"), bytes)
            }
            trim()
        } catch (_: Exception) { entries.clear() }
    }
    fun get(key: String, maxAgeMs: Long = Long.MAX_VALUE): JSONObject? {
        val text = synchronized(lock) {
            val entry = entries[key] ?: return null
            val age = System.currentTimeMillis() - entry.savedAt
            if (age < 0 || age > maxAgeMs) return null
            entries.remove(key); entries[key] = entry; entry.text
        }
        return try { JSONObject(text) } catch (_: Exception) { null }
    }
    fun put(key: String, value: JSONObject) {
        val text = value.toString(); val bytes = text.toByteArray().size
        if (bytes > 384 * 1024) return
        synchronized(lock) {
            if (entries[key]?.text == text && !key.startsWith("read:")) return
            entries.remove(key); entries[key] = Entry(text, System.currentTimeMillis(), bytes); trim(); revision++
            task?.cancel(false); task = writer.schedule({ flush() }, 2_000, TimeUnit.MILLISECONDS)
        }
    }
    private fun trim() { while (entries.size > 96 || entries.values.sumOf { it.bytes } > 2 * 1024 * 1024) entries.remove(entries.keys.first()) }
    fun clear() { synchronized(lock) { entries.clear(); revision++; task?.cancel(false); prefs.edit().remove("conversationContentV1").apply() } }
    fun removePrefix(prefix: String) {
        synchronized(lock) { entries.keys.filter { it.startsWith(prefix) }.forEach { entries.remove(it) }; revision++; task?.cancel(false); task = writer.schedule({ flush() }, 2_000, TimeUnit.MILLISECONDS) }
    }
    fun flushAsync() { writer.execute { flush() } }
    fun flush() {
        val snapshot = synchronized(lock) { task?.cancel(false); task = null; revision to entries.toList() }
        val encoded = JSONArray(snapshot.second.map { (key, entry) -> JSONObject().put("key", key).put("at", entry.savedAt).put("value", entry.text) }).toString()
        synchronized(lock) { if (snapshot.first == revision) prefs.edit().putString("conversationContentV1", encoded).apply() }
    }
    companion object { private val writer = ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true } }
}
