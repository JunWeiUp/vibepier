package io.github.junweiup.vibepier.remote.core.security

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.security.SecureRandom
import java.util.WeakHashMap
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Per-entry authenticated storage for private app data. A random data key is wrapped by Android
 * Keystore once, so large conversation caches do not require a hardware operation on each edit.
 * Entry names are keyed hashes; namespace/name/type are authenticated. No plaintext fallback.
 */
internal class PrivatePreferences(
    private val backing: SharedPreferences,
    private val namespace: String,
    packageName: String,
) : SharedPreferences {
    private val lock = Any()
    private val listeners = WeakHashMap<SharedPreferences.OnSharedPreferenceChangeListener, Boolean>()
    private val values = linkedMapOf<String, Any>()
    private val alias = "$packageName.private-preferences.v1"
    private val dataKey: SecretKey
    private val nameKey: SecretKey
    private val wrappedKey: String

    init {
        val previous = backing.all
        val wrapped = previous[HEADER] as? String
        val material: ByteArray
        if (wrapped == null) {
            check(previous.isEmpty()) { "Encrypted preferences header is missing or invalid" }
            material = ByteArray(32).also(SecureRandom()::nextBytes)
            wrappedKey = encode(crypt(Cipher.ENCRYPT_MODE, wrappingKey(true), material, namespace))
        } else {
            wrappedKey = wrapped
            material = crypt(Cipher.DECRYPT_MODE, wrappingKey(false), decode(wrapped), namespace)
            check(material.size == 32) { "Invalid private storage key" }
        }
        fun derive(purpose: String): ByteArray = Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(material, "HmacSHA256"))
            doFinal("vibepier-private-preferences-v1|$purpose".toByteArray())
        }
        dataKey = SecretKeySpec(derive("values"), "AES")
        nameKey = SecretKeySpec(derive("names"), "HmacSHA256")
        material.fill(0)
        if (wrapped == null) {
            check(backing.edit().putString(HEADER, wrappedKey).commit()) { "Cannot initialize private preferences" }
        } else {
            for ((entry, encoded) in previous) {
                if (entry == HEADER) continue
                check(entry.startsWith(ENTRY) && encoded is String) { "Invalid private preferences schema" }
                try {
                    val payload = JSONObject(String(crypt(Cipher.DECRYPT_MODE, dataKey, decode(encoded), "$namespace|$entry"), Charsets.UTF_8))
                    val name = payload.getString("key")
                    check(entryName(name) == entry)
                    values[name] = unpack(payload)
                } catch (_: Exception) {
                    // Preserve original bytes and block writes: losing an uncertain receipt must never permit a resend.
                    throw IllegalStateException("Invalid private preferences entry")
                }
            }
        }
    }

    private fun wrappingKey(create: Boolean): SecretKey {
        val vault = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (vault.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "The private storage key is unavailable on this device" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            generateKey()
        }
    }
    private fun entryName(name: String) = ENTRY + encode(Mac.getInstance("HmacSHA256").run {
        init(nameKey); doFinal("$namespace|$name".toByteArray())
    })
    private fun seal(name: String, value: Any, entry: String): String {
        val objectValue = JSONObject().put("key", name)
        when (value) {
            is String -> objectValue.put("type", "string").put("value", value)
            is Boolean -> objectValue.put("type", "boolean").put("value", value)
            is Int -> objectValue.put("type", "int").put("value", value)
            is Long -> objectValue.put("type", "long").put("value", value)
            is Float -> objectValue.put("type", "float").put("value", value.toString())
            is Set<*> -> objectValue.put("type", "set").put("value", JSONArray(value.toList()))
            else -> error("Unsupported private preference type")
        }
        return encode(crypt(Cipher.ENCRYPT_MODE, dataKey, objectValue.toString().toByteArray(), "$namespace|$entry"))
    }
    private fun unpack(value: JSONObject): Any = when (value.getString("type")) {
        "string" -> value.getString("value")
        "boolean" -> value.getBoolean("value")
        "int" -> value.getInt("value")
        "long" -> value.getLong("value")
        "float" -> value.getString("value").toFloat()
        "set" -> value.getJSONArray("value").let { array -> (0 until array.length()).map { array.getString(it) }.toSet() }
        else -> error("Invalid private preference type")
    }
    override fun getAll(): MutableMap<String, *> = synchronized(lock) { values.mapValues { copyValue(it.value) }.toMutableMap() }
    override fun contains(key: String) = synchronized(lock) { values.containsKey(key) }
    override fun getString(key: String, defValue: String?): String? = synchronized(lock) { values[key]?.let { it as String } ?: defValue }
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? = synchronized(lock) {
        @Suppress("UNCHECKED_CAST") (values[key] as? Set<String>)?.toMutableSet() ?: defValues?.toMutableSet()
    }
    override fun getInt(key: String, defValue: Int) = synchronized(lock) { values[key]?.let { it as Int } ?: defValue }
    override fun getLong(key: String, defValue: Long) = synchronized(lock) { values[key]?.let { it as Long } ?: defValue }
    override fun getFloat(key: String, defValue: Float) = synchronized(lock) { values[key]?.let { it as Float } ?: defValue }
    override fun getBoolean(key: String, defValue: Boolean) = synchronized(lock) { values[key]?.let { it as Boolean } ?: defValue }
    override fun edit(): SharedPreferences.Editor = Editor()
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        synchronized(lock) { listeners[listener] = true }
    }
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        synchronized(lock) { listeners.remove(listener) }
    }
    private inner class Editor : SharedPreferences.Editor {
        private val updates = linkedMapOf<String, Any?>()
        private var clearing = false
        override fun putString(key: String, value: String?) = apply { updates[key] = value }
        override fun putStringSet(key: String, values: MutableSet<String>?) = apply { updates[key] = values?.toSet() }
        override fun putInt(key: String, value: Int) = apply { updates[key] = value }
        override fun putLong(key: String, value: Long) = apply { updates[key] = value }
        override fun putFloat(key: String, value: Float) = apply { updates[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { updates[key] = value }
        override fun remove(key: String) = apply { updates[key] = null }
        override fun clear() = apply { clearing = true }
        override fun commit() = persist(true)
        override fun apply() { persist(false) }
        private fun persist(synchronous: Boolean): Boolean {
            val changed = linkedSetOf<String>()
            val callbacks: List<SharedPreferences.OnSharedPreferenceChangeListener>
            synchronized(lock) {
                val editor = backing.edit()
                if (clearing) { editor.clear().putString(HEADER, wrappedKey); changed.addAll(values.keys) }
                for ((name, value) in updates) {
                    val entry = entryName(name)
                    if (value == null) editor.remove(entry) else editor.putString(entry, seal(name, value, entry))
                    if (values[name] != value || clearing) changed.add(name)
                }
                if (synchronous) { if (!editor.commit()) return false } else editor.apply()
                if (clearing) values.clear()
                for ((name, value) in updates) if (value == null) values.remove(name) else values[name] = copyValue(value)
                updates.clear(); clearing = false
                callbacks = listeners.keys.toList()
            }
            if (callbacks.isNotEmpty() && changed.isNotEmpty()) {
                val notify = Runnable { changed.forEach { name -> callbacks.forEach { it.onSharedPreferenceChanged(this@PrivatePreferences, name) } } }
                if (Looper.myLooper() == Looper.getMainLooper()) notify.run() else Handler(Looper.getMainLooper()).post(notify)
            }
            return true
        }
    }
    companion object {
        private const val HEADER = "__vibepier_private_key_v1"
        private const val ENTRY = "sealed."
        private val opened = WeakHashMap<SharedPreferences, PrivatePreferences>()
        fun open(context: Context, name: String): SharedPreferences = synchronized(opened) {
            val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
            opened.getOrPut(prefs) { PrivatePreferences(prefs, "${context.packageName}|$name", context.packageName) }
        }
        private fun copyValue(value: Any): Any = if (value is Set<*>) value.toSet() else value
        private fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
        private fun decode(value: String) = Base64.decode(value, Base64.NO_WRAP)
        private fun crypt(mode: Int, key: SecretKey, bytes: ByteArray, aad: String): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            if (mode == Cipher.ENCRYPT_MODE) {
                cipher.init(mode, key); cipher.updateAAD(aad.toByteArray())
                return cipher.iv + cipher.doFinal(bytes)
            }
            require(bytes.size >= 28)
            cipher.init(mode, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            cipher.updateAAD(aad.toByteArray())
            return cipher.doFinal(bytes.copyOfRange(12, bytes.size))
        }
    }
}
