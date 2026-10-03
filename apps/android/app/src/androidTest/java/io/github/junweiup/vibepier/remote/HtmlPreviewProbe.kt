package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.files.ProjectFileHost
import io.github.junweiup.vibepier.remote.features.files.ProjectFileViewer
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Emulator-only: fully synthetic HTML, no provider requests or external browsing. */
object HtmlPreviewProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "files")) as MainActivity
        fun main(block: () -> Unit) {
            var error: Throwable? = null
            test.runOnMainSync { try { block() } catch (e: Throwable) { error = e } }
            error?.let { throw it }
        }
        fun field(value: Any, name: String) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }
        fun views(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) } else emptyList()
        fun evaluate(web: WebView, script: String): String {
            val latch = CountDownLatch(1); var result = ""
            main { web.evaluateJavascript(script) { result = it; latch.countDown() } }
            check(latch.await(5, TimeUnit.SECONDS)); return result
        }
        lateinit var viewer: ProjectFileViewer
        try {
            val html = """
                <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
                <style>body{margin:0;padding:24px;background:#f5f2ea;color:#243b36;font-family:sans-serif}h1{font-size:32px;color:#235e50}section{padding:24px;background:white;border-radius:18px;margin:24px 0}button{padding:14px 24px;background:#235e50;color:white;border:0;border-radius:10px}strong{font-size:48px}</style></head>
                <body><h1>时间洞察 · 预览演示</h1><p>HTML 样式与交互测试</p><section><p>专注时间</p><strong id="count">3</strong><p>小时</p></section><button onclick="document.getElementById('count').textContent='4'">增加一小时</button>
                <script>window.inlineReady=true;fetch('https://blocked.invalid/test').catch(()=>window.networkBlocked=true)</script>
            """.trimIndent() + "<!--" + "x".repeat(9000) + "-->" + "<p id='tail'>完整分块已加载</p></body></html>"
            var reads = 0
            val handler = Handler(Looper.getMainLooper())
            main {
                val host = ProjectFileHost(activity, "fixture", "codex", { op, args, callback ->
                    check(op == "readFile"); reads++
                    val offset = args.getInt("offset")
                    val all = html.toByteArray(Charsets.UTF_8)
                    val chunk = if (offset == 0) all.copyOfRange(0, 8000) else all.copyOfRange(offset, all.size)
                    // First boundary is inside the ASCII padding comment, so UTF-8 remains intact.
                    handler.post { callback(JSONObject().put("ok", true).put("path", "demo.HTML").put("size", all.size)
                        .put("version", "fixture-html").put("text", chunk.toString(Charsets.UTF_8))
                        .put("nextOffset", if (offset == 0) 8000 else -1)) }
                }, { true }, { false }, { _, _ -> }, { false }, {})
                viewer = ProjectFileViewer(host, "demo.HTML"); viewer.show()
            }
            var web: WebView? = null
            repeat(30) {
                if (web == null) { SystemClock.sleep(100); main { web = field(viewer, "htmlPreview").get(viewer) as? WebView } }
            }
            val preview = checkNotNull(web)
            var ready = false
            repeat(30) { if (!ready) { SystemClock.sleep(100); ready = evaluate(preview, "window.inlineReady === true && window.networkBlocked === true && !!document.getElementById('tail')") == "true" } }
            check(ready) { "HTML script, final chunk or blocked network did not settle" }
            check(reads == 2)
            check(evaluate(preview, "getComputedStyle(document.querySelector('h1')).color") == "\"rgb(35, 94, 80)\"")
            check(evaluate(preview, "document.querySelector('button').click(); document.getElementById('count').textContent") == "\"4\"")
            main {
                check(!preview.settings.allowFileAccess && !preview.settings.allowContentAccess && preview.settings.blockNetworkLoads)
                views(viewer.dialog.window!!.decorView).filterIsInstance<CanvasLabel>().single { it.text.toString() == activity.getString(R.string.files_source) }.performClick()
                check(preview.parent == null)
                check((field(viewer, "raw").get(viewer) as StringBuilder).toString() == html)
                views(viewer.dialog.window!!.decorView).filterIsInstance<CanvasLabel>().single { it.text.toString() == activity.getString(R.string.files_preview) }.performClick()
                check(preview.parent != null)
            }
            check(evaluate(preview, "document.getElementById('count').textContent") == "\"4\"")
            test.uiAutomation.takeScreenshot()?.let { bitmap ->
                java.io.File(activity.getExternalFilesDir(null), "html-preview.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
            }
            main { viewer.dismiss(); check(field(viewer, "htmlPreview").get(viewer) == null) }
            return "PASS: multi-chunk HTML default preview, inline styles/scripts, blocked network, source toggle/state preservation and renderer cleanup."
        } finally { main { activity.finish() } }
    }
}
