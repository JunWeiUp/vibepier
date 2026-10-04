package io.github.junweiup.vibepier.remote.features.remote

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.ControlView

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.animation.LinearInterpolator
import kotlin.math.min

/**
 * Graphite surfaces separated by lightness rather than outlines; mint marks only the primary action, live work and the
 * current selection, while amber (approval) and coral (stop/error) sit on low-saturation tinted containers.
 */
object Palette {
    val background = Color.rgb(15, 20, 22)
    val surface1 = Color.rgb(22, 28, 31)
    val surface2 = Color.rgb(28, 36, 39)
    val surface3 = Color.rgb(36, 45, 49)
    val surface4 = Color.rgb(45, 55, 60)
    val outline = Color.rgb(35, 43, 47)
    val outlineStrong = Color.rgb(58, 70, 76)
    val text = Color.rgb(233, 238, 240)
    val muted = Color.rgb(163, 175, 180)
    val faint = Color.rgb(127, 140, 146)
    val accent = Color.rgb(114, 212, 185)
    val onAccent = Color.rgb(14, 42, 35)
    val accentContainer = Color.rgb(27, 46, 43)
    val red = Color.rgb(232, 131, 124)
    val redContainer = Color.rgb(41, 33, 34)
    val amber = Color.rgb(232, 184, 111)
    val amberContainer = Color.rgb(43, 41, 34)
    val blue = Color.rgb(134, 180, 238)
    val blueContainer = Color.rgb(30, 40, 50)
    val violet = Color.rgb(183, 162, 238)
    val violetContainer = Color.rgb(36, 36, 48)
    val surface get() = surface1
    val surfaceTop get() = surface3
    val green get() = accent
}

private fun withAlpha(color: Int, alpha: Float) =
    Color.argb((alpha * 255).toInt(), Color.red(color), Color.green(color), Color.blue(color))

/**
 * A key drawn like a hardware button: an icon, a caption, the Mac key it is bound
 * to, and an accent colour that lights the key while it is held. It reports press
 * and release, so the owner decides what to send. While editing, a tap asks the
 * owner to change the binding instead.
 */
