package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.usage.AppUsageInterval
import io.github.junweiup.vibepier.remote.features.usage.AppUsageMath

import org.junit.Assert.*
import org.junit.Test

class AppUsageMathTest {
    @Test fun actualTimePositionsKeepRepeatedAppsAndUnknownGaps() {
        val hour = 3600000L
        val ranges = AppUsageMath.timeline(listOf(
            AppUsageInterval("a", 9 * hour, 10 * hour + hour / 2),
            AppUsageInterval("b", 11 * hour, 12 * hour),
            AppUsageInterval("a", 14 * hour, 15 * hour),
            AppUsageInterval("", 15 * hour, 16 * hour)
        ), 0, 24 * hour, 18 * hour)
        assertEquals(listOf("unrecorded", "app", "unrecorded", "app", "unrecorded", "app", "rest", "unrecorded", "future"), ranges.map { it.kind })
        assertEquals(listOf(9 * hour, 14 * hour), ranges.filter { it.id == "a" }.map { it.start })
        assertEquals(24 * 3600.0, ranges.sumOf { it.seconds }, .000001)
        assertEquals(18 * hour, ranges.last().start)
    }
    @Test fun midnightAndSnapshotCutoffClipInsteadOfMovingIntervals() {
        val ranges = AppUsageMath.timeline(listOf(AppUsageInterval("a", 90, 150), AppUsageInterval("", 170, 250)), 100, 300, 200)
        assertEquals(listOf(100L to 150L, 150L to 170L, 170L to 200L, 200L to 300L), ranges.map { it.start to it.end })
        assertEquals("unrecorded", ranges[1].kind)
        assertEquals("future", ranges.last().kind)
    }
    @Test fun emptyPastDayIsUnknownAndLongDayKeepsFullDuration() {
        val ranges = AppUsageMath.timeline(emptyList(), 0, 90000000, 90000001)
        assertEquals(1, ranges.size)
        assertEquals("unrecorded", ranges.single().kind)
        assertEquals(90000.0, ranges.single().seconds, .000001)
    }
    @Test fun noEarlyVisitIsDroppedWhenThereAreMoreThan500() {
        val intervals = (0 until 601).map { AppUsageInterval("app.${it % 2}", it * 1000L, (it + 1) * 1000L) }
        val ranges = AppUsageMath.timeline(intervals, 0, 86400000, 601000)
        assertEquals(602, ranges.size)
        assertEquals(0, ranges.first().start)
        assertEquals(601000, ranges.last().start)
    }
    @Test(expected = IllegalArgumentException::class) fun overlappingObservationsAreRejected() {
        AppUsageMath.timeline(listOf(AppUsageInterval("a", 0, 100), AppUsageInterval("b", 90, 200)), 0, 300, 250)
    }
    @Test fun rowAndWholeDayUseDifferentDenominators() {
        assertEquals("34.6%", AppUsageMath.percent(140.0 * 60, 405.0 * 60))
        assertEquals("9.7%", AppUsageMath.percent(140.0 * 60, 1440.0 * 60))
        assertEquals("28.1%", AppUsageMath.percent(405.0 * 60, 1440.0 * 60))
    }
    @Test fun exactDistributionKeepsTinySegmentsAndSumsToOne() {
        val widths = AppUsageMath.widths(listOf(1.0, 405.0 * 60 - 1, 385.0 * 60, 254.0 * 60, 396.0 * 60), 86400.0)
        assertEquals(1.0, widths.sum(), .0000001)
        assertEquals(1.0 / 86400, widths.first(), .0000001)
    }
    @Test fun displayDoesNotRoundSmallIntervalsUp() {
        assertEquals(AppUsageMath.Duration(0, lessThanMinute = true), AppUsageMath.duration(59.0))
        assertEquals(AppUsageMath.Duration(405), AppUsageMath.duration(405.0 * 60))
        assertEquals(AppUsageMath.Duration(0), AppUsageMath.duration(Double.NaN))
        assertEquals(AppUsageMath.Duration(0), AppUsageMath.duration(-1.0))
        assertEquals("—", AppUsageMath.percent(0.0, 0.0))
    }
    @Test(expected = IllegalArgumentException::class) fun missingTimeCannotBecomeAValidSnapshot() {
        AppUsageMath.widths(listOf(1.0, 2.0), 86400.0)
    }
}
