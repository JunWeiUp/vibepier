package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.RelayDnsFallback

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLParameters

class RelayDnsFallbackTest {
    private val host = "relay.example.test"
    private val first = ipv4(203, 0, 113, 10)
    private val second = ipv4(8, 8, 8, 8)

    private fun ipv4(vararg octets: Int): InetAddress =
        InetAddress.getByAddress(octets.map(Int::toByte).toByteArray())

    private fun record(name: String = host, type: Int = 1, ttl: Long = 60, data: String = "203.0.113.10") =
        RelayDnsFallback.Record(name, type, ttl, data)

    @Test fun optedInHostnamesAreValidatedAndCanonicalized() {
        val lookedUp = mutableListOf<String>()
        val resolver = RelayDnsFallback(lookup = { name, _ ->
            lookedUp.add(name)
            RelayDnsFallback.Answer(listOf(first), 0)
        })
        for (name in listOf(host, "RELAY.EXAMPLE.TEST", "relay.example.test.")) {
            assertTrue(RelayDnsFallback.eligible(name))
            assertArrayEquals(arrayOf(first), resolver.resolve(name, RelayDnsFallback.Attempt()))
        }
        assertEquals(listOf(host, host, host), lookedUp)
        for (name in listOf("printer.local", "203.0.113.10", "https://relay.example.test", "bad..example", "")) {
            assertFalse(name, RelayDnsFallback.eligible(name))
            assertThrows(IllegalArgumentException::class.java) {
                resolver.resolve(name, RelayDnsFallback.Attempt())
            }
        }
        assertEquals("ineligible hosts must never start a lookup", 3, lookedUp.size)
    }

    @Test fun cachedAnswerIsReusedUntilItsExactTtlDeadline() {
        var now = 1_000L
        var lookups = 0
        val resolver = RelayDnsFallback(nowMs = { now }, lookup = { _, _ ->
            lookups++
            RelayDnsFallback.Answer(listOf(if (lookups == 1) first else second), 2)
        })
        assertArrayEquals(arrayOf(first), resolver.resolve(host, RelayDnsFallback.Attempt()))
        now = 2_999L
        assertArrayEquals(arrayOf(first), resolver.resolve("RELAY.EXAMPLE.TEST.", RelayDnsFallback.Attempt()))
        assertEquals(1, lookups)
        now = 3_000L
        assertArrayEquals(arrayOf(second), resolver.resolve(host, RelayDnsFallback.Attempt()))
        assertEquals(2, lookups)
    }

    @Test fun zeroTtlAnswerIsReturnedWithoutBeingCached() {
        var lookups = 0
        val resolver = RelayDnsFallback(nowMs = { 0L }, lookup = { _, _ ->
            lookups++
            RelayDnsFallback.Answer(listOf(if (lookups == 1) first else second), 0)
        })
        assertArrayEquals(arrayOf(first), resolver.resolve(host, RelayDnsFallback.Attempt()))
        assertArrayEquals(arrayOf(second), resolver.resolve(host, RelayDnsFallback.Attempt()))
        assertEquals(2, lookups)
    }

    @Test fun oversizedTtlIsCappedAtFiveMinutesWithoutOverflow() {
        var now = 0L
        var lookups = 0
        val resolver = RelayDnsFallback(nowMs = { now }, lookup = { _, _ ->
            lookups++
            RelayDnsFallback.Answer(listOf(if (lookups == 1) first else second), Long.MAX_VALUE)
        })
        assertArrayEquals(arrayOf(first), resolver.resolve(host, RelayDnsFallback.Attempt()))
        now = 299_999L
        assertArrayEquals(arrayOf(first), resolver.resolve(host, RelayDnsFallback.Attempt()))
        assertEquals(1, lookups)
        now = 300_000L
        assertArrayEquals(arrayOf(second), resolver.resolve(host, RelayDnsFallback.Attempt()))
        assertEquals(2, lookups)
    }

