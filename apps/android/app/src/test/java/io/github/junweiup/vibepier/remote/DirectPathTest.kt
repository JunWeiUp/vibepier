package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.RemoteSender

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DirectPathTest {
    /** Same XOR-MAPPED-ADDRESS vector as the Mac RemoteListenerTests. */
    @Test fun parsesStunMapping() {
        val cookie = intArrayOf(0x21, 0x12, 0xA4, 0x42)
        val port = 47800 xor 0x2112
        val ip = intArrayOf(61, 138, 202, 226).mapIndexed { i, v -> (v xor cookie[i]).toByte() }
        val bytes = byteArrayOf(1, 1, 0, 12, 0x21, 0x12, 0xA4.toByte(), 0x42) + ByteArray(12) { 7 } +
            byteArrayOf(0, 0x20, 0, 8, 0, 1, (port shr 8).toByte(), port.toByte()) + ip.toByteArray()
        assertEquals("61.138.202.226:47800", RemoteSender.stunMapping(bytes, bytes.size))
        assertNull(RemoteSender.stunMapping(bytes, 20))
    }

    @Test fun parsesNumericCandidatesOnly() {
        assertEquals(47800, RemoteSender.parseCandidate("61.138.202.226:47800")?.port)
        assertEquals("2408:8000:0:0:0:0:0:1", RemoteSender.parseCandidate("[2408:8000::1]:5000")?.address?.hostAddress)
        assertNull(RemoteSender.parseCandidate("example.com:5000"))
        assertNull(RemoteSender.parseCandidate("1.2.3.4:0"))
        assertNull(RemoteSender.parseCandidate("1.2.3.4"))
    }
}
