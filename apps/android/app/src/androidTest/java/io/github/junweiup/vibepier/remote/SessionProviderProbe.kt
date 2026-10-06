package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionProvider
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import io.github.junweiup.vibepier.remote.features.sessions.ComposerControls
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import io.github.junweiup.vibepier.remote.features.settings.SettingsSheet
import io.github.junweiup.vibepier.remote.fixtures.ConversationReviewFixtures

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.SystemClock
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.view.InputDevice
import android.view.MotionEvent
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** An isolated encrypted peer and fixture UI; never sends an operation to a real Mac. */
object SessionProviderProbe {
    private class Transport : SessionTransport {
        override val mode = "bluetooth"
        override var enrollmentReady = true
        override var onSessionFrame: (JSONObject) -> Unit = {}
        override var onSessionPair: (ByteArray?) -> Unit = {}
        val frames = CopyOnWriteArrayList<JSONObject>()
        override fun sendBinding(message: JSONObject) { frames.add(JSONObject(message.toString())) }
        override fun requestSessionPair(device: String, name: String) {}
        override fun readSessionPair() {}
    }
    private fun field(target: Any, name: String) = target.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(target)
    private fun call(target: Any, name: String, vararg arguments: Any) = target.javaClass.declaredMethods.first {
        it.name == name && it.parameterCount == arguments.size
    }.apply { isAccessible = true }.invoke(target, *arguments)
    private fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()

    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val prefsName = "provider-probe-${UUID.randomUUID()}"
        val context = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("${prefsName}-${name}", Context.MODE_PRIVATE)
        }
        val prefs = io.github.junweiup.vibepier.remote.core.security.PrivatePreferences.open(context, "sessions")
        val transport = Transport()
        lateinit var client: SessionClient
        var clientCreated = false
        val key = SecretKeySpec(ByteArray(32) { 19 }, "AES")
        fun reply(value: JSONObject) {
            val packet = UUID.randomUUID().toString()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key); cipher.updateAAD("vibepier-session-v1|mac|${client.device}|$packet".toByteArray())
            val data = Base64.encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray()), Base64.NO_WRAP)
            val pieces = data.chunked(900)
            pieces.forEachIndexed { i, part -> transport.onSessionFrame(JSONObject().put("type", "vibepier-session1").put("sender", client.device).put("device", client.device).put("packet", packet).put("part", i).put("parts", pieces.size).put("data", part)) }
        }
        fun requests(): List<JSONObject> = transport.frames.map { it.getString("packet") }.distinct().mapNotNull { packet ->
            val frames = transport.frames.filter { it.getString("packet") == packet }.sortedBy { it.getInt("part") }
            if (frames.size != frames.first().getInt("parts")) return@mapNotNull null
            val data = Base64.decode(frames.joinToString("") { it.getString("data") }, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, data.copyOfRange(0, 12)))
            cipher.updateAAD("vibepier-session-v1|phone|${client.device}|$packet".toByteArray())
            JSONObject(String(cipher.doFinal(data.copyOfRange(12, data.size))))
        }
        val peer = SessionProfile2Peer(test, { client }, ::requests, ::reply)
        var activity: MainActivity? = null
        var panel: ConversationPanel? = null
        try {
            peer.main {
                client = SessionClient(context, transport, 2_000); clientCreated = true; client.connectionChanged(true); client.pair()
                transport.onSessionPair(JSONObject().put("state", "approved").put("device", client.device)
                    .put("key", Base64.encodeToString(ByteArray(32) { 19 }, Base64.NO_WRAP)).toString().toByteArray())
            }
            test.waitForIdleSync(); check(client.paired)
            peer.negotiate()
            peer.discover("codex", "same")
            peer.main {
                for (provider in SessionProvider.ids) {
                    client.provider = provider
                    client.saveDraft("same", "$provider draft")
                    client.saveAttachments("same", JSONArray().put(JSONObject().put("attachmentId", provider)))
                    client.rememberPage("same", JSONObject().put("title", provider))
                    client.rememberProcess("same", "reply", JSONObject().put("text", provider))
                }
                for (provider in SessionProvider.ids) {
                    client.provider = provider
                    check(client.draft("same") == "$provider draft")
                    check(client.attachments("same").getJSONObject(0).getString("attachmentId") == provider)
                    check(client.cachedPage("same")!!.getString("title") == provider)
                    check(client.cachedProcess("same", "reply")!!.getString("text") == provider)
                }
            }
            // Current writes require discovery, a fresh native snapshot and a lease.
            val (operation, mutation) = peer.submit("codex", "same", "codex draft") {}
            peer.main {
                client.provider = "claude"
                check(client.uncertain("same").isEmpty())
                check(client.uncertain("same", "codex").size == 1)
            }
            SystemClock.sleep(2_100); test.waitForIdleSync()
            check(client.uncertain("same", "codex").single().getString("id") == operation)
            reply(peer.confirmed(mutation)); test.waitForIdleSync()
            peer.main {
                check(client.provider == "claude" && client.draft("same") == "claude draft")
                check(client.draft("same", "codex").isEmpty())
                check(client.attachments("same").length() == 1 && client.attachments("same", "codex").length() == 0)
                client.request("list", JSONObject().put("limit", 8)) {}
            }
            val listRequest = peer.latest("session.list")
            check(listRequest.getJSONObject("body").getJSONObject("target").getString("adapterId") == "claude")
            peer.read(listRequest, JSONObject().put("sessions", JSONArray()).put("nextOffset", -1))
            peer.main {
                prefs.edit().putString("draft.legacy", "existing Claude draft").commit()
                check(client.draft("legacy", "retired-provider").isEmpty())
                check(client.draft("legacy", "claude").isEmpty())
                client.saveDraft("legacy", "current Claude draft", "claude")
                check(client.draft("legacy", "claude") == "current Claude draft")
                check(prefs.getString("draft.legacy", null) == "existing Claude draft")
            }
            activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval")) as MainActivity
            test.waitForIdleSync()
            peer.main {
                (field(activity!!, "settingsSheet") as? SettingsSheet)?.dismiss()
                ((activity as MainActivity).sessionNavigation.panel as? ConversationPanel)?.close()
                client.provider = "codex"
                val host = field(activity!!, "rootHost") as FrameLayout
                host.getChildAt(0).importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                panel = ConversationPanel(activity!!, client, { panel?.let(host::removeView) }, fixture = "approval")
                host.addView(panel, FrameLayout.LayoutParams(-1, -1)); panel!!.requestApplyInsets()
                check(views(panel!!).any { it.contentDescription?.toString() == activity!!.getString(R.string.choice_selected, "Codex", activity!!.getString(R.string.session_sessions)) })
                check(views(panel!!).first { it.contentDescription?.toString() == activity!!.getString(R.string.choice_switch, "Claude Code", activity!!.getString(R.string.session_sessions)) }.performClick())
                check(client.provider == "claude")
                check(views(panel!!).any { it.contentDescription?.toString() == activity!!.getString(R.string.choice_selected, "Claude Code", activity!!.getString(R.string.session_sessions)) })
                check((field(activity!!, "settingsSheet") as? SettingsSheet)?.isShowing != true)
            }
            test.waitForIdleSync()
            // Exercise the real overlay's hit testing, with the remote settings controls still underneath it.
            fun touchProvider(provider: String) {
                var x = 0f; var y = 0f
                peer.main {
                    val view = views(panel!!).first { it.contentDescription?.toString() == activity!!.getString(R.string.choice_switch, SessionProvider.name(provider), activity!!.getString(R.string.session_sessions)) }
                    val bounds = android.graphics.Rect(); check(view.getGlobalVisibleRect(bounds))
                    x = bounds.exactCenterX(); y = bounds.exactCenterY()
                }
                val time = SystemClock.uptimeMillis()
                for ((action, offset) in listOf(MotionEvent.ACTION_DOWN to 0L, MotionEvent.ACTION_UP to 30L)) {
                    val event = MotionEvent.obtain(time, time + offset, action, x, y, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
                    test.sendPointerSync(event); event.recycle()
                }
                test.waitForIdleSync()
                peer.main {
                    check(client.provider == provider)
                    check(views(panel!!).any { it.contentDescription?.toString() == activity!!.getString(R.string.choice_selected, SessionProvider.name(provider), activity!!.getString(R.string.session_sessions)) })
                    check((field(activity!!, "settingsSheet") as? SettingsSheet)?.isShowing != true)
                }
            }
            touchProvider("codex"); touchProvider("claude")
            peer.main { call(panel!!, "open", "same", "Claude Code QA") }
            SystemClock.sleep(220); test.waitForIdleSync()
            peer.main {
                val capabilities = JSONObject()
                for (name in listOf("send", "new", "interrupt", "settings", "modelSelection", "permissionMode", "attachments", "approvals", "queue")) capabilities.put(name, false)
                val value = ConversationReviewFixtures.conversation("approval").put("provider", "claude").put("threadId", "same")
                    .put("revision", 10).put("canSend", false).put("capabilities", capabilities).put("status", "active").put("hasOlder", true)
                    .put("queuedMessages", JSONArray().put(JSONObject().put("id", "foreign-queue").put("text", "hidden")))
                value.getJSONObject("composer").put("contextUsage", "")
                call(panel!!, "applyPage", value)
                check(field(panel!!, "ready") == true)
                // A readable session keeps local drafting available even when send is unsupported.
                val readOnlyEditor = field(panel!!, "editor") as EditText
                check(readOnlyEditor.isEnabled)
                readOnlyEditor.setText("Local draft without send authority")
                check(!(field(panel!!, "sendButton") as View).isEnabled)
                val controls = field(panel!!, "composerControls") as ComposerControls
                check(controls.add.visibility == View.GONE && !controls.add.isEnabled)
                // Model/mode selectors remain inspectable; fresh preparation still guards writes.
                check(controls.model.isEnabled && controls.mode.isEnabled)
                check(controls.contextUsage.visibility == View.VISIBLE)
                check((field(panel!!, "stopButton") as View).visibility == View.GONE)
                check((field(panel!!, "queuedBox") as LinearLayout).childCount == 0)
                call(panel!!, "loadOlder", false)
                check(field(panel!!, "loadingHistory") == true)
                capabilities.put("send", true)
                call(panel!!, "applyPage", JSONObject(value.toString()).put("revision", 11).put("canSend", true))
                (field(panel!!, "editor") as EditText).setText("Claude Code reply")
                check((field(panel!!, "sendButton") as View).isEnabled)
                check((field(panel!!, "sendButton") as View).contentDescription.toString() != activity!!.getString(R.string.session_add_to_the_send_queue))
                call(panel!!, "applyPage", JSONObject(value.toString()).put("provider", "codex").put("revision", 99))
                check((field(panel!!, "page") as JSONObject).optLong("revision") == 11L)
            }
            return "PASS: Claude Code request identity; provider-isolated durable drafts, attachments, pages, process cache and uncertain operations; late Codex receipt preserves Claude Code draft; unscoped old draft retained without migration; Codex/Claude performClick navigation and real overlay pointer hit testing without opening remote settings; Claude Code read-only composer/queue/interrupt gating; read-only history remains available; explicit send capability and live canSend; wrong-provider snapshot rejected\n"
        } finally {
            peer.main { panel?.close(); activity?.finish(); if (clientCreated) client.close() }
            if (clientCreated) KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("vibepier.codex.${client.device}") }
            prefs.edit().clear().commit()
        }
    }
}
