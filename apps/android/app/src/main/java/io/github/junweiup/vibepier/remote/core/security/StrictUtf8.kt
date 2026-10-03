package io.github.junweiup.vibepier.remote.core.security

/** Reject malformed UTF-8 rather than silently replacing invalid bytes. */
internal object StrictUtf8 {
    fun decode(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
        .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
}
