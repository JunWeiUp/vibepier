package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import io.github.junweiup.vibepier.remote.features.sessions.NewSessionOptionsView
import io.github.junweiup.vibepier.remote.fixtures.ConversationReviewFixtures
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Native creation controls and encrypted draft state, using synthetic options/receipts only. */
object NewSessionComposerProbe {
    fun run(test: Instrumentation): String {
        fun field(value: Any, name: String) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
        fun set(value: Any, name: String, content: Any) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(value, content)
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun main(block: () -> Unit) {
            var error: Throwable? = null
            test.runOnMainSync { try { block() } catch (value: Throwable) { error = value } }
            error?.let { throw it }
        }
        fun settle() { SystemClock.sleep(250); test.waitForIdleSync() }
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "new-composer")) as MainActivity
        try {
            lateinit var panel: ConversationPanel; lateinit var client: SessionClient
            lateinit var dialog: AlertDialog; lateinit var options: NewSessionOptionsView
            val cwd = "/fixture/new-composer-" + UUID.randomUUID()
            fun show() {
                panel.javaClass.getDeclaredMethod("showNewSession").apply { isAccessible = true }.invoke(panel)
                @Suppress("UNCHECKED_CAST") val dialogs = field(panel, "auxiliaryDialogs") as Set<AlertDialog>
                dialog = dialogs.last { it.isShowing }
                options = views(dialog.window!!.decorView).filterIsInstance<NewSessionOptionsView>().single()
            }
            fun menu(): AlertDialog {
                @Suppress("UNCHECKED_CAST") val menus = field(options, "menus") as List<AlertDialog>
                return menus.last { it.isShowing }
            }
            fun choose(index: Int) {
                val list = menu().listView
                list.performItemClick(list.getChildAt(index), index, list.adapter.getItemId(index))
            }
            main {
                panel = activity.sessionNavigation.panel!!; client = field(panel, "client") as SessionClient
                client.provider = "codex"
                set(panel, "projectCwd", cwd); set(panel, "projectName", "Fixture"); set(panel, "drawer", true)
                ConversationReviewFixtures.newRequestBodies.clear()
                show()
            }
            settle()
            main { check(options.ready); (field(options, "model") as View).performClick() }
            settle(); main { choose(1) }; settle(); main { choose(2) }; settle()
            main { check(options.draft.model == "gpt-6-astra" && options.draft.effort == "high"); (field(options, "mode") as View).performClick() }
            settle(); main { choose(2) }; settle()
            main { menu().getButton(AlertDialog.BUTTON_NEGATIVE).performClick() }; settle()
            main { check(!options.draft.confirmFullAccess) }
            main { (field(options, "mode") as View).performClick() }; settle(); main { choose(2) }; settle()
            main { menu().getButton(AlertDialog.BUTTON_POSITIVE).performClick() }; settle()
            main { check(options.draft.confirmFullAccess && options.ready) }
            val attachment = UUID.randomUUID().toString()
            lateinit var draftID: String
            main {
                draftID = options.draft.id
                check(client.saveAttachments(options.draft.attachmentScope, JSONArray().put(JSONObject()
                    .put("attachmentId", attachment).put("name", "example.png").put("mime", "image/png").put("complete", true)), "codex"))
                views(dialog.window!!.decorView).filterIsInstance<EditText>().single().setText("First fixture message")
            }
            SystemClock.sleep(350); test.waitForIdleSync()
            main {
                val persisted = client.creationDraft(cwd, "codex")
                check(persisted.text == "First fixture message" && persisted.id == draftID && persisted.confirmFullAccess)
                dialog.dismiss()
            }
            settle(); main { show() }
            settle()
            main {
                check(options.draft.id == draftID && options.draft.model == "gpt-6-astra" && options.draft.effort == "high")
                check(options.draft.mode == "full-access" && options.draft.confirmFullAccess)
                val controls = views(dialog.window!!.decorView)
                check(controls.filterIsInstance<EditText>().single().text.toString() == "First fixture message")
                check(controls.filterIsInstance<CanvasLabel>().any { it.text.toString().contains("example.png") })
                val start = controls.filterIsInstance<CanvasLabel>().single { it.text.toString() == activity.getString(R.string.session_start) && it.isClickable }
                val bounds = android.graphics.Rect()
                check(start.getGlobalVisibleRect(bounds) && bounds.height() == start.height) { "Start must stay fully visible" }
            }
            test.uiAutomation.takeScreenshot()?.let { bitmap ->
                try { java.io.File(activity.externalCacheDir, "new-session-composer.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } }
                finally { bitmap.recycle() }
            }
            main {
                views(dialog.window!!.decorView).filterIsInstance<CanvasLabel>().single {
                    it.text.toString() == activity.getString(R.string.session_start) && it.isClickable
                }.performClick()
            }
            settle()
            main {
                check(!dialog.isShowing)
                val request = ConversationReviewFixtures.newRequestBodies.single()
                check(request.optString("model") == "gpt-6-astra" && request.optString("effort") == "high")
                check(request.optString("mode") == "full-access" && request.optBoolean("confirmFullAccess"))
                check(request.getJSONArray("attachments").getString(0) == attachment)
                check(request.optString("draftId") == draftID && request.optString("cwd") == cwd)
                check(client.creationDraft(cwd, "codex").id != draftID)
                check(client.attachments("creation:$draftID", "codex").length() == 0)
                val nativeChoices = NewSessionOptionsView(activity,
                    io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft(UUID.randomUUID().toString(), "zcode", "/fixture/zcode"), {}, {})
                nativeChoices.applyOptions(JSONObject().put("ok", true).put("creationVersion", 1)
                    .put("models", JSONArray().put(JSONObject().put("id", "native-model").put("name", "Native model").put("efforts", JSONArray().put("opaque-effort-id"))))
                    .put("efforts", JSONArray().put(JSONObject().put("id", "opaque-effort-id").put("name", "Native deep reasoning")))
                    .put("permissionModes", JSONArray().put(JSONObject().put("id", "plan").put("name", "Plan")))
                    .put("composer", JSONObject().put("model", "native-model").put("effort", "opaque-effort-id").put("mode", "plan")))
                check(nativeChoices.ready)
                val modelText = (field(nativeChoices, "model") as CanvasLabel).text.toString()
                check(modelText.contains("Native deep reasoning") && !modelText.contains("opaque-effort-id"))
            }
            return "PASS: native model/effort/mode controls, explicit full-access confirmation, scoped image draft restore, exact first-message payload and confirmed-draft cleanup\n"
        } finally { main { activity.finish() } }
    }
}
