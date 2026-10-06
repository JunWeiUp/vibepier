package io.github.junweiup.vibepier.remote

import android.content.Context
import android.content.ContextWrapper
import io.github.junweiup.vibepier.remote.core.security.RelaySettingsStore
import io.github.junweiup.vibepier.remote.core.transport.RelayLink
import java.security.KeyStore
import java.util.UUID

object RelaySettingsStoreProbe {
    fun run(base: Context): String {
        val namespace = "relay-store-${UUID.randomUUID()}"
        val context = object : ContextWrapper(base) {
            override fun getPackageName() = "${base.packageName}.$namespace"
            override fun getSharedPreferences(name: String?, mode: Int) = base.getSharedPreferences("$namespace-$name", mode)
        }
        val prefs = context.getSharedPreferences("relay-settings", Context.MODE_PRIVATE)
        try {
            val settings = RelayLink.Settings("wss://relay.example.com/vibepier/relay", "test-room", "s".repeat(64), dnsRecovery = true)
            val store = RelaySettingsStore(context)
            check(store.read() == null)
            store.save(settings)
            check(RelaySettingsStore(context).read() == settings)
            check(prefs.all.values.none { it.toString().contains(settings.secret) || it.toString().contains(settings.url) })
            val sealed = prefs.getString("sealed", "")!!
            store.save(settings)
            check(prefs.getString("sealed", "") != sealed) // Fresh random IV on every write.
            check(prefs.edit().putString("sealed", "!!!!").commit())
            val corrupt = prefs.all.toMap()
            check(runCatching { store.read() }.isFailure)
            check(runCatching { store.save(settings) }.isFailure)
            check(prefs.all == corrupt)
            return "PASS: current relay settings use Android Keystore, preserve explicit DNS recovery, reject corrupt ciphertext without overwriting, and use fresh IVs\n"

        } finally {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("${context.packageName}.relay-settings.v1") }
            base.deleteSharedPreferences("$namespace-relay-settings")
        }
    }
}
