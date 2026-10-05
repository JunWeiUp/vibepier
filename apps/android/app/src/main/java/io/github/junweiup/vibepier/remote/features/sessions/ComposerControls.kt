package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.IconControl
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.LinearLayout

/** Stable model/settings toolbar with a separately labelled submit action. */
@android.annotation.SuppressLint("ViewConstructor") // Created in code with required model/callback arguments, never XML-inflated.
internal class ComposerControls(context: Context, editor: EditText, onAdd: () -> Unit, onMode: () -> Unit, onModel: () -> Unit, onSend: () -> Unit, onContext: () -> Unit, onExecution: () -> Unit = {}) : LinearLayout(context) {
    val attachments = LinearLayout(context).apply { orientation = HORIZONTAL }
    val attachmentScroll = HorizontalScrollView(context).apply { isHorizontalScrollBarEnabled = false; addView(attachments); visibility = GONE }
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun action(text: String, click: () -> Unit) = CanvasLabel(context).apply {
        this.text = text; textSize = 12f; gravity = Gravity.CENTER; minimumHeight = dp(48); maxLines = 1; ellipsize = TextUtils.TruncateAt.END
        setPadding(dp(7), dp(4), dp(7), dp(4)); setTextColor(Palette.muted); isFocusable = true; setOnClickListener { click() }
    }
    val add = action("＋", onAdd).apply { textSize = 24f; setPadding(0, 0, 0, 0); ellipsize = null; contentDescription = context.getString(R.string.composer_add_description) }
    private fun chip(text: String, click: () -> Unit) = action(text, click).apply {
        setTextColor(Palette.text); textSize = Ui.CAPTION; typeface = Ui.medium
        background = Ui.inset(context, Ui.roundRect(context, Palette.surface3, 10), 8, 2); setPadding(dp(12), 0, dp(12), 0)
    }
    val mode = chip(context.getString(R.string.approval_mode), onMode)
    val execution = chip(context.getString(R.string.session_execution_mode), onExecution).apply { visibility = GONE }
    val contextUsage = IconControl(context, IconControl.Icon.CONTEXT, context.getString(R.string.context_usage_description), action = onContext).apply { visibility = GONE }
    val model = chip(context.getString(R.string.choose_model), onModel)
    val send = action(context.getString(R.string.conversation_send), onSend).apply {
        textSize = Ui.LABEL; typeface = Ui.medium; setTextColor(Palette.onAccent)
        background = GradientDrawable().apply { setColor(Palette.accent); cornerRadius = dp(13).toFloat() }
    }
    init {
        orientation = VERTICAL; setPadding(dp(8), dp(8), dp(8), dp(8))
        background = GradientDrawable().apply { setColor(Palette.surface1); cornerRadius = dp(22).toFloat() }
        editor.background = null; editor.setPadding(dp(8), dp(6), dp(8), dp(8)); editor.minimumHeight = dp(48)
        addView(editor, LayoutParams(-1, -2))
        addView(attachmentScroll, LayoutParams(-1, -2).apply { bottomMargin = dp(4) })
        addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            addView(execution, LayoutParams(dp(88), dp(48)))
            addView(mode, LayoutParams(dp(106), dp(48)))
            addView(model, LayoutParams(0, dp(48), 1f))
        }, LayoutParams(-1, -2))
        addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            addView(add, LayoutParams(dp(48), dp(48)))
            addView(contextUsage, LayoutParams(dp(48), dp(48)))
            addView(View(context), LayoutParams(0, 1, 1f))
            addView(send, LayoutParams(dp(112), dp(48)).apply { marginStart = dp(4) })
        }, LayoutParams(-1, -2))
    }
}
