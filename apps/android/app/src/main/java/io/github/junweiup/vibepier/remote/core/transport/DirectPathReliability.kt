package io.github.junweiup.vibepier.remote.core.transport

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** DNS may ignore interruption; one in-flight batch bounds the work even in that case. */
internal class DirectProbeScheduler(
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "vibepier-direct-probe").apply { isDaemon = true }
    }
) : AutoCloseable {
    private val lock = Any()
    private var inFlight = false
    private var closed = false
    private var active: Attempt? = null

    inner class Attempt internal constructor(val token: String) {
        fun isActive(): Boolean = synchronized(lock) { !closed && active === this }

        /** Cancellation and emission share a gate, so cancelled work cannot send late packets. */
        fun emit(action: () -> Unit): Boolean = synchronized(lock) {
            if (closed || active !== this) return false
            action()
            true
        }
    }

    fun start(token: String, accepted: () -> Unit, probe: (Attempt) -> Unit): Boolean = synchronized(lock) {
        if (closed || inFlight) return false
        val attempt = Attempt(token)
        active = attempt
        inFlight = true
        accepted()
        try {
            worker.execute {
                try { if (attempt.isActive()) probe(attempt) }
                finally { synchronized(lock) { inFlight = false } }
            }
        } catch (_: RejectedExecutionException) {
            if (active === attempt) active = null
            inFlight = false
            return false
        }
        true
    }

    fun emit(token: String, action: () -> Unit): Boolean = synchronized(lock) {
        val attempt = active?.takeIf { it.token == token } ?: return false
        attempt.emit(action)
    }

    fun cancel() = synchronized(lock) { active = null }

    override fun close() {
        synchronized(lock) { closed = true; active = null }
        worker.shutdownNow()
    }
}

internal object DirectPathHealth {
    const val REPLY_TIMEOUT_MS = 12_000L

    fun isFresh(hasPath: Boolean, lastReplyAt: Long, now: Long): Boolean =
        // A receive thread may update the reply just after the maintenance thread samples now.
        hasPath && lastReplyAt > 0 && now - lastReplyAt <= REPLY_TIMEOUT_MS

    fun shouldClearApplication(relayOnline: Boolean, hasPath: Boolean, lastReplyAt: Long, now: Long): Boolean =
        !relayOnline && !isFresh(hasPath, lastReplyAt, now)
}