    @Test fun cancelledLookupClosesOwnedSocketsAndCannotReturnOrPopulateTheCache() {
        val owned = Socket()
        val released = Socket()
        val late = Socket()
        var lookups = 0
        val oldAttempt = RelayDnsFallback.Attempt()
        val resolver = RelayDnsFallback(nowMs = { 0L }, lookup = { _, attempt ->
            lookups++
            if (lookups == 1) {
                attempt.track(owned)
                attempt.track(released)
                attempt.release(released)
                attempt.cancel()
                RelayDnsFallback.Answer(listOf(first), 60)
            } else RelayDnsFallback.Answer(listOf(second), 60)
        })
        try {
            assertThrows(SocketException::class.java) { resolver.resolve(host, oldAttempt) }
            assertTrue(owned.isClosed)
            assertFalse(released.isClosed)
            assertThrows(SocketException::class.java) { oldAttempt.track(late) }
            assertTrue(late.isClosed)
            assertArrayEquals(arrayOf(second), resolver.resolve(host, RelayDnsFallback.Attempt()))
            assertEquals("the cancelled answer must not be cached", 2, lookups)
            oldAttempt.cancel()
            assertFalse("an old attempt must not regain released sockets", released.isClosed)
        } finally {
            oldAttempt.cancel()
            owned.close()
            released.close()
            late.close()
        }
    }

    @Test fun cachedAnswerStillRequiresAnActiveAttemptWithinItsBudget() {
        var lookups = 0
        val resolver = RelayDnsFallback(nowMs = { 0L }, lookup = { _, _ ->
            lookups++
            RelayDnsFallback.Answer(listOf(first), 60)
        })
        resolver.resolve(host, RelayDnsFallback.Attempt())
        val cancelled = RelayDnsFallback.Attempt().apply { cancel() }
        assertThrows(SocketException::class.java) { resolver.resolve(host, cancelled) }
        assertThrows(SocketTimeoutException::class.java) {
            resolver.resolve(host, RelayDnsFallback.Attempt(timeoutMs = 0))
        }
        assertArrayEquals(arrayOf(first), resolver.resolve(host, RelayDnsFallback.Attempt()))
        assertEquals(1, lookups)
    }

    @Test fun recoveryUsesTheCachedAddressBeforeAnySystemOrFreshLookup() {
        var lookups = 0
        val resolver = RelayDnsFallback(nowMs = { 0L }, lookup = { _, _ ->
            lookups++
            RelayDnsFallback.Answer(listOf(first), 60)
        })
        resolver.resolve(host, RelayDnsFallback.Attempt())
        assertArrayEquals(arrayOf(first), resolver.cachedAddresses("RELAY.EXAMPLE.TEST."))
        val result = resolver.connectWithRecovery(
            host = host,
            systemConnect = { error("cached recovery must not use system DNS") },
            addressConnect = { addresses ->
                assertArrayEquals(arrayOf(first), addresses)
                "cached connection"
            },
            freshLookup = { error("a successful cached connection needs no fresh lookup") },
        )
        assertEquals("cached connection", result)
        assertEquals(1, lookups)
    }

    @Test fun failedCachedAddressIsInvalidatedBeforeFreshLookupEvenWhenLookupFails() {
        val resolver = RelayDnsFallback(nowMs = { 0L }, lookup = { _, _ ->
            RelayDnsFallback.Answer(listOf(first), 60)
        })
        resolver.resolve(host, RelayDnsFallback.Attempt())
        val events = mutableListOf<String>()
        val failedLookup = UnknownHostException("fresh DNS failed")
        val thrown = assertThrows(UnknownHostException::class.java) {
            resolver.connectWithRecovery<String>(
                host = host,
                systemConnect = { error("cached failure must recover directly through fresh DNS") },
                addressConnect = { addresses ->
                    events.add("cached address")
                    assertArrayEquals(arrayOf(first), addresses)
                    throw SocketException("cached source moved")
                },
                freshLookup = {
                    events.add("fresh lookup")
                    assertNull("the failed source must already be invalidated", resolver.cachedAddresses(host))
                    throw failedLookup
                },
            )
        }
        assertSame(failedLookup, thrown)
        assertEquals(listOf("cached address", "fresh lookup"), events)
        assertNull(resolver.cachedAddresses(host))
    }

