package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.os.SystemClock
import android.util.Base64
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.ZoomableImagePreview
import io.github.junweiup.vibepier.remote.features.sessions.ConversationImage
import io.github.junweiup.vibepier.remote.features.sessions.ConversationMedia
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import kotlin.math.abs

/** Gesture and popup lifecycle evidence from synthetic pixels. Never pairs, connects or sends a session message. */
internal object ImageZoomProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (value: Throwable) { failure = value } }
            failure?.let { throw it }
        }
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun await(description: String, condition: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 5_000
            while (SystemClock.elapsedRealtime() < deadline) {
                var ready = false; main { ready = condition() }; if (ready) return
                SystemClock.sleep(25); test.waitForIdleSync()
            }
            error("Image zoom did not settle: $description")
        }
        fun picture(width: Int): JSONObject {
            val image = Bitmap.createBitmap(width, width * 2, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(image); val paint = Paint()
            val tile = width / 8f
            for (row in 0 until 16) for (column in 0 until 8) {
                paint.color = if ((row + column) % 2 == 0) 0xFF4D9984.toInt() else 0xFF193B34.toInt()
                canvas.drawRect(column * tile, row * tile, (column + 1) * tile, (row + 1) * tile, paint)
            }
            paint.color = 0xFFFFC857.toInt(); canvas.drawCircle(width * .7f, width * 1.4f, tile, paint)
            val bytes = ByteArrayOutputStream().also { image.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray(); image.recycle()
            return JSONObject().put("ok", true).put("image", Base64.encodeToString(bytes, Base64.NO_WRAP))
        }
        val thumb = picture(160); val large = picture(640)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval")) as MainActivity
        var media: ConversationMedia? = null; var popup: AlertDialog? = null
        var gestureEvidence = ""
        lateinit var tile: ConversationImage; val largeReads = mutableListOf<(JSONObject) -> Unit>()
        fun preview() = views(popup!!.window!!.decorView).filterIsInstance<ZoomableImagePreview>().single()
        fun touch(view: View, down: Long, time: Long, action: Int, points: List<Pair<Float, Float>>) {
            val properties = points.indices.map { index -> MotionEvent.PointerProperties().apply { id = index; toolType = MotionEvent.TOOL_TYPE_FINGER } }.toTypedArray()
            val coordinates = points.map { (x, y) -> MotionEvent.PointerCoords().apply { this.x = x; this.y = y; pressure = 1f; size = 1f } }.toTypedArray()
            val event = MotionEvent.obtain(down, time, action, points.size, properties, coordinates, 0, 0, 1f, 1f, 0, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { check(view.dispatchTouchEvent(event)) } finally { event.recycle() }
        }
        fun pinch(view: ZoomableImagePreview) {
            val now = SystemClock.uptimeMillis(); val x = view.width / 2f; val y = view.height / 2f
            val span = minOf(view.width, view.height) * .28f
            touch(view, now, now, MotionEvent.ACTION_DOWN, listOf(x - span / 2 to y))
            touch(view, now, now + 20, MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), listOf(x - span / 2 to y, x + span / 2 to y))
            for ((index, factor) in listOf(1.25f, 1.7f, 2.3f).withIndex()) touch(view, now, now + 40 + index * 20,
                MotionEvent.ACTION_MOVE, listOf(x - span * factor / 2 to y, x + span * factor / 2 to y))
            touch(view, now, now + 100, MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), listOf(x - span * 2.3f / 2 to y, x + span * 2.3f / 2 to y))
            touch(view, now, now + 120, MotionEvent.ACTION_UP, listOf(x - span * 2.3f / 2 to y))
        }
        fun doubleTap(view: ZoomableImagePreview) {
            val now = SystemClock.uptimeMillis(); val point = listOf(view.width / 2f to view.height / 2f)
            touch(view, now, now, MotionEvent.ACTION_DOWN, point); touch(view, now, now + 20, MotionEvent.ACTION_UP, point)
            touch(view, now + 120, now + 120, MotionEvent.ACTION_DOWN, point); touch(view, now + 120, now + 140, MotionEvent.ACTION_UP, point)
        }
        try {
            main {
                activity.sessionNavigation.close()
                media = ConversationMedia(activity, { ConversationMedia.Scope("codex", "synthetic", 1) }, { true }, { "synthetic-image" },
                    request = { operation, params, done ->
                        check(operation == "image")
                        if (params.opt("size") == "thumb") done(thumb) else largeReads.add(done)
                    }, allowLegacyImages = true)
                val strip = media!!.strip(JSONArray().put(JSONObject().put("id", "synthetic-image#0")))
                tile = views(strip).filterIsInstance<ConversationImage>().single(); activity.setContentView(strip)
            }
            await("thumbnail", { tile.bitmap != null })
            main { tile.performClick(); popup = media!!.previewDialog!!.dialog }
            await("viewport layout", { popup?.isShowing == true && preview().viewport.ready })
            lateinit var current: ZoomableImagePreview
            main {
                current = preview(); check(current.viewport.zoom == 1f)
                check(current.height > popup!!.window!!.decorView.height * .75f) { "Image viewport must fill most of the fullscreen host" }
                val visible = android.graphics.Rect()
                check(current.getGlobalVisibleRect(visible) && visible.height() == current.height) { "Fullscreen viewport must be visible between safe controls" }
                pinch(current); check(current.viewport.zoom > 1.2f && current.viewport.zoom <= 6f) { "Two-finger gesture must enlarge the actual viewport" }
                val now = SystemClock.uptimeMillis(); val x = current.width / 2f; val y = current.height / 2f
                val movableX = current.viewport.imageRight - current.viewport.imageLeft > current.width + 1f
                val movableY = current.viewport.imageBottom - current.viewport.imageTop > current.height + 1f
                check(movableX || movableY)
                val beforeX = current.viewport.offsetX; val beforeY = current.viewport.offsetY
                val dragX = if (movableX) current.width * .2f else 0f
                val dragY = if (movableY) current.height * .15f else 0f
                touch(current, now, now, MotionEvent.ACTION_DOWN, listOf(x to y))
                touch(current, now, now + 80, MotionEvent.ACTION_MOVE, listOf(x + dragX to y + dragY))
                touch(current, now, now + 100, MotionEvent.ACTION_UP, listOf(x + dragX to y + dragY))
                gestureEvidence = "viewport=${current.width}x${current.height}, zoom=${current.viewport.zoom}, movable=($movableX,$movableY), pan=(${current.viewport.offsetX},${current.viewport.offsetY})"
                check(if (movableX) abs(current.viewport.offsetX - beforeX) > 1f else current.viewport.offsetX == 0f) { "Image horizontal pan/centering failed: $gestureEvidence" }
                check(if (movableY) abs(current.viewport.offsetY - beforeY) > 1f else current.viewport.offsetY == 0f) { "Image vertical pan/centering failed: $gestureEvidence" }
            }
            SystemClock.sleep(350)
            main { doubleTap(current); check(current.viewport.zoom == 1f && current.viewport.offsetX == 0f && current.viewport.offsetY == 0f) }
            SystemClock.sleep(350)
            main {
                doubleTap(current); check(current.viewport.zoom == 3f)
                check(largeReads.size == 1); largeReads.single()(large)
            }
            await("large image", { views(popup!!.window!!.decorView).filterIsInstance<CanvasLabel>().none { it.isShown && it.text == activity.getString(R.string.image_large_loading) } })
            main {
                check(preview() === current && current.viewport.zoom == 3f) { "Larger image must preserve the inspection zoom" }
                val close = views(popup!!.window!!.decorView).single { it.isClickable && it.contentDescription == activity.getString(R.string.close) }
                check(close.isEnabled && close.isShown); close.performClick(); check(popup!!.isShowing == false)
                tile.performClick(); popup = media!!.previewDialog!!.dialog
            }
            await("reopened image", { popup!!.isShowing && preview().viewport.ready })
            main { check(preview() !== current && preview().viewport.zoom == 1f && preview().viewport.offsetX == 0f && preview().viewport.offsetY == 0f) }
            SystemClock.sleep(350); test.waitForIdleSync()
            test.uiAutomation.takeScreenshot()?.let { image ->
                try { java.io.File(activity.externalCacheDir, "image-zoom-reset.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) } }
                finally { image.recycle() }
            }
            test.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            await("Back closes fullscreen image", { popup?.isShowing == false })
            return "PASS: image-zoom synthetic production fullscreen conversation host (>75% viewport); actual two-finger zoom, enlarged drag, double-tap reset/enlarge, bounded zoom, high-resolution replacement preserves inspection position, Close and system Back stay usable; reopen resets. $gestureEvidence. No pairing, host or session message."
        } finally {
            main { popup?.dismiss(); media?.clear(); activity.finish() }
        }
    }
}
