package io.github.junweiup.vibepier.remote.core.files

import android.annotation.SuppressLint
import org.json.JSONObject
import java.io.DataOutputStream
import java.io.File
import java.net.URL
import java.net.Proxy
import java.security.MessageDigest
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/** One file capability, one cancellable socket, bounded buffers. Never changes global TLS policy. */
internal class BinaryFileClient(private val current: () -> Boolean) {
    private val active = java.util.concurrent.ConcurrentHashMap<HttpsURLConnection, Boolean>()
    @Volatile private var cancelled = false
    fun cancel() { cancelled = true; active.keys.forEach { it.disconnect() }; active.clear() }
    private fun checkCurrent() { check(!cancelled && !Thread.currentThread().isInterrupted && current()) { "File transfer cancelled" } }
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
        val addresses = linkedSetOf<String>()
        if (!host.isNullOrBlank()) addresses.add(host)
        profile.optJSONArray("directHosts")?.let { values ->
            for (i in 0 until minOf(values.length(), 4)) addresses.add(values.optString(i))
        }
        val candidates = addresses.take(5).map { address ->
            require(address.isNotBlank() && address.all { it.isDigit() || it in ".:" || it.lowercaseChar() in 'a'..'f' })
            val literal = if (address.contains(':')) "[$address]" else address
            Route(URL("https://$literal:$port/files/${profile.getString("id")}"), context.socketFactory, expected)
        }.toMutableList()
        if (profile.has("relayURL")) {
            val cloud = URL(profile.getString("relayURL"))
            require(cloud.protocol == "https" && cloud.userInfo == null && cloud.query == null && cloud.ref == null &&
                cloud.path.endsWith("/files/${profile.getString("id")}"))
            candidates.add(Route(cloud, null, null))
        }
        check(candidates.isNotEmpty())
        // Race only body-free HEAD probes. One selected route owns the body;
        // a partial body is never automatically replayed on another route.
        val completion = java.util.concurrent.ExecutorCompletionService<Route?>(routes)
        val jobs = candidates.map { candidate -> completion.submit(java.util.concurrent.Callable<Route?> {
            runCatching {
                repeat(if (candidate.pin == null) 24 else 1) {
                    checkCurrent()
                    if (probe(candidate, profile)) return@Callable candidate
                    Thread.sleep(150)
                }
                null
            }.getOrNull()
        }) }
        try {
            val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(8)
            var finished = 0
            while (finished < jobs.size && System.nanoTime() < deadline) {
                checkCurrent()
                val answer = completion.poll(50, java.util.concurrent.TimeUnit.MILLISECONDS) ?: continue
                finished++
                answer.get()?.let { return it }
            }
            error("File channel unavailable")
        } finally {
            jobs.forEach { it.cancel(true) }
            active.keys.forEach { it.disconnect() }; active.clear()
        }
    }

    private fun connection(route: Route, profile: JSONObject, method: String): HttpsURLConnection {
        checkCurrent()
        val connection = (if (route.pin != null) route.url.openConnection(Proxy.NO_PROXY) else route.url.openConnection()) as HttpsURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = if (method == "HEAD") 1500 else 8000
        connection.readTimeout = if (method == "HEAD") 2500 else 20000
        connection.requestMethod = method
        connection.useCaches = false
        connection.setRequestProperty("Accept-Encoding", "identity")
        connection.setRequestProperty("Authorization", "Bearer " + profile.getString(if (method == "PUT") "writeToken" else "readToken"))
        if (route.factory != null) {
            connection.sslSocketFactory = route.factory
            connection.hostnameVerifier = javax.net.ssl.HostnameVerifier { _, session ->
                runCatching { matches(route.pin!!, session.peerCertificates.map { it as X509Certificate }.toTypedArray()) }.getOrDefault(false)
            }
        }
        active[connection] = true
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
        } finally { active.remove(connection); connection.disconnect() }
    }
    companion object { private val routes = java.util.concurrent.Executors.newFixedThreadPool(6) }
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
        } finally { active.remove(connection); connection.disconnect() }
    }
    fun download(profile: JSONObject, host: String?, size: Long, offset: Long, kind: String = "apk", chunkBytes: Int = 1024 * 1024, consume: (ByteArray) -> Unit) {
        validate(profile, kind, size, offset)
        require(kind in setOf("apk", "media") && chunkBytes in 64 * 1024..1024 * 1024)
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
                    val bytes = ByteArray(minOf(chunkBytes.toLong(), size - received).toInt()); var count = 0
                    while (count < bytes.size) { val n = input.read(bytes, count, bytes.size - count); check(n > 0); count += n; checkCurrent() }
                    consume(bytes); received += count
                }
                check(input.read() == -1)
            }
        } finally { active.remove(connection); connection.disconnect() }
    }
}
