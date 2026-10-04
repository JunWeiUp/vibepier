package io.github.junweiup.vibepier.remote.features.sessions

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.features.markdown.ChatMarkdownView
import io.github.junweiup.vibepier.remote.features.markdown.MarkdownFileLinks
import io.github.junweiup.vibepier.remote.features.remote.Palette
import org.json.JSONArray
import org.json.JSONObject

/** Presentation factories only; provider actions and their receipts stay with the panel. */
internal class ConversationTimelineContent(private val context: Context,
    private val renderer: ConversationMessageRenderer, private val providerName: () -> String,
    private val openFile: (MarkdownFileLinks.Link) -> Unit, private val onApproval: (JSONObject) -> Unit,
    private val scope: () -> ConversationRenderScope, private val activeView: () -> Boolean) {
    data class Pending(val text: String, val at: Long)
    private fun dp(value: Int) = Ui.dp(context, value)
    private fun column() = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private fun label(value: String, size: Float, color: Int = Palette.text) = Ui.label(context, value, size, color)

    fun rows(messages: JSONArray, approvals: JSONArray, pending: List<Pending>, active: Boolean,
             hasOlder: Boolean, loadingHistory: Boolean, changes: View): List<ConversationTimeline.Row> = buildList {
        val renderedScope = scope()
        val current = { activeView() && scope() == renderedScope }
        if (hasOlder) add(ConversationTimeline.Row("older", loadingHistory.toString(), {
            label(context.getString(if (loadingHistory) R.string.session_loading_earlier_messages else R.string.session_pull_down_for_earlier_messages), Ui.CAPTION, Palette.faint)
                .apply { gravity = Gravity.CENTER; setPadding(0, dp(8), 0, dp(8)); layoutParams = LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(12) } }
        }))
        for (index in 0 until messages.length()) {
            val message = messages.getJSONObject(index)
            add(ConversationTimeline.Row("message:${message.optString("id")}", message.toString(),
                { renderer.render(message) }, { renderer.update(it, message) }))
        }
        pending.forEach { item -> add(ConversationTimeline.Row("pending:${item.at}", "$active:${item.text}", { pendingView(item, active, current) })) }
        add(ConversationTimeline.Row("changes", "", { changes }))
        for (index in 0 until approvals.length()) {
            val item = approvals.getJSONObject(index)
            add(ConversationTimeline.Row("approval:${item.optString("id")}:${item.optString("fingerprint")}", item.toString(), { approvalView(item, current) }))
        }
        if (messages.length() == 0 && approvals.length() == 0 && pending.isEmpty()) add(ConversationTimeline.Row("empty", "", {
            label(context.getString(R.string.session_no_messages_to_display_in_this_session_yet), Ui.BODY, Palette.muted)
        }))
    }
    private fun pendingView(item: Pending, active: Boolean, current: () -> Boolean) = column().apply {
        background = renderer.userBubble(); setPadding(dp(14), dp(10), dp(14), dp(12))
        addView(label(context.getString(if (active) R.string.session_you_delivered_appears_after_the_current_task_finishes else R.string.session_you_sent_waiting_for_the_session_to_display_it), Ui.LABEL, Palette.faint).apply { typeface = Ui.medium },
            LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(8) })
        addView(ChatMarkdownView(context, { if (current()) openFile(it) }, anyFile = true).apply { render(item.text) }, LinearLayout.LayoutParams(-1, -2))
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6); bottomMargin = dp(12); marginStart = dp(48) }
    }
    private fun approvalView(item: JSONObject, current: () -> Boolean) = column().apply {
        background = Ui.roundRect(context, Palette.amberContainer, 16); setPadding(dp(14), dp(13), dp(14), dp(14))
        addView(label(context.getString(R.string.session_provider_needs_approval, providerName()), Ui.LABEL, Palette.amber).apply { typeface = Typeface.DEFAULT_BOLD })
        addView(label(item.optString("title"), Ui.BODY).apply { maxLines = 4; ellipsize = android.text.TextUtils.TruncateAt.END },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
        val canDecide = item.optBoolean("canDecide")
        val text = context.getString(if (canDecide) (if (item.optString("kind") == "questions") R.string.session_answer_questions else R.string.session_review_request) else R.string.session_view_details_handle_on_mac)
        addView(Ui.button(context, text, if (canDecide) Ui.Button.PRIMARY else Ui.Button.TONAL) { if (current()) onApproval(item) }.apply {
            background = Ui.roundRect(context, if (canDecide) Palette.amber else Palette.surface3, 12)
            if (canDecide) setTextColor(Color.rgb(42, 29, 7))
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12) })
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10); bottomMargin = dp(12) }
    }
}
