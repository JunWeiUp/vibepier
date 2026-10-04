package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.sessions.AttachmentUploadWindow
import org.junit.Assert.*
import org.junit.Test

class AttachmentUploadWindowTest {
    @Test fun reorderedRepliesDoNotReleaseUnacknowledgedSlotsOrCompleteEarly() {
        val window = AttachmentUploadWindow(10, 3, 3)
        assertEquals(0, window.reserve()); assertEquals(3, window.reserve()); assertEquals(6, window.reserve())
        assertNull(window.reserve())
        window.acknowledge(6, 9)
        assertEquals(3, window.acknowledgedBytes)
        assertEquals(9, window.reserve()); assertNull(window.reserve())
        window.acknowledge(9, 10); window.acknowledge(0, 3)
        assertFalse(window.complete)
        window.acknowledge(3, 6); assertTrue(window.complete)
    }
    @Test fun duplicateAndIncorrectOffsetsCannotAdvanceProgress() {
        val window = AttachmentUploadWindow(5, 3, 1)
        assertEquals(0, window.reserve())
        assertThrows(IllegalArgumentException::class.java) { window.acknowledge(0, 2) }
        assertEquals(0, window.acknowledgedBytes); assertNull(window.reserve())
        window.acknowledge(0, 3)
        assertThrows(IllegalArgumentException::class.java) { window.acknowledge(0, 3) }
        assertEquals(3, window.reserve()); window.acknowledge(3, 5); assertTrue(window.complete)
    }
}
