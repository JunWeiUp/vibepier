package io.github.junweiup.vibepier.remote

import android.content.Context
import android.content.ContextWrapper
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.core.session.ConversationCache
import org.json.JSONObject
import java.security.KeyStore
import java.util.UUID

object PrivatePreferencesProbe {
    fun run(base: Context): String {
        val id = "private-probe-${UUID.randomUUID()}"
        val context = object : ContextWrapper(base) {
            override fun getPackageName() = "${base.packageName}.$id"
            override fun getSharedPreferences(name: String?, mode: Int) = base.getSharedPreferences("$id-$name", mode)
        }
        fun raw(name: String) = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        fun reopen(name: String) = PrivatePreferences(raw(name), "${context.packageName}|$name", context.packageName)
        try {
            val backing = raw("session")
            val store = PrivatePreferences.open(context, "session")
            check(store.edit().putString("draft.private-thread", "private draft 你好").putLong("view", 42L)
                .putInt("int", 7).putFloat("float", 1.25f).putBoolean("flag", true).putStringSet("set", setOf("x", "y")).commit())
            check(store.getString("draft.private-thread", null) == "private draft 你好")
            check(backing.all.keys.none { it.contains("draft") || it == "view" })
            check(backing.all.values.none { it.toString().contains("private draft") || it.toString().contains("private-thread") })
            val restored = reopen("session")
            check(restored.getLong("view", 0) == 42L && restored.getInt("int", 0) == 7)
            check(restored.getFloat("float", 0f) == 1.25f && restored.getBoolean("flag", false))
            check(restored.getStringSet("set", null) == setOf("x", "y"))
            val set = restored.getStringSet("set", null)!!; set.add("mutated")
            check(restored.getStringSet("set", null) == setOf("x", "y"))
            val before = backing.all.toMap()
            check(restored.edit().putString("draft.private-thread", "private draft 你好").commit())
            check(before != backing.all) // Rewrites never reuse the nonce.
            val cache = ConversationCache(restored)
            val large = "秘密内容".repeat(20_000)
            cache.put("page:test", JSONObject().put("text", large)); cache.flush()
            check(ConversationCache(reopen("session")).get("page:test")?.getString("text") == large)
            check(backing.all.values.none { it.toString().contains("秘密内容") })
            check(restored.edit().remove("int").commit() && !reopen("session").contains("int"))
            // Same app, different namespace: copying an authenticated entry never makes it valid.
            val other = PrivatePreferences.open(context, "other")
            other.edit().putString("kept", "safe").commit()
            val transplanted = backing.all.entries.first { it.key.startsWith("sealed.") }
            raw("other").edit().putString(transplanted.key, transplanted.value as String).commit()
            val corrupt = raw("other").all.toMap()
            check(runCatching { reopen("other") }.isFailure)
            check(raw("other").all == corrupt)
            check(raw("other").contains(transplanted.key))
            // Clear preserves the wrapped key and remains encrypted after a fresh open.
            check(restored.edit().clear().putString("new", "replacement").commit())
            check(reopen("session").all == mapOf("new" to "replacement"))
            return "PASS: empty-store initialization, all preference types, hidden keys/content, fresh nonces, large conversation cache round-trip, namespace authentication, corrupt state blocks writes, safe clear\n"
        } finally {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("${context.packageName}.private-preferences.v1") }
            for (name in listOf("session", "other")) base.deleteSharedPreferences("$id-$name")
        }
    }
}
