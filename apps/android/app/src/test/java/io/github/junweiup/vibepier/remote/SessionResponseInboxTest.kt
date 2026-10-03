package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionResponseInbox
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class SessionResponseInboxTest {
    private val device = "00000000-0000-4000-8000-000000000001"
    private val key = SecretKeySpec(ByteArray(32) { 31 }, "AES")
    private fun message(text: String = "fixture") = JSONObject().put("id", UUID.randomUUID().toString()).put("ok", true).put("text", text)
    private fun frames(clear: ByteArray, packet: String = UUID.randomUUID().toString()): List<JSONObject> {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD("vibepier-session-v1|mac|$device|$packet".toByteArray())
        val parts = Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(clear)).chunked(900)
        return parts.mapIndexed { i, text -> JSONObject().put("type", "vibepier-session1").put("sender", device).put("device", device)
            .put("packet", packet).put("part", i).put("parts", parts.size).put("data", text) }
    }
    private fun frames(value: JSONObject) = frames(value.toString().toByteArray())
    private fun decrypt(packet: String, bytes: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD("vibepier-session-v1|mac|$device|$packet".toByteArray())
        return cipher.doFinal(bytes.copyOfRange(12, bytes.size))
    }
    private fun changed(frame: JSONObject, field: String, value: Any) = JSONObject(frame.toString()).put(field, value)

    @Test fun reorderedDuplicatesProduceOneAuthenticatedReply() {
        val inbox = SessionResponseInbox(device, { 0 })
        val original = message("完整消息 C++\n".repeat(500)); val parts = frames(original)
        for (part in parts.drop(1).reversed()) { assertNull(inbox.receive(part, ::decrypt)?.message); assertNull(inbox.receive(part, ::decrypt)?.message) }
        assertEquals(original.toString(), inbox.receive(parts[0], ::decrypt)?.message.toString())
        parts.forEach { assertNull(inbox.receive(it, ::decrypt)) }
    }
    @Test fun conflictingDuplicateDoesNotOverwriteAndExpiryIsAbsolute() {
        var time = 0L; val inbox = SessionResponseInbox(device, { time })
        val parts = frames(message("x".repeat(800))); assertEquals(2, parts.size)
        val ticket = inbox.receive(parts[0], ::decrypt)!!.ticket
        assertNull(inbox.receive(changed(parts[0], "data", "A".repeat(900)), ::decrypt))
        assertNotNull(inbox.receive(parts[1], ::decrypt)?.message)
        assertEquals(SessionResponseInbox.Missing.GONE, inbox.missing(ticket, true))
        val slow = frames(message("x".repeat(800))); val old = inbox.receive(slow[0], ::decrypt)!!.ticket
        time = 44_000; assertNull(inbox.receive(slow[0], ::decrypt)?.message)
        time = 45_000; assertEquals(SessionResponseInbox.Missing.EXPIRED, inbox.missing(old, true))
        val fresh = inbox.receive(slow[0], ::decrypt)!!.ticket
        assertEquals(SessionResponseInbox.Missing.GONE, inbox.missing(old, true))
        assertEquals(SessionResponseInbox.Missing.WAIT, inbox.missing(fresh, true))
    }
    @Test fun retryBudgetAndDisconnectNeverRetainPartialForever() {
        var time = 0L; val inbox = SessionResponseInbox(device, { time })
        val ticket = inbox.receive(frames(message("x".repeat(800)))[0], ::decrypt)!!.ticket
        assertTrue(inbox.receivingContent)
        time = 4000
        repeat(3) { assertEquals(SessionResponseInbox.Missing.RESEND, inbox.missing(ticket, true)); time += 3000 }
        assertEquals(SessionResponseInbox.Missing.EXPIRED, inbox.missing(ticket, true))
        val other = inbox.receive(frames(message("x".repeat(800)))[0], ::decrypt)!!.ticket
        assertEquals(SessionResponseInbox.Missing.EXPIRED, inbox.missing(other, false))
        assertFalse(inbox.receivingContent)
    }
    @Test fun capacityIsBoundedAndRecoveredWithoutEvictingReplayRecords() {
        var time = 0L; val inbox = SessionResponseInbox(device, { time }, replayLimit = 2)
        val packets = (0..8).map { frames(message("x".repeat(800))) }
        packets.take(8).forEach { assertNotNull(inbox.receive(it[0], ::decrypt)) }
        assertNull(inbox.receive(packets[8][0], ::decrypt))
        assertNotNull(inbox.receive(packets[0][1], ::decrypt)?.message)
        assertNotNull(inbox.receive(packets[8][0], ::decrypt))
        assertNotNull(inbox.receive(packets[8][1], ::decrypt)?.message)
        assertNull(inbox.receive(frames(message())[0], ::decrypt))
        inbox.clearPartial(); assertNull(inbox.receive(packets[0][0], ::decrypt))
        time = 300_001; assertNotNull(inbox.receive(frames(message())[0], ::decrypt)?.message)
    }
    @Test fun malformedFrameTypesAndForeignIdentityCannotConsumeSlots() {
        val inbox = SessionResponseInbox(device, { 0 }); val good = frames(message())[0]
        for ((field, value) in listOf("part" to true, "part" to "0", "part" to 0.2, "parts" to 513,
            "sender" to UUID.randomUUID().toString(), "device" to "other", "packet" to "1-1-1-1-1", "extra" to "field",
            "type" to "other", "data" to " ", "data" to "", "data" to "A".repeat(901))) {
            assertNull(field, inbox.receive(changed(good, field, value), ::decrypt))
        }
        assertNotNull(inbox.receive(good, ::decrypt)?.message)
    }
    @Test fun corruptedCipherOversizedPlaintextAndMalformedUtf8NeverBecomeMessages() {
        val inbox = SessionResponseInbox(device, { 0 })
        val corrupted = frames(message())[0]; val raw = Base64.getDecoder().decode(corrupted.getString("data")); raw[raw.lastIndex] = (raw.last().toInt() xor 1).toByte()
        assertThrows(Exception::class.java) { inbox.receive(changed(corrupted, "data", Base64.getEncoder().encodeToString(raw)), ::decrypt) }
        assertThrows(Exception::class.java) { frames(ByteArray(SessionResponseInbox.PLAINTEXT_LIMIT + 1) { 120 }).forEach { inbox.receive(it, ::decrypt) } }
        assertThrows(Exception::class.java) { frames(byteArrayOf(0x7b, 0xc3.toByte(), 0x28, 0x7d)).forEach { inbox.receive(it, ::decrypt) } }
        assertNotNull(inbox.receive(frames(message())[0], ::decrypt)?.message)
    }
    @Test fun replyFlagsAreStrictAndContradictorySuccessIsRejected() {
        val good = message(); assertTrue(SessionResponseInbox.validMessage(good))
        for (flag in listOf("ok", "unknown", "accepted", "submitted", "locked", "configured")) {
            for (value in listOf("true", 1, JSONObject.NULL)) assertFalse(SessionResponseInbox.validMessage(changed(good, flag, value)))
        }
        assertFalse(SessionResponseInbox.validMessage(changed(good, "unknown", true)))
        val missing = JSONObject(good.toString()); missing.remove("ok"); assertFalse(SessionResponseInbox.validMessage(missing))
        assertTrue(SessionResponseInbox.validMessage(JSONObject().put("event", "snapshot")))
    }
    @Test fun mutationReceiptsRequireOriginalThreadProviderAndEffect() {
        val request = JSONObject().put("id", UUID.randomUUID().toString()).put("op", "send").put("threadId", "thread").put("provider", "codex")
        val reply = JSONObject().put("id", request.getString("id")).put("ok", true).put("accepted", true).put("threadId", "thread")
        assertTrue(SessionResponseInbox.confirms(reply, request))
        for ((field, value) in listOf("threadId" to "other", "accepted" to false, "provider" to "claude", "ok" to false)) assertFalse(SessionResponseInbox.confirms(changed(reply, field, value), request))
        assertTrue(SessionResponseInbox.confirms(JSONObject().put("id", request.getString("id")).put("ok", false).put("unknown", true), request))
        request.put("op", "approve").put("fingerprint", "original")
        assertFalse(SessionResponseInbox.confirms(reply, request))
        reply.put("submitted", true).put("fingerprint", "original"); assertTrue(SessionResponseInbox.confirms(reply, request))
        request.put("op", "lockScreen"); assertFalse(SessionResponseInbox.confirms(reply, request))
        reply.put("locked", true); assertTrue(SessionResponseInbox.confirms(reply, request))
        request.put("op", "new").put("cwd", "/fixture"); assertFalse(SessionResponseInbox.confirms(reply, request))
        reply.put("cwd", "/fixture"); assertTrue(SessionResponseInbox.confirms(reply, request))
    }
    @Test fun resetReceiptsRequireAccountCardAndConsistentNativeOutcome() {
        val request = JSONObject().put("id", UUID.randomUUID().toString()).put("provider", "codex").put("op", "codexUsageReset").put("accountId", "account").put("creditId", "card")
        for (outcome in listOf("reset", "alreadyRedeemed", "nothingToReset", "noCredit")) {
            val reply = JSONObject().put("id", request.getString("id")).put("ok", true).put("accountId", "account").put("creditId", "card").put("outcome", outcome).put("accepted", outcome in listOf("reset", "alreadyRedeemed"))
            assertTrue(SessionResponseInbox.confirms(reply, request))
            for ((field, value) in listOf("accountId" to "other", "creditId" to "other", "outcome" to "unknown", "accepted" to !reply.getBoolean("accepted"))) assertFalse(SessionResponseInbox.confirms(changed(reply, field, value), request))
        }
    }
}
