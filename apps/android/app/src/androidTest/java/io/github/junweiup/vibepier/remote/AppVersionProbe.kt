package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.ScrollView
import io.github.junweiup.vibepier.remote.features.files.ProjectFileHost
import io.github.junweiup.vibepier.remote.features.files.ProjectFileViewer
import io.github.junweiup.vibepier.remote.features.updates.AvailableAppVersion
import org.json.JSONObject

/** Isolated review UI, synthetic version and file responses; never contacts a Mac. */
object AppVersionProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "files")) as MainActivity
        fun field(value: Any, name: String) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }
        fun views(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) } else emptyList()
        fun main(block: () -> Unit) {
            var error: Throwable? = null
            test.runOnMainSync { try { block() } catch (e: Throwable) { error = e } }
            error?.let { throw it }
        }
        fun settle() { SystemClock.sleep(200); test.waitForIdleSync() }
        try {
            settle()
            lateinit var versions: Any
            main {
                versions = activity.javaClass.getDeclaredMethod("getAppVersions").apply { isAccessible = true }.invoke(activity)!!
                field(versions, "available").set(versions, AvailableAppVersion(6, "0.1.0-beta.1"))
                activity.javaClass.getDeclaredMethod("showConnectionOptions").apply { isAccessible = true }.invoke(activity)
            }
            settle()
            lateinit var sheet: Any
            lateinit var dialog: AlertDialog
            main {
                sheet = field(activity, "settingsSheet").get(activity)!!
                dialog = field(sheet, "dialog").get(sheet) as AlertDialog
                val all = views(dialog.window!!.decorView)
                check(all.any { it.contentDescription?.contains(activity.getString(R.string.app_version_available, "0.1.0-beta.1", 6L)) == true })
                ((field(sheet, "body").get(sheet) as View).parent as ScrollView).fullScroll(View.FOCUS_DOWN)
            }
            settle()
            main {
                val footer = views(dialog.window!!.decorView).first { it.contentDescription?.contains(activity.getString(R.string.app_version_available, "0.1.0-beta.1", 6L)) == true }
                val bounds = android.graphics.Rect()
                check(footer.getGlobalVisibleRect(bounds) && bounds.height() >= footer.height - 1) { "Version footer must be visible after scrolling" }
            }
            test.uiAutomation.takeScreenshot()?.let { bitmap ->
                java.io.File(activity.getExternalFilesDir(null), "app-version-update.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
            main {
                field(versions, "available").set(versions, null)
                sheet.javaClass.getDeclaredMethod("refresh").invoke(sheet)
                check(views(dialog.window!!.decorView).none { it.contentDescription?.contains(activity.getString(R.string.app_version_available, "0.1.0-beta.1", 6L)) == true })
                dialog.dismiss()
            }
            var requests = 0
            lateinit var viewer: ProjectFileViewer
            val handler = Handler(Looper.getMainLooper())
            val chunks = listOf("<html>" + "a".repeat(8000), "b".repeat(8000), "</html>")
            main {
                val host = ProjectFileHost(activity, "fixture", "codex", { op, _, callback ->
                    check(op == "readFile")
                    val index = requests++
                    check(index < chunks.size)
                    handler.post { callback(JSONObject().put("ok", true).put("path", "example.html").put("size", 16013)
                        .put("version", "fixture-v1").put("text", chunks[index])
                        .put("nextOffset", if (index == 2) -1 else chunks.take(index + 1).sumOf { it.toByteArray().size })) }
                }, { true }, { false }, { _, _ -> }, { false }, {})
                viewer = ProjectFileViewer(host, "example.html")
                viewer.show()
            }
            repeat(15) { settle(); if (requests >= 3) return@repeat }
            main { check(requests == 3); check(field(viewer, "complete").getBoolean(viewer)); viewer.dismiss() }
            return "PASS: version footer, new-version indicator and clearing; HTML reader completes three synthetic chunks while source list starts detached."
        } finally { main { activity.finish() } }
    }
}
