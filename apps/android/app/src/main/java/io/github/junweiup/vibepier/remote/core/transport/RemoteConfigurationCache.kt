package io.github.junweiup.vibepier.remote.core.transport

import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Persist complete Mac snapshots only; connection state never rides in this cache. */
class RemoteConfigurationCache(private val prefs: android.content.SharedPreferences) {
    constructor(context: Context) : this(PrivatePreferences.open(context, "remote-device-cache"))
    data class Snapshot(val revision: String, val slots: List<RemoteSender.AppShortcut>, val bindings: JSONObject?)
    private fun records(): LinkedHashMap<String, JSONObject> {
        val result = linkedMapOf<String, JSONObject>()
        try {
            val array = JSONArray(prefs.getString("configurationsV1", "[]"))
            for (i in 0 until minOf(array.length(), 4)) {
                val item = array.getJSONObject(i); result[item.getString("scope")] = item.getJSONObject("value")
            }
        } catch (_: Exception) { result.clear() }
        return result
    }
    fun read(scope: String): Snapshot? = try {
        records()[scope]?.let { value ->
            val entries = value.optJSONArray("slots") ?: JSONArray()
            val slots = (0 until entries.length()).map { index ->
                val item = entries.getJSONObject(index)
                RemoteSender.AppShortcut(item.getInt("slot"), item.getString("bundleID"), item.getString("name"), item.optString("iconPNG"), item.optBoolean("available"))
            }
            check(ShortcutSnapshot.validSlots(slots.map { it.slot }))
            check(slots.all { it.iconPNG.length <= 160_000 })
            Snapshot(value.optString("revision"), slots.sortedBy { it.slot }, value.optJSONObject("bindings"))
        }
    } catch (_: Exception) { null }
    fun save(scope: String, revision: String, slots: List<RemoteSender.AppShortcut>, bindings: JSONObject?) {
        if (!ShortcutSnapshot.validSlots(slots.map { it.slot })) return
        val entries = JSONArray(slots.map { JSONObject().put("slot", it.slot).put("bundleID", it.bundleID).put("name", it.name).put("iconPNG", it.iconPNG).put("available", it.available) })
        val value = JSONObject().put("revision", revision).put("slots", entries)
        bindings?.let { value.put("bindings", it) }
        val records = records(); records.remove(scope); records[scope] = value
        while (records.size > 4) records.remove(records.keys.first())
        fun snapshot() = JSONArray(records.map { (key, value) -> JSONObject().put("scope", key).put("value", value) })
        var encoded = snapshot().toString()
        while (encoded.toByteArray().size > 2 * 1024 * 1024 && records.isNotEmpty()) { records.remove(records.keys.first()); encoded = snapshot().toString() }
        prefs.edit().putString("configurationsV1", encoded).apply()
    }
}
