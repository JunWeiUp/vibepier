package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.PixelCopy
import android.view.View
import io.github.junweiup.vibepier.remote.features.remote.HomeViewport
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.transport.RemoteSender
import io.github.junweiup.vibepier.remote.features.remote.Palette
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** README photography of production widgets with local, bilingual demonstration data. No Mac connection. */
object VoiceLayoutProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "readme")) as MainActivity
        val chinese = activity.resources.configuration.locales[0].language == "zh"
        fun copy(en: String, zh: String) = if (chinese) zh else en
        fun field(target: Any, name: String) = target.javaClass.getDeclaredField(name).apply { isAccessible = true }
        fun settle() { test.waitForIdleSync(); SystemClock.sleep(250); test.waitForIdleSync() }
        fun capture(name: String) {
            lateinit var bounds: Rect
            test.runOnMainSync {
                val decor = activity.window.decorView
                @Suppress("DEPRECATION")
                val insets = decor.rootWindowInsets
                @Suppress("DEPRECATION")
                bounds = Rect(0, insets.systemWindowInsetTop, decor.width, decor.height - insets.systemWindowInsetBottom)
            }
            val bitmap = Bitmap.createBitmap(bounds.width(), bounds.height(), Bitmap.Config.ARGB_8888)
            val done = CountDownLatch(1)
            var result = PixelCopy.ERROR_UNKNOWN
            PixelCopy.request(activity.window, bounds, bitmap, { result = it; done.countDown() }, Handler(Looper.getMainLooper()))
            check(done.await(10, TimeUnit.SECONDS) && result == PixelCopy.SUCCESS) { "Native window capture failed: $result" }
            File(activity.getExternalFilesDir(null), name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        try {
            settle()
            test.runOnMainSync {
                activity.sessionNavigation.close()
                field(activity, "application").set(activity, RemoteSender.Application("demo.codex", "Codex"))
                field(activity, "appShortcuts").set(activity, listOf(
                    RemoteSender.AppShortcut(0, "demo.codex", "Codex", "", true),
                    RemoteSender.AppShortcut(1, "demo.claude", "Claude", "", true),
                    RemoteSender.AppShortcut(2, "demo.terminal", "Terminal", "", true),
                    RemoteSender.AppShortcut(3, "demo.browser", "Browser", "", true)))
                field(activity, "shortcutsSyncing").setBoolean(activity, false)
                activity.javaClass.getDeclaredMethod("refreshBindings").apply { isAccessible = true }.invoke(activity)
                (field(activity, "connectionTitle").get(activity) as CanvasLabel).text = activity.getString(R.string.mac_connected)
                (field(activity, "subtitle").get(activity) as CanvasLabel).text = copy("Wi-Fi · Studio Mac", "Wi-Fi · 工作室 Mac")
                (field(activity, "connectionDot").get(activity) as View).background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL; setColor(Palette.accent)
                }
            }
            settle()
            capture("voice-layout.png")
            val pads = field(activity, "pads").get(activity) as Map<*, *>
            val voice = pads["talk"] as io.github.junweiup.vibepier.remote.features.remote.TalkPad
            val delete = pads["knob-press"] as io.github.junweiup.vibepier.remote.features.remote.Pad
            val viewport = field(activity, "homeViewport").get(activity) as HomeViewport
            val canvas = viewport.getChildAt(0)
            var voiceY = 0
            var deleteY = 0
            test.runOnMainSync {
                fun full(view: View): Rect {
                    val rect = Rect(); check(view.getGlobalVisibleRect(rect))
                    check(kotlin.math.abs(rect.width() - view.width * canvas.scaleX) <= 2 &&
                        kotlin.math.abs(rect.height() - view.height * canvas.scaleY) <= 2) { "Clipped scaled control" }
                    return rect
                }
                val v = full(voice); val d = full(delete)
                check(v.bottom <= d.top) { "Voice overlaps Delete" }
                check(delete.height >= 48 * activity.resources.displayMetrics.density - 1)
                check(delete.width >= 140 * activity.resources.displayMetrics.density - 1)
                voiceY = v.top; deleteY = d.top
                check(canvas.scaleX == canvas.scaleY && canvas.scaleX <= 1f)
            }
            settle()
            test.runOnMainSync {
                val v = Rect(); val d = Rect(); voice.getGlobalVisibleRect(v); delete.getGlobalVisibleRect(d)
                check(v.top == voiceY && d.top == deleteY) { "Scrolling moved fixed actions" }
                var presses = 0; var releases = 0
                voice.onPress = { presses++ }; voice.onRelease = { releases++ }
                val geometry = voice.javaClass.getDeclaredMethod("geometry").apply { isAccessible = true }.invoke(voice) as FloatArray
                val x = geometry[0]; val y = geometry[1]; val radius = geometry[2]
                val now = SystemClock.uptimeMillis()
                fun touch(action: Int, tx: Float, ty: Float) {
                    val event = android.view.MotionEvent.obtain(now, SystemClock.uptimeMillis(), action, tx, ty, 0)
                    voice.dispatchTouchEvent(event); event.recycle()
                }
                touch(android.view.MotionEvent.ACTION_DOWN, x, y)
                check(presses == 1)
                touch(android.view.MotionEvent.ACTION_MOVE, x + radius + 4, y)
                check(releases == 1)
                touch(android.view.MotionEvent.ACTION_MOVE, x, y)
                check(presses == 1) { "Sliding back restarted voice" }
                touch(android.view.MotionEvent.ACTION_UP, x, y)
                voice.performClick()
            }
            settle(); capture("voice-layout-active.png")
            test.runOnMainSync { voice.releaseIfHeld() }
            val originalWidth = viewport.layoutParams.width
            val originalHeight = viewport.layoutParams.height
            try {
                for ((width, height) in listOf(320 to 480, 320 to 420, 600 to 320)) {
                    test.runOnMainSync {
                        viewport.layoutParams = viewport.layoutParams.apply {
                            this.width = (width * activity.resources.displayMetrics.density).toInt()
                            this.height = (height * activity.resources.displayMetrics.density).toInt()
                        }
                    }
                    settle()
                    test.runOnMainSync {
                        check(canvas.scaleX == canvas.scaleY && canvas.scaleX < 1f)
                        check(kotlin.math.abs(canvas.translationX - viewport.paddingLeft) <= 1) { "Left gutter after scaling" }
                        check(kotlin.math.abs(canvas.width * canvas.scaleX - (viewport.width - viewport.paddingLeft - viewport.paddingRight)) <= 1) { "Canvas no longer fills width" }
                        check(canvas.translationY >= viewport.paddingTop - 1)
                        check(canvas.translationX + canvas.width * canvas.scaleX <= viewport.width - viewport.paddingRight + 1)
                        check(canvas.translationY + canvas.height * canvas.scaleY <= viewport.height - viewport.paddingBottom + 1)
                        fun noVerticalScroll(view: View) {
                            check(view !is android.widget.ScrollView)
                            if (view is android.view.ViewGroup) for (i in 0 until view.childCount) noVerticalScroll(view.getChildAt(i))
                        }
                        noVerticalScroll(canvas)
                        var pressed = 0; var released = 0
                        voice.onPress = { pressed++ }; voice.onRelease = { released++ }
                        val geometry = voice.javaClass.getDeclaredMethod("geometry").apply { isAccessible = true }.invoke(voice) as FloatArray
                        val point = floatArrayOf(geometry[0], geometry[1])
                        val global = android.graphics.Matrix(); voice.transformMatrixToGlobal(global); global.mapPoints(point)
                        val parent = android.graphics.Matrix(); viewport.transformMatrixToGlobal(parent)
                        val inverse = android.graphics.Matrix(); check(parent.invert(inverse)); inverse.mapPoints(point)
                        val now = SystemClock.uptimeMillis()
                        for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)) {
                            val event = android.view.MotionEvent.obtain(now, now, action, point[0], point[1], 0)
                            viewport.dispatchTouchEvent(event); event.recycle()
                        }
                        check(pressed == 1 && released == 1) { "Scaled voice hit target missed" }
                    }
                    capture("voice-layout-${width}x${height}.png")
                }
            } finally {
                test.runOnMainSync {
                    viewport.layoutParams = viewport.layoutParams.apply { width = originalWidth; height = originalHeight }
                }
            }
            return "PASS: uniform home scaling, compact/landscape fit and transformed touch targets; fixed voice/caption and 140x48 Delete fully visible; home has no vertical scroll; circular hold/slide-out/re-entry verified\n"
        } finally { test.runOnMainSync { activity.finish() } }
    }
}
