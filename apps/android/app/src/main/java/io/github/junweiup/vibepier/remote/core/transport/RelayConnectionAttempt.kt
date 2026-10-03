package io.github.junweiup.vibepier.remote.core.transport

import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Races resolved address families through TCP and TLS, retaining the URI's host for TLS. */
internal class RelayConnectionAttempt(
    private val host: String,
    private val port: Int,
    private val timeoutMs: Int = 10_000,
    private val staggerMs: Long = 250,
    private val resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName,
    private val socketFactory: () -> Socket = ::Socket,
    private val finish: (Socket, Int) -> Socket = { socket, _ -> socket },
) {
    companion object {
        /** Preserve DNS preference while interleaving IPv6/IPv4, so one family cannot delay the other. */
        fun candidates(addresses: Array<InetAddress>): List<InetAddress> {
            val unique = addresses.distinctBy { it.hostAddress }
            if (unique.isEmpty()) return emptyList()
            val firstIPv6 = unique.first() is Inet6Address
            val first = unique.filter { (it is Inet6Address) == firstIPv6 }
            val second = unique.filter { (it is Inet6Address) != firstIPv6 }
            return (0 until maxOf(first.size, second.size)).flatMap { index -> listOfNotNull(first.getOrNull(index), second.getOrNull(index)) }.take(8)
        }
    }

    private fun threads(name: String) = java.util.concurrent.ThreadFactory { work -> Thread(work, name).apply { isDaemon = true } }
    private val resolver = Executors.newSingleThreadExecutor(threads("vibepier-relay-dns"))
    private val workers = Executors.newFixedThreadPool(8, threads("vibepier-relay-connect"))
    private val scheduler = Executors.newSingleThreadScheduledExecutor(threads("vibepier-relay-fallback"))
    private val lock = Any()
    private val ready = CountDownLatch(1)
    private val sockets = mutableSetOf<Socket>()
    private val failures = mutableListOf<Exception>()
    private var resolution: Future<Array<InetAddress>>? = null
    private var cancelled = false
    private var completed = false
    private var winner: Socket? = null
    private val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs.toLong())
    private fun remaining() = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()).coerceIn(1, timeoutMs.toLong()).toInt()
    private fun open() = synchronized(lock) { !cancelled && !completed && winner == null }
    private fun close(socket: Socket) { try { socket.close() } catch (_: Exception) {} }

    fun cancel() {
        val owned = synchronized(lock) {
            cancelled = true
            resolution?.cancel(true)
            sockets.toList().also { sockets.clear() }
        }
        ready.countDown(); owned.forEach(::close)
        resolver.shutdownNow(); scheduler.shutdownNow(); workers.shutdownNow()
    }

    /** Called only after the link atomically takes ownership of the returned socket. */
    fun release(socket: Socket) = synchronized(lock) { sockets.remove(socket) }

    fun connect(): Socket {
        try {
            val lookup = resolver.submit<Array<InetAddress>> { resolve(host) }
            synchronized(lock) { resolution = lookup; if (cancelled) lookup.cancel(true) }
            val addresses = candidates(lookup.get(remaining().toLong(), TimeUnit.MILLISECONDS))
            if (addresses.isEmpty()) throw java.net.UnknownHostException(host)
            if (!open()) throw java.net.SocketException("connection cancelled")
            val next = AtomicInteger(0); val finished = AtomicInteger(0)
            fun launchNext() {
                if (!open()) return
                val index = next.getAndIncrement()
                if (index >= addresses.size) return
                workers.execute {
                    var raw: Socket? = null; var connection: Socket? = null; var won = false
                    try {
                        val candidate = socketFactory(); raw = candidate
                        val admitted = synchronized(lock) { if (cancelled || completed || winner != null) false else { sockets.add(candidate); true } }
                        if (!admitted) return@execute
                        if (System.nanoTime() >= deadline) throw SocketTimeoutException("relay connection timed out")
                        candidate.connect(InetSocketAddress(addresses[index], port), remaining())
                        candidate.soTimeout = remaining(); candidate.tcpNoDelay = true
                        val established = finish(candidate, remaining()); connection = established
                        won = synchronized(lock) {
                            sockets.remove(raw)
                            if (cancelled || completed || winner != null) false else {
                                sockets.add(established); winner = established; true
                            }
                        }
                        if (won) ready.countDown()
                    } catch (error: Exception) {
                        synchronized(lock) { failures.add(error) }
                    } finally {
                        if (!won) {
                            connection?.let(::close); raw?.let(::close)
                            synchronized(lock) { sockets.remove(raw); sockets.remove(connection) }
                        }
                        if (finished.incrementAndGet() >= addresses.size) ready.countDown()
                        if (!won && open()) launchNext() // Immediate failures need no stagger delay.
                    }
                }
            }
            launchNext()
            if (addresses.size > 1) scheduler.scheduleWithFixedDelay({ launchNext() }, staggerMs, staggerMs, TimeUnit.MILLISECONDS)
            if (!ready.await(remaining().toLong(), TimeUnit.MILLISECONDS)) throw SocketTimeoutException("relay connection timed out")
            val connected = synchronized(lock) {
                if (cancelled) throw java.net.SocketException("connection cancelled")
                winner ?: throw (failures.lastOrNull() ?: java.net.SocketException("relay connection failed"))
            }
            val losers = synchronized(lock) { completed = true; sockets.filter { it !== connected }.also { sockets.retainAll(setOf(connected)) } }
            losers.forEach(::close)
            return connected
        } catch (error: java.util.concurrent.TimeoutException) {
            cancel(); throw SocketTimeoutException("relay DNS or connection timed out")
        } catch (error: java.util.concurrent.ExecutionException) {
            cancel(); throw (error.cause as? Exception ?: error)
        } catch (error: Exception) {
            cancel(); throw error
        } finally {
            resolver.shutdownNow(); scheduler.shutdownNow(); workers.shutdownNow()
        }
    }
}
