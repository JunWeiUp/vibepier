package io.github.junweiup.vibepier.remote.core.files

import android.annotation.SuppressLint
import org.json.JSONObject
import java.io.DataOutputStream
import java.io.File
import java.net.URL
import java.net.Proxy
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/** One file capability, one cancellable socket, bounded buffers. Never changes global TLS policy. */
internal class BinaryFileClient(private val current: () -> Boolean) {
    private val active = AtomicReference<HttpsURLConnection?>()
    @Volatile private var cancelled = false
    fun cancel() { cancelled = true; active.getAndSet(null)?.disconnect() }
    private fun checkCurrent() { check(!cancelled && current()) { "File transfer cancelled" } }
    private data class Route(val url: URL, val factory: SSLSocketFactory?, val pin: ByteArray?)
    private fun token(value: String): String {
        require(value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' })
        return value
    }
    private fun validate(profile: JSONObject, kind: String, size: Long, offset: Long) {
        require(profile.getInt("version") == 1 && profile.getString("encoding") == "raw" && profile.getString("kind") == kind &&
            profile.getLong("size") == size && profile.getLong("offset") == offset && size in 1..512L * 1024 * 1024)
        token(profile.getString("id")); token(profile.getString("readToken")); token(profile.getString("writeToken"))
    }
    private fun pin(profile: JSONObject): ByteArray = token(profile.getString("pin")).chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun matches(pin: ByteArray, chain: Array<X509Certificate>) = chain.isNotEmpty() &&
        MessageDigest.isEqual(pin, MessageDigest.getInstance("SHA-256").digest(chain[0].encoded))
    @SuppressLint("CustomX509TrustManager") // Exact certificate pin is authenticated by the existing encrypted offer; no global trust changes.
    private fun route(profile: JSONObject, host: String?): Route {
        val expected = pin(profile)
        val context = SSLContext.getInstance("TLSv1.3")
        context.init(null, arrayOf<TrustManager>(object : X509TrustManager {
            override fun getAcceptedIssuers() = emptyArray<X509Certificate>()
            override fun checkClientTrusted(chain: Array<X509Certificate>, type: String) = error("Client certificate not used")
            override fun checkServerTrusted(chain: Array<X509Certificate>, type: String) {
                require(matches(expected, chain)); chain[0].checkValidity()
            }
        }), null)
        val port = profile.getInt("port"); require(port in 1..65535)
        if (!host.isNullOrBlank()) {
            // Host comes from the already authenticated transport, certificate pin from the encrypted offer.
            require(host.all { it.isDigit() || it in ".:" || it.lowercaseChar() in 'a'..'f' })
            val address = if (host.contains(':')) "[$host]" else host
            val direct = Route(URL("https://$address:$port/files/${profile.getString("id")}"), context.socketFactory, expected)
            if (runCatching { probe(direct, profile) }.getOrDefault(false)) return direct
        }
        val cloud = URL(profile.getString("relayURL"))
        require(cloud.protocol == "https" && cloud.userInfo == null && cloud.query == null && cloud.ref == null &&
            cloud.path.endsWith("/files/${profile.getString("id")}"))
        val relay = Route(cloud, null, null)
        // Registration is dispatched concurrently with the encrypted offer. Retry only HEAD,
        // before a body or resumable offset is consumed.
        repeat(24) {
            checkCurrent()
            if (probe(relay, profile)) return relay
            Thread.sleep(150)
        }
        error("File channel unavailable")
    }
    private fun connection(route: Route, profile: JSONObject, method: String): HttpsURLConnection {
        checkCurrent()
        val connection = (if (route.pin != null) route.url.openConnection(Proxy.NO_PROXY) else route.url.openConnection()) as HttpsURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = if (route.pin != null) 1500 else 8000
        connection.readTimeout = 20000
        connection.requestMethod = method
        connection.useCaches = false
        connection.setRequestProperty("Authorization", "Bearer " + profile.getString(if (method == "PUT") "writeToken" else "readToken"))
        if (route.factory != null) {
            connection.sslSocketFactory = route.factory
            connection.hostnameVerifier = javax.net.ssl.HostnameVerifier { _, session ->
                runCatching { matches(route.pin!!, session.peerCertificates.map { it as X509Certificate }.toTypedArray()) }.getOrDefault(false)
            }
        }
        active.set(connection)
        if (cancelled) { connection.disconnect(); checkCurrent() }
        return connection
    }
    private fun probe(route: Route, profile: JSONObject): Boolean {
        val connection = connection(route, profile, "HEAD")
        try {
            return when (connection.responseCode) {
                204 -> true
                404 -> false
                else -> error("File capability refused")
            }
        } finally { active.compareAndSet(connection, null); connection.disconnect() }
    }
    fun upload(profile: JSONObject, host: String?, file: File, progress: (Long) -> Unit) {
        val size = file.length(); validate(profile, "upload", size, 0); require(size <= 10 * 1024 * 1024)
        val route = route(profile, host)
        val connection = connection(route, profile, "PUT")
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/octet-stream")
        connection.setFixedLengthStreamingMode(size)
        try {
            file.inputStream().use { input -> DataOutputStream(connection.outputStream.buffered(256 * 1024)).use { output ->
                val buffer = ByteArray(65536); var sent = 0L
                while (sent < size) {
                    checkCurrent(); val expected = minOf(buffer.size.toLong(), size - sent).toInt()
                    var count = 0
                    while (count < expected) { val n = input.read(buffer, count, expected - count); check(n > 0); count += n }
                    output.write(buffer, 0, count)
                    sent += count; progress(sent)
                }
                check(input.read() == -1); output.flush()
            } }
            checkCurrent(); check(connection.responseCode == 204) { "File upload refused" }
        } finally { active.compareAndSet(connection, null); connection.disconnect() }
    }
    fun download(profile: JSONObject, host: String?, size: Long, offset: Long, consume: (ByteArray) -> Unit) {
        validate(profile, "apk", size, offset)
        val route = route(profile, host)
        val connection = connection(route, profile, "GET")
        if (route.pin != null) connection.setRequestProperty("Range", "bytes=$offset-")
        try {
            check(connection.responseCode == if (route.pin != null) 206 else 200)
            check(connection.contentLengthLong == size - offset)
            if (route.pin != null) check(connection.getHeaderField("Content-Range") == "bytes $offset-${size - 1}/$size")
            connection.inputStream.use { input ->
                var received = offset
                while (received < size) {
                    checkCurrent()
                    val bytes = ByteArray(minOf(1024 * 1024L, size - received).toInt()); var count = 0
                    while (count < bytes.size) { val n = input.read(bytes, count, bytes.size - count); check(n > 0); count += n; checkCurrent() }
                    consume(bytes); received += count
                }
                check(input.read() == -1)
            }
        } finally { active.compareAndSet(connection, null); connection.disconnect() }
    }
}
