package io.github.junweiup.vibepier.remote.features.usage

import java.util.Locale

internal data class AppUsageInterval(val id: String, val start: Long, val end: Long)
internal data class AppUsageTimeRange(val id: String, val start: Long, val end: Long, val kind: String) {
    val seconds get() = (end - start) / 1000.0
}

/** Statistics use seconds; rounded row labels are never added together. */
internal object AppUsageMath {
    /** Coordinates come from timestamps, never from totals or the application's rank. */
    fun timeline(intervals: List<AppUsageInterval>, dayStart: Long, dayEnd: Long, syncedAt: Long): List<AppUsageTimeRange> {
        require(dayEnd > dayStart)
        val cutoff = syncedAt.coerceIn(dayStart, dayEnd)
        val result = mutableListOf<AppUsageTimeRange>()
        var cursor = dayStart
        intervals.sortedBy { it.start }.forEach { interval ->
            require(interval.end > interval.start)
            val start = maxOf(dayStart, interval.start)
            val end = minOf(cutoff, interval.end)
            if (end <= start) return@forEach
            require(start >= cursor) { "Usage intervals overlap" }
            if (start > cursor) result += AppUsageTimeRange("unrecorded", cursor, start, "unrecorded")
            result += AppUsageTimeRange(interval.id, start, end, if (interval.id.isEmpty()) "rest" else "app")
            cursor = end
        }
        if (cursor < cutoff) result += AppUsageTimeRange("unrecorded", cursor, cutoff, "unrecorded")
        if (cutoff < dayEnd) result += AppUsageTimeRange("future", cutoff, dayEnd, "future")
        return result
    }

    data class Duration(val minutes: Long, val lessThanMinute: Boolean = false)
    fun duration(seconds: Double): Duration = when {
        !seconds.isFinite() || seconds <= 0 -> Duration(0)
        seconds < 60 -> Duration(0, lessThanMinute = true)
        else -> Duration((seconds / 60).toLong())
    }
    fun percent(seconds: Double, denominator: Double): String = if (denominator <= 0 || !denominator.isFinite()) "—"
        else String.format(Locale.US, "%.1f%%", seconds.coerceAtLeast(0.0) / denominator * 100)

    fun widths(seconds: List<Double>, daySeconds: Double): List<Double> {
        require(daySeconds.isFinite() && daySeconds > 0)
        val values = seconds.map { if (it.isFinite()) it.coerceAtLeast(0.0) else 0.0 }
        require(kotlin.math.abs(values.sum() - daySeconds) < 1.0) { "Usage distribution does not match the day length" }
        return values.map { it / daySeconds }
    }
}
