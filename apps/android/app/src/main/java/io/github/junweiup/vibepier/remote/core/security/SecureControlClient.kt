package io.github.junweiup.vibepier.remote.core.security

import java.nio.charset.StandardCharsets.UTF_8
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

/** Keys may be non-exportable Android Keystore keys. Only enrollment derives raw key material. */
internal class SecureControlKeys(val handshake: SecretKey, val phone: SecretKey, val mac: SecretKey) {
    fun signature(fields: List<String>): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(handshake)
        doFinal(fields.joinToString("|").toByteArray(UTF_8))
    }

    fun verify(hex: String, fields: List<String>): Boolean {
        if (!hex.matches(Regex("[a-fA-F0-9]{64}"))) return false
        val given = ByteArray(32) { index -> hex.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
        return MessageDigest.isEqual(given, signature(fields))
    }

    companion object {
        /** HKDF-SHA256, empty salt, one 32-byte output block (RFC 5869). */
        fun derive(root: ByteArray, purpose: String): ByteArray {
            require(root.size == 32 && purpose in setOf("handshake", "phone", "mac"))
            val extract = Mac.getInstance("HmacSHA256").run {
                init(SecretKeySpec(ByteArray(32), "HmacSHA256"))
                doFinal(root)
            }
            return Mac.getInstance("HmacSHA256").run {
                init(SecretKeySpec(extract, "HmacSHA256"))
                doFinal("vibepier-control-v1/$purpose".toByteArray(UTF_8) + byteArrayOf(1))
            }
        }

        // Used at enrollment and by JVM interoperability tests. Production reads Keystore keys.
        fun fromRoot(root: ByteArray) = SecureControlKeys(
            SecretKeySpec(derive(root, "handshake"), "HmacSHA256"),
            SecretKeySpec(derive(root, "phone"), "AES"),
            SecretKeySpec(derive(root, "mac"), "AES"),
        )

        fun hex(bytes: ByteArray) = buildString(bytes.size * 2) {
            val digits = "0123456789abcdef"
            bytes.forEach { val value = it.toInt() and 255; append(digits[value ushr 4]); append(digits[value and 15]) }
        }
    }
}

internal class ControlReplayWindow {
    private var highest = 0L
    private val received = HashSet<Long>()

    fun wouldAccept(sequence: Long) = sequence > 0 && sequence > highest - 1024 && sequence !in received
    fun accept(sequence: Long): Boolean {
        if (!wouldAccept(sequence)) return false
        highest = maxOf(highest, sequence)
        received.removeAll { it <= highest - 1024 }
        received.add(sequence)
        return true
    }
}

/** Signed handshake fields; the baseline requires controls, configuration and session RPC. */
internal object ControlProtocol {
    const val VERSION = 1
    const val REQUIRED = 7
    const val PHONE_AUDIO = 8
    // Capability 0x10 is retired and must not be reused.
    const val ALL = REQUIRED or PHONE_AUDIO
    fun versions(field: String): List<Int>? {
        val parts = field.split(',')
        if (parts.size !in 1..8) return null
        val values = parts.map { it.toIntOrNull() ?: return null }
        return values.takeIf { it.all { v -> v in 1..255 } && it.joinToString(",") == field && it == it.distinct().sorted() }
    }
    fun capabilities(field: String): Int? = field.toIntOrNull()?.takeIf { it in 0..65535 && it.toString() == field }
    fun permits(payload: ByteArray, capabilities: Int): Boolean {
        if (capabilities and REQUIRED != REQUIRED) return false
        val text = String(payload, UTF_8)
        val audio = text.startsWith("vibepier-audio1 ") || try {
            JSONObject(text).optString("type") in listOf("vibepier-mic1", "vibepier-mic-state1")
        } catch (_: Exception) { false }
        return !audio || capabilities and PHONE_AUDIO != 0
    }
}

