package io.github.junweiup.vibepier.remote.core.transport

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.security.StrictUtf8
import android.content.Context
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.SecureControlClient
import android.util.Base64
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.net.InetAddress
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.SSLParameters

/**
 * Carries the remote's text lines through the vibepier cloud relay (docs/relay-protocol.md).
 * A minimal RFC 6455 client so the app keeps zero third-party dependencies: the phone
 * joins `room` as `client`, the Mac as `host`, and every other text frame is forwarded.
 * Only control lines travel here; phone-microphone audio stays on Wi-Fi/Bluetooth.
 */
class RelayLink(
    context: Context,
    private val received: (String) -> Unit,
    private val changed: () -> Unit,
) {
    data class Settings(val url: String, val room: String, val secret: String, val dnsRecovery: Boolean = false) {
        val valid: Boolean get() = try {
            val uri = URI(url)
            uri.scheme in listOf("ws", "wss") && !uri.host.isNullOrBlank() && uri.rawUserInfo == null && uri.fragment == null &&
                (!dnsRecovery || uri.scheme == "wss") && ROOM.matches(room) && secret.length in 32..256 && secret.none(Char::isWhitespace)
        } catch (_: Exception) { false }
        val pairingCode: String get() = "vibepierrelay1 $url $room $secret" + if (dnsRecovery) " dns=alidns" else ""
    }

    companion object {
        private val ROOM = Regex("[A-Za-z0-9_-]{1,64}")
        private const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        private const val MAX_FRAME = 1 shl 20
        private val random = SecureRandom()

        /** `vibepierrelay1 <url> <room> <secret>`, copied from VibePier's relay window. */
        fun parsePairing(code: String): Settings? {
            val parts = code.trim().split(Regex("\\s+"))
            if (parts.size !in 4..5 || parts[0] != "vibepierrelay1" || (parts.size == 5 && parts[4] != "dns=alidns")) return null
            return Settings(parts[1], parts[2], parts[3], dnsRecovery = parts.size == 5).takeIf { it.valid }
        }

        fun hello(role: String, room: String, secret: String, timestamp: Long, nonce: String): String {
            val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(secret.toByteArray(), "HmacSHA256")) }
            val digest = mac.doFinal("vibepier-relay1|$role|$room|$timestamp|$nonce".toByteArray())
            return "vibepier-relay1 hello $role $room $timestamp $nonce ${hex(digest)}"
        }

        fun acceptKey(key: String): String = java.util.Base64.getEncoder().encodeToString(
            MessageDigest.getInstance("SHA-1").digest((key + GUID).toByteArray()))

        internal fun verifyUpgrade(headers: List<String>, key: String) {
            val status = headers.firstOrNull()?.split(' ', limit = 3).orEmpty()
            check(status.getOrNull(0) == "HTTP/1.1" && status.getOrNull(1) == "101") { "upgrade refused" }
            val fields = headers.drop(1).map { line ->
                val colon = line.indexOf(':')
                check(colon > 0 && !line.first().isWhitespace()) { "invalid response header" }
                line.substring(0, colon).lowercase() to line.substring(colon + 1).trim()
            }.groupBy({ it.first }, { it.second })
            check(fields["sec-websocket-accept"] == listOf(acceptKey(key))) { "bad accept key" }
            check(fields["upgrade"]?.map { it.lowercase() } == listOf("websocket") &&
                fields["connection"].orEmpty().flatMap { it.split(',') }.any { it.trim().equals("upgrade", true) }) { "invalid upgrade headers" }
            check("sec-websocket-extensions" !in fields && "sec-websocket-protocol" !in fields) { "unrequested websocket extension or protocol" }
        }

        fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

        fun randomBytes(count: Int) = ByteArray(count).also(random::nextBytes)

        fun tlsParameters(host: String, parameters: SSLParameters = SSLParameters()) = parameters.apply {
            serverNames = listOf(SNIHostName(host))
            endpointIdentificationAlgorithm = "HTTPS"
        }

        /** A client frame: FIN set and always masked. */
        fun encodeFrame(opcode: Int, payload: ByteArray, mask: ByteArray = randomBytes(4)): ByteArray {
            val out = ByteArrayOutputStream(payload.size + 14)
            out.write(0x80 or opcode)
            when {
                payload.size < 126 -> out.write(0x80 or payload.size)
                payload.size <= 0xFFFF -> { out.write(0x80 or 126); out.write(payload.size shr 8); out.write(payload.size and 0xFF) }
                else -> { out.write(0x80 or 127); for (shift in 56 downTo 0 step 8) out.write(((payload.size.toLong() shr shift) and 0xFF).toInt()) }
            }
            out.write(mask)
            out.write(ByteArray(payload.size) { (payload[it].toInt() xor mask[it and 3].toInt()).toByte() })
            return out.toByteArray()
        }

        /** Reads an RFC 6455 frame. Production expects unmasked server frames; tests also decode client frames. */
        fun readFrame(input: InputStream, masked: Boolean = false): Triple<Int, Boolean, ByteArray> {
            val b0 = input.read(); val b1 = input.read()
            if (b0 < 0 || b1 < 0) throw EOFException()
            val opcode = b0 and 0x0F; val fin = b0 and 0x80 != 0
            check(b0 and 0x70 == 0 && opcode in listOf(0, 1, 8, 9, 10)) { "unsupported websocket frame" }
            check((b1 and 0x80 != 0) == masked) { "incorrect frame masking" }
            val encodedLength = b1 and 0x7F
            var length = (b1 and 0x7F).toLong()
            if (length == 126L) length = ((readByte(input) shl 8) or readByte(input)).toLong()
            else if (length == 127L) { length = 0; repeat(8) { length = (length shl 8) or readByte(input).toLong() } }
            check(length in 0..MAX_FRAME.toLong()) { "invalid frame length" }
            check((encodedLength != 126 || length >= 126) && (encodedLength != 127 || length >= 65536)) { "nonminimal frame length" }
            check(opcode < 8 || (fin && length <= 125 && (opcode != 8 || length != 1L))) { "invalid control frame" }
            val mask = if (masked) readFully(input, 4) else null
            val payload = readFully(input, length.toInt())
            if (mask != null) for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i and 3].toInt()).toByte()
            return Triple(opcode, fin, payload)
        }

        private fun readByte(input: InputStream): Int = input.read().also { if (it < 0) throw EOFException() }
        private fun readFully(input: InputStream, count: Int): ByteArray {
            val bytes = ByteArray(count); var offset = 0
            while (offset < count) {
                val n = input.read(bytes, offset, count - offset)
                if (n < 0) throw EOFException()
                offset += n
            }
            return bytes
        }
    }

    /** One bounded text message; pings/pongs never enter or reset this fragment state. */
    internal class MessageBuffer {
        private val bytes = ByteArrayOutputStream()
        private var fragmented = false
        fun append(opcode: Int, fin: Boolean, payload: ByteArray): String? {
            check((opcode == 0 && fragmented) || (opcode == 1 && !fragmented)) { "invalid continuation" }
            check(payload.size <= MAX_FRAME - bytes.size()) { "message too large" }
            bytes.write(payload)
            if (!fin) { fragmented = true; return null }
            val text = StrictUtf8.decode(bytes.toByteArray())
            bytes.reset(); fragmented = false
            return text
        }
    }

    private val resources = context.resources
    private val deviceKeys = DeviceKeys(context)
    private val security = SecureControlClient(deviceKeys.device, deviceKeys::controlKeys)
    fun authorizationChanged() { security.disconnect() }

    @Volatile var status: String = resources.getString(R.string.relay_unconfigured); private set
    /** True while the Mac is joined to the same room. */
    @Volatile var peerOnline = false; private set
    private val lock = Object()
    private var settings: Settings? = null
    private var running = false
    private var generation = 0
    private var socket: Socket? = null
    private var connecting: RelayConnectionAttempt? = null
    private var dnsLookup: RelayDnsFallback.Attempt? = null
    private val dnsFallback = RelayDnsFallback()
    private var output: OutputStream? = null
    private var worker: Thread? = null
    private var networkEpoch = 0L
    private val networkMonitor = RelayNetworkMonitor(context)

    fun start(value: Settings?) {
        synchronized(lock) {
            networkEpoch++
            networkMonitor.stop()
            stopLocked()
            settings = value?.takeIf { it.valid }
            if (settings == null) { update(resources.getString(R.string.relay_unconfigured), false); return }
            running = true
            startLoopLocked()
            val epoch = networkEpoch
            networkMonitor.start { networkChanged(epoch) }
        }
    }

    fun stop() = synchronized(lock) {
        networkEpoch++
        networkMonitor.stop()
        stopLocked(); update(resources.getString(R.string.relay_closed), false)
    }

    private fun startLoopLocked() {
        val current = ++generation
        worker = Thread({ loop(current) }, "vibepier-relay").apply { isDaemon = true; start() }
    }

    private fun networkChanged(epoch: Long) = synchronized(lock) {
        if (!running || epoch != networkEpoch) return@synchronized
        reconnectLocked()
    }

    fun reconnect() = synchronized(lock) {
        if (running) reconnectLocked()
    }

    private fun reconnectLocked() {
        // Cancel DNS, TCP/TLS, an old socket read and any retry sleep immediately.
        // The monitor belongs to this relay-mode lifecycle, not the replaced socket generation.
        stopLocked()
        running = true
        update(resources.getString(R.string.relay_connecting), false)
        startLoopLocked()
    }

    private fun stopLocked() {
        // Cancel before changing generation: a DNS cache commit is either still active or rejected.
        dnsLookup?.cancel(); dnsLookup = null
        running = false
        security.disconnect()
        generation++
        worker?.interrupt(); worker = null
        writer.clear()
        connecting?.cancel(); connecting = null
        try { socket?.close() } catch (_: Exception) {}
        socket = null; output = null
    }

    /** Writes happen off the caller's thread (often the UI thread) but in call order. */
    private val writer = RelayWriteQueue()

    /** Sends one text line; dropped silently while disconnected (callers retry on their own cadence). */
    fun send(line: String) {
        val (current, target) = synchronized(lock) { output?.takeIf { running }?.let { generation to it } } ?: return
        val wire = if (security.ready) security.seal(line.toByteArray(Charsets.UTF_8)) else security.hello()
        if (wire == null) return
        val frame = encodeFrame(0x1, wire.toByteArray(Charsets.UTF_8))
        if (!writer.submit {
            if (!synchronized(lock) { running && current == generation && output === target }) return@submit
            // Closing the link must remain able to cancel a stalled socket write.
            try { synchronized(target) { target.write(frame); target.flush() } }
            catch (e: Exception) { abortWrite(current, target, TransportLog.Event.RELAY_SEND, e) }
        }) abortWrite(current, target, TransportLog.Event.RELAY_QUEUE)
    }

    private fun abortWrite(current: Int, target: OutputStream, event: TransportLog.Event, error: Exception? = null) {
        val changedNow = synchronized(lock) {
            if (!running || current != generation || output !== target) return
            output = null
            security.disconnect()
            writer.clear()
            val value = resources.getQuantityString(R.plurals.relay_retry, 1, 1)
            val dirty = status != value || peerOnline
            status = value; peerOnline = false
            try { socket?.close() } catch (_: Exception) {}
            dirty
        }
        TransportLog.warning(event, error)
        if (changedNow) changed()
    }

    private fun alive(current: Int) = synchronized(lock) { running && current == generation }

    private fun update(value: String, peer: Boolean, current: Int? = null) {
        val changedNow = synchronized(lock) {
            if (current != null && (!running || current != generation)) return
            val changedNow = value != status || peer != peerOnline
            status = value
            if (!peer) security.disconnect()
            peerOnline = peer
            changedNow
        }
        if (changedNow) changed()
    }

    private fun loop(current: Int) {
        var delay = 1000L
        while (alive(current)) {
            var wait = delay
            try {
                session(current) { delay = 1000 }
            } catch (e: AuthRejected) {
                update(resources.getString(R.string.relay_rejected, e.message), false, current)
                wait = 60_000
            } catch (e: Exception) {
                update(resources.getQuantityString(R.plurals.relay_retry, (delay / 1000).toInt(), delay / 1000), false, current)
                if (alive(current)) TransportLog.warning(TransportLog.Event.RELAY_CONNECTION, e)
            }
            synchronized(lock) {
                if (current == generation) {
                    connecting?.cancel(); connecting = null
                    try { socket?.close() } catch (_: Exception) {}
                    socket = null; output = null
                }
            }
            if (!alive(current)) return
            try { Thread.sleep(wait) } catch (_: InterruptedException) { return }
            delay = (delay * 2).coerceAtMost(30_000)
        }
    }

    private class AuthRejected(message: String) : Exception(message)

    private fun session(current: Int, joined: () -> Unit) {
        val config = synchronized(lock) { settings.takeIf { running && current == generation } } ?: return
        val uri = URI(config.url)
        val secure = uri.scheme == "wss"
        val port = if (uri.port > 0) uri.port else if (secure) 443 else 80
        update(resources.getString(R.string.relay_connecting), false, current)
        // DNS recovery covers TCP/TLS only; upgrade/protocol/auth errors below never trigger it.
        val sock = if (!secure || !config.dnsRecovery || !RelayDnsFallback.eligible(uri.host)) connect(uri, secure, port, current)
        else dnsFallback.connectWithRecovery(uri.host,
            systemConnect = { connect(uri, secure, port, current) },
            addressConnect = { addresses ->
                TransportLog.info(TransportLog.Event.DNS_RECOVERY)
                connect(uri, secure, port, current, resolve = { addresses })
            },
            freshLookup = { resolveFallback(uri.host, current) },
            guard = { action -> synchronized(lock) {
                if (!running || current != generation) throw java.net.SocketException("connection cancelled")
                action()
            } },
        )
        val out = sock.getOutputStream()
        val input = BufferedInputStream(sock.getInputStream())
        val key = Base64.encodeToString(randomBytes(16), Base64.NO_WRAP)
        val path = (uri.rawPath ?: "").ifEmpty { "/" } + (uri.rawQuery?.let { "?$it" } ?: "")
        val hostHeader = if (uri.port > 0) "${uri.host}:${uri.port}" else uri.host
        out.write(("GET $path HTTP/1.1\r\nHost: $hostHeader\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n").toByteArray())
        out.flush()
        val headers = readHeaders(input)
        verifyUpgrade(headers, key)
        val nonce = hex(randomBytes(16))
        out.write(encodeFrame(0x1, hello("client", config.room, config.secret, System.currentTimeMillis() / 1000, nonce).toByteArray()))
        out.flush()
        sock.soTimeout = 75_000 // The server pings every 25 seconds.
        synchronized(lock) { if (current == generation) output = out }

        val message = MessageBuffer()
        while (alive(current)) {
            val (opcode, fin, payload) = readFrame(input)
            if (!alive(current)) return
            when (opcode) {
                0x8 -> throw EOFException("closed by relay")
                0x9 -> synchronized(out) { out.write(encodeFrame(0xA, payload)); out.flush() }
                0xA -> {}
                0x0, 0x1 -> message.append(opcode, fin, payload)?.let { handle(it, joined, current) }
            }
        }
    }

    private fun resolveFallback(host: String, current: Int): Array<InetAddress> {
        val lookup = RelayDnsFallback.Attempt()
        synchronized(lock) {
            if (!running || current != generation) { lookup.cancel(); throw java.net.SocketException("connection cancelled") }
            dnsLookup = lookup
        }
        update(resources.getString(R.string.relay_fallback_dns), false, current)
        return try { dnsFallback.resolve(host, lookup) } finally {
            synchronized(lock) { if (dnsLookup === lookup) dnsLookup = null }
            lookup.cancel()
        }
    }

    private fun connect(uri: URI, secure: Boolean, port: Int, current: Int,
                        resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName): Socket {
        val attempt = RelayConnectionAttempt(uri.host, port, resolve = resolve, finish = { raw, remaining ->
            if (!secure) raw else {
                val ssl = (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(raw, uri.host, port, true) as SSLSocket
                try {
                    ssl.soTimeout = remaining
                    ssl.sslParameters = tlsParameters(uri.host, ssl.sslParameters)
                    ssl.startHandshake(); ssl
                } catch (error: Exception) { try { ssl.close() } catch (_: Exception) {}; throw error }
            }
        })
        synchronized(lock) {
            if (!running || current != generation) { attempt.cancel(); throw java.net.SocketException("connection cancelled") }
            connecting = attempt
        }
        val sock = try { attempt.connect() } catch (error: Exception) {
            synchronized(lock) { if (connecting === attempt) connecting = null }
            throw error
        }
        synchronized(lock) {
            if (!running || current != generation) { attempt.cancel(); throw java.net.SocketException("connection cancelled") }
            socket = sock; connecting = null; attempt.release(sock)
        }
        return sock
    }

    private fun handle(line: String, joined: () -> Unit, current: Int) {
        if (!alive(current)) return
        if (!line.startsWith("vibepier-relay1 ")) {
            when (val result = security.receive(line)) {
                SecureControlClient.Result.Ready -> send("vibepier-watch1 ${deviceKeys.device}")
                SecureControlClient.Result.Incompatible -> update(resources.getString(R.string.transport_incompatible), true, current)
                is SecureControlClient.Result.Message -> received(String(result.payload, Charsets.UTF_8))
                SecureControlClient.Result.Rejected -> Unit
            }
            return
        }
        val parts = line.split(' ')
        when (parts.getOrNull(1)) {
            "ok" -> { joined(); update(resources.getString(R.string.relay_waiting_mac), false, current) }
            "peer" -> if (parts.getOrNull(2) == "up") update(resources.getString(R.string.relay_connected), true, current) else update(resources.getString(R.string.relay_mac_offline), false, current)
            "error" -> {
                val reason = parts.getOrNull(2) ?: "unknown"
                val text = mapOf("auth" to resources.getString(R.string.relay_wrong_secret), "clock" to resources.getString(R.string.relay_wrong_clock), "replay" to resources.getString(R.string.relay_replay), "bad-room" to resources.getString(R.string.relay_invalid_room))[reason] ?: reason
                if (reason == "auth") throw AuthRejected(text)
                throw IllegalStateException(text)
            }
        }
    }

    private fun readHeaders(input: InputStream): List<String> {
        val lines = mutableListOf<String>()
        val line = StringBuilder()
        var total = 0
        while (true) {
            val b = input.read()
            if (b < 0) throw EOFException()
            if (++total > 16384) throw IllegalStateException("headers too large")
            if (b == '\n'.code) {
                val text = line.toString().trimEnd('\r')
                if (text.isEmpty()) return lines.ifEmpty { throw IllegalStateException("empty response") }
                lines += text; line.clear()
            } else line.append(b.toChar())
        }
    }
}
