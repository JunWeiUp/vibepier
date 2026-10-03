package io.github.junweiup.vibepier.remote.core.ui

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.LayerDrawable
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout

/**
 * The app's shared design language: a type scale, borderless surfaces and the few controls every screen reuses.
 * Primary choices are a segmented control; secondary filters are small chips, so the two never look alike.
 */
internal object Ui {
    const val TITLE = 18f
    const val HEADLINE = 16f
    const val BODY = 15f
    const val LABEL = 13f
    const val CAPTION = 12f
    const val OVERLINE = 11f
    val medium: Typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)

    enum class Button { PRIMARY, TONAL, TEXT }

    fun dp(context: Context, value: Int) = (value * context.resources.displayMetrics.density).toInt()

    fun roundRect(context: Context, color: Int, radius: Int, stroke: Int? = null) = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(context, radius).toFloat()
        if (stroke != null) setStroke(dp(context, 1), stroke)
    }

    /** Draws `drawable` smaller than its view, so a compact-looking control keeps a 48dp touch target. */
    fun inset(context: Context, drawable: Drawable, vertical: Int, horizontal: Int = 0) =
        InsetDrawable(drawable, dp(context, horizontal), dp(context, vertical), dp(context, horizontal), dp(context, vertical))

    fun label(context: Context, value: String, size: Float = BODY, color: Int = Palette.text) = CanvasLabel(context).apply {
        text = value; textSize = size; setTextColor(color)
    }

    fun overline(context: Context, value: String) = label(context, value, OVERLINE, Palette.faint).apply {
        typeface = Typeface.DEFAULT_BOLD; letterSpacing = .08f
    }

    fun button(context: Context, value: String, kind: Button = Button.TONAL, action: () -> Unit) = label(context, value, LABEL, when (kind) {
        Button.PRIMARY -> Palette.onAccent
        else -> Palette.accent
    }).apply {
        typeface = medium; gravity = Gravity.CENTER; minimumHeight = dp(context, 48)
        setPadding(dp(context, 14), dp(context, 8), dp(context, 14), dp(context, 8))
        background = when (kind) {
            Button.PRIMARY -> roundRect(context, Palette.accent, 12)
            Button.TONAL -> roundRect(context, Palette.surface3, 12)
            Button.TEXT -> null
        }
        isFocusable = true; setOnClickListener { action() }
    }

    /** A small tonal pill that still answers touches across a 48dp row. */
    fun pill(context: Context, value: String, color: Int = Palette.accent, action: () -> Unit) = label(context, value, CAPTION, color).apply {
        typeface = medium; gravity = Gravity.CENTER; minimumHeight = dp(context, 48)
        background = inset(context, roundRect(context, Palette.surface3, 14), 10)
        setPadding(dp(context, 12), 0, dp(context, 12), 0)
        isFocusable = true; setOnClickListener { action() }
    }

    /** First-level choice: an equal-width segmented control whose selected segment is a raised surface. */
    fun topTabs(context: Context, options: List<Pair<String, String>>, current: String, kind: String, select: (String) -> Unit) =
        segmented(context, options, current, kind, if (options.size > 2) LABEL else BODY, select = select)

    /**
     * A segmented control drawn inside a 48dp row. `height` is the visible track; the row keeps the full touch target.
     */
    fun segmented(context: Context, options: List<Pair<String, String>>, current: String, kind: String, size: Float = LABEL,
                  height: Int = 40, select: (String) -> Unit) = LinearLayout(context).apply {
        val gap = (48 - height).coerceAtLeast(0) / 2
        background = inset(context, roundRect(context, Palette.surface1, 12), gap)
        setPadding(dp(context, 3), dp(context, gap + 3), dp(context, 3), dp(context, gap + 3))
        minimumHeight = dp(context, 48)
        options.forEach { (id, name) ->
            val selected = id == current
            addView(label(context, name, size, if (selected) Palette.text else Palette.muted).apply {
                typeface = if (selected) Typeface.DEFAULT_BOLD else medium; gravity = Gravity.CENTER; maxLines = 1
                background = if (selected) roundRect(context, Palette.surface4, 9) else null
                setPadding(dp(context, 10), 0, dp(context, 10), 0)
                isFocusable = true
                contentDescription = if (selected) context.getString(R.string.choice_selected, name, kind) else context.getString(R.string.choice_switch, name, kind)
                setOnClickListener { if (!selected) select(id) }
            }, LinearLayout.LayoutParams(0, -1, 1f))
        }
    }

    /** Second-level choice: compact chips under the search field; the selected one is mint on a tinted container. */
    fun filterChips(context: Context, options: List<Pair<String, String>>, current: String, kind: String, select: (String) -> Unit) = LinearLayout(context).apply {
        gravity = Gravity.CENTER_VERTICAL
        options.forEach { (id, name) ->
            val selected = id == current
            addView(label(context, name, LABEL, if (selected) Palette.accent else Palette.muted).apply {
                typeface = if (selected) Typeface.DEFAULT_BOLD else medium; gravity = Gravity.CENTER; minimumHeight = dp(context, 48)
                background = inset(context, roundRect(context, if (selected) Palette.accentContainer else Palette.surface1, 10), 9)
                setPadding(dp(context, 14), 0, dp(context, 14), 0)
                isFocusable = true
                contentDescription = if (selected) context.getString(R.string.choice_selected, name, kind) else context.getString(R.string.choice_switch, name, kind)
                setOnClickListener { if (!selected) select(id) }
            }, LinearLayout.LayoutParams(-2, dp(context, 48)).apply { marginEnd = dp(context, 8) })
        }
    }

    /** A rounded tile carrying a line icon; settings rows and list rows use it to name their category at a glance. */
    fun iconBadge(context: Context, iconRes: Int, tint: Int, container: Int, size: Int = 30) = android.widget.ImageView(context).apply {
        setImageResource(iconRes); setColorFilter(tint)
        val pad = dp(context, size) / 5
        setPadding(pad, pad, pad, pad)
        background = roundRect(context, container, 9)
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun divider(context: Context, color: Int = Palette.outline) = View(context).apply { setBackgroundColor(color) }

    /** Rows sharing one rounded surface, separated by hairlines instead of each drawn as its own card. */
    fun listGroup(context: Context) = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = roundRect(context, Palette.surface1, 18)
        clipToOutline = true
        setPadding(0, dp(context, 1), 0, dp(context, 1))
    }

    fun addGroupRow(group: LinearLayout, row: View) {
        val context = group.context
        if (group.childCount > 0) group.addView(divider(context), LinearLayout.LayoutParams(-1, maxOf(1, dp(context, 1) / 2)).apply { marginStart = dp(context, 16) })
        group.addView(row, LinearLayout.LayoutParams(-1, -2))
    }

    /** The row marked as current: tinted, with a teal bar on its leading edge. */
    fun currentRowBackground(context: Context): Drawable = LayerDrawable(arrayOf(ColorDrawable(Palette.accentContainer), ColorDrawable(Palette.accent))).apply {
        setLayerGravity(1, Gravity.START or Gravity.FILL_VERTICAL)
        setLayerWidth(1, dp(context, 3))
    }
}
