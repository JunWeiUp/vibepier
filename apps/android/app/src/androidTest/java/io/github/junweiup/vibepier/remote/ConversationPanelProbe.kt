package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import io.github.junweiup.vibepier.remote.fixtures.ConversationReviewFixtures

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.ScrollView
import org.json.JSONArray
import org.json.JSONObject

/** Synthetic state updates against actual rendered views; never opens or sends to a real desktop thread. */
object ConversationPanelProbe {
    fun run(test: Instrumentation): String {
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval"))
        fun field(value: Any, name: String): Any? = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
        fun call(value: Any, name: String, argument: JSONObject) = value.javaClass.getDeclaredMethod(name, JSONObject::class.java).apply { isAccessible = true }.invoke(value, argument)
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        lateinit var panel: ConversationPanel
        try {
            SystemClock.sleep(250); test.waitForIdleSync()
            test.runOnMainSync {
                panel = (activity as MainActivity).sessionNavigation.panel as ConversationPanel
                (field(panel, "client") as SessionClient).provider = "codex"
                views(panel).first { it.contentDescription?.toString()?.startsWith(activity.getString(R.string.session_open_session) + "优化手机语音与快捷控制") == true }.performClick()
            }
            SystemClock.sleep(250); test.waitForIdleSync()
            lateinit var current: JSONObject
            test.runOnMainSync {
                current = ConversationReviewFixtures.conversation("approval").put("revision", 10)
                call(panel, "applyPage", current)
                call(panel, "applyPage", ConversationReviewFixtures.conversation("approval").put("revision", 9).put("messages", JSONArray()))
                check((field(panel, "page") as JSONObject).getLong("revision") == 10L)
                call(panel, "applyPage", JSONObject(current.toString()).put("threadId", "other").put("revision", 20))
                check((field(panel, "page") as JSONObject).getLong("revision") == 10L)
                call(panel, "showApproval", current.getJSONArray("approvals").getJSONObject(0))
            }
            test.waitForIdleSync()
            lateinit var dialog: AlertDialog
            test.runOnMainSync {
                dialog = field(panel, "approvalDialog") as AlertDialog
                val allow = views(dialog.window!!.decorView).first { it.contentDescription?.toString() == activity.getString(R.string.session_allow_once) }
                check(!allow.isEnabled)
                val scroll = views(dialog.window!!.decorView).filterIsInstance<ScrollView>().first { it.isShown && it.canScrollVertically(1) }
                scroll.isSmoothScrollingEnabled = false
                scroll.fullScroll(View.FOCUS_DOWN)
            }
            SystemClock.sleep(100); test.waitForIdleSync()
            test.runOnMainSync {
                val allow = views(dialog.window!!.decorView).first { it.contentDescription?.toString() == activity.getString(R.string.session_allow_once) }
                check(allow.isEnabled) { "Approval disabled: ready=${field(panel, "ready")}, provider=${(field(panel, "client") as SessionClient).provider}, submitting=${field(panel, "submittingApproval")}, page=${(field(panel, "page") as JSONObject).optJSONObject("capabilities")}; scroll=" + views(dialog.window!!.decorView).filterIsInstance<ScrollView>().map { "y=${it.scrollY}, more=${it.canScrollVertically(1)}" } }
                val changed = JSONObject(current.toString()); changed.getJSONArray("approvals").getJSONObject(0).put("fingerprint", "updated-request")
                call(panel, "applyPage", changed.put("revision", 11))
                check(!dialog.isShowing)
                check((field(panel, "notice") as CanvasLabel).text.toString()== activity.getString(R.string.session_the_request_changed_review_it_again))
                call(panel, "showApproval", changed.getJSONArray("approvals").getJSONObject(0))
                dialog = field(panel, "approvalDialog") as AlertDialog
                call(panel, "applyPage", JSONObject(changed.toString()).put("revision", 12).put("approvals", JSONArray()))
                check(!dialog.isShowing)
                check((field(panel, "notice") as CanvasLabel).text.toString()== activity.getString(R.string.session_the_request_was_handled_or_is_no_longer_valid))
                call(panel, "applyPage", current) // Must not resurrect the dismissed request.
                check((field(panel, "page") as JSONObject).getJSONArray("approvals").length() == 0)
            }
            // Exercise the same production dialog with native and asynchronous questions.
            test.runOnMainSync {
                val questions = JSONArray().put(JSONObject().put("id", "q1").put("question", "选择哪种方案？")
                    .put("freeform", true).put("options", JSONArray().put(JSONObject().put("label", "方案 A").put("description", "推荐选项"))))
                    .put(JSONObject().put("id", "q2").put("question", "还有什么要求？").put("freeform", true).put("options", JSONArray()))
                val card = JSONObject().put("id", "question1").put("fingerprint", "question-v1").put("kind", "questions")
                    .put("method", "item/tool/requestUserInput").put("title", "回答 Codex 的问题").put("canDecide", true).put("questions", questions)
                current = JSONObject(current.toString()).put("revision", 30).put("approvals", JSONArray().put(card))
                call(panel, "applyPage", current)
                call(panel, "showApproval", card)
                dialog = field(panel, "approvalDialog") as AlertDialog
            }
            test.waitForIdleSync()
            test.uiAutomation.takeScreenshot()?.let { bitmap ->
                java.io.File(test.targetContext.getExternalFilesDir(null), "codex-questions.png").outputStream().use {
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                }
                bitmap.recycle()
            }
            test.runOnMainSync {
                fun submit() = views(dialog.window!!.decorView).filterIsInstance<CanvasLabel>().first { it.text == activity.getString(R.string.session_submit_answer) }
                check(!submit().isEnabled) // No preselected answer and no automatic submit.
                val choice = views(dialog.window!!.decorView).first { it.contentDescription == "方案 A" + activity.getString(R.string.session_not_selected) }
                choice.performClick()
                check(choice.isSelected)
                check(!submit().isEnabled) // Blocking questions require every answer.
                val fields = views(dialog.window!!.decorView).filterIsInstance<android.widget.EditText>()
                fields[0].setText("自定义答案")
                check(!choice.isSelected)
                fields[1].setText("第二个答案")
                check(submit().isEnabled)
                dialog.dismiss()
                call(panel, "showApproval", current.getJSONArray("approvals").getJSONObject(0))
                dialog = field(panel, "approvalDialog") as AlertDialog
                check(views(dialog.window!!.decorView).filterIsInstance<android.widget.EditText>()[0].text.toString() == "自定义答案")
                val changed = JSONObject(current.toString()).put("revision", 31)
                changed.getJSONArray("approvals").getJSONObject(0).put("fingerprint", "question-v2").put("method", "vibepier/asyncQuestions")
                call(panel, "applyPage", changed)
                check(!dialog.isShowing)
                call(panel, "showApproval", changed.getJSONArray("approvals").getJSONObject(0))
                dialog = field(panel, "approvalDialog") as AlertDialog
                views(dialog.window!!.decorView).filterIsInstance<android.widget.EditText>()[0].setText("只回答第一题")
                check(submit().isEnabled)
                call(panel, "applyPage", JSONObject(changed.toString()).put("revision", 32).put("approvals", JSONArray()))
                check(!dialog.isShowing)
            }
            return "PASS: old revision rejected, wrong thread rejected, full-read approval gating, changed request invalidation, desktop decision expiry, no stale approval resurrection; questions: no default submit, options/custom input, all-answer gating, partial async answer, draft retention, stale question dismissal\n"
        } finally { test.runOnMainSync { activity.finish() } }
    }
}
