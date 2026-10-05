package io.github.junweiup.vibepier.remote.core.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Bundle
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.accessibility.AccessibilityNodeInfo
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.features.remote.Palette
import kotlin.math.roundToInt

/** Bounded bitmap viewport. Gestures move pixels inside this view, leaving dialog actions outside it. */
@android.annotation.SuppressLint("ViewConstructor")
internal class ZoomableImagePreview(context: Context, bitmap: Bitmap, private val preferredHeightDp: Int = 360) : ControlView(context) {
    override val usesSharedInteraction = false
    private var bitmap = bitmap
    internal val viewport = ImageViewport()
    private val destination = RectF()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val scaleGesture = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            viewport.zoomBy(detector.scaleFactor, detector.focusX, detector.focusY); changed(); return true
        }
    }).apply { isQuickScaleEnabled = false }
    private val gesture = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(event: MotionEvent) = true
        override fun onDoubleTap(event: MotionEvent): Boolean {
            viewport.doubleTap(event.x, event.y); changed(); return true
        }
        override fun onSingleTapConfirmed(event: MotionEvent): Boolean { performClick(); return true }
        override fun onScroll(first: MotionEvent?, event: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
            if (!scaleGesture.isInProgress && event.pointerCount == 1) {
                viewport.panBy(-distanceX, -distanceY); changed()
            }
            return true
        }
    })
    init {
        isClickable = true; isFocusable = true
        background = Ui.roundRect(context, Palette.surface1, 12); clipToOutline = true
        contentDescription = context.getString(R.string.image_zoom_description)
        changed()
    }
    fun setBitmap(value: Bitmap, reset: Boolean = true) {
        bitmap = value
        viewport.configure(bitmap.width.toFloat(), bitmap.height.toFloat(), width.toFloat(), height.toFloat(), reset)
        changed()
    }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(resolveSize(Ui.dp(context, 320), widthMeasureSpec), resolveSize(Ui.dp(context, preferredHeightDp), heightMeasureSpec))
    }
    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        viewport.configure(bitmap.width.toFloat(), bitmap.height.toFloat(), width.toFloat(), height.toFloat(), reset = oldWidth == 0 || oldHeight == 0)
        changed()
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (!viewport.ready || bitmap.isRecycled) return
        destination.set(viewport.imageLeft, viewport.imageTop, viewport.imageRight, viewport.imageBottom)
        val save = canvas.save(); canvas.clipRect(0, 0, width, height)
        canvas.drawBitmap(bitmap, null, destination, paint); canvas.restoreToCount(save)
    }
    @android.annotation.SuppressLint("ClickableViewAccessibility") // GestureDetector confirms clicks through performClick; accessibility zoom actions are explicit below.
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled) return false
        if (event.actionMasked == MotionEvent.ACTION_DOWN) parent?.requestDisallowInterceptTouchEvent(true)
        scaleGesture.onTouchEvent(event); gesture.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL)
            parent?.requestDisallowInterceptTouchEvent(false)
        return true
    }
    override fun performClick(): Boolean { super.performClick(); return true }
    private fun changed() {
        stateDescription = context.getString(R.string.image_zoom_level, (viewport.zoom * 100).roundToInt())
        invalidate()
    }
    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, context.getString(R.string.image_toggle_zoom)))
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD, context.getString(R.string.image_zoom_in)))
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD, context.getString(R.string.image_zoom_out)))
    }
    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
        if (!isEnabled) return false
        when (action) {
            AccessibilityNodeInfo.ACTION_CLICK -> viewport.doubleTap(width / 2f, height / 2f)
            AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> viewport.zoomBy(2f, width / 2f, height / 2f)
            AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> viewport.zoomBy(.5f, width / 2f, height / 2f)
            else -> return super.performAccessibilityAction(action, arguments)
        }
        changed(); return true
    }
}
