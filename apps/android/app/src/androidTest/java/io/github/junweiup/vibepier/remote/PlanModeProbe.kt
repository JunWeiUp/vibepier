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
internal object PlanModeProbe {
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
        val prefix = "plan-mode-${UUID.randomUUID()}"
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
        val cwd = "/fixture/plan-mode"; val adapter = "codex.currentV1"
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
        fun discovery() = JSONObject().put("version", 1).put("revision", "host-cap").put("adapters", JSONArray().put(JSONObject()
            .put("id", adapter).put("provider", "codex").put("default", true).put("backendKinds", JSONArray().put("desktopAttached")).put("actions", actions())))
        fun profile() = JSONObject().put("versions", JSONArray().put(2)).put("minimumClientVersion", 2).put("methods", JSONArray(SessionAgentProtocol.Method.entries.map { it.wire }))
        fun declaration(revision: String) = JSONObject().put("version", 1).put("adapterId", adapter).put("provider", "codex").put("revision", revision).put("actions", actions())
        fun composer() = JSONObject().put("model", "synthetic-model").put("modelLabel", "Synthetic model").put("effort", "medium")
            .put("mode", if (coupled) (if (executionMode == "plan") "plan" else "default") else "auto")
            .put("executionMode", executionMode).put("executionModeVerified", true).put("executionModePermissionCoupled", coupled)
        fun catalog() = JSONArray().put(JSONObject().put("id", "default").put("name", "Execute").apply { if (coupled) put("permissionMode", "default") })
            .put(JSONObject().put("id", "plan").put("name", "Plan").apply { if (coupled) put("permissionMode", "plan") })
        fun options() = JSONObject().put("ok", true).put("creationVersion", 1).put("composer", composer()).put("executionModes", if (supported) catalog() else JSONArray())
            .put("models", JSONArray().put(JSONObject().put("id", "synthetic-model").put("name", "Synthetic model").put("efforts", JSONArray().put("medium"))))
            .put("permissionModes", JSONArray().put(JSONObject().put("id", if (coupled) "default" else "auto").put("name", "Ask to approve")))
            .put("executionModePermissionCoupled", coupled)
            .put("agentCapabilities", declaration("creation-cap"))
        fun descriptor(thread: String = "synthetic-thread") = JSONObject().put("sessionRef", "session:$thread").put("adapterId", adapter).put("nativeThreadId", thread)
            .put("ownershipEpoch", "owner-1").put("capabilityRevision", "session-cap").put("title", "Synthetic planning session")
            .put("cwd", cwd).put("workspaceRef", "synthetic-workspace").put("status", "idle")
        fun snapshot(thread: String) = JSONObject().put("threadId", thread).put("title", "Synthetic planning session").put("cwd", cwd).put("status", "idle")
            .put("contentState", "complete").put("canSend", true).put("composer", composer()).put("executionModes", if (supported) catalog() else JSONArray())
            .put("executionModePermissionCoupled", coupled)
            .put("messages", JSONArray()).put("turns", JSONArray()).put("agentCapabilities", declaration("session-cap"))
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
            val reply = JSONObject().put("id", request.getString("id")).put("ok", true).put("provider", request.optString("provider", "codex"))
            if (request.has("viewVersion")) reply.put("viewVersion", request.get("viewVersion"))
            if (request.has("threadId")) reply.put("threadId", request.get("threadId"))
            when (request.getString("op")) {
                "providers" -> reply.put("providerAccess", SessionProviderAccess(1, setOf("codex")).json())
                    .put("agentCapabilities", discovery()).put("agentProfiles", profile())
                "composerOptions" -> options().keys().forEach { name -> reply.put(name, options().get(name)) }
                "agentRequest" -> {
                    val body = request.getJSONObject("body"); val params = body.getJSONObject("params"); val target = body.optJSONObject("target")
                    val result = JSONObject(); val response = JSONObject().put("agentProtocol", 2).put("requestId", request.getString("id")).put("result", result)
                    when (body.getString("method")) {
                        "session.list" -> result.put("sessions", JSONArray().put(descriptor()))
                        "workspace.list" -> result.put("workspaces", JSONArray().put(JSONObject().put("workspaceRef", "synthetic-workspace").put("adapterId", adapter).put("cwd", cwd).put("title", "Synthetic project").put("project", "Synthetic project")))
                        "session.open", "session.snapshot" -> {
                            val thread = target!!.getString("sessionRef").substringAfter("session:")
                            result.put("session", descriptor(thread)).put("snapshot", snapshot(thread)).put("controlLease", sessionLease).put("streamEpoch", "stream-1").put("throughSequence", 0)
                        }
                        "session.items" -> {
                            check(params.getString("kind") == "composerOptions")
                            val native = options()
                            native.keys().forEach { name -> result.put(name, native.get(name)) }
                        }
                        "session.observe" -> result.put("streamEpoch", "stream-1").put("throughSequence", 0).put("events", JSONArray()).put("resyncRequired", false)
                        "session.creationOptions" -> result.put("options", options().put("draftId", params.get("draftId"))).put("creationLease", JSONObject().put("controlLease", creationLease)
                            .put("target", JSONObject().put("adapterId", adapter).put("workspaceRef", "synthetic-workspace").put("draftId", params.get("draftId")).put("optionsRevision", "creation-options")))
                        "session.configure" -> {
                            executionMode = params.getJSONObject("options").getString("executionMode")
                            response.put("operationId", body.get("operationId")).put("status", "confirmed").put("effect", "session.configured").put("target", target)
                            result.put("effectiveOptions", composer())
                        }
                        "session.create" -> {
                            executionMode = params.getJSONObject("options").getString("executionMode")
                            response.put("operationId", body.get("operationId")).put("status", "confirmed").put("effect", "session.created").put("target", target)
                            result.put("sessionCreated", true).put("initialInput", "confirmed").put("session", descriptor("created-thread"))
                                .put("executionMode", params.getJSONObject("options").get("executionMode")).put("executionModeState", "confirmed")
                        }
                    }
                    reply.put("body", response)
                }
            }
            sendReply(reply)
        } catch (error: Throwable) { failure.compareAndSet(null, error) } }
        fun screenshot(stage: String) {
            // A synthetic acknowledgement can complete before WindowManager finishes a dialog's
            // exit animation. Main-thread state alone does not fence the composited screenshot.
            test.waitForIdleSync(); SystemClock.sleep(350); test.waitForIdleSync()
            val locale = activity!!.resources.configuration.locales[0].language
            test.uiAutomation.takeScreenshot()?.let { bitmap ->
                try { File(activity!!.externalCacheDir, "plan-mode-$locale-$stage.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } }
                finally { bitmap.recycle() }
            }
        }
        fun controls() = field(panel!!, "composerControls") as ComposerControls
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
                client = SessionClient(isolated, transport, 4_000); clientCreated = true; client.connectionChanged(true); client.pair()
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
            waitFor("session discovery", { client.agent.session("codex", "synthetic-thread") != null })
            main { panel!!.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }.invoke(panel, "synthetic-thread", "Synthetic planning session") }
            waitFor("execution control", { field(panel!!, "ready") == true && controls().execution.isEnabled })
            for (mode in listOf("plan", "default")) {
                main { check(controls().execution.performClick()) }
                waitFor("advertised choices", { runCatching { views(dialog().window!!.decorView).filterIsInstance<CanvasLabel>().any { it.isClickable && it.text.toString().removePrefix("✓ ") == activity!!.getString(if (mode == "plan") R.string.session_execution_plan else R.string.session_execution_run) } }.getOrDefault(false) })
                screenshot("menu-$mode")
                lateinit var selectedMenu: AlertDialog
                main {
                    selectedMenu = dialog()
                    views(selectedMenu.window!!.decorView).filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString().removePrefix("✓ ") == activity!!.getString(if (mode == "plan") R.string.session_execution_plan else R.string.session_execution_run) }.performClick()
                }
                assertMenuClosed(selectedMenu)
                waitFor("actual $mode acknowledgement", { client.uncertain("synthetic-thread").isEmpty() && controls().execution.text.toString().startsWith(activity!!.getString(if (mode == "plan") R.string.session_execution_plan else R.string.session_execution_run)) })
                screenshot("confirmed-$mode")
            }
            check(requests.count { it.optJSONObject("body")?.optString("method") == "session.items" } == 1) { "Opening the second execution menu must reuse the fetched catalog" }
            val configures = requests.filter { it.optJSONObject("body")?.optString("method") == "session.configure" }
            check(configures.map { it.getJSONObject("body").getJSONObject("params").getJSONObject("options").getString("executionMode") } == listOf("plan", "default"))
            check(configures.all { it.getJSONObject("body").getJSONObject("params").getJSONObject("options").length() == 1 })
            var projectsLoaded = false
            main { client.request("projects") { projectsLoaded = it.opt("ok") == true } }
            waitFor("workspace discovery", { projectsLoaded })
            lateinit var creation: AlertDialog; lateinit var choices: NewSessionOptionsView
            main {
                set(panel!!, "drawer", true); set(panel!!, "projectCwd", cwd); set(panel!!, "projectName", "Synthetic project")
                panel!!.javaClass.getDeclaredMethod("showNewSession").apply { isAccessible = true }.invoke(panel)
                creation = dialog(); choices = views(creation.window!!.decorView).filterIsInstance<NewSessionOptionsView>().single()
            }
            waitFor("creation choices", { choices.ready })
            main { (field(choices, "execution") as View).performClick() }
            test.waitForIdleSync()
            lateinit var creationModeMenu: AlertDialog
            main {
                @Suppress("UNCHECKED_CAST") val menus = field(choices, "menus") as List<AlertDialog>
                creationModeMenu = menus.last { it.isShowing }
                val list = creationModeMenu.listView; list.performItemClick(list.getChildAt(1), 1, list.adapter.getItemId(1))
                check(choices.draft.executionMode == "plan" && choices.draft.mode == "auto")
                views(creation.window!!.decorView).filterIsInstance<EditText>().single().setText("Synthetic first message")
            }
            assertMenuClosed(creationModeMenu)
            screenshot("new-plan")
            main { views(creation.window!!.decorView).filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == activity!!.getString(R.string.session_start) }.performClick() }
            waitFor("creation confirmed", { !creation.isShowing })
            val created = requests.single { it.optJSONObject("body")?.optString("method") == "session.create" }.getJSONObject("body").getJSONObject("params")
            check(created.getJSONObject("options").getString("executionMode") == "plan" && created.getJSONObject("options").getString("mode") == "auto")
            check(created.getJSONObject("initialMessage").getJSONArray("content").getJSONObject(0).getString("text") == "Synthetic first message")
            waitFor("created session opened", { field(panel!!, "ready") == true })
            coupled = true
            main { panel!!.javaClass.getDeclaredMethod("requestOpen").apply { isAccessible = true }.invoke(panel) }
            waitFor("native coupled plan", { field(panel!!, "ready") == true && controls().mode.visibility == View.GONE })
            screenshot("coupled-plan")
            main { controls().execution.performClick() }
            waitFor("coupled exit choice", { runCatching { views(dialog().window!!.decorView).filterIsInstance<CanvasLabel>().any { it.isClickable && it.text.toString() == activity!!.getString(R.string.session_execution_run) } }.getOrDefault(false) })
            lateinit var coupledModeMenu: AlertDialog
            main {
                coupledModeMenu = dialog()
                check(views(coupledModeMenu.window!!.decorView).filterIsInstance<CanvasLabel>().any {
                    it.text.toString() == activity!!.getString(R.string.session_execution_coupled_description, "Ask to approve")
                }) { "Coupled execution must disclose the advertised default permission" }
                views(coupledModeMenu.window!!.decorView).filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == activity!!.getString(R.string.session_execution_run) }.performClick()
            }
            assertMenuClosed(coupledModeMenu)
            waitFor("safe coupled execution", { client.uncertain("created-thread").isEmpty() && controls().mode.visibility == View.VISIBLE &&
                (field(panel!!, "page") as JSONObject).getJSONObject("composer").optString("mode") == "default" })
            check(requests.last { it.optJSONObject("body")?.optString("method") == "session.configure" }.getJSONObject("body").getJSONObject("params").getJSONObject("options").length() == 1)
            main { panel!!.javaClass.getDeclaredMethod("refreshComposerOptions").apply { isAccessible = true }.invoke(panel) }
            waitFor("explicit detail catalog refresh", { requests.any { it.optJSONObject("body")?.optString("method") == "session.items" && it.getJSONObject("body").getJSONObject("params").opt("refreshOptions") == true } &&
                (field(panel!!, "composerOptionCatalogs") as Map<*, *>).values.filterIsInstance<JSONObject>().any { it.opt("executionModePermissionCoupled") == true } })
            lateinit var coupledCreation: AlertDialog; lateinit var coupledChoices: NewSessionOptionsView; lateinit var coupledCreationMenu: AlertDialog
            main {
                set(panel!!, "drawer", true)
                panel!!.javaClass.getDeclaredMethod("showNewSession").apply { isAccessible = true }.invoke(panel)
                coupledCreation = dialog(); coupledChoices = views(coupledCreation.window!!.decorView).filterIsInstance<NewSessionOptionsView>().single()
            }
            waitFor("coupled creation choices", { coupledChoices.ready })
            main {
                (field(coupledChoices, "execution") as View).performClick()
                @Suppress("UNCHECKED_CAST") val menus = field(coupledChoices, "menus") as List<AlertDialog>
                coupledCreationMenu = menus.last { it.isShowing }
                val list = coupledCreationMenu.listView
                check(list.adapter.getItem(0).toString() == activity!!.getString(R.string.session_execution_default_permissions,
                    activity!!.getString(R.string.session_execution_run), "Ask to approve")) { "New coupled execution must disclose the advertised default permission" }
                list.performItemClick(list.getChildAt(1), 1, list.adapter.getItemId(1))
                val original = coupledChoices.draft.copy(text = "Synthetic coupled draft").request(SessionAgentProtocol.id(), JSONArray())
                check(original.optString("executionMode") == "plan" && !original.has("mode"))
            }
            assertMenuClosed(coupledCreationMenu)
            main { coupledCreation.dismiss(); set(panel!!, "drawer", false) }
            supported = false
            main { panel!!.javaClass.getDeclaredMethod("requestOpen").apply { isAccessible = true }.invoke(panel) }
            waitFor("unsupported disabled", { field(panel!!, "ready") == true && (controls().execution.visibility == View.GONE || !controls().execution.isEnabled) })
            screenshot("unsupported")
            check(requests.count { it.optJSONObject("body")?.optString("method") == "session.configure" } == 3)
            return "PASS: plan-mode encrypted cap v1 + profile 2; existing Execute → Plan → Execute confirms actual readback; creation submits native plan option with unchanged first message and independent permissions; explicit coupled catalog hides plan permissions and discloses advertised default permissions in both menus without changing requests; unsupported control disabled; screenshots plan-mode-<locale>-*.png in review external cache. Synthetic emulator only."
        } finally {
            main { panel?.close(); activity?.finish(); if (clientCreated) client.close() }
            if (clientCreated) DeviceKeys(isolated).clear()
            PrivatePreferences.open(isolated, "sessions").edit().clear().commit()
        }
    }
}