@SuppressLint("ViewConstructor")
open class Pad(
    context: Context,
    iconRes: Int,
    var label: String,
    private val accent: Int,
    private val compact: Boolean = false,
) : ControlView(context) {
    var onPress: () -> Unit = {}
    var onRelease: () -> Unit = {}
    var onEdit: () -> Unit = {}

    /** The bound hotkey, shown on the key cap. */
    var binding = ""
        set(v) { field = v; bindingLabel = KeyLabels.label(context, v); contentDescription = context.getString(R.string.control_binding_description, label, bindingLabel); invalidate() }
    protected var bindingLabel = ""
        private set
    private val customSuffix = context.getString(R.string.custom_binding_suffix)
    var editing = false
        set(v) { field = v; invalidate() }
    /** The binding belongs to the current application rather than the shared profile; its key cap is tinted. */
    var custom = false
        set(v) { field = v; invalidate() }

    protected val density = resources.displayMetrics.density
    protected val fontScale = resources.displayMetrics.scaledDensity
    private val gesture = PressGesture()
    protected val icon = context.getDrawable(iconRes)!!.mutate()
    protected var held = false
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = density }
    protected val caption = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 14 * fontScale
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
    private val chipText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 11 * fontScale
        textAlign = Paint.Align.CENTER
        typeface = Typeface.MONOSPACE
    }
    private val chipFill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val chipRect = RectF()
    protected val editStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * density
        pathEffect = DashPathEffect(floatArrayOf(6 * density, 4 * density), 0f)
    }
    private val rect = RectF()

    init {
        isHapticFeedbackEnabled = true
        isClickable = true
        isFocusable = true
        isLongClickable = false
    }

    override fun onDraw(canvas: Canvas) {
        rect.set(0f, 0f, width.toFloat(), height.toFloat())
        val radius = (if (compact) 14 else 20) * density
        fill.shader = null
        fill.color = if (compact) Palette.surface3 else Palette.surface1
        canvas.drawRoundRect(rect, radius, radius, fill)
        if (held) { fill.color = withAlpha(accent, 0.16f); canvas.drawRoundRect(rect, radius, radius, fill) }
        if (editing) {
            editStroke.color = accent
            canvas.drawRoundRect(rect, radius, radius, editStroke)
        } else if (isFocused) {
            stroke.color = accent
            canvas.drawRoundRect(rect, radius, radius, stroke)
        }

        if (compact) {
            // The fixed Delete target uses one icon and its action label; a duplicate key cap crowds large text.
            val size = (18 * density).toInt()
            val gap = 10 * density
            val groupWidth = size + gap + caption.measureText(label)
            val left = ((width - groupWidth) / 2).coerceAtLeast(8 * density)
            val top = (height - size) / 2
            icon.setBounds(left.toInt(), top, left.toInt() + size, top + size)
            icon.setTint(if (held) accent else Palette.muted)
            icon.draw(canvas)
            caption.color = Palette.text
            caption.textAlign = Paint.Align.LEFT
            canvas.drawText(label, left + size + gap, height / 2f - (caption.ascent() + caption.descent()) / 2, caption)
            caption.textAlign = Paint.Align.CENTER
            return
        }
        val size = (22 * density).toInt()
        val left = (16 * density).toInt()
        val top = (16 * density).toInt()
        icon.setBounds(left, top, left + size, top + size)
        icon.setTint(if (held) accent else Palette.muted)
        icon.draw(canvas)
        caption.color = if (held) accent else Palette.text
        caption.textAlign = Paint.Align.LEFT
        canvas.drawText(label, 47 * density, top + size / 2f - (caption.ascent() + caption.descent()) / 2, caption)
        caption.textAlign = Paint.Align.CENTER
        drawBinding(canvas, 16 * density, height - 14 * density - chipHeight(), accent, width - 32 * density, alignStart = true)
    }

    private fun chipHeight() = maxOf(20 * density, chipText.fontSpacing + 4 * density)
    protected fun bindingWidth() = if (binding.isEmpty()) 0f else chipText.measureText(bindingLabel) + 16 * density

    /** The binding as a small key cap whose top edge is at `top`, centred on `x` or starting there. */
    protected fun drawBinding(canvas: Canvas, x: Float, top: Float, accent: Int, maxWidth: Float = Float.POSITIVE_INFINITY, alignStart: Boolean = false, onPrimary: Boolean = false) {
        if (binding.isEmpty()) return
        var text = bindingLabel + if (custom && alignStart) customSuffix else ""
        if (chipText.measureText(text) + 16 * density > maxWidth) {
            val count = chipText.breakText(text, true, (maxWidth - 16 * density - chipText.measureText("…")).coerceAtLeast(0f), null)
            text = text.take(count) + "…"
        }
        val w = chipText.measureText(text) + 16 * density
        val left = if (alignStart) x else x - w / 2
        chipRect.set(left, top, left + w, top + chipHeight())
        val tinted = onPrimary || editing || held || custom
        // An app-specific binding always reads as mint; the key's own accent only shows while it is held.
        val tint = if (onPrimary) Palette.onAccent else if (held || editing) accent else Palette.accent
        chipFill.color = if (tinted) withAlpha(tint, if (held) 0.24f else 0.14f) else Palette.surface3
        canvas.drawRoundRect(chipRect, 7 * density, 7 * density, chipFill)
        chipText.color = if (tinted) tint else Palette.muted
        canvas.drawText(text, chipRect.centerX(), chipRect.centerY() - (chipText.descent() + chipText.ascent()) / 2, chipText)
    }

    protected open fun containsTouch(x: Float, y: Float): Boolean = x >= 0 && y >= 0 && x < width && y < height

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (!isEnabled) return false
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (!gesture.begin(e.getPointerId(0), containsTouch(e.x, e.y))) return false
                parent?.requestDisallowInterceptTouchEvent(true)
                if (!editing) {
                    updateHeld(true)
                    performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                    onPress()
                }
            }
            MotionEvent.ACTION_MOVE -> {
                val index = e.findPointerIndex(gesture.pointer)
                if (index < 0 || !containsTouch(e.getX(index), e.getY(index))) releaseIfHeld()
            }
            MotionEvent.ACTION_POINTER_UP -> {
                if (gesture.end(e.getPointerId(e.actionIndex))) releaseIfHeld()
            }
            MotionEvent.ACTION_UP -> {
                if (gesture.end(e.getPointerId(e.actionIndex))) {
                    if (editing && containsTouch(e.x, e.y)) performClick()
                    else { releaseIfHeld(); super.performClick() }
                }
                parent?.requestDisallowInterceptTouchEvent(false)
            }
            MotionEvent.ACTION_CANCEL -> releaseIfHeld()
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        if (!isEnabled) return false
        performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        if (editing) onEdit() else accessibilityTap()
        return true
    }
    protected open fun accessibilityTap() {
        if (held) { releaseIfHeld(); return }
        updateHeld(true)
        onPress()
        postDelayed({ releaseIfHeld() }, 80)
    }
    override fun onInitializeAccessibilityNodeInfo(info: android.view.accessibility.AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = "android.widget.Button"
        info.isClickable = true
    }
    override fun onDetachedFromWindow() { releaseIfHeld(); animate().cancel(); super.onDetachedFromWindow() }

    protected open fun updateHeld(on: Boolean) {
        held = on
        stateDescription = if (on) context.getString(R.string.key_held) else context.getString(R.string.key_released)
        animate().scaleX(if (on) 0.96f else 1f).scaleY(if (on) 0.96f else 1f).setDuration(90).start()
        invalidate()
    }

    fun releaseIfHeld() {
        gesture.cancel()
        parent?.requestDisallowInterceptTouchEvent(false)
        if (held) { updateHeld(false); onRelease() }
    }
}

