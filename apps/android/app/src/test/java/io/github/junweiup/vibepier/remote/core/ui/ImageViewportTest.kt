package io.github.junweiup.vibepier.remote.core.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImageViewportTest {
    @Test fun pinchKeepsTheImagePointUnderTheFocusAfterPanning() {
        val viewport = ImageViewport()
        viewport.configure(1000f, 1000f, 400f, 400f)
        val firstPoint = imagePoint(viewport, 300f, 100f)
        viewport.zoomBy(3f, 300f, 100f)
        assertPoint(firstPoint, imagePoint(viewport, 300f, 100f))

        viewport.panBy(60f, -40f)
        val movedPoint = imagePoint(viewport, 250f, 150f)
        viewport.zoomBy(1.5f, 250f, 150f)
        assertPoint(movedPoint, imagePoint(viewport, 250f, 150f))
        assertEquals(4.5f, viewport.zoom, EPSILON)
    }

    @Test fun landscapeImageCentersTheShortAxisAndClampsBothHorizontalEdges() {
        val viewport = ImageViewport()
        viewport.configure(1600f, 800f, 400f, 600f)
        assertBounds(viewport, 0f, 200f, 400f, 400f)
        viewport.zoomBy(2f, 200f, 300f)
        viewport.panBy(10000f, 10000f)
        assertBounds(viewport, 0f, 100f, 800f, 500f)
        assertEquals(0f, viewport.offsetY, EPSILON)
        viewport.panBy(-20000f, -20000f)
        assertBounds(viewport, -400f, 100f, 400f, 500f)
    }

    @Test fun portraitImageCentersTheShortAxisAndClampsBothVerticalEdges() {
        val viewport = ImageViewport()
        viewport.configure(800f, 1600f, 600f, 400f)
        viewport.zoomBy(2f, 300f, 200f)
        viewport.panBy(10000f, 10000f)
        assertBounds(viewport, 100f, 0f, 500f, 800f)
        assertEquals(0f, viewport.offsetX, EPSILON)
        viewport.panBy(-20000f, -20000f)
        assertBounds(viewport, 100f, -400f, 500f, 400f)
    }

    @Test fun zoomLimitsApplyBeforeAnchoringAndReturningToFitRemovesPan() {
        val viewport = ImageViewport(maxZoom = 4f)
        viewport.configure(1000f, 1000f, 400f, 400f)
        val point = imagePoint(viewport, 250f, 150f)
        viewport.zoomBy(Float.MAX_VALUE, 250f, 150f)
        assertEquals(4f, viewport.zoom, EPSILON)
        assertPoint(point, imagePoint(viewport, 250f, 150f))
        viewport.panBy(80f, 90f)
        viewport.zoomBy(Float.MIN_VALUE, 250f, 150f)
        assertEquals(1f, viewport.zoom, EPSILON)
        assertBounds(viewport, 0f, 0f, 400f, 400f)
    }

    @Test fun reconfigurationRetainsZoomButClampsPanToTheNewFit() {
        val viewport = ImageViewport()
        viewport.configure(1000f, 1000f, 400f, 400f)
        viewport.doubleTap(200f, 200f)
        viewport.panBy(400f, 400f)
        viewport.configure(1000f, 1000f, 800f, 400f, reset = false)
        assertEquals(3f, viewport.zoom, EPSILON)
        assertEquals(200f, viewport.offsetX, EPSILON)
        assertEquals(400f, viewport.offsetY, EPSILON)
        assertBounds(viewport, 0f, 0f, 1200f, 1200f)

        viewport.configure(1000f, 1000f, 800f, 400f)
        assertEquals(1f, viewport.zoom, EPSILON)
        assertBounds(viewport, 200f, 0f, 600f, 400f)
    }

    @Test fun doubleTapZoomsAtItsFocusAndResetsAnyExistingZoom() {
        val viewport = ImageViewport(doubleTapZoom = 3f)
        viewport.configure(1000f, 1000f, 400f, 400f)
        val point = imagePoint(viewport, 250f, 150f)
        viewport.doubleTap(250f, 150f)
        assertEquals(3f, viewport.zoom, EPSILON)
        assertPoint(point, imagePoint(viewport, 250f, 150f))
        viewport.zoomBy(0.5f, 200f, 200f)
        viewport.doubleTap(350f, 350f)
        assertEquals(1f, viewport.zoom, EPSILON)
        assertBounds(viewport, 0f, 0f, 400f, 400f)
    }

    @Test fun invalidGestureDataCannotCorruptTheLastUsableTransform() {
        val viewport = ImageViewport()
        viewport.configure(1000f, 1000f, 400f, 400f)
        viewport.zoomBy(2f, 250f, 150f)
        val original = bounds(viewport)
        for (invalid in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            viewport.zoomBy(invalid, 200f, 200f)
            viewport.zoomBy(2f, invalid, 200f)
            viewport.panBy(10f, invalid)
            viewport.doubleTap(invalid, 200f)
        }
        viewport.zoomBy(0f, 200f, 200f)
        viewport.zoomBy(-1f, 200f, 200f)
        assertEquals(original, bounds(viewport))
        assertEquals(2f, viewport.zoom, EPSILON)
    }

    @Test fun invalidDimensionsClearReadinessAndAValidImageCanRecover() {
        val viewport = ImageViewport()
        viewport.configure(1000f, 1000f, 400f, 400f)
        viewport.zoomBy(3f, 200f, 200f)
        for (invalid in listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            viewport.configure(invalid, 1000f, 400f, 400f, reset = false)
            assertFalse(viewport.ready)
            viewport.panBy(50f, 50f)
            viewport.zoomBy(3f, 200f, 200f)
            assertEquals(1f, viewport.zoom, EPSILON)
            assertBounds(viewport, 0f, 0f, 0f, 0f)
        }
        viewport.configure(1000f, 500f, 400f, 400f, reset = false)
        assertTrue(viewport.ready)
        assertBounds(viewport, 0f, 100f, 400f, 300f)
    }

    @Test fun extremeFiniteDimensionsAndInvalidLimitsKeepPublicGeometryFinite() {
        val viewport = ImageViewport(maxZoom = Float.NaN, doubleTapZoom = Float.POSITIVE_INFINITY)
        viewport.configure(Float.MIN_VALUE, Float.MAX_VALUE, Float.MAX_VALUE, Float.MAX_VALUE)
        assertTrue(viewport.ready)
        viewport.doubleTap(0f, 0f)
        viewport.zoomBy(Float.MAX_VALUE, Float.MAX_VALUE, Float.MAX_VALUE)
        viewport.panBy(-Float.MAX_VALUE, Float.MAX_VALUE)
        assertEquals(6f, viewport.zoom, EPSILON)
        assertTrue(bounds(viewport).all { it.isFinite() })
        assertTrue(viewport.offsetX.isFinite() && viewport.offsetY.isFinite())
        viewport.reset()
        assertEquals(1f, viewport.zoom, EPSILON)
        assertEquals(0f, viewport.offsetX, EPSILON)
        assertEquals(0f, viewport.offsetY, EPSILON)
    }

    private fun imagePoint(viewport: ImageViewport, x: Float, y: Float): Pair<Float, Float> =
        Pair((x - viewport.imageLeft) / (viewport.imageRight - viewport.imageLeft),
            (y - viewport.imageTop) / (viewport.imageBottom - viewport.imageTop))

    private fun assertPoint(expected: Pair<Float, Float>, actual: Pair<Float, Float>) {
        assertEquals(expected.first, actual.first, EPSILON)
        assertEquals(expected.second, actual.second, EPSILON)
    }

    private fun bounds(viewport: ImageViewport): List<Float> =
        listOf(viewport.imageLeft, viewport.imageTop, viewport.imageRight, viewport.imageBottom)

    private fun assertBounds(viewport: ImageViewport, left: Float, top: Float, right: Float, bottom: Float) {
        listOf(left, top, right, bottom).zip(bounds(viewport)).forEach { (expected, actual) ->
            assertEquals(expected, actual, EPSILON)
        }
    }

    companion object { private const val EPSILON = 0.001f }
}
