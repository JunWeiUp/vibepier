package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import io.github.junweiup.vibepier.remote.features.remote.ApplicationPickerPage
import org.json.JSONArray
import org.json.JSONObject

/** Real picker with synthetic Mac catalog and callbacks. Never edits or launches a real Mac application. */
object ApplicationPickerProbe {
    fun run(test: Instrumentation): String {
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
        }
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "offline")) as MainActivity
        var source = "mac-one"
        var selected = ""
        var writes = 0
        var reads = 0
        var saveReply: ((JSONObject) -> Unit)? = null
        fun catalog() = JSONObject().put("ok", true).put("revision", "revision-$writes")
            .put("applications", JSONArray().put(JSONObject().put("bundleID", "demo.codex").put("name", "Codex")).put(JSONObject().put("bundleID", "demo.claude").put("name", "Claude")))
            .put("shortcuts", JSONArray().apply { for (i in 0..4) put(JSONObject().put("slot", i).put("bundleID", if (i == 0) selected else "").put("name", if (i == 0 && selected.isNotEmpty()) "Codex" else "")) })
        lateinit var page: ApplicationPickerPage
        fun root() = page.dialog.window!!.decorView
        fun click(label: String) = views(root()).single { it.contentDescription?.toString() == label && it.isClickable }.performClick()
        try {
            main {
                activity.sessionNavigation.panel?.close()
                page = ApplicationPickerPage(activity, { op, fields, reply ->
                    when (op) {
                        "applications" -> { reads++; reply(catalog()) }
                        "applicationShortcutSet" -> {
                            writes++; check(fields.getInt("index") == 0)
                            check(fields.getString("revision") == "revision-${writes - 1}")
                            selected = fields.getString("bundleID"); saveReply = reply
                        }
                        else -> error("Unexpected operation: $op")
                    }
                }, initialSlot = 0, source = { source })
                page.show()
            }
            test.waitForIdleSync()
            main {
                views(root()).filterIsInstance<EditText>().single().setText("codex")
                check(views(root()).none { it.contentDescription == "Claude\ndemo.claude" })
                click("Codex\ndemo.codex")
                check(writes == 1 && selected == "demo.codex")
                // A second tap while saving must not submit another request.
                click("Codex\ndemo.codex"); check(writes == 1)
                saveReply!!(catalog())
                check(views(root()).any { it.contentDescription == activity.getString(R.string.app_picker_saved) })
                click(activity.getString(R.string.app_picker_slot, 1, "Codex"))
                click(activity.getString(R.string.app_picker_clear)); check(writes == 2 && selected.isEmpty())
                saveReply!!(JSONObject().put("ok", false).put("error", "Synthetic conflict"))
                click(activity.getString(R.string.app_picker_refresh)); check(reads == 2)
            }
            test.waitForIdleSync()
            main {
                val close = views(root()).single { it.contentDescription == activity.getString(R.string.app_picker_close) && it.isClickable }
                val rect = android.graphics.Rect()
                check(close.getGlobalVisibleRect(rect) && rect.height() == close.height) { "Close must remain reachable" }
                views(root()).filterIsInstance<EditText>().single().setText("")
            }
            test.waitForIdleSync(); android.os.SystemClock.sleep(300)
            test.uiAutomation.takeScreenshot()?.let { bitmap ->
                try { java.io.File(activity.externalCacheDir, "application-picker.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } } finally { bitmap.recycle() }
            }
            main {
                source = "mac-two"
                click("Codex\ndemo.codex"); check(writes == 2)
                check(views(root()).any { it.contentDescription == activity.getString(R.string.app_picker_source_changed) })
                page.dismiss()
                // A callback after dismissal cannot reopen the picker or change its state.
                saveReply!!(catalog()); check(!page.dialog.isShowing)
                activity.javaClass.getDeclaredMethod("showApplicationPicker", Integer::class.java).apply { isAccessible = true }.invoke(activity, 0)
                val shown = activity.javaClass.getDeclaredField("applicationPicker").apply { isAccessible = true }.get(activity) as ApplicationPickerPage
                check(shown.dialog.isShowing); shown.dismiss()
            }
            return "PASS: app picker search/select/clear, duplicate save guard, conflict refresh, dismissal and real activity entry; synthetic catalog only\n"
        } finally { main { runCatching { page.dismiss() }; activity.finish() } }
    }
}
