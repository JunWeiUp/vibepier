package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.RelayConnectionAttempt

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLHandshakeException

class RelayConnectionAttemptTest {
    private val ipv4 = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
    private val ipv6 = InetAddress.getByAddress(ByteArray(16).apply { this[15] = 1 })
    private class FakeSocket(private val dialing: (FakeSocket) -> Unit = {}) : Socket() {
        var address: InetAddress? = null
        val entered = CountDownLatch(1)
        val closed = CountDownLatch(1)
        override fun connect(endpoint: SocketAddress?, timeout: Int) {
            address = (endpoint as InetSocketAddress).address
            entered.countDown(); dialing(this)
        }
        override fun setSoTimeout(timeout: Int) {}
        override fun setTcpNoDelay(on: Boolean) {}
        override fun close() { closed.countDown(); super.close() }
    }

    @Test fun candidatesInterleaveFamiliesAndDeduplicateWithoutReplacingHostIdentity() {
        val other6 = InetAddress.getByAddress(ByteArray(16).apply { this[15] = 2 })
        val other4 = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 2))
        assertEquals(listOf(ipv6, ipv4, other6, other4), RelayConnectionAttempt.candidates(arrayOf(ipv6, other6, ipv4, other4, ipv6)))
        assertEquals(listOf(ipv4, ipv6), RelayConnectionAttempt.candidates(arrayOf(ipv4, ipv6)))
    }

    @Test fun stalledIPv6FallsBackWithoutWaitingForItsConnectTimeout() {
        val sockets = CopyOnWriteArrayList<FakeSocket>()
        val attempt = RelayConnectionAttempt("relay.example", 443, timeoutMs = 2_000, staggerMs = 20,
            resolve = { arrayOf(ipv6, ipv4) }, socketFactory = {
                FakeSocket { socket ->
                    if (socket.address == ipv6) { socket.closed.await(3, TimeUnit.SECONDS); throw SocketException("closed") }
                }.also(sockets::add)
            })
        try {
            val result = attempt.connect() as FakeSocket
            assertEquals(ipv4, result.address)
            assertTrue(sockets.first { it.address == ipv6 }.closed.await(1, TimeUnit.SECONDS))
            assertFalse(result.closed.await(10, TimeUnit.MILLISECONDS))
        } finally { attempt.cancel() }
    }

    @Test fun tlsFailureAlsoFallsBackImmediatelyAndClosesFailedRawSocket() {
        val sockets = CopyOnWriteArrayList<FakeSocket>()
        val attempt = RelayConnectionAttempt("relay.example", 443, timeoutMs = 2_000, staggerMs = 5_000,
            resolve = { arrayOf(ipv6, ipv4) }, socketFactory = { FakeSocket().also(sockets::add) },
            finish = { socket, _ -> if ((socket as FakeSocket).address == ipv6) throw SSLHandshakeException("certificate failure") else socket })
        try {
            assertEquals(ipv4, (attempt.connect() as FakeSocket).address)
            assertEquals(0L, sockets.first { it.address == ipv6 }.closed.count)
        } finally { attempt.cancel() }
    }

    @Test fun stalledTLSCannotPreventTheOtherFamilyFromCompleting() {
        val sockets = CopyOnWriteArrayList<FakeSocket>()
        val attempt = RelayConnectionAttempt("relay.example", 443, timeoutMs = 2_000, staggerMs = 20,
            resolve = { arrayOf(ipv6, ipv4) }, socketFactory = { FakeSocket().also(sockets::add) }, finish = { socket, _ ->
                if ((socket as FakeSocket).address == ipv6) { socket.closed.await(3, TimeUnit.SECONDS); throw SocketException("closed") }
                socket
            })
        try {
            assertEquals(ipv4, (attempt.connect() as FakeSocket).address)
            assertTrue(sockets.first { it.address == ipv6 }.closed.await(1, TimeUnit.SECONDS))
        } finally { attempt.cancel() }
    }

    @Test fun cancellingOldAttemptClosesItsSocketsAndCannotCloseANewConnection() {
        val entered = CountDownLatch(1)
        val oldSocket = FakeSocket { socket -> entered.countDown(); socket.closed.await(3, TimeUnit.SECONDS); throw SocketException("closed") }
        val old = RelayConnectionAttempt("old.example", 443, timeoutMs = 2_000, resolve = { arrayOf(ipv6) }, socketFactory = { oldSocket })
        val executor = Executors.newSingleThreadExecutor()
        val future = executor.submit<Socket> { old.connect() }
        try {
            assertTrue(entered.await(1, TimeUnit.SECONDS)); old.cancel()
            try { future.get(1, TimeUnit.SECONDS); error("cancelled connection returned") } catch (error: ExecutionException) { assertTrue(error.cause is SocketException) }
            assertEquals(0L, oldSocket.closed.count)
            val nextSocket = FakeSocket()
            val next = RelayConnectionAttempt("new.example", 443, resolve = { arrayOf(ipv4) }, socketFactory = { nextSocket })
            try {
                val result = next.connect(); next.release(result)
                old.cancel(); next.cancel()
                assertSame(nextSocket, result); assertEquals(1L, nextSocket.closed.count)
            } finally { nextSocket.close() }
        } finally { old.cancel(); executor.shutdownNow() }
    }

    @Test fun deadlineIncludesDnsAndDoesNotLeavePendingConnectionAttempts() {
        val block = CountDownLatch(1)
        val sockets = CopyOnWriteArrayList<FakeSocket>()
        val attempt = RelayConnectionAttempt("slow.example", 443, timeoutMs = 100,
            resolve = { block.await(); arrayOf(ipv4) }, socketFactory = { FakeSocket().also(sockets::add) })
        try { attempt.connect(); error("DNS timeout returned") } catch (_: SocketTimeoutException) { assertTrue(sockets.isEmpty()) }
        finally { attempt.cancel(); block.countDown() }
    }

    @Test fun tlsWrapperRetainsItsRawTransportUntilTheLinkTakesOwnership() {
        val raw = FakeSocket()
        val wrapped = object : Socket() { override fun close() { raw.close(); super.close() } }
        val attempt = RelayConnectionAttempt("relay.example", 443, resolve = { arrayOf(ipv4) }, socketFactory = { raw }, finish = { _, _ -> wrapped })
        val result = attempt.connect()
        assertSame(wrapped, result); assertEquals(1L, raw.closed.count)
        attempt.release(result); attempt.cancel()
        assertEquals(1L, raw.closed.count)
        result.close(); assertEquals(0L, raw.closed.count)
    }
}
