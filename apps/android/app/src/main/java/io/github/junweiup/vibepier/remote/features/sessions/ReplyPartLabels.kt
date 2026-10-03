package io.github.junweiup.vibepier.remote.features.sessions

import android.content.Context
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.session.ReplyPartGrouping

/** Translate presentation only; tool identity, grouping boundaries and cached anchors stay language independent. */
internal object ReplyPartLabels {
    private val captions = mapOf(
        "file-read" to R.string.group_file_read, "file-search" to R.string.group_file_search,
        "web-search" to R.string.group_web_search, "web-fetch" to R.string.group_web_fetch,
        "agent" to R.string.group_agent, "image-view" to R.string.group_image_view,
        "image-generation" to R.string.group_image_generation, "attachment" to R.string.group_attachment,
    )
    fun title(context: Context, entries: List<ReplyPartGrouping.Entry>): String {
        val summary = ReplyPartGrouping.summary(entries)
        val resource = when (summary.kind) {
            "command" -> R.plurals.group_commands
            "file-edit" -> R.plurals.group_edits
            "thinking" -> R.plurals.group_thoughts
            "notice" -> R.plurals.group_notices
            else -> null
        }
        if (resource != null) return context.resources.getQuantityString(resource, summary.count, summary.count)
        captions[summary.kind]?.let { return context.getString(R.string.group_action_count, context.getString(it), summary.count) }
        val name = summary.name.ifBlank { context.getString(R.string.tool_call) }
        return context.resources.getQuantityString(R.plurals.group_named_calls, summary.count, name, summary.count)
    }
    fun statusLabels(context: Context, entries: List<ReplyPartGrouping.Entry>): List<Pair<String, String>> =
        ReplyPartGrouping.statusCounts(entries).map { (status, count) ->
            val label = when (status) {
                "running" -> context.getString(R.string.running)
                "failed" -> context.resources.getQuantityString(R.plurals.group_failed, count, count)
                "declined" -> context.resources.getQuantityString(R.plurals.group_not_run, count, count)
                else -> "✓"
            }
            label to status
        }
}
