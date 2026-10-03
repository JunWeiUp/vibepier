package io.github.junweiup.vibepier.remote.features.usage

import android.content.Context
import io.github.junweiup.vibepier.remote.R

/** Resolve category and duration labels only at the presentation boundary. */
internal object AppUsageLabels {
    fun duration(context: Context, seconds: Double): String {
        val value = AppUsageMath.duration(seconds)
        val minutes = value.minutes
        return when {
            value.lessThanMinute -> context.getString(R.string.usage_duration_under_minute)
            minutes == 0L -> context.getString(R.string.usage_duration_zero)
            minutes < 60 -> context.getString(R.string.usage_duration_minutes, minutes)
            minutes % 60 == 0L -> context.getString(R.string.usage_duration_hours, minutes / 60)
            else -> context.getString(R.string.usage_duration_hours_minutes, minutes / 60, minutes % 60)
        }
    }
    fun category(context: Context, kind: String) = context.getString(when (kind) {
        "rest" -> R.string.usage_rest
        "unrecorded" -> R.string.usage_unrecorded
        else -> R.string.usage_future
    })
    fun name(context: Context, segment: AppUsageSegment) = if (segment.kind == "app") segment.name else category(context, segment.kind)
    fun summary(context: Context, snapshot: AppUsageSnapshot?): String = when {
        snapshot == null -> context.getString(R.string.usage_summary_empty)
        !snapshot.enabled -> context.getString(R.string.usage_summary_disabled)
        else -> context.getString(R.string.usage_summary_synced, duration(context, snapshot.total))
    }
}
