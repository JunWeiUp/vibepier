package io.github.junweiup.vibepier.remote.features.remote

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.transport.RemoteSender
import io.github.junweiup.vibepier.remote.core.ui.ControlView

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.TextPaint
import android.text.TextUtils
import android.view.MotionEvent
import android.util.Base64

/** An application icon and caption, drawn without a selectable text widget. */
class AppShortcutView(context: Context) : ControlView(context) {
    private val density = resources.displayMetrics.density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val caption = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 10.5f * resources.displayMetrics.scaledDensity
        textAlign = Paint.Align.CENTER
    }
    private var entry: RemoteSender.AppShortcut? = null
    private var bitmap: Bitmap? = null
    private var active = false
    private var pending = false
    private var pendingAction = "activate"
    private var online = false
    private var pressedIdentity: Pair<String?, Boolean>? = null
    private val tile = RectF()
    private val box = RectF()
    private val dash = android.graphics.DashPathEffect(floatArrayOf(4 * density, 3 * density), 0f)
    fun update(value: RemoteSender.AppShortcut?, current: String?, requested: String? = null, action: String = "activate") {
        if (entry?.iconPNG != value?.iconPNG) {
            bitmap = try {
                val bytes = Base64.decode(value?.iconPNG ?: "", Base64.DEFAULT)
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            } catch (_: IllegalArgumentException) { null }
        }
        entry = value
        online = current != null
        pending = !requested.isNullOrEmpty() && value?.bundleID == requested
        active = !current.isNullOrEmpty() && value?.bundleID == current
        pendingAction = action
        contentDescription = when {
            DockApplications.isTemporaryPlaceholder(value) -> context.getString(R.string.dock_placeholder_description)
            value?.bundleID?.isBlank() == true -> context.getString(R.string.app_picker_choose_slot, value.slot + 1)
            active -> context.getString(R.string.dock_hide_description, value?.name.orEmpty())
            else -> context.getString(R.string.dock_switch_description, value?.name ?: context.getString(R.string.not_configured))
        }
        invalidate()
    }
    override fun drawableStateChanged() { super.drawableStateChanged(); invalidate() }
    @android.annotation.SuppressLint("ClickableViewAccessibility") // Delegate touch dispatch to View; its normal click and accessibility paths both call our performClick override.
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) pressedIdentity = entry?.bundleID to active
        val handled = super.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_CANCEL) pressedIdentity = null
        else if (event.actionMasked == MotionEvent.ACTION_UP) post { pressedIdentity = null }
        return handled
    }
    override fun performClick(): Boolean {
        // A live foreground update must not turn the user's activation tap into a hide tap.
        if (pressedIdentity?.let { it != (entry?.bundleID to active) } == true) return false
        performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
        return super.performClick()
    }
    override fun onDraw(canvas: Canvas) {
        val size = minOf(40 * density, width - 12 * density)
        val left = (width - size) / 2
        val top = 4 * density
        tile.set(left, top, left + size, top + size)
        if (isPressed || isFocused) {
            paint.style = Paint.Style.FILL
            paint.color = Palette.surface2
            box.set(density, 0f, width - density, height.toFloat())
            canvas.drawRoundRect(box, 13 * density, 13 * density, paint)
        }
        paint.style = Paint.Style.FILL
        if (DockApplications.isTemporaryPlaceholder(entry)) {
            paint.color = Palette.outlineStrong
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 1.5f * density
            paint.pathEffect = dash
            box.set(tile.left + density, tile.top + density, tile.right - density, tile.bottom - density)
            canvas.drawRoundRect(box, 12 * density, 12 * density, paint)
            paint.pathEffect = null
            paint.style = Paint.Style.FILL
            caption.color = Palette.faint
            val old = caption.textSize
            caption.textSize = 18 * density
            canvas.drawText("+", tile.centerX(), tile.centerY() - (caption.ascent() + caption.descent()) / 2, caption)
            caption.textSize = old
        } else bitmap?.let { canvas.drawBitmap(it, null, tile, paint) } ?: run {
            paint.color = Palette.surface3
            canvas.drawRoundRect(tile, 12 * density, 12 * density, paint)
            caption.color = Palette.muted
            val old = caption.textSize
            caption.textSize = 17 * density
            canvas.drawText(if (entry?.bundleID.isNullOrEmpty()) "+" else entry!!.name.take(1), tile.centerX(), tile.centerY() - (caption.ascent() + caption.descent()) / 2, caption)
            caption.textSize = old
        }
        caption.color = if (pending) Palette.amber else if (active) Palette.text else Palette.muted
        val text = TextUtils.ellipsize(if (pending) (if (pendingAction == "hide") context.getString(R.string.dock_hiding) else context.getString(R.string.dock_switching)) else if (DockApplications.isTemporaryPlaceholder(entry)) context.getString(R.string.temporary_app) else entry?.name ?: if (online) context.getString(R.string.syncing) else context.getString(R.string.disconnected), caption, width - 8 * density, TextUtils.TruncateAt.END)
        canvas.drawText(text.toString(), width / 2f, tile.bottom + 15 * density, caption)
        if (active || pending) {
            // The current application is marked by a short bar under its name, never by an outline.
            paint.color = if (pending) Palette.amber else Palette.accent
            val bar = 16 * density
            box.set(width / 2f - bar / 2, height - 4 * density, width / 2f + bar / 2, height - density)
            canvas.drawRoundRect(box, 2 * density, 2 * density, paint)
        }
    }
}
