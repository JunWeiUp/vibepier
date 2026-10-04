package io.github.junweiup.vibepier.remote.features.remote

object BindingProfiles {
    data class SavedProfile(val bundleID: String, val overrideCount: Int)

    /** Read existing overrides directly, so profiles saved by older APKs appear. */
    fun savedProfiles(values: Map<String, *>): List<SavedProfile> {
        val counts = mutableMapOf<String, Int>()
        for ((key, value) in values) {
            if (!key.startsWith("app.") || value !is String || Keys.normalize(value) == null) continue
            val control = Keys.defaults.keys.firstOrNull { key.endsWith(".keys.$it") } ?: continue
            val app = key.removePrefix("app.").removeSuffix(".keys.$control")
            if (app.isNotBlank()) counts[app] = (counts[app] ?: 0) + 1
        }
        return counts.map { SavedProfile(it.key, it.value) }.sortedBy { it.bundleID }
    }
    fun key(control: String, app: String?) =
        if (app.isNullOrBlank()) "keys.$control" else "app.$app.keys.$control"

    fun labelKey(control: String, app: String?) = "label.${key(control, app)}"

    fun resolveLabel(control: String, app: String?, fallback: String, read: (String) -> String?): String =
        read(labelKey(control, app))?.takeIf { it.isNotBlank() }
            ?: read(labelKey(control, null))?.takeIf { it.isNotBlank() }
            ?: fallback

    fun resolve(control: String, app: String?, read: (String) -> String?): String =
        read(key(control, app))?.let(Keys::normalize)
            ?: read(key(control, null))?.let(Keys::normalize)
            ?: Keys.defaults.getValue(control)
}
