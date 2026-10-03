package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.RelayLink

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import javax.net.ssl.SNIHostName

class RelayLinkTest {
    private val secret = "0123456789abcdef0123456789abcdef"

    /** Read the exact fixture also consumed by Swift and Go, never a copied expectation. */
    @Test fun helloMatchesServerVector() {
        val vectors = org.json.JSONArray(javaClass.getResourceAsStream("/relay-hello.json")!!.bufferedReader().use { it.readText() })
        var checked = 0
        for (index in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(index)
            // relay2 is the routed Mac/server protocol; phones use relay1.
            if (vector.getString("protocol") != "vibepier-relay1") continue
            val role = vector.getString("role"); val room = vector.getString("room")
            val timestamp = vector.getLong("timestamp"); val nonce = vector.getString("nonce")
            assertEquals("vibepier-relay1 hello $role $room $timestamp $nonce ${vector.getString("hmac")}",
                RelayLink.hello(role, room, vector.getString("secret"), timestamp, nonce))
            checked++
        }
        assertEquals(2, checked)
    }

    @Test fun acceptKeyFollowsRfc6455Example() {
        assertEquals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", RelayLink.acceptKey("dGhlIHNhbXBsZSBub25jZQ=="))
    }

    @Test fun upgradeRequiresExactStatusAndAgreedHeaders() {
        val key = java.util.Base64.getEncoder().encodeToString("the sample nonce".toByteArray(Charsets.US_ASCII))
        val good = listOf("HTTP/1.1 101 Switching Protocols", "Upgrade: WebSocket", "Connection: keep-alive, Upgrade",
            "Sec-WebSocket-Accept: ${RelayLink.acceptKey(key)}")
        RelayLink.verifyUpgrade(good, key)
        for (bad in listOf(
            listOf("HTTP/1.1 200 101 misleading-status") + good.drop(1),
            good.filterNot { it.startsWith("Connection:") },
            good + good.last(), good + "Sec-WebSocket-Extensions: permessage-deflate",
            good + "Sec-WebSocket-Protocol: unrequested", good.dropLast(1) + "Sec-WebSocket-Accept: invalid",
        )) assertThrows(IllegalStateException::class.java) { RelayLink.verifyUpgrade(bad, key) }
    }

    @Test fun fallbackTlsKeepsOriginalHostForSniAndCertificateValidation() {
        val parameters = RelayLink.tlsParameters("relay.example")
        assertEquals("HTTPS", parameters.endpointIdentificationAlgorithm)
        assertEquals("relay.example", (parameters.serverNames.single() as SNIHostName).asciiName)
    }

    @Test fun pairingCodeIsValidated() {
        val settings = RelayLink.parsePairing("  vibepierrelay1 wss://example.com/vibepier/relay mac-1 $secret ")
        assertEquals(RelayLink.Settings("wss://example.com/vibepier/relay", "mac-1", secret), settings)
        assertNull(RelayLink.parsePairing("vibepierrelay1 https://example.com/r mac-1 $secret"))
        assertNull(RelayLink.parsePairing("vibepierrelay1 wss://example.com/r bad/room $secret"))
        assertNull(RelayLink.parsePairing("vibepierrelay1 wss://example.com/r mac-1 short"))
        assertNull(RelayLink.parsePairing("vibepierrelay2 wss://example.com/r mac-1 $secret"))
    }

    @Test fun dnsRecoveryIsExplicitAndBoundToEncryptedRelayURLs() {
        val ordinary = RelayLink.parsePairing("vibepierrelay1 wss://relay.example.test/r my-mac $secret")!!
        assertFalse(ordinary.dnsRecovery)
        val optedIn = ordinary.copy(dnsRecovery = true)
        assertEquals(optedIn, RelayLink.parsePairing(optedIn.pairingCode))
        assertNull(RelayLink.parsePairing("${ordinary.pairingCode} dns=unknown"))
        assertNull(RelayLink.parsePairing("vibepierrelay1 ws://relay.example.test/r my-mac $secret dns=alidns"))
        assertNull(RelayLink.parsePairing("vibepierrelay1 wss://user:password@relay.example.test/r my-mac $secret"))
    }

    @Test fun framesRoundTripAtEveryLengthEncoding() {
        for (size in listOf(0, 125, 126, 65535, 65536, 200_000)) {
            val payload = ByteArray(size) { (it * 31).toByte() }
            val mask = byteArrayOf(1, 2, 3, 4)
            val frame = RelayLink.encodeFrame(0x1, payload, mask)
            assertEquals(0x81, frame[0].toInt() and 0xFF)
            assertTrue("client frames are masked", frame[1].toInt() and 0x80 != 0)
            val (opcode, fin, decoded) = RelayLink.readFrame(ByteArrayInputStream(frame), masked = true)
            assertEquals(0x1, opcode)
            assertTrue(fin)
            assertArrayEquals(payload, decoded)
        }
    }

    @Test fun readsUnmaskedServerFrames() {
        val (opcode, fin, payload) = RelayLink.readFrame(ByteArrayInputStream(byteArrayOf(0x89.toByte(), 0x02, 'h'.code.toByte(), 'i'.code.toByte())))
        assertEquals(0x9, opcode)
        assertTrue(fin)
        assertEquals("hi", String(payload))
    }

    @Test fun rejectsMalformedFrameHeadersBeforeReadingPayload() {
        val headers = listOf(
            byteArrayOf(0xC1.toByte(), 0), // unnegotiated extension
            byteArrayOf(0x81.toByte(), 0x80.toByte()), // masked server frame
            byteArrayOf(0x82.toByte(), 0), // binary is not part of the text relay protocol
            byteArrayOf(0x09, 0), // fragmented control frame
            byteArrayOf(0x89.toByte(), 126, 0, 126),
            byteArrayOf(0x88.toByte(), 1),
            byteArrayOf(0x81.toByte(), 126, 0, 125), // nonminimal length
            byteArrayOf(0x81.toByte(), 127, 0x80.toByte(), 0, 0, 0, 0, 0, 0, 0), // signed overflow
            byteArrayOf(0x81.toByte(), 127, 0, 0, 0, 0, 0, 0, 0, 126),
        )
        for (header in headers) assertThrows(IllegalStateException::class.java) { RelayLink.readFrame(ByteArrayInputStream(header)) }
    }

    @Test fun fragmentedTextRequiresCorrectOrderAndCompleteUtf8() {
        val buffer = RelayLink.MessageBuffer()
        assertThrows(IllegalStateException::class.java) { buffer.append(0, true, byteArrayOf()) }
        assertNull(buffer.append(1, false, byteArrayOf(0xE2.toByte())))
        assertThrows(IllegalStateException::class.java) { buffer.append(1, true, "interleaved".toByteArray()) }
        assertEquals("€", buffer.append(0, true, byteArrayOf(0x82.toByte(), 0xAC.toByte())))
        assertEquals("next", buffer.append(1, true, "next".toByteArray()))
        assertThrows(java.nio.charset.CharacterCodingException::class.java) { RelayLink.MessageBuffer().append(1, true, byteArrayOf(0xFF.toByte())) }
    }

    @Test fun fragmentedMessagesHaveAnAggregateLimit() {
        val buffer = RelayLink.MessageBuffer()
        assertNull(buffer.append(1, false, ByteArray(1 shl 20) { 'a'.code.toByte() }))
        assertThrows(IllegalStateException::class.java) { buffer.append(0, true, byteArrayOf(1)) }
        assertEquals(1 shl 20, buffer.append(0, true, byteArrayOf())!!.length)
    }
}