    @Test fun expiredCacheReturnsToSystemFirstAndOnlyItsFailureStartsFreshRecovery() {
        var now = 1_000L
        val resolver = RelayDnsFallback(nowMs = { now }, lookup = { _, _ ->
            RelayDnsFallback.Answer(listOf(first), 2)
        })
        resolver.resolve(host, RelayDnsFallback.Attempt())
        now = 2_999L
        assertArrayEquals(arrayOf(first), resolver.cachedAddresses(host))
        now = 3_000L
        assertNull("observing cached addresses must not extend their TTL", resolver.cachedAddresses(host))
        assertEquals("system connection", resolver.connectWithRecovery(
            host = host,
            systemConnect = { "system connection" },
            addressConnect = { error("system success needs no address recovery") },
            freshLookup = { error("system success needs no fresh DNS") },
        ))
        val events = mutableListOf<String>()
        val result = resolver.connectWithRecovery(
            host = host,
            systemConnect = {
                events.add("system connection")
                throw SocketException("system-resolved source unavailable")
            },
            freshLookup = {
                events.add("fresh lookup")
                arrayOf(second)
            },
            addressConnect = { addresses ->
                events.add("fresh address")
                assertArrayEquals(arrayOf(second), addresses)
                "recovered connection"
            },
        )
        assertEquals("recovered connection", result)
        assertEquals(listOf("system connection", "fresh lookup", "fresh address"), events)
    }

    @Test fun failedFreshConnectionAlsoInvalidatesTheNewlyResolvedCache() {
        val resolver = RelayDnsFallback(nowMs = { 0L }, lookup = { _, _ ->
            RelayDnsFallback.Answer(listOf(second), 60)
        })
        var freshLookups = 0
        val failedFresh = SocketException("freshly resolved source is unreachable")
        val thrown = assertThrows(SocketException::class.java) {
            resolver.connectWithRecovery<String>(
                host = host,
                systemConnect = { throw SocketException("system-resolved source is unreachable") },
                freshLookup = {
                    freshLookups++
                    resolver.resolve(host, RelayDnsFallback.Attempt()).also {
                        assertArrayEquals(arrayOf(second), resolver.cachedAddresses(host))
                    }
                },
                addressConnect = { addresses ->
                    assertArrayEquals(arrayOf(second), addresses)
                    throw failedFresh
                },
            )
        }
        assertSame(failedFresh, thrown)
        assertEquals(1, freshLookups)
        assertNull("the next reconnect must not reuse the failed fresh source", resolver.cachedAddresses(host))
    }

    @Test fun staleGenerationGuardStopsFreshRecoveryAndCannotInvalidateSharedCache() {
        val resolver = RelayDnsFallback(nowMs = { 0L }, lookup = { _, _ ->
            RelayDnsFallback.Answer(listOf(first), 60)
        })
        resolver.resolve(host, RelayDnsFallback.Attempt())
        var stale = false
        var freshLookups = 0
        var guards = 0
        val stopped = SocketException("connection generation stopped")
        val thrown = assertThrows(SocketException::class.java) {
            resolver.connectWithRecovery<String>(
                host = host,
                systemConnect = { error("cached recovery must not use system DNS") },
                addressConnect = {
                    stale = true
                    throw SocketException("old connection stopped")
                },
                freshLookup = {
                    freshLookups++
                    arrayOf(second)
                },
                guard = { action ->
                    guards++
                    if (stale) throw stopped
                    action()
                },
            )
        }
        assertSame(stopped, thrown)
        assertEquals(0, freshLookups)
        assertEquals(2, guards)
        assertArrayEquals("a rejected old generation must not mutate shared cache", arrayOf(first), resolver.cachedAddresses(host))
    }

    @Test fun IPLiteralKeepsSystemOnlyStrategyAndCannotInvalidateAnotherHostCache() {
        val resolver = RelayDnsFallback(nowMs = { 0L }, lookup = { _, _ ->
            RelayDnsFallback.Answer(listOf(first), 60)
        })
        resolver.resolve(host, RelayDnsFallback.Attempt())
        val custom = "203.0.113.20"
        assertNull(resolver.cachedAddresses(custom))
        resolver.invalidate(custom)
        assertArrayEquals(arrayOf(first), resolver.cachedAddresses(host))
        assertEquals("custom connection", resolver.connectWithRecovery(
            host = custom,
            systemConnect = { "custom connection" },
            addressConnect = { error("custom relays must not use cached recovery") },
            freshLookup = { error("custom relays must not use fresh recovery") },
            guard = { error("custom relays must not inspect the official cache") },
        ))
        val failedSystem = SocketException("custom source failed")
        val thrown = assertThrows(SocketException::class.java) {
            resolver.connectWithRecovery<String>(
                host = custom,
                systemConnect = { throw failedSystem },
                addressConnect = { error("custom relays must not recover through another address") },
                freshLookup = { error("custom relays must not use fresh recovery") },
            )
        }
        assertSame(failedSystem, thrown)
        assertArrayEquals(arrayOf(first), resolver.cachedAddresses(host))
        resolver.invalidate("RELAY.EXAMPLE.TEST.")
        assertNull(resolver.cachedAddresses(host))
    }

