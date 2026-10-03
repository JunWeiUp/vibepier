package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.core.ui.ControlView

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

@android.annotation.SuppressLint("ViewConstructor") // Created in code with required model/callback arguments, never XML-inflated.
internal class AttachmentPreview(context: Context, private val bitmap: Bitmap, private val maximumHeightDp: Int? = 360) : ControlView(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val destination = RectF()
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val naturalHeight = (width * bitmap.height.toFloat() / bitmap.width).toInt()
        val height = maximumHeightDp?.let { naturalHeight.coerceAtMost((it * resources.displayMetrics.density).toInt()) } ?: naturalHeight
        setMeasuredDimension(width, resolveSize(height, heightMeasureSpec))
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val scale = minOf(width.toFloat() / bitmap.width, height.toFloat() / bitmap.height)
        val w = bitmap.width * scale; val h = bitmap.height * scale
        destination.set((width-w)/2, (height-h)/2, (width+w)/2, (height+h)/2)
        canvas.drawBitmap(bitmap, null, destination, paint)
    }
}
