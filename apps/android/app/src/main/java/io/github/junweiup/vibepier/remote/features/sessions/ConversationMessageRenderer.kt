package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.R
import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO
import android.widget.LinearLayout
import io.github.junweiup.vibepier.remote.core.session.SessionProvider
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.features.markdown.ChatMarkdownView
import io.github.junweiup.vibepier.remote.features.markdown.MarkdownFileLinks
import io.github.junweiup.vibepier.remote.features.remote.Palette
import org.json.JSONArray
import org.json.JSONObject

/** Renders a message from its content; page subscriptions and mutation state belong to ConversationPanel. */
internal class ConversationMessageRenderer(
    private val context: Context,
    private val provider: () -> String,
    private val inline: (JSONObject, JSONArray) -> View,
    private val images: (JSONArray) -> View,
    private val markdown: (MarkdownFileLinks.Link) -> Unit,
    private val expand: (JSONObject) -> Unit,
    private val scope: () -> ConversationRenderScope,
    private val active: () -> Boolean,
) {
    private fun dp(value: Int) = Ui.dp(context, value)
    private fun background(color: Int, radius: Int) = Ui.roundRect(context, color, radius)
    private fun row() = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
    private fun column() = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private fun label(value: String, size: Float, color: Int) = Ui.label(context, value, size, color)
    private fun button(value: String, action: () -> Unit) = Ui.button(context, value, Ui.Button.TONAL, action)
    /** The user's turns: a raised bubble whose tail corner points at the right edge. */
    fun userBubble() = GradientDrawable().apply {
        setColor(Palette.surface3)
        val r = dp(18).toFloat(); val tail = dp(6).toFloat()
        cornerRadii = floatArrayOf(r, r, r, r, tail, tail, r, r)
    }
    private class MessageView(context: Context) : LinearLayout(context) {
        var process: InlineReplyProcess? = null
        var user = false
    }
    private fun sequence(message: JSONObject): JSONArray? = message.optJSONArray("sequence") ?: message.optJSONArray("parts")?.let { entries ->
        JSONArray((0 until entries.length()).map { index -> JSONObject(entries.getJSONObject(index).toString()).apply {
            put("index", index); put("bodyVersion", "${optString("text").hashCode()}|${optString("status")}")
            if (optString("kind") !in setOf("text", "plan")) { remove("text"); put("bodyDeferred", true) }
        } })
    }
    /** Ordered replies update their existing process view rather than rebuilding the message bubble. */
    fun update(view: View, message: JSONObject): Boolean {
        val box = view as? MessageView ?: return false
        val process = box.process ?: return false
        if (box.user || message.optString("role") == "user") return false
        val sequence = sequence(message) ?: return false
        process.accept(sequence, message.optInt("partCount", sequence.length()))
        return true
    }
    fun render(message: JSONObject): View {
        val renderedScope = scope()
        val openMarkdown: (MarkdownFileLinks.Link) -> Unit = { if (active() && scope() == renderedScope) markdown(it) }
        val user = message.optString("role") == "user"
        val box = MessageView(context).apply {
            orientation = LinearLayout.VERTICAL; this.user = user
            if (user) background = userBubble()
            setPadding(dp(if (user) 14 else 4), dp(if (user) 10 else 4), dp(if (user) 14 else 4), dp(if (user) 12 else 4))
            // The bubble already says who wrote it; only the agent's replies carry a name line.
            if (user) contentDescription = context.getString(R.string.you)
            else addView(row().apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(label(SessionProvider.mark(provider()), 10f, Palette.background).apply {
                    gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD; background = background(Palette.text, 6)
                    importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
                }, LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginEnd = dp(8) })
                addView(label(SessionProvider.name(provider()), Ui.LABEL, Palette.muted).apply { typeface = Ui.medium })
            }, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(8) })
            val sequence = sequence(message)
            val ordered = !user && sequence != null
            if (ordered) addView(inline(message, sequence!!).also { process = it as? InlineReplyProcess }, LinearLayout.LayoutParams(-1, -2))
            else if (message.optString("text").isNotEmpty()) addView(ChatMarkdownView(context, openMarkdown, anyFile = true).apply { render(message.optString("text")) }, LinearLayout.LayoutParams(-1, -2))
            if (!ordered) message.optJSONArray("images")?.takeIf { it.length() > 0 }?.let {
                addView(images(it), LinearLayout.LayoutParams(-1, -2).apply { if (message.optString("text").isNotEmpty()) topMargin = dp(10) })
            }
            if (!ordered && message.optBoolean("hasMore")) addView(button(context.getString(R.string.expand_message)) { if (active() && scope() == renderedScope) expand(message) }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
            if (!user && !ordered && message.optString("status") == "running") addView(label(context.getString(R.string.provider_working, SessionProvider.name(provider())), Ui.CAPTION, Palette.amber), LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
        }
        box.layoutParams = LinearLayout.LayoutParams(if (user) -2 else -1, -2).apply {
            topMargin = dp(6); bottomMargin = dp(if (user) 12 else 18)
            if (user) { marginStart = dp(48); gravity = Gravity.END }
        }
        return box
    }
}