    @Test fun recordsMustHaveASuccessfulDnsStatusAndMatchTheQuestionName() {
        val answer = RelayDnsFallback.validateRecords(host, 0, listOf(
            record(name = "RELAY.EXAMPLE.TEST."),
            record(name = "unrelated.example", ttl = 1, data = "8.8.8.8"),
            record(type = 28, ttl = 1, data = "2001:4860:4860::8888"),
        ))
        assertEquals(listOf(first), answer.addresses)
        assertEquals(60L, answer.ttlSeconds)
        assertThrows(UnknownHostException::class.java) {
            RelayDnsFallback.validateRecords(host, 3, listOf(record()))
        }
        assertThrows(UnknownHostException::class.java) {
            RelayDnsFallback.validateRecords(host, 0, listOf(record(name = "unrelated.example")))
        }
        assertThrows(UnknownHostException::class.java) {
            RelayDnsFallback.validateRecords(host, 0, emptyList())
        }
    }

    @Test fun onlyLiteralPublicIpv4RecordsAreUsable() {
        val rejected = listOf(
            "0.0.0.0", "0.1.2.3", "127.0.0.1", "10.1.2.3", "172.16.1.2",
            "172.31.255.255", "192.168.1.2", "169.254.1.2", "224.0.0.1",
            "239.255.255.255", "240.0.0.1", "255.255.255.255", "256.1.2.3",
            "8.8.8", "8.8.8.8.8", "1843246944", "8.8.8.-1", "::1", "dns.example",
        )
        for (data in rejected) {
            assertThrows("invalid address $data", UnknownHostException::class.java) {
                RelayDnsFallback.validateRecords(host, 0, listOf(record(data = data)))
            }
        }
        val answer = RelayDnsFallback.validateRecords(host, 0, listOf(
            record(data = "10.1.2.3", ttl = 1),
            record(data = "203.0.113.10", ttl = 60),
        ))
        assertEquals(listOf(first), answer.addresses)
        assertEquals("discarded addresses must not affect usable TTL", 60L, answer.ttlSeconds)
    }

    @Test fun cnameChainUsesItsShortestTtlAndDoesNotAuthorizeUnrelatedRecords() {
        val answer = RelayDnsFallback.validateRecords(host, 0, listOf(
            record(name = "EDGE.EXAMPLE.", ttl = 200),
            record(type = 5, ttl = 100, data = "alias.example."),
            record(name = "alias.example", type = 5, ttl = 40, data = "edge.example"),
            record(name = "unrelated.example", ttl = 1, data = "8.8.8.8"),
        ))
        assertEquals(listOf(first), answer.addresses)
        assertEquals(40L, answer.ttlSeconds)
        assertThrows(UnknownHostException::class.java) {
            RelayDnsFallback.validateRecords(host, 0, listOf(
                record(type = 5, data = "alias.example"),
                record(name = "alias.example", type = 5, data = host),
                record(name = "unrelated.example"),
            ))
        }
    }

    @Test fun dnsTlsRequiresHttpsValidationAndTheResolverHostname() {
        val supplied = SSLParameters().apply {
            endpointIdentificationAlgorithm = ""
            serverNames = listOf(SNIHostName("wrong.example"))
        }
        val parameters = RelayDnsFallback.tlsParameters(supplied)
        assertSame(supplied, parameters)
        assertEquals("HTTPS", parameters.endpointIdentificationAlgorithm)
        assertEquals("dns.alidns.com", (parameters.serverNames.single() as SNIHostName).asciiName)
        val defaults = RelayDnsFallback.tlsParameters()
        assertEquals("HTTPS", defaults.endpointIdentificationAlgorithm)
        assertEquals("dns.alidns.com", (defaults.serverNames.single() as SNIHostName).asciiName)
    }
}
