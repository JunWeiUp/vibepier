package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.ShortcutSnapshot

import org.junit.Assert.*
import org.junit.Test

class ShortcutSnapshotTest {
    @Test fun eightApplicationsPublishOnlyWhenEverySlotArrives() {
        val snapshot = ShortcutSnapshot<String>()
        assertTrue(snapshot.begin("eight", 8))
        var displayed = listOf("previous complete list")
        for (slot in listOf(7, 2, 0, 6, 4, 1, 5)) {
            snapshot.append("eight", slot, entry = "app-$slot")?.let { displayed = it }
            assertEquals(listOf("previous complete list"), displayed)
            assertFalse(snapshot.complete)
        }
        displayed = snapshot.append("eight", 3, entry = "app-3")!!
        assertEquals((0..7).map { "app-$it" }, displayed)
        assertTrue(snapshot.complete)
    }

    @Test fun duplicateAndInvalidFramesCannotCompleteOrReplaceAnEntry() {
        val snapshot = ShortcutSnapshot<String>()
        snapshot.begin("current", 3)
        assertNull(snapshot.append("current", 0, entry = "original"))
        assertNull(snapshot.append("current", 0, entry = "duplicate"))
        assertNull(snapshot.append("old", 1, entry = "wrong revision"))
        assertNull(snapshot.append("current", 1, 5, "wrong count"))
        assertNull(snapshot.append("current", -1, entry = "negative slot"))
        assertNull(snapshot.append("current", 3, entry = "outside list"))
        assertNull(snapshot.append("current", Int.MAX_VALUE, entry = "huge slot"))
        assertFalse(snapshot.contains(1))
        assertFalse(snapshot.complete)
        assertNull(snapshot.append("current", 2, entry = "last"))
        assertEquals(listOf("original", "middle", "last"), snapshot.append("current", 1, entry = "middle"))
        assertNull(snapshot.append("current", 2, entry = "late duplicate"))
    }

    @Test fun legacyFiveAndAListShrinkReplaceOnlyTheirOwnPendingSnapshot() {
        val snapshot = ShortcutSnapshot<Int>()
        assertTrue(snapshot.begin("legacy"))
        assertEquals(5, snapshot.count)
        for (slot in 0..3) assertNull(snapshot.append("legacy", slot, entry = slot))
        assertEquals((0..4).toList(), snapshot.append("legacy", 4, entry = 4))
        assertTrue(snapshot.begin("larger", 8))
        assertNull(snapshot.append("larger", 7, entry = 7))
        assertTrue(snapshot.begin("smaller", 5))
        assertFalse(snapshot.contains(7))
        assertFalse(snapshot.complete)
        assertNull(snapshot.append("larger", 0, 8, 100))
        for (slot in 0..3) assertNull(snapshot.append("smaller", slot, entry = slot))
        assertEquals((0..4).toList(), snapshot.append("smaller", 4, entry = 4))
    }

    @Test fun sameRevisionDoesNotDropProgressAndChangedCountStartsFresh() {
        val snapshot = ShortcutSnapshot<String>()
        snapshot.begin("revision", 8)
        snapshot.append("revision", 0, entry = "keep")
        assertFalse(snapshot.begin("revision", 8))
        assertTrue(snapshot.contains(0))
        assertTrue(snapshot.begin("revision", 6))
        assertFalse(snapshot.contains(0))
        assertEquals(6, snapshot.count)
        assertFalse(snapshot.begin("", 9))
        assertFalse(snapshot.begin("invalid", 0))
        assertFalse(snapshot.begin("invalid", -1))
        assertEquals("revision", snapshot.revision)
        assertEquals(6, snapshot.count)
        snapshot.clear()
        assertEquals("", snapshot.revision)
        assertEquals(5, snapshot.count)
        assertFalse(snapshot.complete)
        assertNull(snapshot.append("revision", 0, entry = "stale"))
    }

    @Test fun cachedSlotValidationAcceptsAnyContiguousLength() {
        assertTrue(ShortcutSnapshot.validSlots(emptyList()))
        assertTrue(ShortcutSnapshot.validSlots(listOf(0, 1, 2)))
        assertTrue(ShortcutSnapshot.validSlots((0..4).toList()))
        assertTrue(ShortcutSnapshot.validSlots(listOf(7, 0, 2, 1, 4, 3, 6, 5)))
        assertFalse(ShortcutSnapshot.validSlots(listOf(0, 0, 1)))
        assertFalse(ShortcutSnapshot.validSlots(listOf(0, 1, 3)))
        assertFalse(ShortcutSnapshot.validSlots(listOf(-1, 0, 1)))
        assertFalse(ShortcutSnapshot.validSlots(listOf(1, 2, 3)))
    }
}
