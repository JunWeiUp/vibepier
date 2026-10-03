package io.github.junweiup.vibepier.remote.core.security

import io.github.junweiup.vibepier.remote.R
import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.github.junweiup.vibepier.remote.core.transport.RelayLink
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Encrypts relay credentials with a non-exportable, device-local Android Keystore key. */
internal class RelaySettingsStore(context: Context) {
    private val resources = context.resources
    private val prefs = context.getSharedPreferences("relay-settings", Context.MODE_PRIVATE)
    private val alias = "${context.packageName}.relay-settings.v1"
    private fun key(create: Boolean): SecretKey? {
        val vault = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (vault.getKey(alias, null) as? SecretKey)?.let { return it }
        if (!create) return null
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            generateKey()
        }
    }
    fun read(): RelayLink.Settings? = synchronized(lock) {
        try {
            val stored = prefs.getString("sealed", null) ?: return null
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            if (bytes.size < 28) return null
            val secret = key(false) ?: return null
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            cipher.updateAAD(alias.toByteArray())
            RelayLink.parsePairing(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
        } catch (_: Exception) { null }
    }
    fun save(settings: RelayLink.Settings) = synchronized(lock) {
        require(settings.valid)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, checkNotNull(key(true)))
        cipher.updateAAD(alias.toByteArray())
        val code = settings.pairingCode
        val sealed = Base64.encodeToString(cipher.iv + cipher.doFinal(code.toByteArray()), Base64.NO_WRAP)
        check(prefs.edit().putString("sealed", sealed).commit()) { resources.getString(R.string.relay_store_save_failed) }
    }
    fun migrate(legacy: SharedPreferences): RelayLink.Settings? {
        val saved = read()
        if (saved != null) {
            check(legacy.edit().remove("relayPairing").commit()) { resources.getString(R.string.relay_store_cleanup_failed) }
            return saved
        }
        val old = RelayLink.parsePairing(legacy.getString("relayPairing", "") ?: "") ?: return null
        save(old)
        check(legacy.edit().remove("relayPairing").commit()) { resources.getString(R.string.relay_store_cleanup_failed) }
        return old
    }
    companion object { private val lock = Any() }
}
