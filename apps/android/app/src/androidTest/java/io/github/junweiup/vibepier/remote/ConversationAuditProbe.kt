package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.sessions.ConversationTimeline
import io.github.junweiup.vibepier.remote.features.sessions.InlineReplyProcess
import io.github.junweiup.vibepier.remote.features.sessions.ConversationMessageRenderer
import io.github.junweiup.vibepier.remote.features.sessions.ConversationRenderScope
import io.github.junweiup.vibepier.remote.features.sessions.ConversationTimelineContent
import org.json.JSONArray
import org.json.JSONObject

/** Uses actual Android views with synthetic pages; no native provider/control operation. */
object ConversationAuditProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "queued")) as MainActivity
        fun field(target: Any, name: String) = target.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(target)
        fun main(action: () -> Unit) {
            val failure = java.util.concurrent.atomic.AtomicReference<Throwable>()
            test.runOnMainSync { try { action() } catch (error: Throwable) { failure.set(error) } }
            failure.get()?.let { throw it }
        }
        var originalProvider: String? = null
        fun settle() { test.waitForIdleSync(); SystemClock.sleep(250); test.waitForIdleSync() }
        try {
            settle()
            main { activity.sessionNavigation.show() }
            val panel = checkNotNull(activity.sessionNavigation.panel)
            main {
                val client = field(panel, "client") as SessionClient
                originalProvider = client.provider; client.provider = "codex"
                panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }
                    .invoke(panel, "audit-demo", "Synthetic conversation")
            }
            settle()
            main {
                val apply = panel.javaClass.getDeclaredMethod("applyPage", JSONObject::class.java).apply { isAccessible = true }
                fun page() = JSONObject((field(panel, "page") as JSONObject).toString())
                val baseline = page()
                check(baseline.optString("threadId") == "audit-demo" && field(panel, "ready") == true) {
                    "Synthetic page not ready: thread=${baseline.optString("threadId")}, ready=${field(panel, "ready")}, drawer=${field(panel, "drawer")}" }
                baseline.put("capabilities", JSONObject(baseline.optJSONObject("capabilities")?.toString() ?: "{}")
                    .put("queue", true).put("send", true).put("interrupt", true))
                apply.invoke(panel, baseline)
                val editor = field(panel, "editor") as EditText
                val send = field(panel, "sendButton") as CanvasLabel
                val stop = field(panel, "stopButton") as View
                check(!send.isEnabled && send.text.toString() == activity.getString(R.string.conversation_queue_send)) {
                    "Expected empty queued composer: provider=${(field(panel, "client") as SessionClient).provider}, text=${send.text}, enabled=${send.isEnabled}, status=${page().optString("status")}" }
                check(stop.isEnabled) { "Only the header should offer a verified stop" }
                send.performClick()
                check((field(panel, "page") as JSONObject).optString("status") == "active")
                editor.setText("Keep this draft")
                check(send.isEnabled && stop.isEnabled)
                val staleCreation = panel.navigationState().put("creationAttachment", true).put("creationPickerToken", "closed-dialog")
                val dummyUri = android.net.Uri.parse("content://synthetic/never-read")
                check(!panel.addPickedCreationAttachment(dummyUri, staleCreation))
                check(!panel.addRestoredPhoneAttachment(dummyUri, staleCreation)) { "Creation picker fell through to an ordinary thread" }
                val timeline = field(panel, "timeline") as LinearLayout
                val originalRows = (0 until timeline.childCount).map(timeline::getChildAt)
                val process = (field(panel, "renderedProcesses") as List<*>).first() as InlineReplyProcess
                val states = field(panel, "processStates") as Map<*, *>
                val state = states.values.first() as InlineReplyProcess.State
                state.bodies.getValue("p-cmd-1").apply { expanded = true; loaded = true; text = "Cached output"; nextOffset = -1 }
                state.changed()
                val changed = page()
                changed.getJSONArray("messages").getJSONObject(1).getJSONArray("parts").getJSONObject(1)
                    .put("text", "Streamed progress")
                apply.invoke(panel, changed)
                check(originalRows.size == timeline.childCount)
                originalRows.forEachIndexed { index, view -> check(timeline.getChildAt(index) === view) { "Unchanged message/streaming process row was recreated" } }
                check((field(panel, "renderedProcesses") as List<*>).first() === process)
                check(state.bodies.getValue("p-cmd-1").expanded && state.bodies.getValue("p-cmd-1").text == "Cached output")
                apply.invoke(panel, page().put("blocker", JSONObject().put("code", "rateLimit")))
                val waiting = field(panel, "waitCancel") as CanvasLabel
                check(waiting.text.toString() == activity.getString(R.string.session_stop_waiting))
                check(panel.navigationState().optString("provider") == "codex")
                waiting.performClick()
                check(field(panel, "drawer") == false)
                check((field(panel, "waitMessage") as CanvasLabel).text.toString().contains(activity.getString(R.string.session_wait_stopping))) { "Stop waiting did not request cancellation of the verified turn" }

                // Reorder/prepend/delete through the production reconciler without detaching kept rows.
                val holder = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
                val rows = ConversationTimeline(holder)
                var builds = 0
                fun row(key: String, signature: String = key) = ConversationTimeline.Row(key, signature, {
                    builds++; CanvasLabel(activity).apply { text = key; layoutParams = LinearLayout.LayoutParams(200, 120) }
                }, { view -> (view as CanvasLabel).text = signature; true })
                rows.reconcile(listOf(row("a"), row("b")))
                val a = holder.getChildAt(0); val b = holder.getChildAt(1)
                holder.measure(View.MeasureSpec.makeMeasureSpec(200, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
                holder.layout(0, 0, 200, holder.measuredHeight)
                val anchor = checkNotNull(rows.anchor(130))
                rows.reconcile(listOf(row("prefix"), row("a"), row("b", "changed")))
                check(builds == 3 && holder.getChildAt(1) === a && holder.getChildAt(2) === b)
                holder.measure(View.MeasureSpec.makeMeasureSpec(200, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
                holder.layout(0, 0, 200, holder.measuredHeight)
                check(rows.position(anchor) == 250) { "Prepend did not preserve the visible row offset" }
                rows.reconcile(listOf(row("b", "changed"), row("a")))
                check(holder.childCount == 2 && holder.getChildAt(0) === b && holder.getChildAt(1) === a)

                // A late click on a removed row must never act on another provider/thread/binding.
                var scope = ConversationRenderScope("authorization", "codex", "original", 1)
                var approvalClicks = 0; var expanded = 0
                val renderer = ConversationMessageRenderer(activity, { scope.provider }, { _, _ -> View(activity) },
                    { View(activity) }, {}, { expanded++ }, { scope }, { true })
                val content = ConversationTimelineContent(activity, renderer, { "Codex" }, {}, { approvalClicks++ }, { scope }, { true })
                val approval = JSONObject().put("id", "approval").put("fingerprint", "original-request").put("title", "Synthetic approval")
                val oldApproval = content.rows(JSONArray(), JSONArray().put(approval), emptyList(), false, false, false, View(activity))
                    .first { it.key.startsWith("approval:") }.create() as LinearLayout
                val oldMessage = renderer.render(JSONObject().put("id", "message").put("role", "assistant").put("text", "Synthetic text").put("hasMore", true)) as LinearLayout
                val oldExpand = (0 until oldMessage.childCount).map(oldMessage::getChildAt).filterIsInstance<CanvasLabel>().last()
                oldApproval.getChildAt(oldApproval.childCount - 1).performClick(); oldExpand.performClick()
                check(approvalClicks == 1 && expanded == 1)
                scope = scope.copy(source = "replacement", provider = "claude", thread = "other", generation = 2)
                oldApproval.getChildAt(oldApproval.childCount - 1).performClick(); oldExpand.performClick()
                check(approvalClicks == 1 && expanded == 1) { "A stale row action followed the new conversation target" }
            }
            return "PASS: explicit queue/send, empty composer never stops, header stop survives drafts, keyed View/process reuse, expanded cached output retained, prepend/reorder/delete reconciliation, visible-row anchor, local stop-waiting retains active task, invalid creation picker rejected, stale row handlers reject changed source/provider/thread/generation. Synthetic UI only."
        } finally { main {
            originalProvider?.let { previous -> activity.sessionNavigation.panel?.let { (field(it, "client") as SessionClient).provider = previous } }
            activity.finish()
        } }
    }
}
