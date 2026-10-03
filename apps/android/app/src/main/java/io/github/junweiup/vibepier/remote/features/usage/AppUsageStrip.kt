package io.github.junweiup.vibepier.remote.features.usage

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import java.time.LocalDate
import java.time.ZoneId

/** Each fragment occupies its observed time; repeated visits keep separate positions. */
@android.annotation.SuppressLint("ViewConstructor") // Created in code with required model/callback arguments, never XML-inflated.
internal class AppUsageStrip(context: Context, private val snapshot: AppUsageSnapshot,
    private val preview: (AppUsageTimeRange) -> Unit, private val select: (AppUsageTimeRange) -> Unit) : View(context) {
    private val ranges = snapshot.timeline.orEmpty()
    private val dayMillis = snapshot.daySeconds * 1000
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val box = RectF()
    private val clip = Path()
    private val futureDash = DashPathEffect(floatArrayOf(dp(3), dp(3)), 0f)
    private data class Tick(val hour: Int, val fraction: Double, val label: String)
    private val appColors = snapshot.apps.associate { app -> app.id to runCatching { Color.parseColor(app.color) }.getOrDefault(Palette.muted) }
    private var selectedID = ""
    private var touched = -1
    private val ticks = (0..24 step 6).map { hour ->
        val date = LocalDate.parse(snapshot.date)
        val instant = if (hour == 24) date.plusDays(1).atStartOfDay(ZoneId.of(snapshot.timeZone))
            else date.atTime(hour, 0).atZone(ZoneId.of(snapshot.timeZone))
        Tick(hour, (instant.toInstant().toEpochMilli() - snapshot.dayStart) / dayMillis, String.format(java.util.Locale.ROOT, "%02d:00", hour))
    }
    private var labeledTicks = ticks
    private fun dp(v: Int) = Ui.dp(context, v).toFloat()
    private fun position(time: Long) = ((time - snapshot.dayStart) / dayMillis * width).toFloat()
    private fun name(range: AppUsageTimeRange) = when (range.kind) {
        "app" -> snapshot.apps.firstOrNull { it.id == range.id }?.name ?: range.id
        else -> AppUsageLabels.category(context, range.kind)
    }
    init {
        minimumHeight = Ui.dp(context, 84)
        isFocusable = true
        contentDescription = context.getString(R.string.usage_timeline_description, ranges.take(100).joinToString("; ") {
            context.getString(R.string.usage_interval_description, name(it), snapshot.timeRange(it), AppUsageLabels.duration(context, it.seconds))
        })
        setOnClickListener { if (touched >= 0) select(ranges[touched]) }
    }
    fun highlight(id: String) { selectedID = id; invalidate() }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        paint.textSize = 11 * resources.displayMetrics.scaledDensity
        fun fits(values: List<Tick>): Boolean {
            var right = -dp(6)
            for (tick in values) {
                val x = (tick.fraction * w).toFloat()
                val size = paint.measureText(tick.label)
                val left = when (tick.hour) { 0 -> x; 24 -> x - size; else -> x - size / 2 }
                if (left < right + dp(6)) return false
                right = left + size
            }
            return true
        }
        // Preserve the real timeline and boundary marks; reduce labels when large text overlaps.
        val major = ticks.filter { it.hour % 12 == 0 }
        labeledTicks = when { fits(ticks) -> ticks; fits(major) -> major; else -> ticks.filter { it.hour == 0 || it.hour == 24 } }
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        box.set(0f, dp(1), width.toFloat(), dp(53))
        clip.reset(); clip.addRoundRect(box, dp(7), dp(7), Path.Direction.CW)
        canvas.save(); canvas.clipPath(clip)
        ranges.forEachIndexed { index, range ->
            val left = position(range.start); val right = position(range.end)
            paint.style = Paint.Style.FILL; paint.pathEffect = null
            val color = when (range.kind) {
                "app" -> appColors[range.id] ?: 0xff56615b.toInt()
                "rest" -> 0xff667369.toInt()
                "unrecorded" -> 0xff56615b.toInt()
                else -> 0xff161d19.toInt()
            }
            paint.color = color
            canvas.drawRect(left, box.top, right, box.bottom, paint)
            if (range.kind == "unrecorded") {
                canvas.save(); canvas.clipRect(left, box.top, right, box.bottom)
                paint.color = Palette.faint; paint.strokeWidth = dp(2)
                var x = left - box.height()
                while (x < right) { canvas.drawLine(x, box.bottom, x + box.height(), box.top, paint); x += dp(7) }
                canvas.restore()
            }
            if (range.kind == "future") {
                paint.color = Palette.muted; paint.style = Paint.Style.STROKE; paint.strokeWidth = dp(1)
                paint.pathEffect = futureDash
                canvas.drawRect(left, box.top + dp(1), right - dp(1), box.bottom - dp(1), paint)
            }
            if ((range.kind == "app" && range.id == selectedID) || index == touched) {
                paint.pathEffect = null; paint.style = Paint.Style.STROKE; paint.strokeWidth = dp(2); paint.color = Palette.text
                if (right - left >= dp(2)) canvas.drawRect(left + dp(1), box.top + dp(1), right - dp(1), box.bottom - dp(1), paint)
            }
        }
        canvas.restore(); paint.pathEffect = null
        ticks.forEach { (_, fraction, _) ->
            val x = (fraction * width).toFloat()
            paint.style = Paint.Style.STROKE; paint.color = Palette.faint; paint.strokeWidth = dp(1)
            canvas.drawLine(x.coerceIn(dp(1), width - dp(1)), box.bottom + dp(3), x.coerceIn(dp(1), width - dp(1)), box.bottom + dp(7), paint)
        }
        labeledTicks.forEach { (hour, fraction, label) ->
            val x = (fraction * width).toFloat()
            paint.style = Paint.Style.FILL
            paint.textSize = 11 * resources.displayMetrics.scaledDensity
            paint.textAlign = when (hour) { 0 -> Paint.Align.LEFT; 24 -> Paint.Align.RIGHT; else -> Paint.Align.CENTER }
            canvas.drawText(label, x, box.bottom + dp(10) - paint.ascent(), paint)
        }
    }
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                if (width <= 0) return false
                if (event.actionMasked == MotionEvent.ACTION_DOWN && event.y > dp(54)) return false
                parent.requestDisallowInterceptTouchEvent(true)
                val timestamp = snapshot.dayStart + ((event.x / width).coerceIn(0f, .999999f) * dayMillis).toLong()
                touched = ranges.indexOfFirst { timestamp >= it.start && timestamp < it.end }
                if (touched >= 0) preview(ranges[touched])
                invalidate(); return true
            }
            MotionEvent.ACTION_UP -> { parent.requestDisallowInterceptTouchEvent(false); performClick(); return true }
            MotionEvent.ACTION_CANCEL -> { parent.requestDisallowInterceptTouchEvent(false); touched = -1; invalidate(); return true }
        }
        return true
    }
    override fun performClick(): Boolean { super.performClick(); return true }
}
