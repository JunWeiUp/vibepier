package io.github.junweiup.vibepier.remote.features.remote

import io.github.junweiup.vibepier.remote.core.transport.RemoteSender

/** A permanent temporary-app position keeps every saved launch slot in place. */
internal object DockApplications {
    private val temporaryPlaceholder = RemoteSender.AppShortcut(-1, "", "", "", false)

    fun entries(configured: List<RemoteSender.AppShortcut>, current: RemoteSender.Application?): List<RemoteSender.AppShortcut> {
        val foreground = current?.takeIf { it.bundleID.isNotBlank() }
        val savedForeground = foreground != null && configured.any { it.bundleID == foreground.bundleID }
        val first = if (foreground != null && !savedForeground) {
            RemoteSender.AppShortcut(-1, foreground.bundleID, foreground.name, foreground.iconPNG, true)
        } else temporaryPlaceholder
        return listOf(first) + configured.map { saved ->
            if (foreground != null && saved.bundleID == foreground.bundleID) {
                saved.copy(name = foreground.name, iconPNG = foreground.iconPNG.ifBlank { saved.iconPNG }, available = true)
            } else saved
        }
    }

    fun isTemporaryPlaceholder(entry: RemoteSender.AppShortcut?) = entry?.slot == -1 && entry.bundleID.isBlank()

    fun action(entry: RemoteSender.AppShortcut, current: RemoteSender.Application?): String? {
        if (current == null || current.bundleID.isBlank() || entry.bundleID.isBlank() || !entry.available) return null
        return if (entry.bundleID == current.bundleID) "hide" else "activate"
    }
}
