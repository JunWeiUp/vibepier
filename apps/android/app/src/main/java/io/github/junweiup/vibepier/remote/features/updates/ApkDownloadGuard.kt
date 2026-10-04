package io.github.junweiup.vibepier.remote.features.updates

import java.io.File
import java.io.RandomAccessFile

/** Cancellation and disk commits share one lock, so no obsolete worker can reopen a retired file. */
class ApkDownloadGuard {
    @Volatile var generation = 0; private set
    @Synchronized fun cancel() { generation++ }
    @Synchronized fun durableLength(token: Int, file: File, current: () -> Boolean): Long {
        check(token == generation && current())
        return RandomAccessFile(file, "rw").use { out -> out.fd.sync(); out.length() }
    }
    @Synchronized fun append(token: Int, file: File, offset: Long, bytes: ByteArray, current: () -> Boolean) {
        check(token == generation && current())
        RandomAccessFile(file, "rw").use { out ->
            check(out.length() == offset)
            try { out.seek(offset); out.write(bytes); out.fd.sync() }
            catch (error: Exception) { out.setLength(offset); out.fd.sync(); throw error }
        }
    }
}
