package io.github.junweiup.vibepier.remote

import android.content.SharedPreferences
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.features.remote.BindingSync
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy

class CurrentStorageSchemaTest {
    private class Memory(initial: Map<String, Any>) {
        val values = initial.toMutableMap()
        var writes = 0
        val prefs: SharedPreferences = Proxy.newProxyInstance(
            SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)
        ) { _, method, args ->
            when (method.name) {
                "getAll" -> values.toMap()
                "contains" -> values.containsKey(args!![0])
                "getString", "getBoolean", "getLong" -> values[args!![0]] ?: args[1]
                "edit" -> editor()
                else -> error("Unexpected preferences method: ${method.name}")
            }
        } as SharedPreferences
        private fun editor(): SharedPreferences.Editor {
            val updates = mutableMapOf<String, Any?>()
            return Proxy.newProxyInstance(
                SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)
            ) { proxy, method, args ->
                when (method.name) {
                    "putString", "putBoolean", "putLong" -> { updates[args!![0] as String] = args[1]; proxy }
                    "remove" -> { updates[args!![0] as String] = null; proxy }
                    "apply", "commit" -> {
                        writes++
                        updates.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
                        if (method.name == "commit") true else null
                    }
                    else -> error("Unexpected editor method: ${method.name}")
                }
            } as SharedPreferences.Editor
        }
    }

    @Test fun plaintextOrInvalidPrivateHeaderIsRejectedWithoutWriting() {
        for (data in listOf(mapOf("draft" to "synthetic"), mapOf("sealed.entry" to "invalid"),
            mapOf("__vibepier_private_key_v1" to 1))) {
            val memory = Memory(data)
            assertThrows(IllegalStateException::class.java) {
                PrivatePreferences(memory.prefs, "synthetic|test", "synthetic")
            }
            assertEquals(data, memory.values)
            assertEquals(0, memory.writes)
        }
    }

    @Test fun emptyDeviceStoreInitializesOnlyPhoneIdentity() {
        val memory = Memory(emptyMap())
        val keys = DeviceKeys(memory.prefs)
        assertEquals(setOf("device"), memory.values.keys)
        assertEquals(keys.device, memory.values["device"])
        assertFalse(keys.authorized)
        assertNull(keys.authorizationIdentity)
        assertEquals(1, memory.writes)
    }

    @Test fun missingOrInvalidEpochNeverCreatesAuthorizationOrUsesKeys() {
        for (epoch in listOf(null, "", "invalid", "1-1-1-1-1")) {
            val data = mutableMapOf<String, Any>("device" to "00000000-0000-0000-0000-000000000001")
            if (epoch != null) data["authorizationIdentity"] = epoch
            val memory = Memory(data)
            val keys = DeviceKeys(memory.prefs)
            assertFalse(keys.authorized)
            assertNull(keys.authorizationIdentity)
            assertNull(keys.controlKeys())
            assertThrows(IllegalStateException::class.java) { keys.sessionKey() }
            assertEquals(data, memory.values)
            assertEquals(0, memory.writes)
        }
    }

    @Test fun oldBindingsAreNotEnqueuedAndRemainUntouchedOnOpen() {
        val data = mapOf("keys.confirm" to "cmd+return")
        val memory = Memory(data)
        val sent = mutableListOf<JSONObject>()
        val sync = BindingSync(memory.prefs, sent::add, {}, {}, {}, "conflict")
        sync.flush()
        assertEquals(data, memory.values)
        assertEquals(0, memory.writes)
        sync.snapshot(JSONObject().put("server", "synthetic").put("entries", JSONObject()))
        assertTrue(sent.isEmpty())
        assertFalse(memory.values.containsKey("bindingSync.migrated"))
    }

    @Test fun currentPendingOperationResumesWithoutCreatingANewOperation() {
        val operation = JSONObject().put("type", "vibepier-binding-set1").put("key", "keys.confirm")
            .put("value", "return").put("name", "").put("label", "").put("version", "")
            .put("operation", "synthetic-operation")
        val memory = Memory(mapOf("bindingSync.pending" to JSONObject().put("keys.confirm", operation).toString()))
        val sent = mutableListOf<JSONObject>()
        val sync = BindingSync(memory.prefs, sent::add, {}, {}, {}, "conflict")
        assertEquals(0, memory.writes)
        sync.snapshot(JSONObject().put("server", "synthetic").put("entries", JSONObject()))
        assertEquals(1, sent.size)
        assertEquals("synthetic-operation", sent.single().getString("operation"))
    }

    @Test fun corruptBindingStateIsNotReplacedWithEmptyState() {
        for (key in listOf("bindingSync.pending", "bindingSync.versions")) {
            for (text in listOf("broken", "{\"keys.confirm\":{}}", "{\"keys.confirm\":1}")) {
                val memory = Memory(mapOf(key to text))
                assertThrows(Exception::class.java) { BindingSync(memory.prefs, {}, {}, {}, {}, "conflict") }
                assertEquals(mapOf(key to text), memory.values)
                assertEquals(0, memory.writes)
            }
        }
    }
}
