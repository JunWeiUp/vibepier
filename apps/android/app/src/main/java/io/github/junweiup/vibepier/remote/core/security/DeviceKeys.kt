package io.github.junweiup.vibepier.remote.core.security

import android.content.Context
import android.security.keystore.KeyProperties
import android.security.keystore.KeyProtection
import java.security.KeyStore
import java.util.UUID
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec

/** Shared phone identity and non-exportable keys. The root key is never written to preferences. */
internal class DeviceKeys(context: Context) {
    private val prefs = context.getSharedPreferences("device-identity", Context.MODE_PRIVATE)
    val device: String = synchronized(lock) {
        prefs.getString("device", null) ?: UUID.randomUUID().toString().also {
            check(prefs.edit().putString("device", it).commit()) { "Cannot persist phone identity" }
        }
    }
    private val prefix = "vibepier.device.$device."
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val names = listOf("session", "handshake", "phone", "mac")

    private fun cachedKeys(): CachedKeys? {
        cache[device]?.let { return it }
        return try {
            val vault = store()
            if (!names.all { vault.containsAlias(prefix + it) }) return null
            CachedKeys(
                vault.getKey(prefix + "session", null) as SecretKey,
                SecureControlKeys(vault.getKey(prefix + "handshake", null) as SecretKey,
                    vault.getKey(prefix + "phone", null) as SecretKey, vault.getKey(prefix + "mac", null) as SecretKey),
            ).also { cache[device] = it }
        } catch (_: Exception) { null }
    }

    val authorized: Boolean get() = synchronized(lock) { cachedKeys() != null }
    fun sessionKey(): SecretKey = synchronized(lock) { checkNotNull(cachedKeys()).session }
    fun controlKeys(): SecureControlKeys? = synchronized(lock) { cachedKeys()?.control }

    /** Persist a reserved range, so restarts never reuse event IDs with this stable device identity. */
    fun nextSequence(): Long = synchronized(lock) {
        var block = sequences[device]
        if (block == null || block.next >= block.end) {
            val start = prefs.getLong("eventSequenceUpperBound", 0)
            check(start in 0..Long.MAX_VALUE - 4096) { "Event sequence exhausted" }
            val end = start + 4096
            check(prefs.edit().putLong("eventSequenceUpperBound", end).commit()) { "Cannot reserve event identifiers" }
            block = SequenceBlock(start, end)
            sequences[device] = block
        }
        ++block.next
    }

    fun install(root: ByteArray) = synchronized(lock) {
        require(root.size == 32)
        cache.remove(device)
        val vault = store()
        val aes = KeyProtection.Builder(KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build()
        try {
            for (purpose in listOf("handshake", "phone", "mac")) {
                val material = SecureControlKeys.derive(root, purpose)
                try {
                    val protection = if (purpose == "handshake") {
                        KeyProtection.Builder(KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                            .setDigests(KeyProperties.DIGEST_SHA256).build()
                    } else aes
                    val algorithm = if (purpose == "handshake") "HmacSHA256" else "AES"
                    vault.setEntry(prefix + purpose, KeyStore.SecretKeyEntry(SecretKeySpec(material, algorithm)), protection)
                } finally { material.fill(0) }
            }
            // The final alias is the enrollment commit marker; readers hold the same lock.
            vault.setEntry(prefix + "session", KeyStore.SecretKeyEntry(SecretKeySpec(root, "AES")), aes)
        } catch (error: Exception) {
            for (name in names) runCatching { vault.deleteEntry(prefix + name) }
            throw error
        }
    }

    fun clear() = synchronized(lock) {
        cache.remove(device)
        val vault = store()
        for (name in names) vault.deleteEntry(prefix + name)
    }

    private data class CachedKeys(val session: SecretKey, val control: SecureControlKeys)
    private data class SequenceBlock(var next: Long, val end: Long)
    companion object {
        private val lock = Any()
        private val cache = mutableMapOf<String, CachedKeys>()
        private val sequences = mutableMapOf<String, SequenceBlock>()
    }
}
