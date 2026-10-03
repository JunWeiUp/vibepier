package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.usage.AppUsageSnapshot
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class AppUsageSnapshotTest {
    private fun fixture(start: Double = 1000.1, end: Double = 1000.2): JSONObject = JSONObject()
        .put("ok", true).put("sourceID", "test-mac").put("sourceName", "Test Mac")
        .put("date", "2026-01-01").put("today", "2026-01-01").put("timeZone", "UTC")
        .put("dayStart", 0).put("daySeconds", 86400).put("syncedAt", 2000).put("enabled", true)
        .put("restSeconds", 0.0001).put("unrecordedSeconds", 0.9998).put("futureSeconds", 86398)
        .put("apps", JSONArray().put(JSONObject().put("id", "app").put("name", "App")
            .put("seconds", 1.0001).put("color", "#BBDDB2")))
        .put("timelineVersion", 1).put("timeline", JSONArray()
            .put(JSONArray(listOf("app", 0, 1000)))
            .put(JSONArray(listOf("app", start, end)))
            .put(JSONArray(listOf("", 1000.3, 1000.4))))

    @Test fun fractionalMillisecondVisitsDoNotInvalidateTheDay() {
        val snapshot = AppUsageSnapshot.parse(fixture())
        assertEquals(1.0001, snapshot.total, 0.000001)
        assertEquals(listOf("app", "unrecorded", "future"), snapshot.timeline!!.map { it.kind })
    }

    @Test(expected = IllegalArgumentException::class)
    fun reversedFractionalIntervalIsStillRejected() { AppUsageSnapshot.parse(fixture(1000.2, 1000.1)) }

    @Test(expected = IllegalArgumentException::class)
    fun zeroDurationInSourceIsStillRejected() { AppUsageSnapshot.parse(fixture(1000.1, 1000.1)) }

    @Test(expected = IllegalArgumentException::class)
    fun overlappingIntervalsAreStillRejected() { AppUsageSnapshot.parse(fixture(999.0, 1001.0)) }
}
