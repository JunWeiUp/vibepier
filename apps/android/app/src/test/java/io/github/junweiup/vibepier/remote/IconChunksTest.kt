package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.IconChunks

import org.junit.Assert.*
import org.junit.Test

class IconChunksTest {
    @Test fun assemblesReorderedAndDuplicatePacketsOnlyWhenComplete() {
        val chunks = IconChunks(3)
        assertNull(chunks.append(2, "ghi"))
        assertNull(chunks.append(2, "ghi"))
        assertNull(chunks.append(0, "abc"))
        assertEquals("abcdefghi", chunks.append(1, "def"))
    }
    @Test fun rejectsInvalidChunksWithoutDamagingExistingData() {
        val chunks = IconChunks(2)
        assertNull(chunks.append(0, "abc"))
        assertNull(chunks.append(-1, "bad"))
        assertNull(chunks.append(2, "bad"))
        assertNull(chunks.append(1, "x".repeat(1201)))
        assertEquals("abcdef", chunks.append(1, "def"))
    }
}
