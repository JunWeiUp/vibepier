package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.graphics.Bitmap
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.features.sessions.ConversationMedia
import org.json.JSONObject
import java.math.BigInteger
import java.net.InetAddress
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.*
import javax.security.auth.x500.X500Principal

/** Loopback-only pinned HTTPS JPEG: exercises the production decoder/cache, never legacy inline media. */
internal object SessionProbeImageCache {
    fun run(test: Instrumentation, client: SessionClient, main: (() -> Unit) -> Unit,
            latest: () -> JSONObject, reply: (JSONObject) -> Unit) {
        val alias = "session-probe-media-${UUID.randomUUID()}"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        var socket: SSLServerSocket? = null
        var media: ConversationMedia? = null
        val failures = AtomicReference<Throwable?>()
        val bodiesServed = java.util.concurrent.atomic.AtomicInteger()
        val bodyCompletion = AtomicReference<CountDownLatch?>()
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    // Conscrypt signs the TLS transcript digest using NONEwithECDSA. SHA256 is also
                    // needed for the generated certificate; this authorizes only the ephemeral fixture key.
                    .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                    .setCertificateSubject(X500Principal("CN=synthetic-loopback"))
                    .setCertificateSerialNumber(BigInteger.ONE).build())
            }.generateKeyPair()
            val chain = arrayOf(store.getCertificate(alias) as X509Certificate)
            val key = store.getKey(alias, null) as PrivateKey
            // Exercise the same delegated signing primitive before entering an opaque socket handshake.
            val digest = MessageDigest.getInstance("SHA-256").digest("synthetic TLS transcript".toByteArray(Charsets.UTF_8))
            val signature = Signature.getInstance("NONEwithECDSA").run { initSign(key); update(digest); sign() }
            check(Signature.getInstance("NONEwithECDSA").run { initVerify(chain[0].publicKey); update(digest); verify(signature) }) {
                "Ephemeral TLS key cannot sign the precomputed transcript digest"
            }
            chain[0].checkValidity()
            chain[0].verify(chain[0].publicKey)
            val manager = object : X509KeyManager {
                override fun getClientAliases(keyType: String?, issuers: Array<out java.security.Principal>?) = null
                override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out java.security.Principal>?, socket: java.net.Socket?) = null
                override fun getServerAliases(keyType: String?, issuers: Array<out java.security.Principal>?) = if (keyType == "EC") arrayOf(alias) else null
                override fun chooseServerAlias(keyType: String?, issuers: Array<out java.security.Principal>?, socket: java.net.Socket?) = if (keyType == "EC") alias else null
                override fun getCertificateChain(requested: String?) = if (requested == alias) chain else null
                override fun getPrivateKey(requested: String?) = if (requested == alias) key else null
            }
            val tls = SSLContext.getInstance("TLSv1.3").apply { init(arrayOf(manager), null, null) }
            val server = tls.serverSocketFactory.createServerSocket(0, 8, InetAddress.getByName("127.0.0.1")) as SSLServerSocket
            socket = server
            val bitmap = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
            val bytes = java.io.ByteArrayOutputStream().use { output -> check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output)); output.toByteArray() }
            bitmap.recycle()
            fun hash(value: ByteArray) = MessageDigest.getInstance("SHA-256").digest(value).joinToString("") { "%02x".format(it) }
            val token = "ab".repeat(32)
            val profile = JSONObject().put("version", 1).put("kind", "media").put("encoding", "raw").put("mime", "image/jpeg")
                .put("id", token).put("readToken", token).put("writeToken", token).put("pin", hash(chain[0].encoded))
                .put("port", server.localPort).put("size", bytes.size).put("offset", 0).put("sha256", hash(bytes))
            executor.submit {
                try {
                    while (!server.isClosed) (server.accept() as SSLSocket).use { connection ->
                        connection.soTimeout = 5_000
                        val input = connection.inputStream.bufferedReader(Charsets.US_ASCII)
                        val line = input.readLine() ?: return@use
                        val headers = mutableListOf<String>()
                        while (true) { val header = input.readLine() ?: break; if (header.isEmpty()) break; headers.add(header) }
                        check(headers.any { it.equals("Authorization: Bearer $token", true) })
                        check(line.split(' ')[1] == "/files/$token")
                        val head = line.startsWith("HEAD ")
                        check(head || line.startsWith("GET ") && headers.any { it.equals("Range: bytes=0-", true) })
                        val response = if (head) "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                            else "HTTP/1.1 206 Partial Content\r\nContent-Length: ${bytes.size}\r\nContent-Range: bytes 0-${bytes.size - 1}/${bytes.size}\r\nConnection: close\r\n\r\n"
                        connection.outputStream.write(response.toByteArray(Charsets.US_ASCII))
                        if (!head) connection.outputStream.write(bytes)
                        connection.outputStream.flush()
                        if (!head) { bodiesServed.incrementAndGet(); bodyCompletion.get()?.countDown() }
                    }
                } catch (error: Throwable) { if (!server.isClosed) failures.set(error) }
            }
            var version = "image-v1"
            var imageRequests = 0
            main {
                media = ConversationMedia(test.targetContext,
                    scope = { ConversationMedia.Scope("codex", "cache-thread", 1, client.authorizationIdentity) }, active = { true }, version = { version },
                    request = { op, args, done ->
                        if (op == "fileCancel") done(JSONObject().put("ok", true)) // Loopback fixture has no retained tickets.
                        else { check(op == "image" && args.optInt("binaryVersion") == 1); imageRequests++; client.request(op, args, done) }
                    }, binaryHost = { "127.0.0.1" })
            }
            val fetch = ConversationMedia::class.java.getDeclaredMethod("fetchImage", String::class.java, String::class.java, kotlin.jvm.functions.Function1::class.java).apply { isAccessible = true }
            fun load(corrupt: Boolean = false) {
                val done = CountDownLatch(1); val result = AtomicReference<Bitmap?>()
                val beforeBodies = bodiesServed.get()
                val served = CountDownLatch(1); bodyCompletion.set(served)
                main { fetch.invoke(media, "image#0", "large", { value: Bitmap? -> result.set(value); done.countDown() }) }
                val request = latest()
                check(request.optInt("binaryVersion") == 1 && request.getString("cacheVersion") == version)
                val offer = JSONObject(profile.toString()).apply { if (corrupt) put("sha256", "00".repeat(32)) }
                reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("binary", offer))
                check(done.await(12, TimeUnit.SECONDS)) { "Pinned image load timed out: ${failures.get()?.javaClass?.simpleName}" }
                failures.get()?.let { throw it }
                check(served.await(2, TimeUnit.SECONDS) && bodiesServed.get() == beforeBodies + 1) { "Image case must complete a pinned HTTPS body before checking decode/hash outcome" }
                if (corrupt) check(result.get() == null) else check(result.get()?.width == 16 && result.get()?.height == 16)
            }
            load()
            main {
                val reads = client.networkReads
                var hits = 0
                repeat(20) { fetch.invoke(media, "image#0", "large", { value: Bitmap? -> check(value?.width == 16 && value.height == 16); hits++ }) }
                check(hits == 20 && imageRequests == 1 && client.networkReads == reads)
                version = "image-v2"
            }
            load(corrupt = true)
            check(imageRequests == 2)
            load() // Hash mismatch cannot seed the new-version cache.
            check(imageRequests == 3)
        } finally {
            main { media?.clear() }
            socket?.close(); executor.shutdownNow(); executor.awaitTermination(2, TimeUnit.SECONDS)
            store.deleteEntry(alias)
        }
    }
}
