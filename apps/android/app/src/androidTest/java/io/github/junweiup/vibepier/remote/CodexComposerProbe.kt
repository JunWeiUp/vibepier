package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.transport.RemoteSender
import io.github.junweiup.vibepier.remote.core.transport.ShortcutSnapshot
import io.github.junweiup.vibepier.remote.features.sessions.ComposerControls
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel

import android.app.Instrumentation
import android.content.Intent
import android.content.Context
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import org.json.JSONArray
import org.json.JSONObject

/** Real composer views with synthetic state; never sends to a desktop conversation. */
object CodexComposerProbe {
    fun run(test: Instrumentation): String {
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval"))
        fun member(o: Any, name: String) = o.javaClass.getDeclaredField(name).apply { isAccessible = true }
        fun get(o: Any, name: String) = member(o, name).get(o)
        fun set(o: Any, name: String, value: Any) = member(o, name).set(o, value)
        fun invoke(o: Any, name: String) = o.javaClass.getDeclaredMethod(name).apply { isAccessible = true }.invoke(o)
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        val prefs = io.github.junweiup.vibepier.remote.core.security.PrivatePreferences.open(test.targetContext, "sessions")
        var pendingID = ""
        val client = activity.javaClass.getDeclaredMethod("getCodex").apply { isAccessible = true }.invoke(activity) as SessionClient
        val originalProvider = client.provider
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
        }
        try {
            main {
                (activity as MainActivity).sessionNavigation.close()
                client.provider = "codex"
                activity.sessionNavigation.show()
            }
            SystemClock.sleep(250); test.waitForIdleSync()
            lateinit var panel: ConversationPanel
            main {
                panel = (activity as MainActivity).sessionNavigation.panel as ConversationPanel
                (views(panel).firstOrNull { it.contentDescription?.toString()?.startsWith(activity.getString(R.string.session_open_session) + "优化手机语音与快捷控制，VibePier") == true } ?: error("Fixture session row missing")).performClick()
            }
            SystemClock.sleep(250); test.waitForIdleSync()
            main {
                // Returning from a picker must preserve an already-watched transport and the panel.
                val sender = activity.javaClass.getDeclaredMethod("getSender").apply { isAccessible = true }.invoke(activity) as RemoteSender
                set(sender, "watching", true)
                var resets = 0
                sender.onApplication = { resets++ }
                activity.intent.putExtra("codexFixture", "")
                set((activity as MainActivity).sessionNavigation, "pickingAttachment", true)
                activity.javaClass.getDeclaredMethod("onPause").apply { isAccessible = true }.invoke(activity)
                check((activity as MainActivity).sessionNavigation.panel === panel)
                activity.javaClass.getDeclaredMethod("onActivityResult", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, Intent::class.java).apply { isAccessible = true }.invoke(activity, 940, 0, null)
                activity.javaClass.getDeclaredMethod("onResume").apply { isAccessible = true }.invoke(activity)
                check((activity as MainActivity).sessionNavigation.panel === panel && resets == 0)
                activity.intent.putExtra("codexFixture", "approval")
                set(sender, "watching", false)
                val editor = get(panel, "editor") as EditText
                val send = get(panel, "sendButton") as View
                val controls = get(panel, "composerControls") as ComposerControls
                editor.setText("Keep my new draft")
                check(send.isEnabled)
                val timeline = get(panel, "timeline")
                set(sender, "bindingsRevision", "unchanged-bindings"); set(sender, "bindingsComplete", true)
                val shortcuts = get(sender, "shortcutSnapshot") as ShortcutSnapshot<RemoteSender.AppShortcut>
                shortcuts.begin("unchanged-icons", 8)
                for (i in 0..7) shortcuts.append("unchanged-icons", i, entry = RemoteSender.AppShortcut(i, "app-$i", "App $i", "", true))
                var iconClears = 0; sender.onShortcuts = { if (it.isEmpty()) iconClears++ }
                activity.javaClass.getDeclaredMethod("onPause").apply { isAccessible = true }.invoke(activity)
                check((activity as MainActivity).sessionNavigation.panel === panel && get(panel, "timeline") === timeline)
                check(editor.text.toString() == "Keep my new draft" && !send.isEnabled)
                check(shortcuts.revision == "unchanged-icons" && shortcuts.count == 8 && shortcuts.complete && iconClears == 0)
                check(get(sender, "bindingsComplete") == true)
                activity.javaClass.getDeclaredMethod("onResume").apply { isAccessible = true }.invoke(activity)
                check((activity as MainActivity).sessionNavigation.panel === panel && get(panel, "timeline") === timeline)
                check(editor.text.toString() == "Keep my new draft" && send.isEnabled)
                set(panel, "settingsOperation", "pending-settings"); invoke(panel, "updateComposer")
                check(!send.isEnabled && !controls.mode.isEnabled && !controls.model.isEnabled)
                check((get(panel, "stopButton") as View).isEnabled && (get(panel, "stopButton") as View).isShown) // Stop remains possible with a draft.
                set(panel, "settingsOperation", ""); set(panel, "uploading", true); set(panel, "uploadLabel", "Uploading")
                invoke(panel, "updateComposer"); check(!send.isEnabled)
                set(panel, "reviewAttachments", JSONArray().put(JSONObject().put("attachmentId", "test-file").put("name", "notes.txt").put("size", 100)))
                set(panel, "uploading", false); set(panel, "uploadLabel", ""); invoke(panel, "updateComposer")
                val remove = views(panel).firstOrNull { it.contentDescription?.toString() == activity.getString(R.string.session_remove_attachment, "notes.txt") } ?: error("Attachment missing after resume; reviews=${get(panel, "reviews")}, draft=${editor.text}")
                check(remove.isEnabled)
                set(panel, "sending", true); invoke(panel, "updateComposer")
                check(!(views(panel).firstOrNull { it.contentDescription?.toString() == activity.getString(R.string.session_remove_attachment, "notes.txt") } ?: error("Attachment missing while sending")).isEnabled)
                set(panel, "sending", false)
                // Simulate an unknown persisted settings receipt without transmitting any request.
                val client = get(panel, "client") as SessionClient
                set(panel, "reviews", false); set(client, "online", true)
                val thread = get(panel, "thread") as String
                pendingID = "composer-probe-" + java.util.UUID.randomUUID()
                prefs.edit().putString("pending.$pendingID", JSONObject().put("id", pendingID).put("op", "settings").put("threadId", thread).put("mode", "auto").toString()).commit()
                invoke(panel, "updateComposer")
                check(!send.isEnabled && !controls.mode.isEnabled && !controls.model.isEnabled)
                check((get(panel, "stopButton") as View).isEnabled && (get(panel, "stopButton") as View).isShown)
                prefs.edit().remove("pending.$pendingID").commit(); set(panel, "reviews", true)
                // Opening another conversation resets transient work; delayed callbacks use generation tokens.
                set(panel, "uploading", true); set(panel, "settingsOperation", "old-thread-operation")
                val before = get(panel, "uploadGeneration") as Int
                panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }.invoke(panel, "another-fixture", "Another thread")
                check(get(panel, "uploading") == false && get(panel, "settingsOperation") == "")
                check((get(panel, "uploadGeneration") as Int) > before)
            }
            return "PASS: Activity background/foreground retains panel, timeline and draft; unchanged icon and binding caches survive watch stop; picker cancel/resume preserves panel and watched transport without reset, pending settings blocks send, unknown settings blocks send/model/mode, stop works with draft, upload blocks send, remove disabled while sending, thread switch clears transient settings/upload and invalidates callbacks\n"
        } finally {
            if (pendingID.isNotEmpty()) prefs.edit().remove("pending.$pendingID").commit()
            main { client.provider = originalProvider; activity.finish() }
        }
    }
}
