package io.github.junweiup.vibepier.remote.core.ui

import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint

/** Small line icon in a 48dp touch target, with a spoken label instead of visible text. */
@android.annotation.SuppressLint("ViewConstructor") // Created in code with required model/callback arguments, never XML-inflated.
internal class IconControl(context: Context, private val icon: Icon, label: String, private val color: Int = Palette.muted, action: () -> Unit) : ControlView(context) {
    enum class Icon { CONTEXT, SESSIONS, REMOTE, SEARCH, REFRESH, CLOSE, MORE, BACK, SETTINGS, PLUS, FOLDER }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 1.7f; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
    init {
        val target = (48 * resources.displayMetrics.density).toInt()
        minimumWidth = target; minimumHeight = target
        contentDescription = label; isFocusable = true; isClickable = true
        tooltipText = label
        setOnClickListener { action() }
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        paint.color = color
        paint.alpha = if (isEnabled) 255 else 102
        val size = 22 * resources.displayMetrics.density
        canvas.save()
        canvas.translate((width - size) / 2, (height - size) / 2)
        canvas.scale(size / 24, size / 24)
        when (icon) {
            Icon.CONTEXT -> {
                canvas.drawArc(3f, 3f, 21f, 21f, -90f, 270f, false, paint)
                canvas.drawArc(7f, 7f, 17f, 17f, 0f, 270f, false, paint)
                canvas.drawLine(12f, 3f, 12f, 7f, paint)
                canvas.drawLine(17f, 12f, 21f, 12f, paint)
            }
            Icon.SESSIONS -> {
                canvas.drawRoundRect(3f, 3f, 18f, 15f, 3f, 3f, paint)
                canvas.drawLine(6f, 15f, 6f, 19f, paint)
                canvas.drawLine(6f, 19f, 10f, 15f, paint)
                canvas.drawLine(7f, 7f, 14f, 7f, paint)
                canvas.drawLine(7f, 11f, 12f, 11f, paint)
                canvas.drawLine(21f, 8f, 21f, 19f, paint)
                canvas.drawLine(21f, 19f, 16f, 19f, paint)
            }
            Icon.REMOTE -> {
                canvas.drawRoundRect(6f, 2f, 18f, 22f, 4f, 4f, paint)
                canvas.drawLine(9f, 9f, 15f, 9f, paint)
                canvas.drawLine(12f, 6f, 12f, 12f, paint)
                canvas.drawCircle(10f, 17f, 0.8f, paint)
                canvas.drawCircle(14f, 17f, 0.8f, paint)
            }
            Icon.SEARCH -> {
                canvas.drawCircle(11f, 11f, 6.5f, paint)
                canvas.drawLine(16f, 16f, 20.5f, 20.5f, paint)
            }
            Icon.REFRESH -> {
                // A circle open at the top right, with the arrowhead pointing the way the arc runs.
                canvas.drawArc(5f, 5f, 19f, 19f, 0f, 300f, false, paint)
                val end = Math.toRadians(300.0)
                val tipX = 12f + 7f * Math.cos(end).toFloat(); val tipY = 12f + 7f * Math.sin(end).toFloat()
                for (side in -1..1 step 2) {
                    val back = end - Math.PI / 2 + side * Math.toRadians(40.0)
                    canvas.drawLine(tipX, tipY, tipX + 3.5f * Math.cos(back).toFloat(), tipY + 3.5f * Math.sin(back).toFloat(), paint)
                }
            }
            Icon.CLOSE -> {
                canvas.drawLine(6f, 6f, 18f, 18f, paint)
                canvas.drawLine(18f, 6f, 6f, 18f, paint)
            }
            Icon.MORE -> {
                paint.style = Paint.Style.FILL
                for (x in 6..18 step 6) canvas.drawCircle(x.toFloat(), 12f, 1.4f, paint)
                paint.style = Paint.Style.STROKE
            }
            Icon.SETTINGS -> {
                canvas.drawLine(4f, 7f, 13f, 7f, paint); canvas.drawLine(17f, 7f, 20f, 7f, paint)
                canvas.drawLine(4f, 17f, 7f, 17f, paint); canvas.drawLine(11f, 17f, 20f, 17f, paint)
                canvas.drawCircle(15f, 7f, 2f, paint); canvas.drawCircle(9f, 17f, 2f, paint)
            }
            Icon.FOLDER -> {
                canvas.drawLine(3f, 8f, 3f, 18f, paint); canvas.drawLine(3f, 18f, 21f, 18f, paint); canvas.drawLine(21f, 18f, 21f, 9f, paint)
                canvas.drawLine(21f, 9f, 11f, 9f, paint); canvas.drawLine(11f, 9f, 9f, 6f, paint); canvas.drawLine(9f, 6f, 3f, 6f, paint)
                canvas.drawLine(3f, 6f, 3f, 8f, paint)
            }
            Icon.PLUS -> {
                canvas.drawLine(12f, 5f, 12f, 19f, paint)
                canvas.drawLine(5f, 12f, 19f, 12f, paint)
            }
            Icon.BACK -> {
                canvas.drawLine(15f, 5f, 8f, 12f, paint)
                canvas.drawLine(8f, 12f, 15f, 19f, paint)
            }
        }
        canvas.restore()
    }
}
