package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.remote.BindingProfiles

import org.junit.Assert.assertEquals
import org.junit.Test

class BindingProfilesTest {
    @Test fun listsLegacyAppOverridesWithoutMetadataOrGlobalEntries() {
        val saved: Map<String, Any> = mapOf(
            "keys.confirm" to "return",
            "app.com.example.editor.keys.confirm" to "cmd+return",
            "app.com.example.editor.keys.knob-press" to "backspace",
            "app.com.example.browser.keys.talk" to "cmd+ctrl",
            "appName.com.example.other" to "Other",
            "app.com.example.invalid.keys.confirm" to "bogus-key",
            "app.com.example.other.keys.unknown-control" to "return",
        )
        assertEquals(listOf(
            BindingProfiles.SavedProfile("com.example.browser", 1),
            BindingProfiles.SavedProfile("com.example.editor", 2)
        ), BindingProfiles.savedProfiles(saved))
        assertEquals(emptyList<BindingProfiles.SavedProfile>(), BindingProfiles.savedProfiles(emptyMap<String, String>()))
    }
    @Test fun appOverridesRemainSeparateAndInheritExistingGlobalBindings() {
        val saved = mutableMapOf("keys.confirm" to "cmd+return")
        fun resolve(app: String?) = BindingProfiles.resolve("confirm", app, saved::get)
        assertEquals("cmd+return", resolve("com.example.A"))
        saved[BindingProfiles.key("confirm", "com.example.A")] = "space"
        saved[BindingProfiles.key("confirm", "com.example.B")] = "tab"
        assertEquals("space", resolve("com.example.A"))
        assertEquals("tab", resolve("com.example.B"))
        assertEquals("cmd+return", resolve(null))
        saved.remove(BindingProfiles.key("confirm", "com.example.A"))
        assertEquals("cmd+return", resolve("com.example.A"))
        saved.clear()
        assertEquals("return", resolve("com.example.A"))
    }
}
