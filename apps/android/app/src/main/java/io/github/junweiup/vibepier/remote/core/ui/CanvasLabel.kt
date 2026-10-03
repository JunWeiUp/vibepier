package io.github.junweiup.vibepier.remote.core.ui

import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.content.Context
import android.graphics.Canvas
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.view.Gravity
import kotlin.math.ceil

/** Display-only text drawn by a plain View: no selection, editor or text actions. */
class CanvasLabel(context: Context) : ControlView(context) {
    private val paint = TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply {
        color = Palette.text
        textSize = 14f * resources.displayMetrics.scaledDensity
    }
    private var layout: StaticLayout? = null
    var text: CharSequence = ""
        set(value) {
            field = value
            contentDescription = value
            refresh()
        }
    var textSize: Float = 14f
        set(value) { field = value; paint.textSize = value * resources.displayMetrics.scaledDensity; refresh() }
    var typeface: Typeface? = Typeface.DEFAULT
        set(value) { field = value; paint.typeface = value; refresh() }
    var letterSpacing: Float = 0f
        set(value) { field = value; paint.letterSpacing = value; refresh() }
    var lineSpacingExtra: Float = 0f
        set(value) { field = value; refresh() }
    var maxLines: Int = Int.MAX_VALUE
        set(value) { field = value.coerceAtLeast(1); refresh() }
    var ellipsize: TextUtils.TruncateAt? = null
        set(value) { field = value; refresh() }
    var gravity: Int = Gravity.TOP or Gravity.START
        set(value) { field = value; refresh() }

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    fun setTextColor(color: Int) { paint.color = color; invalidate() }
    private fun refresh() { requestLayout(); invalidate() }

    @android.annotation.SuppressLint("RtlHardcoded") // Compare absolute gravity only after resolving START/END for the current layout direction.
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val desiredWidth = ceil(Layout.getDesiredWidth(text, paint).toDouble()).toInt() + paddingLeft + paddingRight
        val w = resolveSize(desiredWidth.coerceAtLeast(suggestedMinimumWidth), widthMeasureSpec)
        val available = (w - paddingLeft - paddingRight).coerceAtLeast(1)
        val alignment = when (Gravity.getAbsoluteGravity(gravity, layoutDirection) and Gravity.HORIZONTAL_GRAVITY_MASK) {
            Gravity.CENTER_HORIZONTAL -> Layout.Alignment.ALIGN_CENTER
            Gravity.RIGHT -> Layout.Alignment.ALIGN_OPPOSITE
            else -> Layout.Alignment.ALIGN_NORMAL
        }
        layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, available)
            .setAlignment(alignment)
            .setIncludePad(true)
            .setLineSpacing(lineSpacingExtra * resources.displayMetrics.density, 1f)
            .setMaxLines(maxLines)
            .setEllipsize(ellipsize)
            .setEllipsizedWidth(available)
            .build()
        val h = (layout?.height ?: 0) + paddingTop + paddingBottom
        setMeasuredDimension(w, resolveSize(h.coerceAtLeast(suggestedMinimumHeight), heightMeasureSpec))
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val lines = layout ?: return
        val space = (height - paddingTop - paddingBottom - lines.height).coerceAtLeast(0)
        val offset = when (gravity and Gravity.VERTICAL_GRAVITY_MASK) {
            Gravity.CENTER_VERTICAL -> space / 2
            Gravity.BOTTOM -> space
            else -> 0
        }
        canvas.save()
        canvas.clipRect(paddingLeft, paddingTop, width - paddingRight, height - paddingBottom)
        canvas.translate(paddingLeft.toFloat(), (paddingTop + offset).toFloat())
        lines.draw(canvas)
        canvas.restore()
    }
}
