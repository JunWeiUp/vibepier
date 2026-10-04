package io.github.junweiup.vibepier.remote.features.remote

import android.content.Context
import android.view.ViewGroup
import kotlin.math.max
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

/** Fits the entire home canvas without scrolling or changing its controls' proportions. */
class HomeViewport(context: Context) : ViewGroup(context) {
    private var contentScale = 1f

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(width, height)
        if (childCount == 0) return
        val availableWidth = (width - paddingLeft - paddingRight).coerceAtLeast(1)
        val availableHeight = (height - paddingTop - paddingBottom).coerceAtLeast(1)
        var canvasWidth = max(availableWidth, (360 * resources.displayMetrics.density).roundToInt())
        val content = getChildAt(0)
        fun measureNatural() {
            content.measure(MeasureSpec.makeMeasureSpec(canvasWidth, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
        }
        // Measure before shrinking so weighted sections cannot collapse or clip.
        measureNatural()
        val naturalHeight = content.measuredHeight
        if (naturalHeight.toFloat() * availableWidth / canvasWidth > availableHeight) {
            // Expand the logical width as the controls shrink. The rendered canvas then
            // still spans the window instead of leaving proportional-fit side gutters.
            canvasWidth = max(canvasWidth, ceil(availableWidth.toDouble() * naturalHeight / availableHeight).toInt())
            measureNatural()
        }
        contentScale = availableWidth.toFloat() / canvasWidth
        val canvasHeight = max(content.measuredHeight, floor(availableHeight / contentScale).toInt())
        content.measure(MeasureSpec.makeMeasureSpec(canvasWidth, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(canvasHeight, MeasureSpec.EXACTLY))
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        if (childCount == 0) return
        val content = getChildAt(0)
        content.layout(0, 0, content.measuredWidth, content.measuredHeight)
        content.pivotX = 0f
        content.pivotY = 0f
        content.scaleX = contentScale
        content.scaleY = contentScale
        content.translationX = paddingLeft + (width - paddingLeft - paddingRight - content.width * contentScale) / 2f
        content.translationY = paddingTop + (height - paddingTop - paddingBottom - content.height * contentScale) / 2f
    }

    override fun generateDefaultLayoutParams() = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
}
