package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.view.MotionEvent
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import io.github.junweiup.vibepier.remote.fixtures.ConversationReviewFixtures
import org.json.JSONArray
import org.json.JSONObject

/** Real Android controls with synthetic native state; no real approval or provider side effects. */
object ApprovalActionsProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval")) as MainActivity
        fun field(value: Any, name: String) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun invoke(panel: ConversationPanel, name: String, page: JSONObject) = panel.javaClass
            .getDeclaredMethod(name, JSONObject::class.java).apply { isAccessible = true }.invoke(panel, page)
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
        }
        fun settle() { SystemClock.sleep(250); test.waitForIdleSync() }
        lateinit var panel: ConversationPanel
        try {
            settle()
            main {
                panel = activity.sessionNavigation.panel as ConversationPanel
                views(panel).first { it.contentDescription?.toString()?.startsWith(activity.getString(R.string.session_open_session)) == true }.performClick()
            }
            settle()
            var revision = 100L
            for (provider in listOf("codex", "claude")) for (decision in listOf("allow", "deny", "option", "answer", "readonly-option")) {
                lateinit var page: JSONObject
                lateinit var dialog: AlertDialog
                val actionLabel = when (decision) {
                    "option", "readonly-option" -> "Allow synthetic option"
                    "answer" -> activity.getString(R.string.session_submit_answer)
                    "deny" -> activity.getString(R.string.session_deny)
                    else -> activity.getString(R.string.session_allow_once)
                }
                fun actionButton() = views(dialog.window!!.decorView).single { it.contentDescription == actionLabel }
                main {
                    ConversationReviewFixtures.approvalRequestBodies.clear()
                    (field(panel, "client") as SessionClient).provider = provider
                    val approval = JSONObject().put("id", "$provider-$decision").put("fingerprint", "$provider-$decision-v1")
                        .put("title", "Synthetic approval").put("details", "Read a synthetic test file")
                        .put("canDecide", decision != "readonly-option")
                    if (decision.endsWith("option")) approval.put("options", JSONArray().put(actionLabel).put("Reject synthetic option"))
                    if (decision == "answer") approval.put("kind", "questions").put("method", "item/tool/requestUserInput")
                        .put("questions", JSONArray().put(JSONObject().put("id", "q1").put("question", "Synthetic question")
                            .put("freeform", true).put("options", JSONArray())))
                    page = ConversationReviewFixtures.conversation("approval").put("provider", provider)
                        .put("revision", revision++).put("capabilities", JSONObject().put("approvals", false))
                        .put("approvals", JSONArray().put(approval))
                    invoke(panel, "applyPage", page)
                    invoke(panel, "showApproval", approval)
                    dialog = field(panel, "approvalDialog") as AlertDialog
                }
                settle()
                main {
                    check(!actionButton().isEnabled) { "Unsupported approval was enabled" }
                    if (decision == "answer") views(dialog.window!!.decorView).filterIsInstance<android.widget.EditText>().single().setText("Synthetic answer")
                    page = JSONObject(page.toString()).put("revision", revision++)
                        .put("capabilities", JSONObject().put("approvals", true))
                    invoke(panel, "applyPage", page)
                }
                settle()
                if (decision == "readonly-option") {
                    main {
                        check(!actionButton().isEnabled) { "Read-only native option must not become actionable" }
                        actionButton().performClick()
                    }
                    settle()
                    main {
                        check(ConversationReviewFixtures.approvalRequestBodies.isEmpty()) { "Read-only native option was submitted" }
                        check(dialog.isShowing); dialog.dismiss()
                    }
                    continue
                }
                main {
                    check(actionButton().isEnabled) { "Approval stayed disabled after capability recovery ($provider/$decision)" }
                    page = JSONObject(page.toString()).put("revision", revision++)
                        .put("capabilities", JSONObject().put("approvals", false))
                    invoke(panel, "applyPage", page)
                    check(!actionButton().isEnabled) { "Approval stayed enabled after capability loss" }
                    invoke(panel, "applyPage", JSONObject(page.toString()).put("revision", revision++)
                        .put("capabilities", JSONObject().put("approvals", true)))
                }
                settle()
                val bounds = android.graphics.Rect()
                main {
                    val target = actionButton()
                    check(target.getGlobalVisibleRect(bounds))
                    val location = IntArray(2); target.getLocationOnScreen(location)
                    bounds.set(location[0], location[1], location[0] + target.width, location[1] + target.height)
                }
                val screenshot = checkNotNull(test.uiAutomation.takeScreenshot())
                try {
                    java.io.File(test.targetContext.getExternalFilesDir(null), "approval-$provider-$decision.png").outputStream().use {
                        check(screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
                    }
                } finally { screenshot.recycle() }
                val down = SystemClock.uptimeMillis()
                for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                    val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
                        bounds.exactCenterX(), bounds.exactCenterY(), 0)
                    event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
                    try { check(test.uiAutomation.injectInputEvent(event, true)) } finally { event.recycle() }
                }
                main {
                    check(!actionButton().isEnabled) { "Duplicate decision remained enabled" }
                }
                settle()
                main {
                    check(!dialog.isShowing) { "Confirmed synthetic approval dialog did not close" }
                    val submitted = ConversationReviewFixtures.approvalRequestBodies.single()
                    check(submitted.optString("provider") == provider)
                    when (decision) {
                        "option" -> check(submitted.optString("option") == actionLabel)
                        "answer" -> check(submitted.getJSONObject("answers").getString("q1") == "Synthetic answer")
                        else -> check(submitted.opt("allow") == (decision == "allow"))
                    }
                    check(submitted.optString("fingerprint") == "$provider-$decision-v1") { "Decision addressed a different approval" }
                }
            }
            return "PASS: Codex/Claude approval capability recovery/loss, allow/deny/options/question answers via real touch, in-flight duplicate guard and confirmed dismissal. Synthetic native results only."
        } finally { main { activity.finish() } }
    }
}
