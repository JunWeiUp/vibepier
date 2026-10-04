package io.github.junweiup.vibepier.remote.features.settings

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.IconControl
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.protectControls
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.app.AlertDialog
import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView

/**
 * Settings as a full page of grouped rows. Two- and three-way choices switch in place with a segmented control;
 * everything else opens its own dialog on top, and summaries follow live connection and preference changes.
 */
internal class SettingsSheet(private val context: Context) {
    private val updates = mutableListOf<() -> Unit>()
    private val body = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(2), dp(16), dp(24))
    }
    private var dialog: AlertDialog? = null
    val isShowing get() = dialog?.isShowing == true
    private fun dp(value: Int) = Ui.dp(context, value)
    private val inlineChoices = context.resources.configuration.fontScale <= 1.15f && context.resources.configuration.screenWidthDp >= 360

    /** A row's category: a line icon on a tinted tile. */
    data class Badge(val icon: Int, val tint: Int = Palette.muted, val container: Int = Palette.surface3)

    sealed class Item(val title: String, val summary: () -> String, val badge: Badge)
    class Row(title: String, summary: () -> String, badge: Badge, val action: () -> Unit) : Item(title, summary, badge)
    class Choice(title: String, summary: () -> String, badge: Badge, val options: List<Pair<String, String>>,
                 val current: () -> String, val select: (String) -> Unit) : Item(title, summary, badge)

    fun section(title: String, items: List<Item>) {
        body.addView(Ui.label(context, title, Ui.CAPTION, Palette.faint).apply { typeface = Typeface.DEFAULT_BOLD },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(18); bottomMargin = dp(8); marginStart = dp(6) })
        val group = Ui.listGroup(context)
        items.forEach { item -> Ui.addGroupRow(group, row(item)) }
        body.addView(group, LinearLayout.LayoutParams(-1, -2))
    }

    fun versionFooter(label: () -> String, updateAvailable: () -> Boolean, action: () -> Unit) {
        val dot = View(context).apply {
            background = Ui.roundRect(context, 0xFFE45B65.toInt(), 4)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        val text = Ui.label(context, "", Ui.CAPTION, Palette.muted).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        val footer = LinearLayout(context).apply {
            gravity = Gravity.CENTER; minimumHeight = dp(64); isFocusable = true
            addView(dot, LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginEnd = dp(8) })
            addView(text)
            setOnClickListener { action() }
        }
        body.addView(footer, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(20) })
        updates += {
            val value = label()
            if (text.text.toString() != value) text.text = value
            dot.visibility = if (updateAvailable()) View.VISIBLE else View.GONE
            if (footer.contentDescription != value) footer.contentDescription = value
        }
    }

    private fun row(item: Item): View {
        val summary = Ui.label(context, "", Ui.CAPTION, Palette.muted).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        val text = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(Ui.label(context, item.title).apply { typeface = Ui.medium; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO })
            addView(summary, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(2) })
        }
        val line = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            addView(Ui.iconBadge(context, item.badge.icon, item.badge.tint, item.badge.container), LinearLayout.LayoutParams(dp(30), dp(30)).apply { marginEnd = dp(12) })
            addView(text, LinearLayout.LayoutParams(0, -2, 1f))
        }
        val container = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            minimumHeight = dp(64)
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(10), dp(12), dp(10))
            addView(line, LinearLayout.LayoutParams(-1, -2))
        }
        when (item) {
            is Row -> {
                container.isFocusable = true
                container.background = context.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).let {
                    val drawable = it.getDrawable(0); it.recycle(); drawable
                }
                line.addView(Ui.label(context, "›", 20f, Palette.faint).apply {
                    gravity = Gravity.CENTER; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }, LinearLayout.LayoutParams(dp(20), -2))
                container.setOnClickListener { item.action() }
                updates += {
                    val value = item.summary()
                    if (summary.text.toString() != value) summary.text = value
                    val description = context.getString(R.string.setting_open_description, item.title, value)
                    if (container.contentDescription != description) container.contentDescription = description
                }
            }
            is Choice -> {
                val holder = FrameLayout(context)
                if (inlineChoices) line.addView(holder, LinearLayout.LayoutParams(dp(56) * item.options.size, dp(48)).apply { marginStart = dp(8) })
                else container.addView(holder, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(6) })
                val choices = Ui.segmented(context, item.options, item.current(), item.title, Ui.CAPTION, 34) { item.select(it) }
                holder.addView(choices, FrameLayout.LayoutParams(-1, -1))
                item.options.forEachIndexed { index, (id, _) ->
                    choices.getChildAt(index).setOnClickListener { if (item.current() != id) item.select(id) }
                }
                var renderedChoice: String? = null
                updates += {
                    val value = item.summary()
                    if (summary.text.toString() != value) summary.text = value
                    val current = item.current()
                    if (renderedChoice != current) {
                        renderedChoice = current
                        item.options.forEachIndexed { index, (id, name) ->
                            val selected = id == current
                            (choices.getChildAt(index) as CanvasLabel).apply {
                                isSelected = selected
                                typeface = if (selected) Typeface.DEFAULT_BOLD else Ui.medium
                                setTextColor(if (selected) Palette.text else Palette.muted)
                                background = if (selected) Ui.roundRect(context, Palette.surface4, 9) else null
                                contentDescription = context.getString(if (selected) R.string.choice_selected else R.string.choice_switch, name, item.title)
                            }
                        }
                    }
                }
            }
        }
        return container
    }

    fun show(onDismiss: () -> Unit) {
        refresh()
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Palette.background)
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(6), dp(8), dp(16), dp(4))
                addView(IconControl(context, IconControl.Icon.BACK, context.getString(R.string.back_to_remote), Palette.text) { dismiss() }, LinearLayout.LayoutParams(dp(48), dp(48)))
                addView(Ui.label(context, context.getString(R.string.settings_title), 22f).apply { typeface = Typeface.DEFAULT_BOLD }, LinearLayout.LayoutParams(0, -2, 1f))
            }, LinearLayout.LayoutParams(-1, -2))
            addView(ScrollView(context).apply { isFillViewport = false; addView(body) }, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog)
            .setView(root)
            .create().apply {
                setOnDismissListener { updates.clear(); onDismiss() }
                window?.protectControls()
                show()
                window?.apply {
                    setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Palette.background))
                    setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                }
            }
    }

    fun refresh() = updates.forEach { it() }
    fun dismiss() { dialog?.dismiss() }
}
