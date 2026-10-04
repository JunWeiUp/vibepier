package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.security.ControlReplayWindow
import io.github.junweiup.vibepier.remote.core.security.SecureControlClient
import io.github.junweiup.vibepier.remote.core.security.SecureControlKeys
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec

/** Single-peer loopback host for emulator tests. Exercises the production phone crypto path. */
internal class SecureTestHost(private val device: String, root: ByteArray, private val profile: () -> Pair<String, Int> = { "1" to 15 }) {
    private val keys = SecureControlKeys.fromRoot(root)
    private var hello: String? = null
    private var helloReply: String? = null
    private var ready: String? = null
    private var session = UUID.randomUUID().toString()
    private var replay = ControlReplayWindow()
    private var sent = 0L

    fun receive(line: String, reply: (String) -> String?): String? {
        if (line.length > SecureControlClient.MAX_FRAME) return null
        val fields = line.split(' ')
        if (fields.size !in listOf(5, 7) || fields[1] != device) return null
        if (fields[0] == SecureControlClient.HELLO) {
            if (fields.size != 7 || fields[4] != "1" || fields[5].toIntOrNull()?.let { it and 7 != 7 } != false) return null
            val timestamp = fields[3].toLongOrNull() ?: return null
            if (kotlin.math.abs(System.currentTimeMillis() / 1000 - timestamp) > 120 ||
                !keys.verify(fields[6], fields.take(6))) return null
            if (line == hello) return helloReply
            val (version, capabilities) = profile()
            if (version != "1" || capabilities and 7 != 7) {
                val response = listOf(SecureControlClient.INCOMPATIBLE, device, fields[2], if (version != "1") "version" else "capabilities", version, capabilities.toString())
                hello = line; ready = null
                return (response + SecureControlKeys.hex(keys.signature(response))).joinToString(" ").also { helloReply = it }
            }
            session = UUID.randomUUID().toString()
            replay = ControlReplayWindow(); sent = 0
            val response = listOf(SecureControlClient.READY, device, fields[2], session, version, capabilities.toString())
            hello = line
            return (response + SecureControlKeys.hex(keys.signature(response))).joinToString(" ").also { ready = it; helloReply = it }
        }
        if (ready == null || fields[0] != SecureControlClient.FRAME || fields[2] != session) return null
        val sequence = fields[3].toLongOrNull()?.takeIf { it > 0 } ?: return null
        val box = Base64.getDecoder().decode(fields[4])
        if (box.size !in 28..SecureControlClient.MAX_PLAINTEXT + 28) return null
        val plaintext = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, keys.phone, GCMParameterSpec(128, box.copyOfRange(0, 12)))
            updateAAD(SecureControlClient.aad("phone", device, session, sequence))
            doFinal(box, 12, box.size - 12)
        }
        if (!replay.accept(sequence)) return null
        val response = reply(plaintext.toString(Charsets.UTF_8)) ?: return null
        val outgoing = ++sent
        val encrypted = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, keys.mac)
            updateAAD(SecureControlClient.aad("mac", device, session, outgoing))
            iv + doFinal(response.toByteArray())
        }
        return "${SecureControlClient.FRAME} $device $session $outgoing ${Base64.getEncoder().encodeToString(encrypted)}"
    }
}
