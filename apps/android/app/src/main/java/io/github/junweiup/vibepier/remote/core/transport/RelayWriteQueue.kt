package io.github.junweiup.vibepier.remote.core.transport

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Each queued item is one bounded secure-control frame; a stalled socket cannot grow memory indefinitely. */
internal class RelayWriteQueue(capacity: Int = 256) {
    private val executor = ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS, ArrayBlockingQueue(capacity),
        { task -> Thread(task, "vibepier-relay-send").apply { isDaemon = true } }, ThreadPoolExecutor.AbortPolicy()
    ).apply { allowCoreThreadTimeOut(true) }

    fun submit(task: () -> Unit): Boolean = try { executor.execute(task); true } catch (_: RejectedExecutionException) { false }
    fun clear() { executor.queue.clear() }
    fun close() { executor.shutdownNow() }
}
