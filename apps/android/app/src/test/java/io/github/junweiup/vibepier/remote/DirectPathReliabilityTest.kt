package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.DirectPathHealth
import io.github.junweiup.vibepier.remote.core.transport.DirectProbeScheduler

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class DirectPathReliabilityTest {
    @Test fun slowDnsDoesNotBlockMaintenanceAndCannotQueueMoreProbeBatches() {
        val entered = CountDownLatch(1)
        val releaseDns = CountDownLatch(1)
        val probe = DirectProbeScheduler()
        val maintenance = Executors.newSingleThreadScheduledExecutor()
        val maintained = CountDownLatch(3)
        try {
            assertTrue(probe.start("slow", accepted = {}) {
                entered.countDown()
                releaseDns.await(2, TimeUnit.SECONDS)
            })
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            maintenance.scheduleAtFixedRate({ maintained.countDown() }, 0, 10, TimeUnit.MILLISECONDS)
            assertTrue("relay watches must continue while STUN DNS is blocked", maintained.await(1, TimeUnit.SECONDS))
            repeat(60) { assertFalse(probe.start("another-$it", accepted = {}) { error("queued probe ran") }) }
            probe.cancel()
            assertFalse("an uncancellable DNS batch still occupies the sole worker", probe.start("after-cancel", accepted = {}) {})
        } finally {
            releaseDns.countDown()
            probe.close()
            maintenance.shutdownNow()
        }
    }

    @Test fun cancelledTokenCannotSendAfterItsDnsReturnsOrEmitAnOffer() {
        val entered = CountDownLatch(1)
        val releaseDns = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val packets = AtomicInteger()
        val probe = DirectProbeScheduler()
        try {
            assertTrue(probe.start("old", accepted = {}) { attempt ->
                entered.countDown()
                releaseDns.await(2, TimeUnit.SECONDS)
                attempt.emit { packets.incrementAndGet() }
                completed.countDown()
            })
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            probe.cancel()
            assertFalse(probe.emit("old") { packets.incrementAndGet() })
            releaseDns.countDown()
            assertTrue(completed.await(1, TimeUnit.SECONDS))
            assertEquals(0, packets.get())
        } finally { releaseDns.countDown(); probe.close() }
    }

    @Test fun freshDirectPathPreservesApplicationThroughRelayLossUntilItsExistingDeadline() {
        val repliedAt = 1_000L
        assertFalse(DirectPathHealth.shouldClearApplication(false, true, repliedAt, 12_999L))
        assertFalse(DirectPathHealth.shouldClearApplication(false, true, repliedAt, 13_000L))
        assertTrue(DirectPathHealth.shouldClearApplication(false, true, repliedAt, 13_001L))
        assertFalse("healthy relay remains usable when UDP expires", DirectPathHealth.shouldClearApplication(true, true, repliedAt, 13_001L))
        assertFalse("a newer receive timestamp must not look expired", DirectPathHealth.shouldClearApplication(false, true, 1_002L, 1_001L))
    }

    @Test fun missingDirectPathOrUnconfirmedReplyCannotKeepAnOfflineRelayLookingConnected() {
        assertTrue(DirectPathHealth.shouldClearApplication(false, false, 1_000L, 1_001L))
        assertTrue(DirectPathHealth.shouldClearApplication(false, true, 0L, 1_001L))
    }
}
