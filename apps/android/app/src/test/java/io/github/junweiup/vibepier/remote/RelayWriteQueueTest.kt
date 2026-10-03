package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.RelayWriteQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentLinkedQueue
import org.junit.Assert.*
import org.junit.Test

class RelayWriteQueueTest {
    @Test fun stalledWriterHasBoundedQueueAndDiscardedOldWorkNeverRuns() {
        val queue = RelayWriteQueue(capacity = 2)
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val done = CountDownLatch(1)
        val delivered = ConcurrentLinkedQueue<String>()
        try {
            assertTrue(queue.submit { entered.countDown(); release.await(5, TimeUnit.SECONDS) })
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertTrue(queue.submit { delivered.add("old-one") })
            assertTrue(queue.submit { delivered.add("old-two") })
            assertFalse(queue.submit { delivered.add("overflow") })
            queue.clear()
            assertTrue(queue.submit { delivered.add("new-connection"); done.countDown() })
            release.countDown()
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertEquals(listOf("new-connection"), delivered.toList())
        } finally { release.countDown(); queue.close() }
    }
}
