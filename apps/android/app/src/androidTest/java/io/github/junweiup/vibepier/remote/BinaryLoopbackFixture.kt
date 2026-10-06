package io.github.junweiup.vibepier.remote

import android.graphics.Bitmap
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
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
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.*
import javax.security.auth.x500.X500Principal

/** Synthetic pinned TLS endpoints only; no external hosts, production identity, or plaintext media. */
internal class BinaryLoopbackFixture(private val payload: ByteArray) : AutoCloseable {
    private val alias = "binary-loopback-${UUID.randomUUID()}"
    private val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private lateinit var socket: SSLServerSocket
    private val worker = java.util.concurrent.Executors.newFixedThreadPool(3)
    private val tickets = java.util.concurrent.ConcurrentHashMap<String, JSONObject>()
    val offsets = java.util.concurrent.CopyOnWriteArrayList<Long>()
    val uploaded = AtomicReference<ByteArray?>()
    val bodies = java.util.concurrent.atomic.AtomicInteger()
    val error = AtomicReference<Throwable?>()
    @Volatile var holdAfter: Int? = null
    @Volatile var delayMillis: Long = 0
    private var pin = ""
    val host = "127.0.0.1"
    init {
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
            pin = hash(chain[0].encoded)
            worker.submit {
                try {
                    while (!server.isClosed) {
                        val connection = server.accept() as SSLSocket
                        worker.submit { serve(connection) }
                    }
                } catch (failure: Exception) { if (!server.isClosed) error.set(failure) }
            }
    }
    fun profile(kind: String = "media", mime: String = "image/jpeg", offset: Long = 0): JSONObject {
        val token = UUID.randomUUID().toString().replace("-", "") + UUID.randomUUID().toString().replace("-", "")
        val value = JSONObject().put("version", 1).put("kind", kind).put("encoding", "raw").put("mime", mime)
            .put("id", token).put("readToken", token).put("writeToken", token).put("pin", pin)
            .put("port", socket.localPort).put("size", payload.size).put("offset", offset).put("sha256", hash(payload))
        tickets[token] = value
        return JSONObject(value.toString())
    }
    fun response(mime: String = "image/jpeg") = JSONObject().put("ok", true).put("binary", profile(mime = mime))
    private fun serve(connection: SSLSocket) {
        try { connection.use {
            it.soTimeout = 10_000
            val input = it.inputStream
            fun line(): String {
                val output = java.io.ByteArrayOutputStream()
                while (output.size() <= 8192) {
                    val byte = input.read(); check(byte >= 0)
                    if (byte == 10) return output.toString("US-ASCII").trimEnd('\r')
                    output.write(byte)
                }
                error("fixture_header_too_large")
            }
            val first = line().split(' ')
            val headers = mutableMapOf<String, String>()
            var count = 0
            while (true) {
                val row = line(); if (row.isEmpty()) break
                check(++count <= 64)
                val split = row.indexOf(':'); check(split > 0)
                headers[row.substring(0, split).lowercase()] = row.substring(split + 1).trim()
            }
            val token = first[1].removePrefix("/files/")
            val profile = checkNotNull(tickets[token])
            check(first[1] == "/files/$token" && headers["authorization"] == "Bearer $token")
            val output = it.outputStream
            fun response(code: String, fields: String = "") { output.write("HTTP/1.1 $code\r\nConnection: close\r\n$fields\r\n".toByteArray(Charsets.US_ASCII)) }
            when (first[0]) {
                "HEAD" -> response("204 No Content")
                "GET" -> {
                    val offset = profile.getInt("offset")
                    check(headers["range"] == "bytes=$offset-")
                    offsets.add(offset.toLong())
                    response("206 Partial Content", "Content-Length: ${payload.size - offset}\r\nContent-Range: bytes $offset-${payload.size - 1}/${payload.size}\r\n")
                    var position = offset
                    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
                    while (position < payload.size) {
                        while (holdAfter?.let { position >= it } == true) {
                            check(System.nanoTime() < deadline && !socket.isClosed); Thread.sleep(10)
                        }
                        val length = minOf(64 * 1024, payload.size - position)
                        output.write(payload, position, length); output.flush(); position += length
                        if (delayMillis > 0) Thread.sleep(delayMillis)
                    }
                    bodies.incrementAndGet()
                }
                "PUT" -> {
                    check(profile.getString("kind") == "upload" && headers["content-length"]?.toInt() == payload.size)
                    val bytes = ByteArray(payload.size)
                    var offset = 0
                    while (offset < bytes.size) {
                        val n = input.read(bytes, offset, minOf(64 * 1024, bytes.size - offset)); check(n > 0); offset += n
                        if (delayMillis > 0) Thread.sleep(delayMillis)
                    }
                    uploaded.set(bytes); bodies.incrementAndGet(); response("204 No Content")
                }
                else -> error("fixture_method_invalid")
            }
            output.flush()
        } } catch (failure: Exception) {
            // A cancelled body closes TLS; assertion failures still surface through error.
            if (failure !is java.io.IOException && failure !is InterruptedException && !socket.isClosed) error.set(failure)
        }
    }

    override fun close() { holdAfter = null; socket.close(); worker.shutdownNow(); worker.awaitTermination(2, TimeUnit.SECONDS); store.deleteEntry(alias) }
    companion object {
        fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        fun jpeg(bytes: ByteArray): ByteArray {
            val bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            return try { java.io.ByteArrayOutputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)); it.toByteArray() } }
            finally { bitmap.recycle() }
        }
    }
}
