package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.widget.EditText
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import org.json.JSONArray
import org.json.JSONObject

/** Synthetic native UI: no provider process, credentials, remote sends or real cancellations. */
object SessionBlockerProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "queued")) as MainActivity
        fun field(target: Any, name: String) = target.javaClass.getDeclaredField(name).apply { isAccessible = true }
        fun settle() { test.waitForIdleSync(); SystemClock.sleep(300); test.waitForIdleSync() }
        try {
            settle()
            test.runOnMainSync { activity.sessionNavigation.show() }
            settle()
            val panel = checkNotNull(activity.sessionNavigation.panel)
            test.runOnMainSync {
                panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }
                    .invoke(panel, "blocker-demo", "Blocker demonstration")
            }
            settle()
            val apply = panel.javaClass.getDeclaredMethod("applyPage", JSONObject::class.java).apply { isAccessible = true }
            val render = panel.javaClass.getDeclaredMethod("renderWaitState").apply { isAccessible = true }
            fun snapshot() = JSONObject((field(panel, "page").get(panel) as JSONObject).toString())
            fun label(name: String) = field(panel, name).get(panel) as CanvasLabel
            fun checkMessage(id: Int) { check(label("waitMessage").text.toString().contains(activity.getString(id))) }
            test.runOnMainSync {
                val page = snapshot().put("status", "active").put("activeTurnId", "fixture-turn").put("approvals", JSONArray())
                    .put("blocker", JSONObject().put("code", "rateLimit"))
                apply.invoke(panel, page)
                checkMessage(R.string.session_wait_rate_limit)
                check(label("waitCancel").text.toString() == activity.getString(R.string.session_stop_waiting))
                (field(panel, "editor").get(panel) as EditText).setText("Keep my draft")
                check(label("waitCancel").isEnabled)
            }
            settle()
            val screenshot = test.uiAutomation.takeScreenshot()
            java.io.File(activity.getExternalFilesDir(null), "session-blocker.png").outputStream().use {
                screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            screenshot.recycle()
            test.runOnMainSync {
                val button = label("stopButton"); val bounds = android.graphics.Rect()
                check(button.getGlobalVisibleRect(bounds) && bounds.height() >= button.height - 1) { "Cancel button clipped" }
                label("waitCancel").performClick()
                checkMessage(R.string.session_wait_stopping)
                check(!label("stopButton").isEnabled) { "Duplicate stop remained enabled" }
            }
            settle()
            test.runOnMainSync {
                check(snapshot().optString("status") == "idle") { "Fixture cancellation did not complete" }
                check((field(panel, "editor").get(panel) as EditText).text.toString() == "Keep my draft")
                val page = snapshot().put("status", "active").put("activeTurnId", "fixture-turn")
                page.remove("blocker"); apply.invoke(panel, page)
                field(panel, "lastProgressAt").setLong(panel, SystemClock.elapsedRealtime() - 61_000)
                render.invoke(panel); checkMessage(R.string.session_wait_slow)
                apply.invoke(panel, snapshot().put("status", "idle").put("activeTurnId", ""))
                check((field(panel, "waitBanner").get(panel) as View).visibility == View.GONE)
                field(panel, "ready").setBoolean(panel, false); render.invoke(panel)
                checkMessage(R.string.session_wait_loading)
                check(label("waitCancel").text.toString() == activity.getString(R.string.session_stop_waiting))
                label("waitCancel").performClick()
                check(!field(panel, "drawer").getBoolean(panel)) { "Stop waiting left the conversation" }
                check((field(panel, "waitBanner").get(panel) as View).visibility == View.GONE)
                render.invoke(panel)
                check((field(panel, "waitBanner").get(panel) as View).visibility == View.GONE) { "Periodic render restarted the same wait" }
                check((field(panel, "editor").get(panel) as EditText).text.toString() == "Keep my draft")
                // Exercise durable wait detachment using synthetic receipts in the isolated review package.
                val client = field(panel, "client").get(panel) as io.github.junweiup.vibepier.remote.core.session.SessionClient
                val prefs = io.github.junweiup.vibepier.remote.core.security.PrivatePreferences.open(activity, "sessions")
                val id = java.util.UUID.randomUUID().toString()
                val other = java.util.UUID.randomUUID().toString()
                val target = "wait-detach-$id"
                val original = JSONObject().put("id", id).put("op", "send").put("threadId", target)
                    .put("provider", client.provider).put("text", "synthetic original").put("attachments", JSONArray().put("synthetic-file"))
                val separate = JSONObject(original.toString()).put("id", other).put("threadId", "other-$id")
                check(prefs.edit().putString("pending.$id", original.toString()).putString("pending.$other", separate.toString()).commit())
                try {
                    check(client.waitingOperations(target).size == 1)
                    check(client.stopWaiting(target))
                    check(client.waitingOperations(target).isEmpty())
                    check(client.uncertain(target).single().toString() == original.toString()) { "Stop waiting modified the receipt" }
                    check(client.waitingOperations("other-$id").size == 1) { "Stop waiting affected another session" }
                    check(client.duplicateUnconfirmedSend(target, "synthetic original", JSONArray()))
                    check(!client.duplicateUnconfirmedSend(target, "synthetic new", JSONArray()))
                    check(prefs.getStringSet("stoppedWaiting.${client.sessionScope(target)}", emptySet()) == setOf(id))
                    val next = java.util.UUID.randomUUID().toString()
                    check(prefs.edit().putString("pending.$next", JSONObject(original.toString()).put("id", next).toString()).commit())
                    check(client.waitingOperations(target).single().optString("id") == next) { "A new operation inherited the stopped wait" }
                    client.clearReceipt(next)
                } finally {
                    client.clearReceipt(id); client.clearReceipt(other)
                    prefs.edit().remove("stoppedWaiting.${client.sessionScope(target)}").commit()
                }
            }
            return "PASS: rate-limit banner, visible cancellation with draft, confirmed fixture stop, slow/idle reset, local stop-waiting. Synthetic UI only."
        } finally { test.runOnMainSync { activity.finish() } }
    }
}
