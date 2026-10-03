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
import android.widget.ScrollView
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.transport.RemoteSender
import io.github.junweiup.vibepier.remote.features.remote.Palette
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** README photography of production widgets with local, bilingual demonstration data. No Mac connection. */
object ReadmePreviewProbe {
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
            capture("readme-home.png")
            test.runOnMainSync { activity.sessionNavigation.show() }
            settle()
            val panel = checkNotNull(activity.sessionNavigation.panel)
            val title = copy("Polish the connection flow", "优化连接体验")
            test.runOnMainSync {
                field(panel, "projectName").set(panel, "harbor-app")
                panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }
                    .invoke(panel, "00000000-0000-4000-8000-000000000001", title)
            }
            settle()
            fun part(id: String, kind: String, title: String, text: String) = JSONObject()
                .put("id", id).put("kind", kind).put("title", title).put("text", text).put("status", "completed")
            val parts = JSONArray()
                .put(part("readme-summary", "text", "", copy(
                    "The connection flow is ready.\n\nThe phone now shows **what is happening** and keeps the next action within reach.",
                    "连接流程已整理好。\n\n手机现在会清楚显示**当前状态**，并把下一步操作放在触手可及的位置。")))
                .put(part("readme-file", "file", "ConnectionStatus.kt", "")
                    .put("added", 18).put("removed", 6).put("files", JSONArray().put(JSONObject()
                        .put("path", "src/ConnectionStatus.kt").put("kind", "update").put("added", 18).put("removed", 6))))
                .put(part("readme-tests", "command", "npm run test:ui", "12 tests passed")
                    .put("durationMs", 1240).put("description", copy("Verify the connection states", "验证连接状态")))
                .put(part("readme-result", "text", "", copy(
                    "### What changed\n\n- Clearer connected and reconnecting states\n- One-tap access to your sessions\n- Existing shortcuts kept intact\n\nReady for your review.",
                    "### 本次调整\n\n- 区分已连接与重新连接状态\n- 一键进入正在进行的会话\n- 保留原有快捷键配置\n\n可以开始查看这次改动了。")))
            val page = JSONObject().put("ok", true).put("event", "snapshot").put("provider", "codex")
                .put("threadId", "00000000-0000-4000-8000-000000000001").put("title", title).put("revision", 100)
                .put("capabilities", JSONObject().put("markdownFiles", true).put("projectFiles", true))
                .put("status", "idle").put("canSend", true).put("hasOlder", false).put("approvals", JSONArray())
                .put("composer", JSONObject().put("model", "gpt-6.1-sol").put("effort", "medium").put("mode", "auto"))
                .put("messages", JSONArray().put(JSONObject().put("id", "readme-user").put("role", "user")
                    .put("text", copy("Polish the first connection experience. Keep the existing shortcuts.", "优化首次连接体验，保留已有快捷键。")))
                    .put(JSONObject().put("id", "readme-assistant").put("role", "assistant").put("parts", parts)))
            test.runOnMainSync {
                panel.javaClass.getDeclaredMethod("applyPage", JSONObject::class.java).apply { isAccessible = true }.invoke(panel, page)
            }
            settle()
            test.runOnMainSync { (field(panel, "scroll").get(panel) as ScrollView).scrollTo(0, 0) }
            settle()
            capture("readme-conversation.png")
            return "PASS: captured native home and conversation with synthetic ${if (chinese) "Chinese" else "English"} data; no real transport or provider actions"
        } finally { test.runOnMainSync { activity.finish() } }
    }
}