/** A tactile voice dial; animation runs only while the user holds it. */
@SuppressLint("ViewConstructor")
class TalkPad(context: Context) : Pad(context, R.drawable.ic_mic, context.getString(R.string.hold_to_talk), Palette.accent) {
    var microphoneHint: String = context.getString(R.string.mac_microphone)
        set(value) { field = value; invalidate() }
    private val disc = Paint(Paint.ANTI_ALIAS_FLAG)
    private val halo = Paint(Paint.ANTI_ALIAS_FLAG)
    private val shaderGeometry = FloatArray(3)
    private var shaderHeld: Boolean? = null
    private val editHint = context.getString(R.string.voice_edit_hint)
    private val releaseCaption = context.getString(R.string.release_to_finish)
    private var captionKey = ""
    private var captionLayout: StaticLayout? = null
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val title = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 17 * fontScale
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        color = Palette.onAccent
    }
    private val detail = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 11 * fontScale
        color = Palette.muted
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
    private var phase = 0f
    private val pulse = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 1400
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener { phase = it.animatedValue as Float; invalidate() }
    }

    private fun geometry(): FloatArray {
        val sourceHeight = detail.fontSpacing + 12 * density
        val maxRadius = (if (resources.configuration.fontScale > 1.2f) 112 else 104) * density
        val r = min(min(width / 2f - 16 * density, (height - sourceHeight - 16 * density) / 2), maxRadius).coerceAtLeast(0f)
        return floatArrayOf(width / 2f, sourceHeight + (height - sourceHeight) / 2f, r)
    }

    override fun containsTouch(x: Float, y: Float): Boolean {
        val (cx, cy, r) = geometry()
        return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
    }
    override fun accessibilityTap() {
        if (held) releaseIfHeld() else { updateHeld(true); onPress() }
    }
    override fun onInitializeAccessibilityNodeInfo(info: android.view.accessibility.AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.contentDescription = if (editing) context.getString(R.string.voice_edit_description, KeyLabels.label(context, binding)) else
            if (held) context.getString(R.string.voice_active_description, microphoneHint) else context.getString(R.string.voice_idle_description, microphoneHint)
    }
    private fun clippedHint(value: String, available: Float): String {
        if (detail.measureText(value) <= available) return value
        val count = detail.breakText(value, true, (available - detail.measureText("…")).coerceAtLeast(0f), null)
        return value.take(count) + "…"
    }
    override fun onDraw(canvas: Canvas) {
        val (cx, cy, r) = geometry()
        val color = if (held) Palette.red else Palette.accent
        // Gradients depend only on the dial's geometry and whether it is held; rebuild them when either changes.
        if (shaderHeld != held || shaderGeometry[0] != cx || shaderGeometry[1] != cy || shaderGeometry[2] != r) {
            shaderHeld = held; shaderGeometry[0] = cx; shaderGeometry[1] = cy; shaderGeometry[2] = r
            val glow = r + 22 * density
            halo.shader = android.graphics.RadialGradient(cx, cy, glow, intArrayOf(withAlpha(color, 0.16f), withAlpha(color, 0.10f), withAlpha(color, 0f)),
                floatArrayOf(0f, r / glow, 1f), Shader.TileMode.CLAMP)
            disc.shader = LinearGradient(cx - r, cy - r, cx + r, cy + r,
                if (held) color else Color.rgb(134, 222, 198), if (held) color else Color.rgb(95, 194, 166), Shader.TileMode.CLAMP)
        }
        detail.textAlign = Paint.Align.CENTER
        detail.color = Palette.muted
        canvas.drawText(clippedHint(if (editing) editHint else microphoneHint, width - 24 * density),
            width / 2f, 6 * density - detail.ascent(), detail)

        if (held) {
            for (i in 0 until 2) {
                val p = (phase + i * 0.5f) % 1f
                ring.strokeWidth = 2 * density
                ring.color = withAlpha(color, 0.3f * (1 - p))
                val limit = min(height - cy, cy - detail.fontSpacing - 12 * density) - 2 * density
                canvas.drawCircle(cx, cy, min(r + (8 + 12 * p) * density, limit.coerceAtLeast(r)), ring)
            }
        } else {
            // A soft glow instead of an outline ring keeps the dial the only bright object on the page.
            canvas.drawCircle(cx, cy, r + 22 * density, halo)
        }
        canvas.drawCircle(cx, cy, r, disc)
        if (editing) {
            editStroke.color = color
            canvas.drawCircle(cx, cy, r + 9 * density, editStroke)
        }

        val size = min(r * 0.53f, 52 * density).toInt()
        val contentOffset = r * 0.20f
        val iconY = cy - r * 0.44f + contentOffset
        icon.setBounds((cx - size / 2).toInt(), (iconY - size / 2).toInt(), (cx + size / 2).toInt(), (iconY + size / 2).toInt())
        icon.setTint(Palette.onAccent)
        icon.draw(canvas)

        // The caption and key cap belong to the disc, never to a clipped area below the view.
        title.color = Palette.onAccent
        val text = if (held) releaseCaption else label
        val textWidth = (r * 1.65f).toInt().coerceAtLeast(1)
        val key = "$text|$textWidth"
        if (captionKey != key) {
            captionKey = key
            captionLayout = StaticLayout.Builder.obtain(text, 0, text.length, title, textWidth)
                .setAlignment(Layout.Alignment.ALIGN_CENTER).setIncludePad(false).build()
        }
        val caption = checkNotNull(captionLayout)
        val top = cy - r * 0.12f + contentOffset
        canvas.save(); canvas.translate(cx - textWidth / 2f, top); caption.draw(canvas); canvas.restore()
        drawBinding(canvas, cx, top + caption.height + 6 * density, Palette.onAccent, r * 1.4f, onPrimary = true)
    }

    override fun updateHeld(on: Boolean) {
        super.updateHeld(on)
        animate().scaleX(1f).scaleY(1f).setDuration(0).start()
        if (on) pulse.start() else pulse.cancel()
    }

}
