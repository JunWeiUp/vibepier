package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONObject
import io.github.junweiup.vibepier.remote.core.security.StrictUtf8
import java.util.Base64
import java.util.UUID

/** Main-thread confined, bounded assembly. Crypto and Android clocks are supplied by the caller. */
class SessionResponseInbox(
    private val device: String,
    private val clock: () -> Long,
    private val replayLimit: Int = 4096,
) {
    class Ticket internal constructor(val packet: String)
    data class Progress(val ticket: Ticket, val started: Boolean, val message: JSONObject?)
    enum class Missing { GONE, WAIT, RESEND, EXPIRED }
    private data class Assembly(
        val ticket: Ticket, val parts: Int, val created: Long, val request: String?, val fragmentChars: Int,
        val chunks: MutableMap<Int, String> = mutableMapOf(),
        var retries: Int = 0, var lastProgress: Long = created,
    )
    private val incoming = mutableMapOf<String, Assembly>()
    private val delivered = mutableMapOf<String, Long>()
    val receivingContent get() = incoming.values.any {
        clock() - it.created < ASSEMBLY_MS && clock() - it.lastProgress < 4_000
    }
    fun clearPartial() { incoming.clear() }
    fun clearFastPartial() { incoming.entries.removeAll { it.value.request != null } }

    fun receive(frame: JSONObject, decrypt: (String, ByteArray) -> ByteArray, acceptsFastRequest: (String) -> Boolean = { false }): Progress? {
        val request = if (frame.has("request")) (frame.opt("request") as? String)?.takeIf { uuid(it) && acceptsFastRequest(it) } ?: return null else null
        val fragmentChars = if (request == null) 900 else 7200
        val fields = setOf("type", "sender", "device", "packet", "part", "parts", "data") + if (request == null) emptySet() else setOf("request")
        if (frame.toString().replace("\\/", "/").toByteArray(Charsets.UTF_8).size > (if (request == null) 4096 else 8192) ||
            frame.keys().asSequence().toSet() != fields ||
            frame.opt("type") != "vibepier-session1" || frame.opt("device") != device || frame.opt("sender") != device) return null
        val packet = (frame.opt("packet") as? String)?.takeIf(::uuid) ?: return null
        val count = integer(frame.opt("parts"), 1..(if (request == null) 512 else 56)) ?: return null
        val index = integer(frame.opt("part"), 0 until count) ?: return null
        val text = frame.opt("data") as? String ?: return null
        if (text.isEmpty() || text.length > fragmentChars || (index < count - 1 && text.length != fragmentChars) ||
            text.any { it !in 'A'..'Z' && it !in 'a'..'z' && it !in '0'..'9' && it !in "+/=" }) return null
        val now = clock()
        incoming.entries.removeAll { now - it.value.created >= ASSEMBLY_MS }
        delivered.entries.removeAll { now - it.value >= REPLAY_MS }
        if (packet in delivered || delivered.size >= replayLimit) return null
        val started = packet !in incoming
        if (started && incoming.size >= 8) return null
        val assembly = incoming.getOrPut(packet) { Assembly(Ticket(packet), count, now, request, fragmentChars) }
        if (assembly.parts != count || assembly.request != request || assembly.fragmentChars != fragmentChars) return null
        val previous = assembly.chunks[index]
        if (previous != null && previous != text) return null
        if (previous == null) { assembly.chunks[index] = text; assembly.lastProgress = now }
        if (assembly.chunks.size != count) return Progress(assembly.ticket, started, null)
        incoming.remove(packet)
        val base64 = (0 until count).joinToString("") { assembly.chunks.getValue(it) }
        val bytes = Base64.getDecoder().decode(base64)
        check(bytes.size in 28..(PLAINTEXT_LIMIT + 28) && Base64.getEncoder().encodeToString(bytes) == base64)
        val clear = decrypt(packet, bytes)
        check(clear.size <= PLAINTEXT_LIMIT)
        val message = JSONObject(StrictUtf8.decode(clear))
        check(validMessage(message) && (request == null || message.opt("id") == request))
        delivered[packet] = now
        return Progress(assembly.ticket, started, message)
    }

    fun missing(ticket: Ticket, online: Boolean): Missing {
        val assembly = incoming[ticket.packet]?.takeIf { it.ticket === ticket } ?: return Missing.GONE
        val now = clock()
        if (!online || now - assembly.created >= ASSEMBLY_MS) {
            incoming.remove(ticket.packet); return Missing.EXPIRED
        }
        if (now - assembly.lastProgress < 3000) return Missing.WAIT
        if (++assembly.retries > 3) { incoming.remove(ticket.packet); return Missing.EXPIRED }
        return Missing.RESEND
    }

    companion object {
        const val PLAINTEXT_LIMIT = 300_000
        const val ASSEMBLY_MS = 45_000L
        const val REPLAY_MS = 300_000L
        fun uuid(value: String): Boolean = value.length == 36 && runCatching { UUID.fromString(value).toString().equals(value, true) }.getOrDefault(false)
        private fun integer(value: Any?, range: IntRange): Int? {
            if (value !is Number) return null
            val number = value.toDouble()
            return number.takeIf { it.isFinite() && it >= range.first && it <= range.last && it.toInt().toDouble() == it }?.toInt()
        }
        fun confirms(message: JSONObject, request: JSONObject): Boolean {
            if (!validMessage(message) || message.opt("id") != request.opt("id")) return false
            if (message.has("provider") && message.opt("provider") != request.opt("provider")) return false
            if (message.opt("unknown") == true) return true
            if (message.opt("ok") == false) return message.opt("accepted") != true && message.opt("submitted") != true
            fun sameThread() = request.optString("threadId").isNotEmpty() && message.opt("threadId") == request.opt("threadId")
            return when (request.optString("op")) {
                "codexUsageReset" -> request.optString("accountId").isNotEmpty() && request.optString("creditId").isNotEmpty() && message.opt("accountId") == request.opt("accountId") && message.opt("creditId") == request.opt("creditId") && message.optString("outcome") in setOf("reset", "alreadyRedeemed", "nothingToReset", "noCredit") && message.opt("accepted") == (message.optString("outcome") in setOf("reset", "alreadyRedeemed"))
                "new" -> (message.opt("threadId") as? String)?.isNotEmpty() == true && request.optString("cwd").isNotEmpty() && message.opt("cwd") == request.opt("cwd")
                "lockScreen" -> message.opt("locked") == true
                "unlockScreen" -> message.opt("locked") == false
                "approve" -> sameThread() && message.opt("submitted") == true && request.optString("fingerprint").isNotEmpty() && message.opt("fingerprint") == request.opt("fingerprint")
                else -> sameThread() && message.opt("accepted") == true
            }
        }
        fun validMessage(message: JSONObject): Boolean {
            for (flag in listOf("ok", "unknown", "accepted", "submitted", "locked", "configured")) {
                if (message.has(flag) && message.opt(flag) !is Boolean) return false
            }
            if (message.has("id")) {
                val id = message.opt("id") as? String ?: return false
                if (!uuid(id) || message.opt("ok") !is Boolean) return false
                if (message.opt("unknown") == true && message.opt("ok") != false) return false
            } else {
                val event = message.opt("event") as? String ?: return false
                if (event.isEmpty() || event.length > 64) return false
            }
            return true
        }
    }
}
