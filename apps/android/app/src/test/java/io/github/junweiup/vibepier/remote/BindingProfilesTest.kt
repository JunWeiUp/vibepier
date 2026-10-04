package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.remote.BindingProfiles

import org.junit.Assert.assertEquals
import org.junit.Test

class BindingProfilesTest {
    @Test fun labelsInheritAndResetSeparatelyFromApplicationNames() {
        val saved = mutableMapOf("label.keys.confirm" to "发送", "appName.com.example.A" to "Editor")
        fun label(app: String?) = BindingProfiles.resolveLabel("confirm", app, "确认", saved::get)
        assertEquals("发送", label("com.example.A"))
        saved[BindingProfiles.labelKey("confirm", "com.example.A")] = "运行"
        assertEquals("运行", label("com.example.A"))
        assertEquals("发送", label("com.example.B"))
        saved.remove(BindingProfiles.labelKey("confirm", "com.example.A"))
        assertEquals("发送", label("com.example.A"))
        saved.remove("label.keys.confirm")
        assertEquals("确认", label("com.example.A"))
        assertEquals("Editor", saved["appName.com.example.A"])
    }
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
