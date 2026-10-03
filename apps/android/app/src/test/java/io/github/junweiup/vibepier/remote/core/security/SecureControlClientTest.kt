package io.github.junweiup.vibepier.remote.core.security

import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import org.junit.Assert.*
import org.junit.Test

class SecureControlClientTest {
    private val device = "00000000-0000-4000-8000-000000000001"
    private val root = ByteArray(32) { 0x31 }
    private val keys = SecureControlKeys.fromRoot(root)
    private var now = 1000L
    private fun client(provider: () -> SecureControlKeys? = { keys }) =
        SecureControlClient(device, provider, { 1_700_000_000 }, { now })

    private fun ready(hello: String, session: String = UUID.randomUUID().toString(), crypto: SecureControlKeys = keys, version: String = "1", capabilities: String = "15"): String {
        val fields = hello.split(' ')
        val reply = listOf(SecureControlClient.READY, fields[1], fields[2], session, version, capabilities)
        return (reply + SecureControlKeys.hex(crypto.signature(reply))).joinToString(" ")
    }

    private fun hostFrame(session: String, sequence: Long, text: String = "app state"): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keys.mac)
        cipher.updateAAD(SecureControlClient.aad("mac", device, session, sequence))
        return "${SecureControlClient.FRAME} $device $session $sequence ${Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(text.toByteArray()))}"
    }

    @Test fun unpairedOrUnnegotiatedClientCannotSendControls() {
        val missing = client { null }
        assertNull(missing.hello())
        assertNull(missing.seal("confirm".toByteArray()))
        val peer = client()
        assertFalse(peer.ready)
        assertNull(peer.seal("confirm".toByteArray()))
        assertSame(SecureControlClient.Result.Rejected, peer.receive("vibepier-app1 arbitrary"))
    }

    @Test fun readyMustAuthenticateTheCurrentPendingNonce() {
        val peer = client()
        val hello = peer.hello()!!
        assertTrue(keys.verify(hello.split(' ')[6], hello.split(' ').take(6)))
        assertEquals(hello, peer.hello())
        assertSame(SecureControlClient.Result.Rejected, peer.receive(ready(hello, crypto = SecureControlKeys.fromRoot(ByteArray(32) { 0x32 }))))
        assertSame(SecureControlClient.Result.Ready, peer.receive(ready(hello)))
        assertTrue(peer.ready)
        assertSame(SecureControlClient.Result.Rejected, peer.receive(ready(hello)))
    }

    @Test fun encryptedControlHasBoundDirectionAndSequence() {
        val peer = client(); val handshake = ready(peer.hello()!!)
        peer.receive(handshake)
        val message = peer.seal("confirm".toByteArray())!!.split(' ')
        val box = Base64.getDecoder().decode(message[4])
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, keys.phone, GCMParameterSpec(128, box.copyOfRange(0, 12)))
        cipher.updateAAD(SecureControlClient.aad("phone", device, message[2], message[3].toLong()))
        assertEquals("confirm", String(cipher.doFinal(box, 12, box.size - 12)))
        assertSame(SecureControlClient.Result.Rejected, peer.receive(message.joinToString(" ")))
        assertEquals("2", peer.seal("next".toByteArray())!!.split(' ')[3])
    }

    @Test fun responsesMayReorderButCannotReplayOrPoisonTheWindow() {
        val peer = client(); val handshake = ready(peer.hello()!!); val session = handshake.split(' ')[3]
        peer.receive(handshake)
        val first = hostFrame(session, 1); val second = hostFrame(session, 2)
        assertSame(SecureControlClient.Result.Rejected, peer.receive("$first extra fields"))
        assertSame(SecureControlClient.Result.Rejected, peer.receive(first.replace(" 1 ", " 9000 ")))
        assertTrue(peer.receive(second) is SecureControlClient.Result.Message)
        assertTrue(peer.receive(first) is SecureControlClient.Result.Message)
        assertSame(SecureControlClient.Result.Rejected, peer.receive(first))
    }

    @Test fun timeoutDisconnectAndRemovedKeyInvalidateTheConnection() {
        var authorized: SecureControlKeys? = keys
        val peer = client { authorized }; val handshake = ready(peer.hello()!!)
        peer.receive(handshake)
        now += 30_000
        assertFalse(peer.ready)
        assertNull(peer.seal("late key".toByteArray()))
        val next = ready(peer.hello()!!); peer.receive(next)
        assertTrue(peer.ready)
        authorized = null
        assertFalse(peer.ready)
        assertNull(peer.seal("revoked".toByteArray()))
        peer.disconnect()
        authorized = keys
        assertFalse(peer.ready)
        assertSame(SecureControlClient.Result.Rejected, peer.receive(next))
    }

    @Test fun expiredChallengeAndOversizedPayloadAreRejected() {
        val peer = client(); val challenge = ready(peer.hello()!!)
        now += 10_000
        assertSame(SecureControlClient.Result.Rejected, peer.receive(challenge))
        peer.receive(ready(peer.hello()!!))
        assertNull(peer.seal(ByteArray(SecureControlClient.MAX_PLAINTEXT + 1)))
        assertSame(SecureControlClient.Result.Rejected, peer.receive("x".repeat(SecureControlClient.MAX_FRAME + 1)))
    }

    @Test fun matchesIndependentSharedCryptographyVectors() {
        val fixture = java.util.Properties().apply {
            SecureControlClientTest::class.java.classLoader!!.getResourceAsStream("control-v1.properties")!!.use { load(it) }
        }
        for (purpose in listOf("handshake", "phone", "mac")) {
            assertEquals(fixture.getProperty(purpose + "KeyHex"), SecureControlKeys.hex(SecureControlKeys.derive(root, purpose)))
        }
        val hello = fixture.getProperty("hello").split(' ')
        assertTrue(keys.verify(hello[6], hello.take(6)))
        val response = fixture.getProperty("ready").split(' ')
        assertTrue(keys.verify(response[6], response.take(6)))
        val peer = client()
        peer.receive(ready(peer.hello()!!, fixture.getProperty("session")))
        val result = peer.receive(fixture.getProperty("macFrame"))
        assertTrue(result is SecureControlClient.Result.Message)
        assertEquals(fixture.getProperty("macPayload"), String((result as SecureControlClient.Result.Message).payload))
    }

    @Test fun negotiatedFieldsCannotBeTamperedAndUnsupportedSelectionIsNotReady() {
        val peer = client(); val offer = peer.hello()!!
        val response = ready(offer)
        assertSame(SecureControlClient.Result.Rejected, peer.receive(response.replace(" 15 ", " 7 ")))
        assertFalse(peer.ready)
        assertSame(SecureControlClient.Result.Incompatible, peer.receive(ready(offer, version = "2")))
        assertTrue(peer.incompatible)
        assertNull(peer.seal("confirm".toByteArray()))
        for ((version, capabilities) in listOf("1" to "1", "1" to "31", "1,2" to "15")) {
            assertSame(SecureControlClient.Result.Incompatible, peer.receive(ready(peer.hello()!!, version = version, capabilities = capabilities)))
            assertFalse(peer.ready)
        }
        assertSame(SecureControlClient.Result.Ready, peer.receive(ready(peer.hello()!!)))
        assertFalse(peer.incompatible)
    }

    @Test fun onlyAuthenticatedCurrentRefusalCanReportIncompatibility() {
        val peer = client(); val offer = peer.hello()!!.split(' ')
        fun refusal(nonce: String = offer[2], crypto: SecureControlKeys = keys): String {
            val fields = listOf(SecureControlClient.INCOMPATIBLE, device, nonce, "version", "2", "15")
            return (fields + SecureControlKeys.hex(crypto.signature(fields))).joinToString(" ")
        }
        assertSame(SecureControlClient.Result.Rejected, peer.receive(refusal(crypto = SecureControlKeys.fromRoot(ByteArray(32) { 0x32 }))))
        assertSame(SecureControlClient.Result.Rejected, peer.receive(refusal(nonce = UUID.randomUUID().toString())))
        assertFalse(peer.incompatible)
        assertSame(SecureControlClient.Result.Incompatible, peer.receive(refusal()))
        assertTrue(peer.incompatible)
        assertEquals(offer.joinToString(" "), peer.hello())
        peer.disconnect()
        assertFalse(peer.incompatible)
        assertSame(SecureControlClient.Result.Rejected, peer.receive(refusal()))
    }

    @Test fun baselineWithoutPhoneAudioKeepsSessionsButRejectsAudioInBothDirections() {
        val peer = client(); val response = ready(peer.hello()!!, capabilities = "7"); peer.receive(response)
        val session = response.split(' ')[3]
        assertTrue(peer.ready)
        assertFalse(peer.supports(ControlProtocol.PHONE_AUDIO))
        assertNotNull(peer.seal("{\"type\":\"vibepier-session1\",\"text\":\"vibepier-mic1\"}".toByteArray()))
        assertNull(peer.seal("vibepier-audio1 $device stream 1 packet".toByteArray()))
        assertNull(peer.seal("{\"type\":\"vibepier-mic1\"}".toByteArray()))
        assertSame(SecureControlClient.Result.Rejected, peer.receive(hostFrame(session, 9000, "{\"type\":\"vibepier-mic-state1\"}")))
        assertTrue(peer.receive(hostFrame(session, 1)) is SecureControlClient.Result.Message)
    }

    @Test fun legacyAndMalformedRepliesNeverDowngradeTheHandshake() {
        val peer = client(); val offer = peer.hello()!!; val nonce = offer.split(' ')[2]
        val old = listOf("vibepier-secure-ready1", device, nonce, UUID.randomUUID().toString())
        assertSame(SecureControlClient.Result.Rejected, peer.receive((old + SecureControlKeys.hex(keys.signature(old))).joinToString(" ")))
        for ((version, capabilities) in listOf("01" to "15", "1,1" to "15", "2,1" to "15", "1" to "015", "1" to "65536", "1" to "-1")) {
            assertSame(SecureControlClient.Result.Rejected, peer.receive(ready(offer, version = version, capabilities = capabilities)))
            assertFalse(peer.ready)
        }
    }
}
