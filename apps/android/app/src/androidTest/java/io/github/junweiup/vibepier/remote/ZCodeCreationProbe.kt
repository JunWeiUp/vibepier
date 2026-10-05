package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.SystemClock
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.core.session.*
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.sessions.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Real production controls over an isolated encrypted synthetic Mac. No production host is contacted. */
internal object ZCodeCreationProbe {
    private class Transport : SessionTransport {
        override val mode = "bluetooth"
        override val enrollmentReady = true
        override var onSessionFrame: (JSONObject) -> Unit = {}
        override var onSessionPair: (ByteArray?) -> Unit = {}
        val frames = CopyOnWriteArrayList<JSONObject>()
        var completed: (List<JSONObject>) -> Unit = {}
        override fun sendBinding(message: JSONObject) {
            frames.add(JSONObject(message.toString()))
            if (message.optInt("part") == message.optInt("parts") - 1)
                completed(frames.filter { it.opt("packet") == message.opt("packet") }.sortedBy { it.getInt("part") })
        }
        override fun requestSessionPair(device: String, name: String) {}
        override fun readSessionPair() {}
    }
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val prefix = "zcode-creation-${UUID.randomUUID()}"
        val isolated = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("$prefix-$name", Context.MODE_PRIVATE)
        }
        val transport = Transport(); val keyBytes = ByteArray(32) { 31 }; val key = SecretKeySpec(keyBytes, "AES")
        val requests = CopyOnWriteArrayList<JSONObject>(); val failure = AtomicReference<Throwable?>()
        lateinit var client: SessionClient
        var activity: MainActivity? = null; var panel: ConversationPanel? = null
        var clientCreated = false
        var executionMode = "default"; var supported = true; var coupled = false
        val cwd = "/fixture/plan-mode"; val adapter = "zcode.desktopV1"
        val adapters = mapOf("codex" to "codex.desktopV1", "claude" to "claude.desktopV1", "zcode" to adapter)
        val tabCatalogVersions = mutableMapOf<String, Int>()
        val sessionLease = UUID.randomUUID().toString(); val creationLease = UUID.randomUUID().toString()
        fun main(block: () -> Unit) {
            var error: Throwable? = null
            test.runOnMainSync { try { block() } catch (value: Throwable) { error = value } }
            error?.let { throw it }; failure.get()?.let { throw it }
        }
        fun field(value: Any, name: String) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
        fun set(value: Any, name: String, data: Any) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(value, data)
        fun views(value: View): List<View> = listOf(value) + if (value is ViewGroup) (0 until value.childCount).flatMap { views(value.getChildAt(it)) } else emptyList()
        fun waitFor(message: String, condition: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 8_000
            while (SystemClock.elapsedRealtime() < deadline) {
                var complete = false; main { complete = condition() }; if (complete) return
                SystemClock.sleep(60); test.waitForIdleSync()
            }
            error("Timed out: $message; methods=${requests.map { it.optJSONObject("body")?.optString("method") ?: it.optString("op") }}")
        }
        fun actions() = JSONObject().apply {
            SessionV1Contract.capabilityKeys.forEach { name ->
                val enabled = name != "executionMode" || supported
                put(name, JSONObject().put("supported", enabled).put("available", enabled).put("reason", if (enabled) "available" else "Synthetic unsupported"))
            }
        }
        fun discovery() = JSONObject().put("version", 1).put("revision", "host-cap").put("adapters", JSONArray(adapters.map { (source, selected) -> JSONObject()
            .put("id", selected).put("provider", source).put("default", true).put("backendKinds", JSONArray().put("desktopAttached")).put("actions", actions()) }))
        fun profile() = JSONObject().put("versions", JSONArray().put(2)).put("minimumClientVersion", 2).put("methods", JSONArray(SessionAgentProtocol.Method.entries.map { it.wire }))
        fun declaration(revision: String, source: String = "zcode") = JSONObject().put("version", 1).put("adapterId", adapters.getValue(source)).put("provider", source).put("revision", revision).put("actions", actions())
        fun composer() = JSONObject().put("model", "synthetic-model").put("modelLabel", "Synthetic model").put("effort", "medium")
            .put("mode", if (coupled) (if (executionMode == "plan") "plan" else "default") else "auto")
            .put("executionMode", executionMode).put("executionModeVerified", true).put("executionModePermissionCoupled", coupled)
        fun catalog() = JSONArray().put(JSONObject().put("id", "default").put("name", "Execute").apply { if (coupled) put("permissionMode", "default") })
            .put(JSONObject().put("id", "plan").put("name", "Plan").apply { if (coupled) put("permissionMode", "plan") })
        val nativeFailure = "上次解锁未成功，已停止尝试。请手动解锁 Mac"
        var rejectCreation = true
        var dropCreationReplies = false
        var failOptions = true
        fun options(source: String = "zcode") = JSONObject(test.context.assets.open("zcode-creation-options.json").bufferedReader().use { it.readText() })
            .put("agentCapabilities", declaration("creation-cap", source)).apply {
                tabCatalogVersions[source]?.let { revision ->
                    val model = "$source-tab-model-$revision"
                    put("models", JSONArray().put(JSONObject().put("id", model).put("name", model).put("efforts", JSONArray())))
                    getJSONObject("composer").put("model", model).put("modelLabel", model).put("effort", "")
                }
            }
        fun descriptor(thread: String = "synthetic-thread", source: String = "zcode") = JSONObject().put("sessionRef", "session:$thread").put("adapterId", adapters.getValue(source)).put("nativeThreadId", thread)
            .put("ownershipEpoch", "owner-1").put("capabilityRevision", "session-cap").put("title", "Synthetic planning session")
            .put("cwd", cwd).put("workspaceRef", "synthetic-workspace").put("status", "idle")
        fun snapshot(thread: String, source: String = "zcode") = JSONObject().put("threadId", thread).put("title", "Synthetic planning session").put("cwd", cwd).put("status", "idle")
            .put("contentState", "complete").put("canSend", true).put("composer", composer()).put("executionModes", if (supported) catalog() else JSONArray())
            .put("executionModePermissionCoupled", coupled)
            .put("messages", JSONArray()).put("turns", JSONArray()).put("agentCapabilities", declaration("session-cap", source))
        fun sendReply(value: JSONObject) {
            val packet = UUID.randomUUID().toString(); val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key); cipher.updateAAD("vibepier-session-v1|mac|${client.device}|$packet".toByteArray())
            val data = Base64.encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray()), Base64.NO_WRAP)
            data.chunked(900).let { pieces -> pieces.forEachIndexed { index, part -> transport.onSessionFrame(JSONObject()
                .put("type", "vibepier-session1").put("sender", client.device).put("device", client.device).put("packet", packet)
                .put("part", index).put("parts", pieces.size).put("data", part)) } }
        }
        transport.completed = { frames -> try {
            val packet = frames.first().getString("packet")
            val encrypted = Base64.decode(frames.joinToString("") { it.getString("data") }, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, encrypted.copyOfRange(0, 12)))
            cipher.updateAAD("vibepier-session-v1|phone|${client.device}|$packet".toByteArray())
            val request = JSONObject(String(cipher.doFinal(encrypted.copyOfRange(12, encrypted.size))))
            requests.add(request)
            val reply = JSONObject().put("id", request.getString("id")).put("ok", true).put("provider", request.optString("provider", "zcode"))
            if (request.has("viewVersion")) reply.put("viewVersion", request.get("viewVersion"))
            if (request.has("threadId")) reply.put("threadId", request.get("threadId"))
            when (request.getString("op")) {
                "providers" -> reply.put("providerAccess", SessionProviderAccess(1, adapters.keys).json())
                    .put("agentCapabilities", discovery()).put("agentProfiles", profile())
                "composerOptions" -> options().keys().forEach { name -> reply.put(name, options().get(name)) }
                "agentRequest" -> {
                    val body = request.getJSONObject("body"); val params = body.getJSONObject("params"); val target = body.optJSONObject("target")
                    val result = JSONObject(); val response = JSONObject().put("agentProtocol", 2).put("requestId", request.getString("id")).put("result", result)
                    val source = request.optString("provider", "zcode")
                    val selectedAdapter = adapters.getValue(source)
                    when (body.getString("method")) {
                        "session.list" -> result.put("sessions", JSONArray().put(descriptor(source = source)))
                        "workspace.list" -> result.put("workspaces", JSONArray().put(JSONObject().put("workspaceRef", "synthetic-workspace").put("adapterId", selectedAdapter).put("cwd", cwd).put("title", "Synthetic project").put("project", "Synthetic project")))
                        "session.open", "session.snapshot" -> {
                            val thread = target!!.getString("sessionRef").substringAfter("session:")
                            result.put("session", descriptor(thread, source)).put("snapshot", snapshot(thread, source)).put("controlLease", sessionLease).put("streamEpoch", "stream-1").put("throughSequence", 0)
                        }
                        "session.observe" -> result.put("streamEpoch", "stream-1").put("throughSequence", 0).put("events", JSONArray()).put("resyncRequired", false)
                        "session.creationOptions" -> if (failOptions) {
                            reply.put("ok", false).put("code", "agent_native_unavailable")
                            response.put("code", "agent_native_unavailable"); response.remove("result")
                        } else result.put("options", options(source).put("draftId", params.get("draftId"))).put("creationLease", JSONObject().put("controlLease", creationLease)
                            .put("target", JSONObject().put("adapterId", selectedAdapter).put("workspaceRef", "synthetic-workspace").put("draftId", params.get("draftId")).put("optionsRevision", "creation-options")))
                        "session.configure" -> {
                            executionMode = params.getJSONObject("options").getString("executionMode")
                            response.put("operationId", body.get("operationId")).put("status", "confirmed").put("effect", "session.configured").put("target", target)
                            result.put("effectiveOptions", composer())
                        }
                        "session.create" -> {
                            executionMode = params.getJSONObject("options").getString("executionMode")
                            response.put("operationId", body.get("operationId")).put("status", "confirmed").put("effect", "session.created").put("target", target)
                            if (rejectCreation) {
                                reply.put("ok", false); response.put("status", "rejected")
                                result.put("code", "agent_native_rejected").put("error", nativeFailure)
                            } else result.put("sessionCreated", true).put("initialInput", "confirmed").put("session", descriptor("created-thread"))
                                .put("executionMode", params.getJSONObject("options").get("executionMode")).put("executionModeState", "confirmed")
                        }
                    }
                    reply.put("body", response)
                }
            }
            if (!(dropCreationReplies && request.optJSONObject("body")?.optString("method") == "session.create")) sendReply(reply)
        } catch (error: Throwable) { failure.compareAndSet(null, error) } }
        fun screenshot(stage: String) {
            // A synthetic acknowledgement can complete before WindowManager finishes a dialog's
            // exit animation. Main-thread state alone does not fence the composited screenshot.
            test.waitForIdleSync(); SystemClock.sleep(350); test.waitForIdleSync()
            val locale = activity!!.resources.configuration.locales[0].language
            test.uiAutomation.takeScreenshot()?.let { bitmap ->
                try { File(activity!!.externalCacheDir, "zcode-creation-$locale-$stage.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } }
                finally { bitmap.recycle() }
            }
        }
        fun dialog(): AlertDialog {
            @Suppress("UNCHECKED_CAST") val dialogs = field(panel!!, "auxiliaryDialogs") as Set<AlertDialog>
            return dialogs.last { it.isShowing }
        }
        fun assertMenuClosed(menu: AlertDialog) {
            waitFor("selected mode menu closed", { !menu.isShowing && menu.window?.decorView?.isAttachedToWindow != true })
            main { check(!menu.isShowing && menu.window?.decorView?.isAttachedToWindow != true) }
        }
        try {
            val declared = SessionAgentCapabilities.decode(discovery()) ?: error("Invalid synthetic discovery")
            check(SessionAgentProtocol.Profile.decode(profile()) != null)
            check(SessionAgentTargetCapabilities.decode(declaration("session-cap"), declared) != null)
            check(SessionAgentTargetCapabilities.decode(declaration("creation-cap"), declared) != null)
            check(SessionExecutionModes.decode(options()).size == 2)
            main {
                client = SessionClient(isolated, transport, 4_000); clientCreated = true; client.provider = "zcode"; client.connectionChanged(true); client.pair()
                transport.onSessionPair(JSONObject().put("state", "approved").put("device", client.device)
                    .put("key", Base64.encodeToString(keyBytes, Base64.NO_WRAP)).toString().toByteArray())
            }
            waitFor("authenticated profile", { client.paired && client.agent.negotiated && client.selectedAgentAdapter()?.id == adapter })
            activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval")) as MainActivity
            main {
                activity!!.sessionNavigation.panel?.close()
                val host = field(activity!!, "rootHost") as FrameLayout
                panel = ConversationPanel(activity!!, client, { }); host.removeAllViews(); host.addView(panel, FrameLayout.LayoutParams(-1, -1))
            }
            waitFor("session discovery", { client.agent.session("zcode", "synthetic-thread") != null })
            var projectsLoaded = false
            main { client.request("projects") { projectsLoaded = it.opt("ok") == true } }
            waitFor("workspace discovery", { projectsLoaded })
            lateinit var creation: AlertDialog; lateinit var choices: NewSessionOptionsView
            main {
                set(panel!!, "drawer", true); set(panel!!, "projectCwd", cwd); set(panel!!, "projectName", "Default workspace")
                panel!!.javaClass.getDeclaredMethod("showNewSession").apply { isAccessible = true }.invoke(panel)
                creation = dialog(); choices = views(creation.window!!.decorView).filterIsInstance<NewSessionOptionsView>().single()
            }
            waitFor("failed native options read", { requests.any { it.optJSONObject("body")?.optString("method") == "session.creationOptions" } &&
                views(creation.window!!.decorView).filterIsInstance<CanvasLabel>().any { it.text.toString().startsWith(activity!!.getString(R.string.agent_state_not_ready)) } })
            main { check(!choices.loaded); check(requests.count { it.optJSONObject("body")?.optString("method") == "session.creationOptions" } == 3); check(requests.none { it.optJSONObject("body")?.optString("method") == "session.create" }) }
            screenshot("unavailable")
            failOptions = false
            main { views(creation.window!!.decorView).filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == activity!!.getString(R.string.session_start) }.performClick() }
            waitFor("actual native catalog loaded", { choices.loaded && (field(choices, "model") as View).isEnabled && (field(choices, "execution") as View).isEnabled })
            main {
                check(choices.ready); check(client.creationCapability("new", choices.draft)); check(client.creationCapability("executionMode", choices.draft))
                check(choices.draft.executionMode == "plan" && choices.draft.mode == "build" && !choices.draft.executionModePermissionCoupled)
            }
            main { (field(choices, "refresh") as View).performClick() }
            waitFor("explicit catalog refresh", { requests.any { it.optJSONObject("body")?.optString("method") == "session.creationOptions" && it.getJSONObject("body").getJSONObject("params").opt("refreshOptions") == true } })
            fun chooseControl(name: String, index: Int) {
                main { check((field(choices, name) as View).performClick()) }; test.waitForIdleSync()
                main {
                    @Suppress("UNCHECKED_CAST") val menus = field(choices, "menus") as List<AlertDialog>
                    val menu = menus.last { it.isShowing }; val list = menu.listView
                    check(index < list.adapter.count); list.performItemClick(list.getChildAt(index), index, list.adapter.getItemId(index))
                }
                test.waitForIdleSync()
            }
            chooseControl("model", 1)
            main { check(choices.draft.model == options().getJSONArray("models").getJSONObject(1).getString("id")); check(choices.draft.effort.isEmpty()) }
            chooseControl("execution", 0)
            main { check(choices.draft.executionMode == "default" && choices.draft.mode == "build" && choices.ready && !choices.draft.confirmFullAccess) }
            chooseControl("mode", 1)
            main { check(choices.ready && choices.draft.mode == "edit") }
            chooseControl("execution", 1)
            main { check(choices.ready && choices.draft.executionMode == "plan" && choices.draft.mode == "edit" && !choices.draft.executionModePermissionCoupled) }
            screenshot("choices-enabled")
            main { views(creation.window!!.decorView).filterIsInstance<EditText>().single().setText("Synthetic ZCode first message") }
            main { views(creation.window!!.decorView).filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == activity!!.getString(R.string.session_start) }.performClick() }
            waitFor("native rejection shown verbatim", { creation.isShowing && views(creation.window!!.decorView).filterIsInstance<CanvasLabel>().any { it.text.toString() == nativeFailure } })
            main {
                check(views(creation.window!!.decorView).filterIsInstance<EditText>().single().isEnabled)
                check(choices.ready); check(client.uncertain("", "zcode").isEmpty())
                check(requests.count { it.optJSONObject("body")?.optString("method") == "session.create" } == 1)
            }
            screenshot("native-unlock-failure")
            rejectCreation = false
            main { views(creation.window!!.decorView).filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == activity!!.getString(R.string.session_start) }.performClick() }
            waitFor("creation confirmed", { !creation.isShowing })
            val created = requests.last { it.optJSONObject("body")?.optString("method") == "session.create" }.getJSONObject("body").getJSONObject("params")
            check(created.getJSONObject("options").getString("executionMode") == "plan" && created.getJSONObject("options").getString("mode") == "edit")
            check(created.getJSONObject("options").getString("model") == options().getJSONArray("models").getJSONObject(1).getString("id"))
            check(created.getJSONObject("initialMessage").getJSONArray("content").getJSONObject(0).getString("text") == "Synthetic ZCode first message")
            fun showNextCreation() {
                main {
                    set(panel!!, "drawer", true); set(panel!!, "projectCwd", cwd); set(panel!!, "projectName", "Default workspace")
                    panel!!.javaClass.getDeclaredMethod("showNewSession").apply { isAccessible = true }.invoke(panel)
                    creation = dialog(); choices = views(creation.window!!.decorView).filterIsInstance<NewSessionOptionsView>().single()
                }
                waitFor("new independent draft enabled", { choices.loaded && choices.ready && views(creation.window!!.decorView).filterIsInstance<EditText>().single().isEnabled })
            }
            fun clickCreation(resource: Int) {
                views(creation.window!!.decorView).filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == activity!!.getString(resource) }.performClick()
            }
            showNextCreation(); dropCreationReplies = true
            main {
                views(creation.window!!.decorView).filterIsInstance<EditText>().single().setText("Unconfirmed original creation")
                clickCreation(R.string.session_start)
            }
            waitFor("unknown creation timeout", { views(creation.window!!.decorView).filterIsInstance<CanvasLabel>().any { it.text.toString() == activity!!.getString(R.string.session_check_result) } })
            val unresolved = client.uncertain("", "zcode").single { it.optString("op") == "new" }
            main { clickCreation(R.string.session_stop_waiting); check(!creation.isShowing); check(client.waitingStopped("", unresolved)) }
            showNextCreation()
            main {
                check(views(creation.window!!.decorView).filterIsInstance<EditText>().single().text.isEmpty())
                check(views(creation.window!!.decorView).filterIsInstance<CanvasLabel>().any { it.text.toString() == activity!!.getString(R.string.creation_pending_history) })
                views(creation.window!!.decorView).filterIsInstance<EditText>().single().setText("Unconfirmed original creation")
                clickCreation(R.string.session_start)
                check(views(creation.window!!.decorView).filterIsInstance<CanvasLabel>().any { it.text.toString() == activity!!.getString(R.string.creation_duplicate_pending) })
                check(requests.count { it.optJSONObject("body")?.optString("method") == "session.create" } == 3)
            }
            dropCreationReplies = false
            main {
                views(creation.window!!.decorView).filterIsInstance<EditText>().single().setText("Different fresh creation")
                clickCreation(R.string.session_start)
            }
            waitFor("different creation confirmed while original preserved", { !creation.isShowing })
            val allCreates = requests.filter { it.optJSONObject("body")?.optString("method") == "session.create" }
            check(allCreates.size == 4)
            check(allCreates[2].getJSONObject("body").getJSONObject("target").getString("draftId") != allCreates[3].getJSONObject("body").getJSONObject("target").getString("draftId"))
            check(client.uncertain("", "zcode").any { it.optString("id") == unresolved.optString("id") })
            main {
                client.listMode = "projects"
                for (source in adapters.keys) {
                    client.provider = source
                    client.rememberDrawerState(JSONObject().put("listMode", "projects").put("projectCwd", cwd).put("projectName", "Restored project"))
                }
                client.provider = "zcode"
                set(panel!!, "projectCwd", cwd); set(panel!!, "projectName", "Restored project")
                panel!!.javaClass.getDeclaredMethod("showDrawer").apply { isAccessible = true }.invoke(panel)
            }
            for (source in listOf("codex", "claude", "zcode")) {
                tabCatalogVersions[source] = 0
                main {
                    views(panel!!).filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == io.github.junweiup.vibepier.remote.core.session.SessionProvider.name(source) }.performClick()
                }
                waitFor("restored $source project loaded without project-list reentry", { client.provider == source && (field(panel!!, "newSession") as View).visibility == View.VISIBLE })
                main {
                    check(field(panel!!, "projectCwd") == cwd)
                    (field(panel!!, "newSession") as View).performClick()
                    creation = dialog(); choices = views(creation.window!!.decorView).filterIsInstance<NewSessionOptionsView>().single()
                }
                waitFor("$source creation options loaded directly after tab switch", { choices.loaded && choices.ready && choices.draft.model == "$source-tab-model-0" })
                main { views(creation.window!!.decorView).filterIsInstance<EditText>().single().setText("Keep $source first message") }
                tabCatalogVersions[source] = 1
                main { (field(choices, "refresh") as View).performClick() }
                waitFor("$source refreshed invalidated model replaced", { choices.loaded && choices.ready && choices.draft.model == "$source-tab-model-1" })
                main {
                    check(views(creation.window!!.decorView).filterIsInstance<EditText>().single().text.toString() == "Keep $source first message")
                    creation.dismiss()
                }
            }
            check(requests.count { it.optJSONObject("body")?.optString("method") == "session.create" } == 4)
            return "PASS: ZCode actual native catalog over encrypted profile 2; failed options keep draft and submit nothing; actual native rejection code/message stays visible, no automatic retry, one explicit retry; empty Start reloads; model switch and Plan/Run enabled; plan and permissions remain independent; first message/model/plan sent exactly once; stopped creation opens a fresh draft, preserves old receipt, blocks identical message, submits a different message once; Codex/Claude/ZCode tab restoration loads new-session data without project reentry and refresh replaces an obsolete model while preserving text. Synthetic host, real emulator controls."
        } finally {
            main { panel?.close(); activity?.finish(); if (clientCreated) client.close() }
            if (clientCreated) DeviceKeys(isolated).clear()
            PrivatePreferences.open(isolated, "sessions").edit().clear().commit()
        }
    }
}
