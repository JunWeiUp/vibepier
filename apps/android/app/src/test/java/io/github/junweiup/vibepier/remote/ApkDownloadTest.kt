package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.updates.ApkDownloadGuard
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ApkDownloadTest {
    @Test fun binaryWritesResumeOnlyAtSyncedLengthAndRejectGapsOrDuplicates() {
        val root = Files.createTempDirectory("apk-binary").toFile()
        try {
            val file = File(root, "fixture.apk"); val guard = ApkDownloadGuard(); val token = guard.generation
            val first = ByteArray(64 * 1024) { (it % 251).toByte() }
            guard.append(token, file, 0, first) { true }
            assertEquals(first.size.toLong(), guard.durableLength(token, file) { true })
            assertThrows(IllegalStateException::class.java) { guard.append(token, file, 0, first) { true } }
            assertThrows(IllegalStateException::class.java) { guard.append(token, file, first.size + 1L, first) { true } }
            val restored = ApkDownloadGuard()
            assertEquals(first.size.toLong(), restored.durableLength(restored.generation, file) { true })
            restored.append(restored.generation, file, first.size.toLong(), first) { true }
            assertArrayEquals(first + first, file.readBytes())
        } finally { root.deleteRecursively() }
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
