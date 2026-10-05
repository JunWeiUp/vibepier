package io.github.junweiup.vibepier.remote.core.ui

import kotlin.math.max
import kotlin.math.min

/** Fit-center image geometry shared by drawing and touch handling. */
internal class ImageViewport(maxZoom: Float = 6f, doubleTapZoom: Float = 3f) {
    private val maximumZoom = maxZoom.takeIf { it.isFinite() && it >= 1f } ?: 6f
    private val tapZoom = (doubleTapZoom.takeIf { it.isFinite() && it >= 1f } ?: 3f)
        .coerceAtMost(maximumZoom)
    private var viewportWidth = 0.0
    private var viewportHeight = 0.0
    private var fittedWidth = 0.0
    private var fittedHeight = 0.0

    var zoom = 1f
        private set
    var offsetX = 0f
        private set
    var offsetY = 0f
        private set
    var ready = false
        private set

    val imageLeft: Float get() = horizontalEdge(-1.0)
    val imageTop: Float get() = verticalEdge(-1.0)
    val imageRight: Float get() = horizontalEdge(1.0)
    val imageBottom: Float get() = verticalEdge(1.0)

    fun configure(
        imageWidth: Float,
        imageHeight: Float,
        viewportWidth: Float,
        viewportHeight: Float,
        reset: Boolean = true
    ) {
        ready = listOf(imageWidth, imageHeight, viewportWidth, viewportHeight)
            .all { it.isFinite() && it > 0f }
        if (!ready) {
            this.viewportWidth = 0.0
            this.viewportHeight = 0.0
            fittedWidth = 0.0
            fittedHeight = 0.0
            this.reset()
            return
        }
        this.viewportWidth = viewportWidth.toDouble()
        this.viewportHeight = viewportHeight.toDouble()
        // Double intermediates also keep very narrow images and large inputs finite.
        val fit = min(this.viewportWidth / imageWidth, this.viewportHeight / imageHeight)
        fittedWidth = imageWidth * fit
        fittedHeight = imageHeight * fit
        if (reset) this.reset() else clampOffsets(offsetX.toDouble(), offsetY.toDouble())
    }

    fun reset() {
        zoom = 1f
        offsetX = 0f
        offsetY = 0f
    }

    fun zoomBy(factor: Float, focusX: Float, focusY: Float) {
        if (!ready || !factor.isFinite() || factor <= 0f || !focusX.isFinite() || !focusY.isFinite()) return
        val nextZoom = (zoom.toDouble() * factor).coerceIn(1.0, maximumZoom.toDouble()).toFloat()
        val ratio = nextZoom.toDouble() / zoom
        // Preserve the image point under the focus, unless an edge needs clamping.
        val nextX = (focusX - viewportWidth / 2.0) * (1.0 - ratio) + offsetX * ratio
        val nextY = (focusY - viewportHeight / 2.0) * (1.0 - ratio) + offsetY * ratio
        zoom = nextZoom
        clampOffsets(nextX, nextY)
    }

    fun panBy(dx: Float, dy: Float) {
        if (!ready || !dx.isFinite() || !dy.isFinite()) return
        clampOffsets(offsetX.toDouble() + dx, offsetY.toDouble() + dy)
    }

    fun doubleTap(x: Float, y: Float) {
        if (!ready || !x.isFinite() || !y.isFinite()) return
        if (zoom > 1f) reset() else zoomBy(tapZoom, x, y)
    }

    private fun clampOffsets(x: Double, y: Double) {
        val limitX = max(0.0, (fittedWidth * zoom - viewportWidth) / 2.0)
        val limitY = max(0.0, (fittedHeight * zoom - viewportHeight) / 2.0)
        offsetX = finiteFloat(x.coerceIn(-limitX, limitX))
        offsetY = finiteFloat(y.coerceIn(-limitY, limitY))
    }

    private fun horizontalEdge(direction: Double): Float = if (ready) {
        finiteFloat(viewportWidth / 2.0 + offsetX + direction * fittedWidth * zoom / 2.0)
    } else 0f

    private fun verticalEdge(direction: Double): Float = if (ready) {
        finiteFloat(viewportHeight / 2.0 + offsetY + direction * fittedHeight * zoom / 2.0)
    } else 0f

    private fun finiteFloat(value: Double): Float =
        value.coerceIn(-Float.MAX_VALUE.toDouble(), Float.MAX_VALUE.toDouble()).toFloat()
}
