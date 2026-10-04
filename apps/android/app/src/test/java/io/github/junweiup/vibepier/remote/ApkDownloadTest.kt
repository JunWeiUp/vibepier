package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.updates.ApkDownloadWindow
import io.github.junweiup.vibepier.remote.features.updates.ApkDownloadGuard
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ApkDownloadTest {
    @Test fun outOfOrderWindowNeverAdvancesPastUnsyncedBytes() {
        val window = ApkDownloadWindow(9, 0, 2, 4)
        assertEquals(listOf(0L, 2L, 4L, 6L), (1..4).map { window.reserve() })
        assertNull(window.reserve())
        for (offset in listOf(6L, 4L, 2L)) window.accept(offset, byteArrayOf(1, 2))
        assertNull(window.ready()); assertEquals(0L, window.durableOffset)
        window.accept(0, byteArrayOf(3, 4))
        assertNull(window.reserve()) // A ready/writing slot still occupies the window.
        val first = window.ready()!!
        window.committed(0, first)
        assertEquals(8L, window.reserve()); window.accept(8, byteArrayOf(9))
        while (!window.complete) window.committed(window.durableOffset, window.ready()!!)
        assertEquals(9L, window.durableOffset); assertEquals(0, window.occupied)
    }
    @Test fun duplicateWrongLengthAndUnrequestedRepliesAreRejected() {
        val window = ApkDownloadWindow(5, 0, 2, 4)
        window.reserve()
        assertThrows(IllegalArgumentException::class.java) { window.accept(2, byteArrayOf(1, 2)) }
        assertThrows(IllegalArgumentException::class.java) { window.accept(0, byteArrayOf(1)) }
        window.accept(0, byteArrayOf(1, 2))
        assertThrows(IllegalArgumentException::class.java) { window.accept(0, byteArrayOf(1, 2)) }
        assertThrows(IllegalStateException::class.java) { window.committed(2, window.ready()!!) }
    }
    @Test fun oldPeersAndBluetoothUseOneSlotAndResumeAtActualLength() {
        for (chunk in listOf(8192, 131072)) {
            val window = ApkDownloadWindow(300000, 100003, chunk, 1)
            assertEquals(100003L, window.reserve()); assertNull(window.reserve())
            val bytes = ByteArray(chunk)
            window.accept(100003, bytes); window.committed(100003, bytes)
            assertEquals(100003L + chunk, window.reserve())
        }
    }
    @Test fun cancellationReplacementAndConnectionChangeBlockLateDiskWrites() {
        val root = Files.createTempDirectory("apk-window").toFile()
        try {
            val file = File(root, "fixture.apk"); val guard = ApkDownloadGuard()
            val token = guard.generation
            assertEquals(0L, guard.durableLength(token, file) { true })
            guard.append(token, file, 0, byteArrayOf(1, 2)) { true }
            assertThrows(IllegalStateException::class.java) { guard.append(token, file, 4, byteArrayOf(3)) { true } }
            assertThrows(IllegalStateException::class.java) { guard.append(token, file, 2, byteArrayOf(3)) { false } }
            assertEquals(2L, guard.durableLength(token, file) { true })
            guard.cancel(); file.delete()
            assertThrows(IllegalStateException::class.java) { guard.append(token, file, 0, byteArrayOf(9)) { true } }
            assertFalse(file.exists()) // Obsolete worker cannot resurrect a cancelled snapshot.
            guard.append(guard.generation, file, 0, byteArrayOf(4)) { true }
            assertArrayEquals(byteArrayOf(4), file.readBytes())
        } finally { root.deleteRecursively() }
    }
}
