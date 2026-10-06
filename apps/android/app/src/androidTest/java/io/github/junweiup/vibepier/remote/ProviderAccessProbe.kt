package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.SystemClock
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionProviderAccess
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

/** Synthetic encrypted Mac policy and a real native drawer on an emulator only. */
internal object ProviderAccessProbe {
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
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val prefix = "provider-access-${UUID.randomUUID()}"
        val context = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("$prefix-$name", Context.MODE_PRIVATE)
        }
        val transport = Transport()
        val keyBytes = ByteArray(32) { 29 }
        lateinit var client: SessionClient
        var clientReady = false
        var activity: MainActivity? = null
        var panel: ConversationPanel? = null
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
        }
        fun views(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) } else emptyList()
        fun reply(value: JSONObject) {
            val packet = UUID.randomUUID().toString()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyBytes, "AES"))
            cipher.updateAAD("vibepier-session-v1|mac|${client.device}|$packet".toByteArray())
            val data = Base64.encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray()), Base64.NO_WRAP)
            main {
                data.chunked(900).let { pieces -> pieces.forEachIndexed { i, part ->
                    transport.onSessionFrame(JSONObject().put("type", "vibepier-session1").put("sender", client.device)
                        .put("device", client.device).put("packet", packet).put("part", i).put("parts", pieces.size).put("data", part))
                } }
            }
            test.waitForIdleSync()
        }
        fun policy(revision: Long, enabled: Set<String>) = reply(JSONObject().put("event", "providersChanged")
            .put("providerAccess", SessionProviderAccess(revision, enabled).json()))
        try {
            main {
                client = SessionClient(context, transport, 2_000); clientReady = true
                client.connectionChanged(true); client.pair()
                transport.onSessionPair(JSONObject().put("state", "approved").put("device", client.device)
                    .put("key", Base64.encodeToString(keyBytes, Base64.NO_WRAP)).toString().toByteArray())
            }
            test.waitForIdleSync()
            policy(0, setOf("codex", "claude"))
            var original = ""
            var originalRecord = ""
            main {
                client.saveDraft("synthetic", "preserve this draft")
                client.rememberPage("synthetic", JSONObject().put("title", "synthetic cached conversation"))
                client.rememberProcess("synthetic", "reply", JSONObject().put("text", "synthetic cached process"))
                var refused: JSONObject? = null
                client.request("send", JSONObject().put("threadId", "synthetic").put("text", "preserve this draft")) { refused = it }
                check(refused?.optString("code") == "agent_state_not_ready")
                check(client.uncertain("synthetic").isEmpty())
                // A pre-upgrade unresolved intent is local data, not authority for a new write.
                original = UUID.randomUUID().toString()
                originalRecord = JSONObject().put("id", original).put("provider", "codex").put("op", "send")
                    .put("threadId", "synthetic").put("text", "preserve this draft").toString()
                check(PrivatePreferences.open(context, "sessions").edit().putString("pending.$original", originalRecord).commit())
            }
            activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval")) as MainActivity
            test.waitForIdleSync()
            main {
                activity!!.sessionNavigation.panel?.close()
                val host = activity!!.javaClass.getDeclaredField("rootHost").apply { isAccessible = true }.get(activity) as FrameLayout
                panel = ConversationPanel(activity!!, client, { panel?.let(host::removeView) })
                host.addView(panel, FrameLayout.LayoutParams(-1, -1))
            }
            policy(1, setOf("claude"))
            main {
                check(client.provider == "claude" && client.enabledProviders == listOf("claude"))
                val labels = views(panel!!).mapNotNull { it.contentDescription?.toString() }
                check(labels.any { it == activity!!.getString(R.string.choice_selected, "Claude Code", activity!!.getString(R.string.session_sessions)) })
                check(labels.none { it == activity!!.getString(R.string.choice_switch, "Codex", activity!!.getString(R.string.session_sessions)) })
                client.provider = "codex"
                check(client.cachedPage("synthetic") == null)
                check(client.cachedProcess("synthetic", "reply") == null)
                check(client.draft("synthetic") == "preserve this draft")
                check(client.uncertain("synthetic").isEmpty())
                check(PrivatePreferences.open(context, "sessions").contains("pending.$original"))
                var rejected = false
                client.request("send", JSONObject().put("threadId", "synthetic").put("text", "must not send")) {
                    rejected = it.opt("ok") == false && it.optString("code") == "agent_state_not_ready"
                }
                check(rejected)
                // Old session intents remain inert even with their original ID.
                var recoveryRejected = false
                client.retryPending(original) { recoveryRejected = it.optBoolean("unknown") }
                check(recoveryRejected)
                check(client.uncertain("synthetic").isEmpty())
                check(PrivatePreferences.open(context, "sessions").contains("pending.$original"))
                client.provider = "claude"
            }
            policy(2, emptySet())
            main {
                check(client.enabledProviders.isEmpty())
                check(views(panel!!).filterIsInstance<CanvasLabel>().any { it.text == activity!!.getString(R.string.providers_none_enabled) })
                check(views(panel!!).first { it.contentDescription == activity!!.getString(R.string.session_refresh_list) }.performClick())
                check(!panel!!.restoreNavigationState(JSONObject().put("source", client.authorizationIdentity)
                    .put("provider", "codex").put("thread", "synthetic").put("drawer", false)))
            }
            policy(1, setOf("codex", "claude"))
            main { check(client.enabledProviders.isEmpty()) }
            main {
                val restored = SessionClient(context, Transport(), 2_000)
                check(restored.providerAccessKnown && restored.enabledProviders.isEmpty())
                restored.close()
            }
            policy(3, setOf("claude"))
            main {
                check(client.provider == "claude" && client.enabledProviders == listOf("claude"))
                check(client.draft("synthetic", "codex") == "preserve this draft")
                // Policy changes cannot reactivate a retired session journal entry.
                check(client.uncertain("synthetic", "codex").isEmpty())
                var retryRejected = false
                client.retryPending(original) { retryRejected = it.opt("ok") == false && it.opt("unknown") == true }
                check(retryRejected)
                client.clearReceipt(original)
                check(PrivatePreferences.open(context, "sessions").getString("pending.$original", null) == originalRecord)
            }
            return "PASS: authenticated live policy hides disabled native tabs, switches selection, clears visible cache, preserves drafts and inert old journal bytes without displaying or retrying them, blocks new sends, renders all-off refresh safely, rejects stale policy/navigation, persists all-off across client recreation and re-enables only selected provider. Synthetic emulator only."
        } finally {
            main { panel?.close(); activity?.finish(); if (clientReady) client.close() }
            if (clientReady) DeviceKeys(context).clear()
            PrivatePreferences.open(context, "sessions").edit().clear().commit()
        }
    }
}
