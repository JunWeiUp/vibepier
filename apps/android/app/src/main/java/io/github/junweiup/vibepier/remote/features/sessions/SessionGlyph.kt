package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.core.ui.ControlView
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

/** A session's state in the leading slot of a list row: a ring while running, "!" awaiting approval, a dot when open. */
@SuppressLint("ViewConstructor")
internal class SessionGlyph(context: Context, private val state: State) : ControlView(context) {
    enum class State { RUNNING, APPROVAL, CURRENT, IDLE }
    private val density = resources.displayMetrics.density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val box = RectF()
    private val arc = RectF()

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    override fun onDraw(canvas: Canvas) {
        box.set(0f, 0f, width.toFloat(), height.toFloat())
        paint.style = Paint.Style.FILL
        paint.color = when (state) {
            State.RUNNING -> Palette.accentContainer
            State.APPROVAL -> Palette.amberContainer
            else -> Palette.surface2
        }
        canvas.drawRoundRect(box, 9 * density, 9 * density, paint)
        val cx = width / 2f; val cy = height / 2f
        when (state) {
            State.RUNNING -> {
                paint.style = Paint.Style.STROKE; paint.strokeWidth = 2 * density; paint.strokeCap = Paint.Cap.ROUND
                val r = 6 * density
                paint.color = Palette.outlineStrong
                canvas.drawCircle(cx, cy, r, paint)
                paint.color = Palette.accent
                arc.set(cx - r, cy - r, cx + r, cy + r)
                canvas.drawArc(arc, -90f, 110f, false, paint)
            }
            State.APPROVAL -> {
                paint.color = Palette.amber
                paint.strokeWidth = 2 * density; paint.strokeCap = Paint.Cap.ROUND; paint.style = Paint.Style.STROKE
                canvas.drawLine(cx, cy - 6 * density, cx, cy + 1.5f * density, paint)
                paint.style = Paint.Style.FILL
                canvas.drawCircle(cx, cy + 5.5f * density, 1.3f * density, paint)
            }
            State.CURRENT -> { paint.color = Palette.accent; canvas.drawCircle(cx, cy, 3.5f * density, paint) }
            State.IDLE -> {}
        }
    }
}