/** One client per connection. Never buffers control actions while negotiating or disconnected. */
internal class SecureControlClient(
    private val device: String,
    private val keys: () -> SecureControlKeys?,
    private val wallSeconds: () -> Long = { System.currentTimeMillis() / 1000 },
    private val monotonicMs: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    sealed class Result {
        object Ready : Result()
        object Incompatible : Result()
        class Message(val payload: ByteArray) : Result()
        object Rejected : Result()
    }

    private var session: String? = null
    private var nonce: String? = null
    private var pendingHello: String? = null
    private var pendingAt = 0L
    private var verifiedAt = 0L
    private var sent = 0L
    private var replay = ControlReplayWindow()
    private var capabilities = 0
    @Volatile var incompatible = false; private set

    init { require(validID(device)) }

    val ready: Boolean @Synchronized get() = session != null && keys() != null && monotonicMs() - verifiedAt in 0..29_999
    @Synchronized fun supports(capability: Int) = ready && capabilities and capability == capability

    /** Retries reuse the same authenticated nonce, so packet loss cannot reset an active replay window. */
    @Synchronized fun hello(): String? {
        val key = keys() ?: return null
        val now = monotonicMs()
        pendingHello?.takeIf { now - pendingAt in 0..9_999 }?.let { return it }
        session = null
        capabilities = 0
        nonce = UUID.randomUUID().toString()
        val fields = listOf(HELLO, device, nonce!!, wallSeconds().toString(), ControlProtocol.VERSION.toString(), ControlProtocol.ALL.toString())
        pendingAt = now
        return (fields + SecureControlKeys.hex(key.signature(fields))).joinToString(" ").also { pendingHello = it }
    }

    @Synchronized fun receive(line: String): Result {
        if (line.length > MAX_FRAME) return Result.Rejected
        val key = keys() ?: return Result.Rejected
        val fields = line.split(' ')
        if (fields.size !in listOf(5, 7) || fields[1] != device) return Result.Rejected
        if (fields[0] in listOf(READY, INCOMPATIBLE)) {
            if (fields.size != 7 || pendingHello == null || fields[2] != nonce || monotonicMs() - pendingAt !in 0..9_999 ||
                !key.verify(fields[6], fields.take(6))) return Result.Rejected
            val versions = ControlProtocol.versions(fields[4]) ?: return Result.Rejected
            val selected = ControlProtocol.capabilities(fields[5]) ?: return Result.Rejected
            if (fields[0] == INCOMPATIBLE) {
                if (fields[3] !in listOf("version", "capabilities")) return Result.Rejected
                return rejectCompatibility()
            }
            if (!validID(fields[3])) return Result.Rejected
            if (versions != listOf(ControlProtocol.VERSION) || selected and ControlProtocol.ALL != selected ||
                selected and ControlProtocol.REQUIRED != ControlProtocol.REQUIRED) return rejectCompatibility()
            session = fields[3]
            capabilities = selected
            incompatible = false
            pendingHello = null
            nonce = null
            sent = 0
            replay = ControlReplayWindow()
            verifiedAt = monotonicMs()
            return Result.Ready
        }
        if (fields.size != 5 || fields[0] != FRAME || !ready || fields[2] != session) return Result.Rejected
        val sequence = fields[3].toLongOrNull()?.takeIf { it > 0 } ?: return Result.Rejected
        if (!replay.wouldAccept(sequence)) return Result.Rejected
        val plaintext = try {
            val box = Base64.getDecoder().decode(fields[4])
            if (box.size !in 28..MAX_PLAINTEXT + 28) return Result.Rejected
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, key.mac, GCMParameterSpec(128, box.copyOfRange(0, 12)))
                updateAAD(aad("mac", device, fields[2], sequence))
                doFinal(box, 12, box.size - 12)
            }
        } catch (_: Exception) { return Result.Rejected }
        if (!ControlProtocol.permits(plaintext, capabilities) || !replay.accept(sequence)) return Result.Rejected
        verifiedAt = monotonicMs()
        return Result.Message(plaintext)
    }

    @Synchronized fun seal(plaintext: ByteArray): String? {
        if (!ready || plaintext.size > MAX_PLAINTEXT || sent == Long.MAX_VALUE || !ControlProtocol.permits(plaintext, capabilities)) return null
        val current = session ?: return null
        val key = keys() ?: return null
        val sequence = sent + 1
        val box = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.ENCRYPT_MODE, key.phone)
                updateAAD(aad("phone", device, current, sequence))
                iv + doFinal(plaintext)
            }
        } catch (_: Exception) { return null }
        sent = sequence
        return "$FRAME $device $current $sequence ${Base64.getEncoder().encodeToString(box)}"
    }

    @Synchronized fun disconnect() {
        session = null
        nonce = null
        pendingHello = null
        sent = 0
        replay = ControlReplayWindow()
        capabilities = 0
        incompatible = false
    }

    private fun rejectCompatibility(): Result {
        // Keep the pending nonce until its normal deadline: retrying a refusal must not churn server replay receipts.
        session = null
        capabilities = 0
        sent = 0
        replay = ControlReplayWindow()
        incompatible = true
        return Result.Incompatible
    }

    companion object {
        const val HELLO = "vibepier-secure-hello2"
        const val READY = "vibepier-secure-ready2"
        const val INCOMPATIBLE = "vibepier-secure-incompatible2"
        const val FRAME = "vibepier-secure1"
        const val MAX_PLAINTEXT = 8192
        const val MAX_FRAME = 16_384
        fun aad(direction: String, device: String, session: String, sequence: Long) =
            "vibepier-control-v1|$direction|$device|$session|$sequence".toByteArray(UTF_8)
        private fun validID(value: String) = try { UUID.fromString(value).toString().equals(value, true) } catch (_: Exception) { false }
    }
}
