package io.github.junweiup.vibepier.remote.core.transport

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLParameters
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/** On-demand DNS recovery for an explicitly opted-in relay after the system-resolved connection fails. */
internal class RelayDnsFallback(
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
    private val lookup: (String, Attempt) -> Answer = ::queryAliDns,
) {
    data class Answer(val addresses: List<InetAddress>, val ttlSeconds: Long)
    data class Record(val name: String, val type: Int, val ttlSeconds: Long, val data: String)
    private data class Cached(val host: String, val answer: Answer, val expiresAt: Long)
    private var cached: Cached? = null
    private val cacheLock = Any()

    /** A read-only snapshot; observing the cache never extends its TTL. */
    fun cachedAddresses(host: String): Array<InetAddress>? {
        if (!eligible(host)) return null
        return synchronized(cacheLock) {
            cached?.takeIf { it.host == canonical(host) && nowMs() < it.expiresAt }?.answer?.addresses?.toTypedArray()
        }
    }

    fun invalidate(host: String) = synchronized(cacheLock) {
        if (cached?.host == canonical(host)) cached = null
    }

    /** TCP/TLS recovery only. WebSocket protocol and relay authentication run after this returns. */
    fun <T> connectWithRecovery(
        host: String,
        systemConnect: () -> T,
        addressConnect: (Array<InetAddress>) -> T,
        freshLookup: () -> Array<InetAddress>,
        guard: (() -> Unit) -> Unit = { it() },
    ): T {
        if (!eligible(host)) return systemConnect()
        fun connectFresh(): T {
            val addresses = freshLookup()
            try { return addressConnect(addresses) } catch (error: Exception) {
                guard { invalidate(host) }
                throw error
            }
        }
        var previous: Array<InetAddress>? = null
        guard { previous = cachedAddresses(host) }
        val known = previous
        if (known != null) {
            try { return addressConnect(known) } catch (_: Exception) {
                // A formerly working source may move before its DNS TTL expires.
                guard { invalidate(host) }
                return connectFresh()
            }
        }
        try { return systemConnect() } catch (_: Exception) {
            guard {} // A stopped generation must not launch a new DNS lookup.
            return connectFresh()
        }
    }

    /** Its sockets remain cancellable during TCP, TLS, headers, and response-body reads. */
    class Attempt(private val timeoutMs: Int = 5_000) {
        private val lock = Any()
        private var cancelled = false
        private var expired = false
        private val sockets = mutableSetOf<Socket>()
        private val deadline = System.nanoTime() + timeoutMs.toLong() * 1_000_000
        private val expiry = deadlines.schedule({
            val owned = synchronized(lock) { expired = true; sockets.toList().also { sockets.clear() } }
            owned.forEach { try { it.close() } catch (_: Exception) {} }
        }, timeoutMs.toLong(), TimeUnit.MILLISECONDS)

        fun check() = synchronized(lock) {
            if (cancelled) throw SocketException("relay DNS lookup cancelled")
            if (expired || System.nanoTime() >= deadline) throw SocketTimeoutException("relay DNS lookup timed out")
        }
        fun remainingMs(): Int {
            check()
            return ((deadline - System.nanoTime()) / 1_000_000).coerceIn(1, timeoutMs.toLong()).toInt()
        }
        fun track(socket: Socket) {
            try { synchronized(lock) { check(); sockets.add(socket) } }
            catch (error: Exception) { try { socket.close() } catch (_: Exception) {}; throw error }
        }
        fun release(socket: Socket) = synchronized(lock) { sockets.remove(socket) }
        internal fun <T> accept(value: () -> T): T = synchronized(lock) { check(); value() }
        fun cancel() {
            val owned = synchronized(lock) { cancelled = true; sockets.toList().also { sockets.clear() } }
            expiry.cancel(false)
            owned.forEach { try { it.close() } catch (_: Exception) {} }
        }
    }

    fun resolve(host: String, attempt: Attempt): Array<InetAddress> {
        require(eligible(host)) { "DNS recovery requires a public DNS hostname" }
        val name = canonical(host)
        attempt.check()
        val hit = cachedAddresses(name)
        if (hit != null) return attempt.accept { hit }
        val answer = lookup(name, attempt)
        if (answer.addresses.isEmpty()) throw UnknownHostException("relay DNS response has no usable address")
        return attempt.accept {
            val ttl = answer.ttlSeconds.coerceIn(0, 300)
            synchronized(cacheLock) {
                cached = if (ttl == 0L) null else Cached(name, answer.copy(addresses = answer.addresses.toList()), nowMs() + ttl * 1_000)
            }
            answer.addresses.toTypedArray()
        }
    }

    companion object {
        private const val DNS_HOST = "dns.alidns.com"
        private const val MAX_BODY = 16 * 1_024
        private val deadlines = Executors.newSingleThreadScheduledExecutor { work ->
            Thread(work, "vibepier-relay-dns-deadline").apply { isDaemon = true }
        }
        private fun canonical(host: String) = host.removeSuffix(".").lowercase(Locale.ROOT)
        fun eligible(host: String): Boolean {
            val name = canonical(host)
            return name.length <= 253 && name.matches(Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+")) &&
                name.any { it in 'a'..'z' } && !name.endsWith(".local")
        }

        /** Default system trust remains in use; the bootstrap IP never becomes the TLS identity. */
        fun tlsParameters(parameters: SSLParameters = SSLParameters()) = parameters.apply {
            serverNames = listOf(SNIHostName(DNS_HOST))
            endpointIdentificationAlgorithm = "HTTPS"
        }

        /** Validate the queried name and literal public IPv4 records without another DNS lookup. */
        fun validateRecords(host: String, status: Int, records: List<Record>): Answer {
            require(eligible(host)) { "DNS recovery requires a public DNS hostname" }
            if (status != 0) throw UnknownHostException("relay DNS response status $status")
            val names = linkedSetOf(canonical(host))
            var ttl = Long.MAX_VALUE
            repeat(8) {
                for (record in records) {
                    if (record.type == 5 && canonical(record.name) in names) {
                        val target = canonical(record.data)
                        if (target.matches(Regex("[a-z0-9_-]+(?:\\.[a-z0-9_-]+)+")) && names.add(target)) {
                            ttl = minOf(ttl, record.ttlSeconds.coerceAtLeast(0))
                        }
                    }
                }
            }
            val addresses = records.mapNotNull { record ->
                if (record.type != 1 || canonical(record.name) !in names) return@mapNotNull null
                val parts = record.data.split('.')
                if (parts.size != 4 || parts.any { part -> part.isEmpty() || part.any { it !in '0'..'9' } || part.length > 3 }) return@mapNotNull null
                val octets = parts.map { it.toIntOrNull()?.takeIf { value -> value in 0..255 } ?: return@mapNotNull null }
                val address = InetAddress.getByAddress(octets.map(Int::toByte).toByteArray())
                if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress || address.isSiteLocalAddress || address.isMulticastAddress || octets[0] == 0 || octets[0] >= 240) return@mapNotNull null
                ttl = minOf(ttl, record.ttlSeconds.coerceAtLeast(0))
                address
            }.distinctBy { it.hostAddress }.take(8)
            if (addresses.isEmpty()) throw UnknownHostException("relay DNS response has no usable address")
            return Answer(addresses, ttl.coerceAtMost(300))
        }

        private fun queryAliDns(host: String, attempt: Attempt): Answer {
            val raw = Socket()
            var ssl: SSLSocket? = null
            try {
                attempt.track(raw)
                val bootstrap = InetAddress.getByAddress(byteArrayOf(223.toByte(), 5, 5, 5))
                raw.connect(InetSocketAddress(bootstrap, 443), attempt.remainingMs())
                val connection = (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(raw, DNS_HOST, 443, true) as SSLSocket
                ssl = connection; attempt.track(connection)
                connection.sslParameters = tlsParameters(connection.sslParameters)
                connection.soTimeout = attempt.remainingMs()
                connection.startHandshake()
                attempt.check()
                val request = "GET /resolve?name=$host&type=A HTTP/1.1\r\nHost: $DNS_HOST\r\nAccept: application/dns-json\r\nConnection: close\r\n\r\n"
                connection.getOutputStream().apply { write(request.toByteArray(Charsets.US_ASCII)); flush() }
                val input = connection.getInputStream()
                var headerBytes = 0
                fun readByte(): Int {
                    connection.soTimeout = attempt.remainingMs()
                    return input.read()
                }
                fun line(): String {
                    val text = StringBuilder()
                    while (true) {
                        val next = readByte()
                        if (next < 0) throw java.io.EOFException("incomplete DNS HTTP response")
                        if (++headerBytes > MAX_BODY) throw java.io.IOException("DNS HTTP headers too large")
                        if (next == 10) return text.toString().trimEnd('\r')
                        text.append(next.toChar())
                    }
                }
                val status = line().split(' ').getOrNull(1)?.toIntOrNull()
                if (status != 200) throw java.io.IOException("DNS HTTP response $status")
                val headers = mutableMapOf<String, String>()
                while (true) {
                    val header = line()
                    if (header.isEmpty()) break
                    val colon = header.indexOf(':')
                    if (colon <= 0) throw java.io.IOException("invalid DNS HTTP header")
                    headers[header.substring(0, colon).lowercase(Locale.ROOT)] = header.substring(colon + 1).trim()
                }
                val output = ByteArrayOutputStream()
                fun copy(count: Int) {
                    if (count < 0 || count > MAX_BODY - output.size()) throw java.io.IOException("DNS HTTP body too large")
                    val buffer = ByteArray(minOf(count, 4_096))
                    var remaining = count
                    while (remaining > 0) {
                        connection.soTimeout = attempt.remainingMs()
                        val size = input.read(buffer, 0, minOf(buffer.size, remaining))
                        if (size < 0) throw java.io.EOFException("incomplete DNS HTTP body")
                        output.write(buffer, 0, size); remaining -= size
                    }
                }
                if (headers["transfer-encoding"]?.lowercase(Locale.ROOT) == "chunked") {
                    while (true) {
                        val size = line().substringBefore(';').toIntOrNull(16) ?: throw java.io.IOException("invalid DNS HTTP chunk")
                        if (size == 0) break
                        copy(size)
                        if (readByte() != 13 || readByte() != 10) throw java.io.IOException("invalid DNS HTTP chunk end")
                    }
                } else {
                    val length = headers["content-length"]
                    if (length != null) copy(length.toIntOrNull() ?: throw java.io.IOException("invalid DNS HTTP length"))
                    else {
                        while (true) {
                            val next = readByte()
                            if (next < 0) break
                            if (output.size() >= MAX_BODY) throw java.io.IOException("DNS HTTP body too large")
                            output.write(next)
                        }
                    }
                }
                attempt.check()
                val json = JSONObject(output.toString("UTF-8"))
                val answers = json.optJSONArray("Answer")
                val records = (0 until minOf(answers?.length() ?: 0, 128)).map { index ->
                    val record = answers!!.getJSONObject(index)
                    Record(record.getString("name"), record.getInt("type"), record.getLong("TTL"), record.getString("data"))
                }
                return validateRecords(host, json.getInt("Status"), records)
            } finally {
                ssl?.let { attempt.release(it); try { it.close() } catch (_: Exception) {} }
                attempt.release(raw); try { raw.close() } catch (_: Exception) {}
            }
        }
    }
}
