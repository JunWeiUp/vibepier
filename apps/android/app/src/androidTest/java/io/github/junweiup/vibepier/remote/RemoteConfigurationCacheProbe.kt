package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.RemoteConfigurationCache
import io.github.junweiup.vibepier.remote.core.transport.RemoteSender

import android.content.Context
import android.content.ContextWrapper
import org.json.JSONArray
import org.json.JSONObject

object RemoteConfigurationCacheProbe {
    fun run(context: Context) {
        val wrapped = object : ContextWrapper(context) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("remote-cache-probe-$name", mode)
        }
        val prefs = io.github.junweiup.vibepier.remote.core.security.PrivatePreferences.open(wrapped, "remote-device-cache")
        prefs.edit().clear().commit()
        try {
            fun slots(count: Int) = (0 until count).map { RemoteSender.AppShortcut(it, "app.$it", "App $it", "icon-$it", true) }
            val legacy = slots(5)
            val eight = slots(8)
            val bindings = JSONObject().put("revision", "keys-v1").put("entries", JSONObject().put("global.talk", "cmd"))
            RemoteConfigurationCache(prefs).save("mac-a", "icons-v1", legacy, bindings)
            val restored = RemoteConfigurationCache(prefs).read("mac-a")!!
            check(restored.slots == legacy && restored.revision == "icons-v1") // Existing five-app caches still restore.
            check(restored.bindings!!.optString("revision") == "keys-v1")
            check(RemoteConfigurationCache(prefs).read("mac-b") == null)
            for (invalid in listOf(legacy.drop(1), legacy.dropLast(1) + legacy.last().copy(slot = 5), legacy + legacy.last(), legacy.map { it.copy(slot = it.slot - 1) })) {
                RemoteConfigurationCache(prefs).save("mac-a", "invalid", invalid, null)
                check(RemoteConfigurationCache(prefs).read("mac-a")!!.revision == "icons-v1")
            }
            check(RemoteConfigurationCache(prefs).read("mac-a")!!.revision == "icons-v1")
            RemoteConfigurationCache(prefs).save("mac-eight", "icons-eight", eight.reversed(), bindings)
            check(RemoteConfigurationCache(prefs).read("mac-eight")!!.slots == eight) // Variable-size snapshots sort by slot.
            val foreground = RemoteSender.AppShortcut(-1, "current.mac.app", "Current Mac App", "", true)
            RemoteConfigurationCache(prefs).save("mac-eight", "ephemeral-current", listOf(foreground) + eight, bindings)
            check(RemoteConfigurationCache(prefs).read("mac-eight")!!.revision == "icons-eight")
            check(RemoteConfigurationCache(prefs).read("mac-eight")!!.slots == eight) // A live current-app tile never replaces the configured snapshot.
            RemoteConfigurationCache(prefs).save("mac-b", "icons-v2", legacy.map { it.copy(name = "Changed") }, bindings)
            check(RemoteConfigurationCache(prefs).read("mac-a")!!.slots == legacy)
            check(RemoteConfigurationCache(prefs).read("mac-b")!!.slots.first().name == "Changed")
            val records = JSONArray(prefs.getString("configurationsV1", "[]"))
            for (index in 0 until records.length()) {
                val record = records.getJSONObject(index)
                if (record.getString("scope") == "mac-eight") record.getJSONObject("value").getJSONArray("slots").getJSONObject(0).put("slot", 99)
            }
            prefs.edit().putString("configurationsV1", records.toString()).commit()
            check(RemoteConfigurationCache(prefs).read("mac-eight") == null) // Corrupted slot numbers are rejected on read too.
            RemoteConfigurationCache(prefs).save("mac-eight", "icons-eight", eight, bindings)
            var sender = RemoteSender(wrapped)
            try {
                fun invoke(name: String, message: JSONObject) = sender.javaClass.getDeclaredMethod(name, JSONObject::class.java).apply { isAccessible = true }.invoke(sender, message)
                val scope = sender.javaClass.getDeclaredMethod("configurationScope").apply { isAccessible = true }.invoke(sender) as String
                RemoteConfigurationCache(prefs).save(scope, "icons-v1", legacy, bindings)
                sender.changeMode("wifi")
                fun shortcut(revision: String, slot: Int, count: Int? = null) = JSONObject()
                    .put("revision", revision).put("slot", slot).put("bundleID", "updated.$slot")
                    .put("name", "Updated $slot").put("iconPNG", "new-$slot").put("available", true)
                    .also { if (count != null) it.put("count", count) }
                check(sender.cachedShortcuts == legacy)
                invoke("receiveRevision", JSONObject().put("shortcutsRevision", "icons-v2").put("shortcutsCount", 8))
                check(sender.cachedShortcuts == legacy) // Updating a revision keeps the last complete set visible.
                for (slot in listOf(7, 0, 5, 2, 4, 1, 6)) invoke("receiveShortcut", shortcut("icons-v2", slot, 8))
                check(sender.cachedShortcuts == legacy)
                invoke("receiveShortcut", shortcut("icons-v2", 0, 8).put("name", "Duplicate"))
                invoke("receiveShortcut", shortcut("icons-v2", -1, 8))
                invoke("receiveShortcut", shortcut("icons-v2", 8, 8))
                invoke("receiveShortcut", shortcut("stale-revision", 3, 8))
                invoke("receiveShortcut", shortcut("icons-v2", 3, 5))
                check(sender.cachedShortcuts == legacy)
                invoke("receiveShortcut", shortcut("icons-v2", 3, 8))
                check(sender.cachedShortcuts.size == 8 && sender.cachedShortcuts.first().name == "Updated 0")
                check(sender.cachedShortcuts.map { it.slot } == (0..7).toList())
                sender.close(); sender = RemoteSender(wrapped); sender.changeMode("wifi")
                check(sender.cachedShortcuts.size == 8 && sender.cachedShortcuts.last().iconPNG == "new-7")
                check(sender.cachedShortcuts.none { it.slot < 0 || it.bundleID == foreground.bundleID })
                invoke("receiveRevision", JSONObject().put("shortcutsRevision", "legacy-server")) // Old Macs do not announce a count.
                for (slot in 0..3) invoke("receiveShortcut", shortcut("legacy-server", slot))
                check(sender.cachedShortcuts.size == 8)
                invoke("receiveShortcut", shortcut("legacy-server", 4))
                check(sender.cachedShortcuts.size == 5)
                sender.close(); sender = RemoteSender(wrapped); sender.changeMode("wifi")
                check(sender.cachedShortcuts.size == 5 && sender.cachedShortcuts.last().iconPNG == "new-4")
                verifyCurrentApplicationIcons(sender)
                sender.changeHost("192.0.2.1")
                check(sender.cachedShortcuts.isEmpty()) // Switching to an uncached Mac never uses another endpoint's icons.
            } finally { sender.close() }
            prefs.edit().putString("configurationsV1", "corrupt").commit()
            check(RemoteConfigurationCache(prefs).read("mac-a") == null)
            RemoteConfigurationCache(prefs).save("mac-c", "recovered", eight, bindings)
            check(RemoteConfigurationCache(prefs).read("mac-c")!!.revision == "recovered")
        } finally { prefs.edit().clear().commit() }
    }

    /** Invokes receive handlers directly, with no selected network endpoint or Mac commands. */
    private fun verifyCurrentApplicationIcons(sender: RemoteSender) {
        fun invoke(name: String, message: JSONObject) = sender.javaClass.getDeclaredMethod(name, JSONObject::class.java)
            .apply { isAccessible = true }.invoke(sender, message)
        fun clear() = sender.javaClass.getDeclaredMethod("clearCurrentApplication").apply { isAccessible = true }.invoke(sender)
        val identity = sender.javaClass.getDeclaredField("sender").apply { isAccessible = true }.get(sender) as String
        fun status(bundle: String, revision: String) = invoke("receiveApplicationStatus", JSONObject()
            .put("bundleID", bundle).put("name", "Name $bundle").put("currentAppRevision", revision))
        fun frame(bundle: String, revision: String, part: Int, count: Int, text: String) = JSONObject()
            .put("type", "vibepier-current1").put("sender", identity).put("bundleID", bundle).put("revision", revision)
            .put("iconPart", part).put("iconParts", count).put("iconPNG", text)
        fun icon(bundle: String, revision: String, part: Int, count: Int, text: String) =
            invoke("receiveCurrentIcon", frame(bundle, revision, part, count, text))
        fun cache() = sender.javaClass.getDeclaredField("currentIcons").apply { isAccessible = true }.get(sender) as Map<*, *>
        val originalCallback = sender.onApplication
        val published = mutableListOf<RemoteSender.Application?>()
        sender.onApplication = { published.add(it) }
        try {
            status("current.a", "a-v1")
            check(published.single() == RemoteSender.Application("current.a", "Name current.a"))
            icon("current.a", "a-v1", 2, 3, "cc")
            icon("current.a", "a-v1", 0, 3, "aa")
            icon("current.a", "a-v1", 0, 3, "aa") // Repeated fragments still do not publish an incomplete icon.
            icon("current.a", "a-v1", -1, 3, "bad")
            icon("current.a", "a-v1", 3, 3, "bad")
            icon("current.a", "a-v1", 1, 129, "bad")
            invoke("receiveCurrentIcon", frame("current.a", "a-v1", 1, 3, "bad").put("sender", "another-phone"))
            icon("other.app", "a-v1", 1, 3, "bad")
            icon("current.a", "old-revision", 1, 3, "bad")
            check(published.size == 1 && published.last()!!.iconPNG.isEmpty())
            icon("current.a", "a-v1", 1, 3, "bb")
            check(published.size == 2 && published.last()!!.iconPNG == "aabbcc")

            status("current.a", "a-v2")
            val afterNewRevision = published.size
            icon("current.a", "a-v2", 0, 2, "fresh-")
            icon("current.a", "a-v1", 1, 2, "old-icon")
            icon("current.a", "a-v1", 0, 1, "old-complete-icon")
            icon("current.a", "a-v2", 1, 3, "wrong-count")
            check(published.size == afterNewRevision && published.last()!!.iconPNG == "aabbcc")
            icon("current.a", "a-v2", 1, 2, "icon")
            check(published.last()!!.iconPNG == "fresh-icon")

            status("current.a", "a-v3")
            icon("current.a", "a-v3", 0, 2, "retired-")
            status("current.b", "b-v1")
            val afterForegroundChange = published.size
            icon("current.a", "a-v3", 1, 2, "late-icon")
            icon("current.a", "a-v2", 0, 1, "duplicate-old-icon")
            icon("current.b", "b-v1", 1, 2, "B")
            check(published.size == afterForegroundChange && published.last()!!.bundleID == "current.b" && published.last()!!.iconPNG.isEmpty())
            icon("current.b", "b-v1", 0, 2, "icon-")
            check(published.size == afterForegroundChange + 1 && published.last()!!.iconPNG == "icon-B")

            clear()
            check(published.last() == null)
            val afterDisconnect = published.size
            icon("current.b", "b-v1", 0, 1, "late-after-disconnect")
            check(published.size == afterDisconnect && published.last() == null)
            status("current.b", "b-v1")
            check(published.last()!!.iconPNG == "icon-B") // A reconnect to this endpoint can reuse a complete icon.

            for (index in 0..16) {
                status("cached.$index", "revision-$index")
                icon("cached.$index", "revision-$index", 0, 1, "icon-$index")
                check(cache().size <= 16)
            }
            check(cache().size == 16 && !cache().containsKey("cached.0") && cache().containsKey("cached.16"))
            status("cached.1", "revision-1") // Touch the oldest cached icon so it becomes the most recently used.
            check(published.last()!!.iconPNG == "icon-1")
            status("cached.17", "revision-17")
            icon("cached.17", "revision-17", 0, 1, "icon-17")
            check(cache().size == 16 && cache().containsKey("cached.1") && !cache().containsKey("cached.2"))
            sender.changeHost("192.0.2.2")
            check(cache().isEmpty() && published.last() == null)
            val afterEndpointChange = published.size
            icon("cached.16", "revision-16", 0, 1, "late-old-endpoint")
            check(published.size == afterEndpointChange && published.last() == null)
            status("cached.16", "revision-16")
            check(published.last()!!.iconPNG.isEmpty()) // Another Mac never inherits this endpoint's current-app icons.
        } finally { sender.onApplication = originalCallback }
    }
}
