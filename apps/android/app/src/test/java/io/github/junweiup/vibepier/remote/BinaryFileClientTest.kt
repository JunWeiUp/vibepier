package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.files.BinaryFileClient
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.nio.file.Files
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

/** Current raw HTTPS protocol against loopback only; no Android devices or production trust. */
class BinaryFileClientTest {
    private class Fixture : AutoCloseable {
        val payload = ByteArray(192 * 1024 + 17) { (it % 251).toByte() }
        val uploaded = AtomicReference<ByteArray?>()
        val requests = AtomicInteger()
        val root = Files.createTempDirectory("binary-tls-fixture").toFile()
        val token = "ab".repeat(32)
        private val executor = Executors.newFixedThreadPool(3)
        private val server: SSLServerSocket
        private val pin: String
        @Volatile var fault = ""
        init {
            val keyFile = File(root, "fixture.p12")
            val command = ProcessBuilder(File(System.getProperty("java.home"), "bin/keytool").path,
                "-genkeypair", "-alias", "fixture", "-keyalg", "RSA", "-keysize", "2048", "-storetype", "PKCS12",
                "-keystore", keyFile.path, "-storepass", "synthetic-only", "-keypass", "synthetic-only",
                "-dname", "CN=127.0.0.1", "-ext", "SAN=ip:127.0.0.1", "-validity", "2", "-noprompt")
                .redirectErrorStream(true).redirectOutput(File(root, "keytool.log")).start()
            check(command.waitFor(15, TimeUnit.SECONDS) && command.exitValue() == 0)
            val store = KeyStore.getInstance("PKCS12").apply { keyFile.inputStream().use { load(it, "synthetic-only".toCharArray()) } }
            pin = MessageDigest.getInstance("SHA-256").digest(store.getCertificate("fixture").encoded).joinToString("") { "%02x".format(it) }
            val manager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, "synthetic-only".toCharArray()) }
            val tls = SSLContext.getInstance("TLSv1.3").apply { init(manager.keyManagers, null, null) }
            server = tls.serverSocketFactory.createServerSocket(0, 8, InetAddress.getByName("127.0.0.1")) as SSLServerSocket
            executor.submit {
                try { while (!server.isClosed) {
                    val socket = server.accept() as SSLSocket
                    executor.submit { handle(socket) }
                } } catch (_: java.io.IOException) { }
            }
        }
        fun profile(kind: String = "apk", offset: Int = 0) = JSONObject().put("version", 1).put("kind", kind)
            .put("encoding", "raw").put("id", token).put("readToken", token).put("writeToken", token)
            .put("size", payload.size).put("offset", offset).put("pin", pin).put("port", server.localPort)
        private fun handle(socket: SSLSocket) {
            try { socket.use {
                it.soTimeout = 5000
                val input = it.inputStream
                fun line(): String {
                    val bytes = java.io.ByteArrayOutputStream()
                    while (bytes.size() < 8192) { val b = input.read(); check(b >= 0); if (b == 10) return bytes.toString("US-ASCII").trimEnd('\r'); bytes.write(b) }
                    error("oversized fixture header")
                }
                val first = line().split(' '); val headers = mutableMapOf<String, String>()
                while (true) { val row = line(); if (row.isEmpty()) break; check(headers.size < 64); headers[row.substringBefore(':').lowercase()] = row.substringAfter(':').trim() }
                requests.incrementAndGet()
                val output = it.outputStream
                fun response(status: String, fields: String = "") { output.write("HTTP/1.1 $status\r\nConnection: close\r\n$fields\r\n".toByteArray()) }
                if (first[1] != "/files/$token" || headers["authorization"] != "Bearer $token") { response("403 Forbidden"); output.flush(); return }
                when (first[0]) {
                    "HEAD" -> response("204 No Content")
                    "GET" -> {
                        val offset = headers.getValue("range").removePrefix("bytes=").removeSuffix("-").toInt()
                        val length = payload.size - offset
                        val declared = if (fault == "length") length - 1 else length
                        val start = if (fault == "range") offset + 1 else offset
                        response("206 Partial Content", "Content-Length: $declared\r\nContent-Range: bytes $start-${payload.size - 1}/${payload.size}\r\n")
                        output.write(payload, offset, if (fault == "truncated") length / 2 else length)
                    }
                    "PUT" -> {
                        check(headers.getValue("content-length").toInt() == payload.size)
                        val body = ByteArray(payload.size); java.io.DataInputStream(input).readFully(body)
                        uploaded.set(body); response("204 No Content")
                    }
                    else -> error("unsupported fixture method")
                }
                output.flush()
            } } catch (_: Exception) { /* TLS rejection/cancellation is expected in negative cases. */ }
        }
        override fun close() { server.close(); executor.shutdownNow(); executor.awaitTermination(2, TimeUnit.SECONDS); root.deleteRecursively() }
    }
    @Test fun rawDownloadResumesExactlyAndKeepsDigest() = Fixture().use { fixture ->
        val offset = 100003
        val body = java.io.ByteArrayOutputStream().apply { write(fixture.payload, 0, offset) }
        BinaryFileClient { true }.download(fixture.profile(offset = offset), "127.0.0.1", fixture.payload.size.toLong(), offset.toLong(), chunkBytes = 65536) { body.write(it) }
        assertArrayEquals(fixture.payload, body.toByteArray())
        assertArrayEquals(MessageDigest.getInstance("SHA-256").digest(fixture.payload), MessageDigest.getInstance("SHA-256").digest(body.toByteArray()))
    }
    @Test fun rawUploadUsesOneBodyAndExactBytes() = Fixture().use { fixture ->
        val file = File(fixture.root, "input").apply { writeBytes(fixture.payload) }
        val progress = mutableListOf<Long>()
        BinaryFileClient { true }.upload(fixture.profile("upload"), "127.0.0.1", file) { progress.add(it) }
        assertArrayEquals(fixture.payload, fixture.uploaded.get())
        assertEquals(fixture.payload.size.toLong(), progress.last())
        assertTrue(progress.zipWithNext().all { it.second > it.first })
        assertEquals(2, fixture.requests.get()) // HEAD + one PUT; no alternate/text body replay.
    }
    @Test fun invalidCertificatePinAndWrongCapabilityAreRejected() = Fixture().use { fixture ->
        for (field in listOf("pin", "readToken")) {
            assertThrows(Exception::class.java) {
                BinaryFileClient { true }.download(fixture.profile().put(field, "cd".repeat(32)), "127.0.0.1", fixture.payload.size.toLong(), 0) { fail("unauthenticated bytes delivered") }
            }
        }
    }
    @Test fun invalidRangeLengthAndTruncatedBodiesNeverComplete() = Fixture().use { fixture ->
        for (fault in listOf("range", "length", "truncated")) {
            fixture.fault = fault
            assertThrows(Exception::class.java) {
                BinaryFileClient { true }.download(fixture.profile(), "127.0.0.1", fixture.payload.size.toLong(), 0) { fail("invalid whole body delivered") }
            }
        }
    }
    @Test fun cancellationStopsAtCommittedChunkAndDoesNotRetry() = Fixture().use { fixture ->
        val client = BinaryFileClient { true }; var delivered = 0
        assertThrows(Exception::class.java) {
            client.download(fixture.profile(), "127.0.0.1", fixture.payload.size.toLong(), 0, chunkBytes = 65536) {
                delivered += it.size; client.cancel()
            }
        }
        assertEquals(65536, delivered)
        assertEquals(2, fixture.requests.get())
    }
    @Test fun oldEncodingAndMismatchedScopeMetadataFailBeforeConnecting() = Fixture().use { fixture ->
        for (profile in listOf(fixture.profile().put("encoding", "base64"), fixture.profile("upload"), fixture.profile(offset = 1))) {
            assertThrows(Exception::class.java) { BinaryFileClient { true }.download(profile, "127.0.0.1", fixture.payload.size.toLong(), 0) { fail() } }
        }
        assertEquals(0, fixture.requests.get())
    }
}
