package io.github.junweiup.vibepier.remote.features.remote

import android.content.SharedPreferences
import org.json.JSONObject
import java.util.UUID

/** Main-thread owner of migration, durable edits, and per-entry conflict resolution. */
class BindingSync(private val prefs: SharedPreferences, private val send: (JSONObject) -> Unit,
                  private val beforeChange: () -> Unit, private val changed: () -> Unit,
                  private val notice: (String) -> Unit, private val conflictMessage: String) {
    private val versions = parse(prefs.getString("bindingSync.versions", null))
    private val pending = parse(prefs.getString("bindingSync.pending", null))
    private var server = prefs.getString("bindingSync.server", "") ?: ""
    private var ready = false
    init {
        if (!prefs.getBoolean("bindingSync.migrated", false)) {
            prefs.all.forEach { (key, value) ->
                if (validKey(key) && value is String && Keys.normalize(value) != null) enqueue(key, value, appName(key))
            }
            persist().putBoolean("bindingSync.migrated", true).apply()
        }
    }
    fun disconnected() { ready = false }
    fun edit(key: String, value: String?, name: String, label: String = "") {
        // Once sent, retain that operation until acknowledged. A second edit follows it.
        val previous = pending.optJSONObject(key)
        if (previous != null && previous.optBoolean("sent")) {
            previous.put("next", value ?: JSONObject.NULL).put("nextName", name).put("nextLabel", label)
        } else enqueue(key, value, name, label)
        beforeChange()
        val editor = persist()
        if (value == null) editor.remove(key) else editor.putString(key, value)
        if (value == null || label.isBlank()) editor.remove("label.$key") else editor.putString("label.$key", label)
        editor.apply()
        changed()
        flush()
    }
    private fun enqueue(key: String, value: String?, name: String, label: String = "") {
        pending.put(key, JSONObject().put("type", "vibepier-binding-set1").put("key", key)
            .put("value", value ?: JSONObject.NULL).put("name", name).put("label", label)
            .put("version", versions.optJSONObject(key)?.optString("version") ?: "")
            .put("operation", UUID.randomUUID().toString()))
    }
    fun flush() {
        if (!ready) return
        // One in flight limits BLE congestion and preserves edit order across lost acknowledgements.
        val key = pending.keys().asSequence().sorted().firstOrNull() ?: return
        val operation = pending.getJSONObject(key)
        operation.put("sent", true)
        persist().apply()
        send(operation)
    }
    fun snapshot(snapshot: JSONObject) {
        val incomingServer = snapshot.getString("server")
        if (server.isNotEmpty() && server != incomingServer) {
            versions.keys().asSequence().toList().forEach(versions::remove)
            beforeChange()
            val editor = prefs.edit()
            prefs.all.keys.filter(::validKey).filter { !pending.has(it) }.forEach { editor.remove(it); editor.remove("label.$it") }
            editor.apply()
        }
        server = incomingServer
        val entries = snapshot.getJSONObject("entries")
        var updated = false
        val editor = prefs.edit()
        entries.keys().forEach { key ->
            if (!validKey(key)) return@forEach
            val entry = entries.getJSONObject(key)
            if (pending.has(key)) {
                if ((versions.optJSONObject(key)?.optLong("generation") ?: -1) <= entry.optLong("generation")) versions.put(key, entry)
            } else updated = applyEntry(key, entry, editor) || updated
        }
        if (updated) beforeChange()
        editor.apply()
        persist().apply()
        ready = true
        if (updated) changed()
        flush()
    }
    fun acknowledge(message: JSONObject) {
        if (message.optString("server") != server) return
        val key = message.optString("key")
        val operation = pending.optJSONObject(key) ?: return
        if (operation.optString("operation") != message.optString("operation")) return
        if (message.has("error")) {
            ready = false // Keep the durable edit; retry on the next connection/status.
            notice(message.getString("error"))
            return
        }
        pending.remove(key)
        val editor = prefs.edit()
        beforeChange()
        val acknowledged = message.optJSONObject("entry")
        val latest = versions.optJSONObject(key)
        val canonical = if (latest != null && latest.optLong("generation") > (acknowledged?.optLong("generation") ?: -1)) latest else acknowledged
        if (canonical != null) applyEntry(key, canonical, editor)
        else { editor.remove(key); editor.remove("label.$key"); versions.remove(key) }
        editor.apply()
        val accepted = message.optBoolean("accepted") && canonical?.optString("version") == acknowledged?.optString("version")
        if (accepted && operation.has("next")) {
            val value = if (operation.isNull("next")) null else operation.getString("next")
            enqueue(key, value, operation.optString("nextName"), operation.optString("nextLabel"))
            prefs.edit().apply {
                if (value == null) remove(key) else putString(key, value)
                val label = operation.optString("nextLabel")
                if (value == null || label.isBlank()) remove("label.$key") else putString("label.$key", label)
            }.apply()
        }
        persist().apply()
        changed()
        if (!accepted) notice(conflictMessage)
        flush()
    }
    private fun applyEntry(key: String, entry: JSONObject, editor: SharedPreferences.Editor): Boolean {
        val previous = versions.optJSONObject(key)
        if (previous != null && previous.optLong("generation") > entry.optLong("generation")) return false
        val value = if (entry.isNull("value")) null else entry.optString("value").takeIf { it.isNotEmpty() }
        if (value != null && Keys.normalize(value) == null) return false
        val label = entry.optString("label").takeIf { value != null && it.isNotBlank() }.orEmpty()
        if (label.length > 200) return false
        val updated = prefs.getString(key, null) != value || prefs.getString("label.$key", "") != label
        if (label.isEmpty()) editor.remove("label.$key") else editor.putString("label.$key", label)
        versions.put(key, entry)
        if (value == null) editor.remove(key) else editor.putString(key, value)
        val app = appID(key)
        val name = entry.optString("name")
        if (app != null && name.isNotBlank()) editor.putString("appName.$app", name)
        return updated
    }
    private fun persist() = prefs.edit().putString("bindingSync.versions", versions.toString())
        .putString("bindingSync.pending", pending.toString()).putString("bindingSync.server", server)
    private fun appName(key: String) = appID(key)?.let { prefs.getString("appName.$it", it) } ?: ""
    companion object {
        private fun parse(text: String?) = try { JSONObject(text ?: "{}") } catch (_: Exception) { JSONObject() }
        private fun appID(key: String): String? = Keys.defaults.keys.firstOrNull { key.startsWith("app.") && key.endsWith(".keys.$it") }
            ?.let { key.removePrefix("app.").removeSuffix(".keys.$it") }
        private fun validKey(key: String) = Keys.defaults.keys.any { key == "keys.$it" } || !appID(key).isNullOrBlank()
    }
}
