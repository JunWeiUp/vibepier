package io.github.junweiup.vibepier.remote.features.usage

import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences

import android.content.Context
import org.json.JSONObject

internal data class AppUsageApplication(val id: String, val name: String, val seconds: Double, val color: String, val icon: String)
internal data class AppUsageSegment(val id: String, val name: String, val seconds: Double, val color: String, val kind: String = "app")
internal data class AppUsageSnapshot(
    val source: String, val sourceName: String, val date: String, val today: String, val timeZone: String,
    val syncedAt: Long, val enabled: Boolean, val apps: List<AppUsageApplication>, val daySeconds: Double,
    val rest: Double, val unrecorded: Double, val future: Double, val current: String, val intervals: List<Triple<String, Long, Long>>,
    val dayStart: Long, val timeline: List<AppUsageTimeRange>?
) {
    val total get() = apps.sumOf { it.seconds }
    val coverage get() = total + rest
    fun timeRange(range: AppUsageTimeRange): String {
        val formatter = java.text.SimpleDateFormat("HH:mm", java.util.Locale.CHINA).apply { timeZone = java.util.TimeZone.getTimeZone(this@AppUsageSnapshot.timeZone) }
        fun time(value: Long) = if (value == dayStart + (daySeconds * 1000).toLong()) "24:00" else formatter.format(java.util.Date(value))
        return "${time(range.start)}–${time(range.end)}"
    }
    fun segments(order: List<String>): List<AppUsageSegment> = apps.sortedBy { order.indexOf(it.id).takeIf { n -> n >= 0 } ?: Int.MAX_VALUE }
        .map { AppUsageSegment(it.id, it.name, it.seconds, it.color) } + listOf(
            AppUsageSegment("rest", "", rest, "#667369", "rest"),
            AppUsageSegment("unrecorded", "", unrecorded, "#56615B", "unrecorded"),
            AppUsageSegment("future", "", future, "#161D19", "future")
        )
    companion object {
        fun parse(value: JSONObject): AppUsageSnapshot {
            require(value.optBoolean("ok"))
            val array = value.getJSONArray("apps")
            val apps = (0 until array.length()).map { index -> array.getJSONObject(index).let {
                AppUsageApplication(it.getString("id"), it.getString("name"), it.getDouble("seconds"), it.getString("color"), it.optString("iconPNG"))
            } }
            require(apps.all { it.id.isNotEmpty() && it.seconds.isFinite() && it.seconds >= 0 })
            require(apps.map { it.id }.distinct().size == apps.size)
            val intervals = value.optJSONArray("intervals")
            val dayStart = value.optLong("dayStart", java.time.LocalDate.parse(value.getString("date"))
                .atStartOfDay(java.time.ZoneId.of(value.getString("timeZone"))).toInstant().toEpochMilli())
            val observed = if (value.optInt("timelineVersion") == 1) value.getJSONArray("timeline").let { array ->
                (0 until array.length()).mapNotNull { i -> array.getJSONArray(i).let {
                    // macOS sends fractional milliseconds. A valid short interval can collapse
                    // to one millisecond boundary when converted to Android's Long timestamps.
                    val start = it.getDouble(1)
                    val end = it.getDouble(2)
                    require(start.isFinite() && end.isFinite() && end > start)
                    val interval = AppUsageInterval(it.getString(0), it.getLong(1), it.getLong(2))
                    interval.takeIf { range -> range.end > range.start }
                } }
            } else null
            val timeline = observed?.let { AppUsageMath.timeline(it, dayStart, dayStart + (value.getDouble("daySeconds") * 1000).toLong(), value.getLong("syncedAt")) }
            val snapshot = AppUsageSnapshot(value.getString("sourceID"), value.getString("sourceName"), value.getString("date"), value.getString("today"),
                value.getString("timeZone"), value.getLong("syncedAt"), value.getBoolean("enabled"), apps, value.getDouble("daySeconds"),
                value.getDouble("restSeconds"), value.getDouble("unrecordedSeconds"), value.getDouble("futureSeconds"), value.optString("currentAppID"),
                if (intervals == null) emptyList() else (0 until intervals.length()).map { i -> intervals.getJSONObject(i).let { Triple(it.getString("appID"), it.getLong("start"), it.getLong("end")) } },
                dayStart, timeline)
            require(snapshot.source.isNotBlank())
            AppUsageMath.widths(snapshot.segments(emptyList()).map { it.seconds }, snapshot.daySeconds)
            timeline?.let { ranges ->
                require(ranges.filter { it.kind == "app" }.all { range -> apps.any { it.id == range.id } })
                apps.forEach { app -> require(kotlin.math.abs(ranges.filter { it.kind == "app" && it.id == app.id }.sumOf { it.seconds } - app.seconds) < 1.0) }
                require(kotlin.math.abs(ranges.filter { it.kind == "rest" }.sumOf { it.seconds } - snapshot.rest) < 1.0)
                require(kotlin.math.abs(ranges.filter { it.kind == "unrecorded" }.sumOf { it.seconds } - snapshot.unrecorded) < 1.0)
                require(kotlin.math.abs(ranges.filter { it.kind == "future" }.sumOf { it.seconds } - snapshot.future) < 1.0)
            }
            return snapshot
        }
    }
}

/** A source UUID is required for cache access, so switching Macs cannot blend their days. */
internal class AppUsageCache(context: Context) {
    private val prefs = PrivatePreferences.open(context, "application-usage-cache")
    fun read(source: String, date: String): JSONObject? {
        if (source.isBlank()) return null
        return try { prefs.getString("$source:$date", null)?.let(::JSONObject) } catch (_: Exception) { null }
    }
    fun latest(source: String): JSONObject? {
        if (source.isBlank()) return null
        return prefs.all.filterKeys { it.startsWith("$source:") }.values.mapNotNull {
            try { JSONObject(it as String).takeIf { value -> value.optBoolean("ok") } } catch (_: Exception) { null }
        }.maxByOrNull { it.optLong("syncedAt") }
    }
    fun remember(value: JSONObject) {
        val snapshot = AppUsageSnapshot.parse(value)
        val key = "${snapshot.source}:${snapshot.date}"
        val records = prefs.all.filterValues { it is String }.mapNotNull { (k, v) ->
            try { Triple(k, v as String, JSONObject(v).getLong("syncedAt")) } catch (_: Exception) { null }
        }.filter { it.first != key }.sortedByDescending { it.third }.take(13).toMutableList()
        records.add(0, Triple(key, value.toString(), snapshot.syncedAt))
        while (records.sumOf { it.second.toByteArray().size } > 1024 * 1024 && records.size > 1) records.removeAt(records.lastIndex)
        prefs.edit().clear().apply { records.forEach { putString(it.first, it.second) } }.apply()
    }
    fun summarySnapshot(source: String): AppUsageSnapshot? {
        if (source.isBlank()) return null
        val latest = prefs.all.filterKeys { it.startsWith("$source:") }.values.mapNotNull { try { AppUsageSnapshot.parse(JSONObject(it as String)) } catch (_: Exception) { null } }
            .maxByOrNull { it.syncedAt }
        return latest
    }
}
