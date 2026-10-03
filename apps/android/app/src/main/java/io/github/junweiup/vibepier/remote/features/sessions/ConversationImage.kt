package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.ControlView
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF

/**
 * A conversation image fetched from the Mac by id: a rounded, center-cropped tile that shows a placeholder until the
 * bitmap arrives, so the timeline keeps its layout while images load.
 */
@android.annotation.SuppressLint("ViewConstructor") // Created in code with required model/callback arguments, never XML-inflated.
internal class ConversationImage(context: Context, private val tileWidth: Int, private val tileHeight: Int) : ControlView(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val hint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Palette.muted; textAlign = Paint.Align.CENTER; textSize = android.util.TypedValue.applyDimension(android.util.TypedValue.COMPLEX_UNIT_SP, 12f, resources.displayMetrics) }
    private val frame = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Palette.surfaceTop }
    private val clip = Path()
    private val bounds = RectF()
    private val source = Rect()
    private val destination = Rect()
    private fun updateGeometry() {
        val radius = 10 * resources.displayMetrics.density
        bounds.set(0f, 0f, width.toFloat(), height.toFloat())
        clip.reset(); clip.addRoundRect(bounds, radius, radius, Path.Direction.CW)
        destination.set(0, 0, width, height)
        bitmap?.let { image ->
            val crop = crop(image.width, image.height, width, height)
            source.set(crop[0], crop[1], crop[2], crop[3])
        }
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh); updateGeometry()
    }
    var bitmap: Bitmap? = null
        set(value) { field = value; updateGeometry(); invalidate() }
    var placeholder = context.getString(R.string.image_loading)
        set(value) { field = value; invalidate() }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(resolveSize(tileWidth, widthMeasureSpec), resolveSize(tileHeight, heightMeasureSpec))
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.save(); canvas.clipPath(clip)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), frame)
        val image = bitmap
        if (image == null) canvas.drawText(placeholder, width / 2f, height / 2f - (hint.ascent() + hint.descent()) / 2, hint)
        else canvas.drawBitmap(image, source, destination, paint)
        canvas.restore()
    }

    companion object {
        /** The centered part of an image, as left, top, right, bottom, that fills a tile without stretching. */
        fun crop(imageWidth: Int, imageHeight: Int, width: Int, height: Int): List<Int> {
            if (width <= 0 || height <= 0) return listOf(0, 0, imageWidth, imageHeight)
            return if (imageWidth.toLong() * height > imageHeight.toLong() * width) {
                val w = (imageHeight.toLong() * width / height).toInt(); listOf((imageWidth - w) / 2, 0, (imageWidth + w) / 2, imageHeight)
            } else {
                val h = (imageWidth.toLong() * height / width).toInt(); listOf(0, (imageHeight - h) / 2, imageWidth, (imageHeight + h) / 2)
            }
        }
    }
}
