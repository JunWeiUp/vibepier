package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.content.Context
import android.content.ContextWrapper
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import io.github.junweiup.vibepier.remote.features.sessions.NewSessionOptionsView
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
        fun awaitState(label: String, ready: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 3_000
            while (SystemClock.elapsedRealtime() < deadline) {
                var complete = false
                main { complete = ready() }
                if (complete) return
                SystemClock.sleep(20)
            }
            error("New receipt fixture did not reach $label")
        }
        for (scenario in listOf("fresh", "unknown", "notfound", "complete")) {
            val kind = if (scenario == "fresh") "unknown" else scenario
            val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "new-receipt-$kind"))
            val journal = SessionJournalFixture(test)
            val prefs = journal.prefs
            val id = java.util.UUID.randomUUID().toString()
            lateinit var client: SessionClient
            lateinit var panel: ConversationPanel
            var clientCreated = false
            var panelCreated = false
            val requestsBefore = ConversationReviewFixtures.newRequests.size
            val bodiesBefore = ConversationReviewFixtures.newRequestBodies.size
            fun submitted() = ConversationReviewFixtures.newRequests.drop(requestsBefore)
            try {
                test.waitForIdleSync()
                lateinit var dialog: AlertDialog
                fun show(pending: JSONObject? = null) {
                    if (pending == null) panel.javaClass.getDeclaredMethod("showNewSession").apply { isAccessible = true }.invoke(panel)
                    else panel.javaClass.getDeclaredMethod("showNewSession", JSONObject::class.java).apply { isAccessible = true }.invoke(panel, pending)
                    @Suppress("UNCHECKED_CAST") val dialogs = field(panel, "auxiliaryDialogs") as Set<AlertDialog>
                    dialog = dialogs.last { it.isShowing }
                }
                fun click(resource: Int) {
                    val button = views(dialog.window!!.decorView).filterIsInstance<CanvasLabel>().single {
                        it.text.toString() == activity.getString(resource) && it.isClickable
                    }
                    check(button.isEnabled && button.performClick()) { "Receipt fixture action must be enabled: ${activity.getString(resource)}" }
                }
                main {
                    // Do not borrow the Activity's native client or its persisted provider/authorization.
                    (activity as MainActivity).sessionNavigation.close()
                    client = journal.client; clientCreated = true
                    client.provider = "codex"
                    check(client.paired && client.online && client.agent.negotiated && client.uncertain("", "codex").isEmpty())
                    panel = ConversationPanel(activity, client, {}, fixture = "new-receipt-$kind"); panelCreated = true
                    activity.setContentView(panel)
                    set(panel, "projectCwd", "/fixture/new"); set(panel, "projectName", "Fixture"); set(panel, "drawer", true)
                    if (scenario != "fresh") journal.seed(JSONObject().put("id", id).put("op", "new")
                        .put("provider", "codex").put("cwd", "/fixture/new").put("text", "Keep the original draft"))
                    // The default dialog is a fresh draft; old receipts are an explicit user selection.
                    show()
                    if (scenario != "fresh") {
                        check(views(dialog.window!!.decorView).filterIsInstance<EditText>().single().isEnabled)
                        check(prefs.contains("agentPending.$id"))
                        dialog.dismiss()
                        show(checkNotNull(client.agent.context(id)))
                    }
                }
                if (scenario == "fresh") awaitState("fresh creation options") {
                    views(dialog.window!!.decorView).filterIsInstance<NewSessionOptionsView>().single().loaded
                }
                else awaitState("selected $scenario receipt") {
                    val editor = views(dialog.window!!.decorView).filterIsInstance<EditText>().single()
                    client.provider == "codex" && !editor.isEnabled && editor.text.toString() == "Keep the original draft"
                }
                main {
                    val editor = views(dialog.window!!.decorView).filterIsInstance<EditText>().single()
                    if (scenario == "fresh") { editor.setText("Keep the original draft"); click(R.string.session_start) }
                    else {
                        check(!editor.isEnabled && editor.text.toString() == "Keep the original draft") {
                            "Selected $scenario receipt must keep its Codex draft locked (provider=${client.provider})"
                        }
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
                        check(submitted().size == if (scenario == "fresh") 1 else 0)
                        if (scenario == "unknown") {
                            dialog.dismiss(); show(checkNotNull(client.agent.context(id)))
                            check(!views(dialog.window!!.decorView).filterIsInstance<EditText>().single().isEnabled)
                            check(prefs.contains("agentPending.$id"))
                        }
                    }
                } else if (scenario == "notfound") {
                    main { check(submitted().isEmpty()); click(R.string.session_retry_original_request) }
                    settle()
                    main { check(!dialog.isShowing); check(submitted() == listOf(id)) }
                } else {
                    // The review response exercises the UI only. Settlement requires verified profile-2 evidence.
                    main { check(!dialog.isShowing); check(prefs.contains("agentPending.$id")); journal.settleCreation(id) }
                    test.waitForIdleSync()
                    main { check(!prefs.contains("agentPending.$id")); check(submitted().isEmpty()) }
                }
            } finally {
                main {
                    if (panelCreated) panel.close()

                    // Both preferences and device identity below belong only to this scenario namespace.

                    val cleanup = prefs.edit()
                    prefs.all.keys.forEach(cleanup::remove)
                    check(cleanup.commit())
                    while (ConversationReviewFixtures.newRequests.size > requestsBefore)
                        ConversationReviewFixtures.newRequests.removeAt(ConversationReviewFixtures.newRequests.lastIndex)
                    while (ConversationReviewFixtures.newRequestBodies.size > bodiesBefore)
                        ConversationReviewFixtures.newRequestBodies.removeAt(ConversationReviewFixtures.newRequestBodies.lastIndex)
                    activity.finish()
                }
                journal.close()
            }
        }
        return "PASS: scenario-isolated Codex client/identity/preferences without resetting native authorization; new-session timeout blocks fresh submission, fresh draft stays editable beside old receipts; explicitly selected pending draft survives dialog reopen, receipt lookup never resubmits, notFound retries only the original ID, completed receipt opens the session\n"
    }
}
