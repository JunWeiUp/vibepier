package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import io.github.junweiup.vibepier.remote.fixtures.ConversationReviewFixtures
import org.json.JSONObject

/** Real dialog clicks with synthetic receipts; no provider, real phone or Mac is contacted. */
object NewSessionReceiptProbe {
    fun run(test: Instrumentation): String {
        fun field(value: Any, name: String) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
        fun set(value: Any, name: String, content: Any) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(value, content)
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun main(block: () -> Unit) {
            var error: Throwable? = null
            test.runOnMainSync { try { block() } catch (failure: Throwable) { error = failure } }
            error?.let { throw it }
        }
        fun settle() { SystemClock.sleep(220); test.waitForIdleSync() }
        for (scenario in listOf("fresh", "unknown", "notfound", "complete")) {
            val kind = if (scenario == "fresh") "unknown" else scenario
            val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "new-receipt-$kind"))
            val prefs = PrivatePreferences.open(activity, "sessions")
            val id = "new-probe-" + java.util.UUID.randomUUID()
            try {
                test.waitForIdleSync()
                lateinit var panel: ConversationPanel
                lateinit var dialog: AlertDialog
                fun show() {
                    panel.javaClass.getDeclaredMethod("showNewSession").apply { isAccessible = true }.invoke(panel)
                    @Suppress("UNCHECKED_CAST") val dialogs = field(panel, "auxiliaryDialogs") as Set<AlertDialog>
                    dialog = dialogs.last { it.isShowing }
                }
                fun click(resource: Int) {
                    views(dialog.window!!.decorView).filterIsInstance<CanvasLabel>().single {
                        it.text.toString() == activity.getString(resource) && it.isClickable
                    }.performClick()
                }
                main {
                    panel = (activity as MainActivity).sessionNavigation.panel as ConversationPanel
                    set(panel, "projectCwd", "/fixture/new"); set(panel, "projectName", "Fixture"); set(panel, "drawer", true)
                    ConversationReviewFixtures.newRequests.clear()
                    if (scenario != "fresh") check(prefs.edit().putString("pending.$id", JSONObject().put("id", id).put("op", "new")
                        .put("provider", "codex").put("cwd", "/fixture/new").put("text", "Keep the original draft").toString()).commit())
                    show()
                }
                settle()
                main {
                    val editor = views(dialog.window!!.decorView).filterIsInstance<EditText>().single()
                    if (scenario == "fresh") { editor.setText("Keep the original draft"); click(R.string.session_start) }
                    else {
                        check(!editor.isEnabled && editor.text.toString() == "Keep the original draft")
                        click(R.string.session_check_result)
                    }
                }
                settle()
                if (scenario == "fresh" || scenario == "unknown") {
                    main {
                        check(dialog.isShowing)
                        check(!views(dialog.window!!.decorView).filterIsInstance<EditText>().single().isEnabled)
                        click(R.string.session_check_result)
                    }
                    settle()
                    main {
                        check(ConversationReviewFixtures.newRequests.size == if (scenario == "fresh") 1 else 0)
                        if (scenario == "unknown") {
                            dialog.dismiss(); show()
                            check(!views(dialog.window!!.decorView).filterIsInstance<EditText>().single().isEnabled)
                            check(prefs.contains("pending.$id"))
                        }
                    }
                } else if (scenario == "notfound") {
                    main { check(ConversationReviewFixtures.newRequests.isEmpty()); click(R.string.session_retry_original_request) }
                    settle()
                    main { check(!dialog.isShowing); check(ConversationReviewFixtures.newRequests == listOf(id)) }
                } else main { check(!dialog.isShowing); check(!prefs.contains("pending.$id")); check(ConversationReviewFixtures.newRequests.isEmpty()) }
            } finally {
                main { prefs.edit().remove("pending.$id").commit(); activity.finish() }
            }
        }
        return "PASS: new-session timeout blocks fresh submission, pending draft survives dialog reopen, receipt lookup never resubmits, notFound retries only the original ID, completed receipt opens the session\n"
    }
}
