package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.RemoteSender
import io.github.junweiup.vibepier.remote.features.remote.DockApplications

import org.junit.Assert.*
import org.junit.Test

class DockApplicationsTest {
    private fun configured(count: Int = 8) = (0 until count).map {
        RemoteSender.AppShortcut(it, "app.$it", "Saved App $it", "saved-icon-$it", true)
    }

    @Test fun configuredForegroundKeepsItsFixedPositionAndAllSavedLaunchSlots() {
        val saved = configured()
        val original = saved.toList()
        val entries = DockApplications.entries(saved, RemoteSender.Application("app.5", "Live App 5"))

        assertEquals(9, entries.size)
        assertTrue(DockApplications.isTemporaryPlaceholder(entries.first()))
        assertEquals((0..7).toList(), entries.drop(1).map { it.slot })
        assertEquals(saved.map { it.bundleID }, entries.drop(1).map { it.bundleID })
        assertEquals("Live App 5", entries[6].name)
        assertEquals("saved-icon-5", entries[6].iconPNG)
        assertEquals(original, saved)
    }

    @Test fun evenLegacyDuplicateSlotsKeepTheirSavedPositions() {
        val saved = configured(5).toMutableList().apply {
            this[3] = this[3].copy(bundleID = "app.1", name = "Duplicate App 1")
        }
        val entries = DockApplications.entries(saved, RemoteSender.Application("app.1", "Live App 1"))

        assertTrue(DockApplications.isTemporaryPlaceholder(entries.first()))
        assertEquals(saved.map { it.bundleID }, entries.drop(1).map { it.bundleID })
        assertEquals((0..4).toList(), entries.drop(1).map { it.slot })
        assertEquals(5, saved.size)
        assertEquals(2, saved.count { it.bundleID == "app.1" })
    }

    @Test fun unconfiguredForegroundUsesOnlyThePermanentTemporaryPosition() {
        val saved = configured()
        val current = RemoteSender.Application("external.app", "External App", "live-icon")
        val entries = DockApplications.entries(saved, current)

        assertEquals(9, entries.size)
        assertEquals(RemoteSender.AppShortcut(-1, "external.app", "External App", "live-icon", true), entries.first())
        assertEquals(saved, entries.drop(1))
        assertEquals("hide", DockApplications.action(entries.first(), current))
    }

    @Test fun foregroundChangesNeverMoveConfiguredEntriesOrChangeDockLength() {
        val saved = configured()
        val foregrounds = listOf(
            RemoteSender.Application("app.7", "App Seven", "first-live-icon"),
            RemoteSender.Application("external.one", "External One", "external-icon"),
            RemoteSender.Application("app.2", "App Two", "second-live-icon"),
            RemoteSender.Application("external.two", "External Two"),
            null)
        val states = foregrounds.map { DockApplications.entries(saved, it) }

        for (state in states) {
            assertEquals(9, state.size)
            assertEquals(saved.map { it.slot }, state.drop(1).map { it.slot })
            assertEquals(saved.map { it.bundleID }, state.drop(1).map { it.bundleID })
        }
        assertEquals("first-live-icon", states[0][8].iconPNG)
        assertEquals("external.one", states[1].first().bundleID)
        assertEquals("second-live-icon", states[2][3].iconPNG)
        assertEquals("saved-icon-7", states[2][8].iconPNG)
        assertEquals("external.two", states[3].first().bundleID)
        assertTrue(DockApplications.isTemporaryPlaceholder(states[4].first()))
    }

    @Test fun disconnectKeepsThePermanentPositionAndDisablesAllCommands() {
        val saved = configured()
        val previous = DockApplications.entries(saved, RemoteSender.Application("external.app", "External App"))
        val offline = DockApplications.entries(saved, null)
        assertEquals(previous.size, offline.size)
        assertTrue(DockApplications.isTemporaryPlaceholder(offline.first()))
        assertEquals(saved, offline.drop(1))
        assertEquals(offline, DockApplications.entries(saved, RemoteSender.Application("", "Unknown")))
        for (entry in previous) {
            assertNull(DockApplications.action(entry, null))
            assertNull(DockApplications.action(entry, RemoteSender.Application("", "Unknown")))
        }
    }

    @Test fun selectedSavedAppHidesFromItsOriginalPositionAndOthersActivate() {
        val saved = configured()
        val current = RemoteSender.Application("app.4", "App Four")
        val entries = DockApplications.entries(saved, current)

        assertNull(DockApplications.action(entries.first(), current))
        assertEquals("hide", DockApplications.action(entries[5], current))
        assertEquals("hide", DockApplications.action(entries[5], current))
        for (entry in entries.drop(1).filter { it.bundleID != current.bundleID }) {
            assertEquals("activate", DockApplications.action(entry, current))
        }
        assertEquals("activate", DockApplications.action(saved[4], RemoteSender.Application("app.0", "App Zero")))
    }

    @Test fun blankAndUnavailableEntriesCannotIssueCommandsButLiveSavedAppCanHide() {
        val current = RemoteSender.Application("app.0", "App Zero")
        assertNull(DockApplications.action(configured()[1].copy(available = false), current))
        assertNull(DockApplications.action(configured()[1].copy(bundleID = ""), current))
        assertNull(DockApplications.action(configured()[0].copy(available = false), current))
        val entries = DockApplications.entries(listOf(configured()[0].copy(available = false)), current)
        assertTrue(DockApplications.isTemporaryPlaceholder(entries.first()))
        assertTrue(entries[1].available) // Foreground presence confirms the app, even if its saved path is stale.
        assertEquals("hide", DockApplications.action(entries[1], current))
    }

    @Test fun temporaryPositionExistsBeforeConfigurationAndDuringDisconnect() {
        val current = RemoteSender.Application("current.app", "Current App")
        val entries = DockApplications.entries(emptyList(), current)
        assertEquals(listOf(RemoteSender.AppShortcut(-1, "current.app", "Current App", "", true)), entries)
        assertEquals("hide", DockApplications.action(entries.first(), current))
        val offline = DockApplications.entries(emptyList(), null)
        assertEquals(1, offline.size)
        assertTrue(DockApplications.isTemporaryPlaceholder(offline.first()))
        assertNull(DockApplications.action(offline.first(), current))
    }
}
