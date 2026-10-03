package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.sessions.ComposerControls
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import io.github.junweiup.vibepier.remote.features.sessions.InlineReplyProcess
import io.github.junweiup.vibepier.remote.fixtures.ConversationReviewFixtures

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.os.SystemClock
import android.util.Base64
import org.json.JSONObject
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object SessionClientProbe {
    private class Transport : SessionTransport {
        override val mode = "bluetooth"
        override var enrollmentReady = true
        override var onSessionFrame: (JSONObject) -> Unit = {}
        override var onSessionPair: (ByteArray?) -> Unit = {}
        val frames = CopyOnWriteArrayList<JSONObject>()
        var onCompletePacket: (() -> Unit)? = null
        override fun sendBinding(message: JSONObject) {
            frames.add(JSONObject(message.toString()))
            if (message.optInt("part") == message.optInt("parts") - 1) onCompletePacket?.invoke()
        }
        var pairRequests = 0
        override fun requestSessionPair(device: String, name: String) { pairRequests++ }
        override fun readSessionPair() {}
    }
    fun run(test: Instrumentation): String {
        RemoteConfigurationCacheProbe.run(test.targetContext)
        ConversationCacheProbe.run(test.targetContext)
        val name = "codex-probe-${UUID.randomUUID()}"
        val context = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(ignored: String?, mode: Int) = baseContext.getSharedPreferences("${name}-${ignored}", Context.MODE_PRIVATE)
        }
        val transport = Transport(); lateinit var client: SessionClient
        val events = CopyOnWriteArrayList<JSONObject>(); val replies = CopyOnWriteArrayList<JSONObject>()
        val key = SecretKeySpec(ByteArray(32) { 7 }, "AES")
        fun decodeLast(expectedOp: String? = null, expectedID: String? = null): JSONObject {
            for (packet in transport.frames.map { it.getString("packet") }.distinct().asReversed()) {
                val frames = transport.frames.filter { it.getString("packet") == packet }.sortedBy { it.getInt("part") }
                val data = Base64.decode(frames.joinToString("") { it.getString("data") }, Base64.NO_WRAP)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, data.copyOfRange(0,12)))
                cipher.updateAAD("vibepier-session-v1|phone|${client.device}|$packet".toByteArray())
                val value = JSONObject(String(cipher.doFinal(data.copyOfRange(12,data.size))))
                if ((expectedOp == null || value.optString("op") == expectedOp) && (expectedID == null || value.optString("id") == expectedID)) return value
            }
            error("No $expectedOp request")
        }
        fun reply(value: JSONObject) {
            // Match the metadata added by production SessionRemote/SessionProviderReply.
            if (value.optBoolean("ok") && value.optString("id").isNotEmpty()) {
                val request = decodeLast(expectedID = value.getString("id"))
                if (!value.has("threadId") && request.has("threadId")) value.put("threadId", request.get("threadId"))
                if (request.optString("op") == "new") value.put("cwd", request.get("cwd"))
                if (request.optString("op") == "approve") value.put("fingerprint", request.get("fingerprint"))
            }
            val packet = UUID.randomUUID().toString(); val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key); cipher.updateAAD("vibepier-session-v1|mac|${client.device}|$packet".toByteArray())
            val data = Base64.encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray()), Base64.NO_WRAP)
            val pieces = data.chunked(900)
            pieces.forEachIndexed { i, part -> transport.onSessionFrame(JSONObject().put("type", "vibepier-session1").put("sender", client.device).put("device", client.device).put("packet", packet).put("part", i).put("parts", pieces.size).put("data", part)) }
        }
        try {
            test.runOnMainSync {
                client = SessionClient(context, transport, 80); client.onEvent = { events.add(it) }
                transport.enrollmentReady = false; client.pair(); check(transport.pairRequests == 0)
                transport.enrollmentReady = true; client.pair(); check(transport.pairRequests == 1)
                check(!client.online)
                // Discovery updates while awaiting Mac approval must not cancel enrollment.
                client.connectionChanged(false)
                transport.onSessionPair(JSONObject().put("state", "approved").put("device", client.device).put("key", Base64.encodeToString(ByteArray(32) { 7 }, Base64.NO_WRAP)).toString().toByteArray())
            }
            test.waitForIdleSync(); check(client.paired); check(!client.online)
            test.runOnMainSync { client.connectionChanged(true) }
            var operation = ""
            test.runOnMainSync {
                client.saveDraft("thread", "hello")
                operation = client.request("send", JSONObject().put("threadId", "thread").put("text", "hello")) { replies.add(it) }
            }
            SystemClock.sleep(160); test.waitForIdleSync()
            check(replies.last().optBoolean("unknown")); check(client.uncertain("thread").size == 1)
            reply(JSONObject().put("id", operation).put("ok", true).put("accepted", true)); test.waitForIdleSync()
            check(events.last().optString("event") == "lateReceipt"); check(events.last().getJSONObject("operation").optString("threadId") == "thread")
            check(client.draft("thread").isEmpty()); check(client.uncertain("thread").isEmpty())
            test.runOnMainSync {
                client.saveDraft("thread", "second")
                operation = client.request("send", JSONObject().put("threadId", "thread").put("text", "second")) { replies.add(it) }
            }
            SystemClock.sleep(160); test.waitForIdleSync()
            val original = decodeLast()
            test.runOnMainSync { client.saveDraft("thread", "edited later"); client.retryPending(operation) { replies.add(it) } }
            val retry = decodeLast(); check(original.getString("id") == retry.getString("id")); check(retry.getString("text") == "second")
            reply(JSONObject().put("id", operation).put("ok", true).put("accepted", true)); test.waitForIdleSync()
            check(client.draft("thread") == "edited later")
            // Settings and stop are mutable too: persist uncertainty, then reconcile without clearing text/attachments.
            for (op in listOf("settings", "interrupt")) {
                test.runOnMainSync {
                    client.saveDraft("thread", "keep this draft")
                    client.saveAttachments("thread", org.json.JSONArray().put(JSONObject().put("attachmentId", "keep")))
                    operation = client.request(op, JSONObject().put("threadId", "thread").put("mode", "auto").put("expectedTurnId", "old-turn")) { replies.add(it) }
                }
                SystemClock.sleep(160); test.waitForIdleSync()
                check(replies.last().optBoolean("unknown"))
                val reserved = decodeLast()
                test.runOnMainSync { client.retryPending(operation) { replies.add(it) } }
                check(decodeLast().getString("id") == reserved.getString("id"))
                reply(JSONObject().put("id", operation).put("ok", true).put("accepted", true)); test.waitForIdleSync()
                check(client.draft("thread") == "keep this draft")
                check(client.attachments("thread").length() == 1 && client.uncertain("thread").isEmpty())
            }
            test.runOnMainSync {
                client.saveAttachments("thread", org.json.JSONArray().put(JSONObject().put("attachmentId", "sent")).put(JSONObject().put("attachmentId", "added-later")))
                client.clearSentAttachments("thread", org.json.JSONArray().put("sent"))
            }
            check(client.attachments("thread").getJSONObject(0).getString("attachmentId") == "added-later")
            // New sessions are durable mutations for every provider, and timeouts must not retransmit them.
            for (source in listOf("codex", "claude", "zcode")) {
                val beforeFrames = transport.frames.size
                test.runOnMainSync {
                    operation = client.request("new", JSONObject().put("provider", source).put("cwd", "/fixture/new").put("text", "original first message")) { replies.add(it) }
                }
                SystemClock.sleep(160); test.waitForIdleSync()
                check(replies.last().optBoolean("unknown"))
                check(transport.frames.drop(beforeFrames).map { it.getString("packet") }.distinct().size == 1) { "New session automatically retransmitted" }
                check(client.uncertain("", source).single().getString("id") == operation)
                test.runOnMainSync {
                    client.close(); client = SessionClient(context, transport, 80); client.onEvent = { events.add(it) }; client.connectionChanged(true)
                    check(client.uncertain("", source).single().getString("id") == operation)
                    client.retryPending(operation) { replies.add(it) }
                }
                val retryNew = decodeLast("new")
                check(retryNew.getString("id") == operation && retryNew.getString("provider") == source && retryNew.getString("text") == "original first message")
                reply(JSONObject().put("id", operation).put("ok", true).put("threadId", "created-fixture")); test.waitForIdleSync()
                check(client.uncertain("", source).isEmpty())
            }
            // A late creation receipt clears only what the original request actually submitted.
            val draftRoot = java.io.File(context.filesDir, "codex-drafts").apply { mkdirs() }
            for (scenario in listOf("same", "edited", "new-attachment", "corrupt")) {
                val draft = io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft(
                    UUID.randomUUID().toString(), "claude", "/fixture/create-$scenario", "Original", "sonnet", "high", "plan")
                val sentID = UUID.randomUUID().toString(); val addedID = UUID.randomUUID().toString()
                val sentFile = java.io.File(draftRoot, "probe-" + UUID.randomUUID()).apply { writeText("sent fixture") }
                val addedFile = java.io.File(draftRoot, "probe-" + UUID.randomUUID()).apply { writeText("retained fixture") }
                try {
                    val entries = org.json.JSONArray().put(JSONObject().put("attachmentId", sentID).put("cachePath", sentFile.path))
                    test.runOnMainSync {
                        check(client.saveCreationDraft(draft)); check(client.saveAttachments(draft.attachmentScope, entries, "claude"))
                        operation = client.request("new", draft.request(UUID.randomUUID().toString(), org.json.JSONArray().put(sentID))) { replies.add(it) }
                    }
                    SystemClock.sleep(160); test.waitForIdleSync()
                    check(client.uncertain("", "claude").any { it.optString("id") == operation })
                    test.runOnMainSync {
                        if (scenario == "edited") check(client.saveCreationDraft(draft.copy(text = "Keep my next prompt", model = "opus")))
                        if (scenario == "new-attachment") check(client.saveAttachments(draft.attachmentScope,
                            entries.put(JSONObject().put("attachmentId", addedID).put("cachePath", addedFile.path)), "claude"))
                        if (scenario == "corrupt") check(io.github.junweiup.vibepier.remote.core.security.PrivatePreferences.open(context, "sessions").edit()
                            .putString("creationDraft.claude.${io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft.key(draft.cwd)}", "invalid fixture JSON").commit())
                    }
                    reply(JSONObject().put("id", operation).put("ok", true).put("threadId", "created-$scenario")); test.waitForIdleSync()
                    if (scenario == "corrupt") {
                        check(sentFile.exists()); check(client.uncertain("", "claude").any { it.optString("id") == operation })
                        check(runCatching { client.creationDraft(draft.cwd, "claude") }.isFailure)
                        test.runOnMainSync { check(client.saveCreationDraft(draft)); client.clearReceipt(operation) }
                    } else {
                        check(!sentFile.exists()); check(addedFile.exists()); check(client.uncertain("", "claude").none { it.optString("id") == operation })
                        val saved = client.creationDraft(draft.cwd, "claude")
                        when (scenario) {
                            "same" -> check(saved.id != draft.id)
                            "edited" -> check(saved.id == draft.id && saved.text == "Keep my next prompt" && saved.model == "opus")
                            "new-attachment" -> check(saved.id == draft.id && client.attachments(draft.attachmentScope, "claude").getJSONObject(0).getString("attachmentId") == addedID)
                        }
                    }
                } finally { sentFile.delete(); addedFile.delete() }
            }
            // Actual upload helper over encrypted session frames, with draft/project/provider pinned.
            val uploadDraft = io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft(UUID.randomUUID().toString(), "claude", "/fixture/upload")
            val uploadBytes = ByteArray(19_000) { (it % 251).toByte() }
            val uploadFile = java.io.File(draftRoot, "probe-" + UUID.randomUUID()).apply { writeBytes(uploadBytes) }
            val uploaded = java.io.ByteArrayOutputStream(); val uploadedDone = java.util.concurrent.CountDownLatch(1)
            val uploadResult = java.util.concurrent.atomic.AtomicReference<JSONObject>()
            test.runOnMainSync {
                client.close(); client = SessionClient(context, transport, 5000); client.onEvent = { events.add(it) }; client.connectionChanged(true)
                check(client.provider == "codex")
                transport.onCompletePacket = {
                    val request = decodeLast()
                    check(request.optString("draftId") == uploadDraft.id && request.optString("cwd") == uploadDraft.cwd && request.optString("provider") == "claude")
                    check(!request.has("threadId")) // Transport metadata may include the current view version; draft scope is independent.
                    when (request.optString("op")) {
                        "newAttachmentStart" -> check(request.optInt("size") == uploadBytes.size)
                        "newAttachmentChunk" -> {
                            check(request.optInt("offset") == uploaded.size())
                            uploaded.write(Base64.decode(request.getString("data"), Base64.NO_WRAP))
                        }
                        "newAttachmentComplete" -> {
                            check(uploaded.toByteArray().contentEquals(uploadBytes))
                            val digest = java.security.MessageDigest.getInstance("SHA-256").digest(uploadBytes).joinToString("") { "%02x".format(it) }
                            check(request.getString("sha256") == digest)
                        }
                        else -> error("Unexpected upload operation")
                    }
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("attachmentId", request.getString("attachmentId")))
                }
                io.github.junweiup.vibepier.remote.features.sessions.CodexFileUpload.upload(context.resources, client, uploadDraft.attachmentScope,
                    uploadFile, "example.txt", "text/plain", {}, creation = uploadDraft) { uploadResult.set(it); uploadedDone.countDown() }
            }
            try {
                check(uploadedDone.await(8, java.util.concurrent.TimeUnit.SECONDS)); check(uploadResult.get().optBoolean("ok"))
                check(uploaded.toByteArray().contentEquals(uploadBytes))
            } finally {
                test.runOnMainSync {
                    transport.onCompletePacket = null; client.close(); client = SessionClient(context, transport, 80)
                    client.onEvent = { events.add(it) }; client.connectionChanged(true)
                }
                uploadFile.delete()
            }
            val optionPackets = transport.frames.map { it.getString("packet") }.distinct().size
            test.runOnMainSync {
                val id = client.request("newOptions", uploadDraft.value()) { error("Dismissed options must not call back") }
                client.cancelCreationOptions(id)
            }
            SystemClock.sleep(300); test.waitForIdleSync()
            check(transport.frames.map { it.getString("packet") }.distinct().size == optionPackets + 1) { "Dismissed creation options retried" }
            // Read-only requests share one RPC and successful content survives a recreated client.
            val coalescedResults = java.util.concurrent.atomic.AtomicInteger()
            test.runOnMainSync {
                val before = client.networkReads
                val fields = JSONObject().put("threadId", "cache-thread").put("cacheVersion", "models-v1")
                val first = client.request("composerOptions", fields) { check(it.optBoolean("ok")); coalescedResults.incrementAndGet() }
                val second = client.request("composerOptions", fields) { check(it.optBoolean("ok")); coalescedResults.incrementAndGet() }
                check(first == second && client.networkReads == before + 1 && client.coalescedReads > 0)
                reply(JSONObject().put("id", first).put("ok", true).put("models", org.json.JSONArray().put(JSONObject().put("id", "cached-model"))))
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(coalescedResults.get() == 2)
                val before = client.networkReads
                repeat(20) { client.request("composerOptions", JSONObject().put("threadId", "cache-thread").put("cacheVersion", "models-v1")) { check(it.getJSONArray("models").getJSONObject(0).optString("id") == "cached-model") } }
                check(client.networkReads == before && client.cacheHits >= 20)
                val first = client.request("image", JSONObject().put("threadId", "cache-thread").put("imageId", "image#0").put("size", "large").put("cacheVersion", "image-v1")) {}
                reply(JSONObject().put("id", first).put("ok", true).put("image", "AQID"))
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                val before = client.networkReads
                repeat(20) { client.request("image", JSONObject().put("threadId", "cache-thread").put("imageId", "image#0").put("size", "large").put("cacheVersion", "image-v1")) { check(it.optString("image") == "AQID") } }
                check(client.networkReads == before)
                client.request("image", JSONObject().put("threadId", "cache-thread").put("imageId", "image#0").put("size", "large").put("cacheVersion", "image-v2")) {}
                check(client.networkReads == before + 1)
                reply(JSONObject().put("id", decodeLast("image").getString("id")).put("ok", false).put("error", "not available"))
            }
            test.waitForIdleSync()
            // Exercise uncertain approval state with real views and the isolated fake transport.
            val activity = test.startActivitySync(android.content.Intent(test.targetContext, MainActivity::class.java)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "offline"))
            lateinit var panel: ConversationPanel
            lateinit var dialog: android.app.AlertDialog
            fun field(value: Any, name: String): Any? = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
            fun views(root: android.view.View): List<android.view.View> = listOf(root) + if (root is android.view.ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
            try {
                test.runOnMainSync {
                    panel = ConversationPanel(activity, client, {})
                    activity.setContentView(panel)
                    reply(JSONObject().put("id", decodeLast().getString("id")).put("ok", true).put("threads", org.json.JSONArray()).put("nextOffset", -1))
                }
                test.waitForIdleSync()
                val initialList = field(panel, "list")
                test.runOnMainSync {
                    panel.javaClass.getDeclaredMethod("loadList", Boolean::class.javaPrimitiveType, Boolean::class.javaPrimitiveType).apply { isAccessible = true }.invoke(panel, false, false)
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }.invoke(panel, "thread", "Isolated approval test")
                    reply(JSONObject().put("id", decodeLast().getString("id")).put("ok", true).put("opening", true))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(field(panel, "opening") == true && field(panel, "ready") == false)
                    (field(panel, "openRecovery") as Runnable).run()
                    val sync = decodeLast(); check(sync.getString("op") == "sync")
                    reply(ConversationReviewFixtures.conversation("approval").put("threadId", "thread").put("viewVersion", client.viewVersion).put("id", sync.getString("id")))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(field(panel, "opening") == false && field(panel, "ready") == true)
                    val readsBeforeReturn = client.networkReads
                    panel.back()
                    check(client.networkReads == readsBeforeReturn) { "Fresh drawer read unexpectedly: before=$readsBeforeReturn after=${client.networkReads}, cache=${field(client, "lists")}, latest=${decodeLast()}" } // Fresh list reuse sends no read request.
                    check(field(panel, "list") === initialList)
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    check(decodeLast().getString("op") == "close") // Fresh rows are reused; closing a subscription remains necessary.
                    panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }.invoke(panel, "thread", "Timeout test")
                    (field(panel, "openDeadline") as Runnable).run()
                    check(field(panel, "opening") == false && field(panel, "ready") == false)
                    check((field(panel, "status") as CanvasLabel).text.toString().contains(context.getString(R.string.session_could_not_open_session_tap_refresh_to_retry)))
                    val pending = field(client, "pending") as Map<*, *>
                    check(pending.values.none { field(it!!, "json").let { j -> (j as JSONObject).optString("op") == "open" } })
                    panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }.invoke(panel, "thread", "Isolated approval test")
                    val state = ConversationReviewFixtures.conversation("approval").put("threadId", "thread").put("viewVersion", client.viewVersion).put("revision", 20)
                    client.onEvent(state)
                    client.connectionChanged(false); panel.connectionChanged()
                    check(field(panel, "ready") == false)
                    client.connectionChanged(true); panel.connectionChanged()
                    val reopen = decodeLast()
                    check(reopen.getString("op") == "open" && reopen.getString("threadId") == "thread")
                    reply(JSONObject().put("id", reopen.getString("id")).put("ok", true))
                    client.onEvent(JSONObject(state.toString()).put("viewVersion", client.viewVersion))
                    check(field(panel, "ready") == true)
                    val retainedPage = field(panel, "page")
                    val retainedTimeline = field(panel, "timeline")
                    (field(panel, "editor") as android.widget.EditText).setText("background draft")
                    panel.suspend()
                    client.connectionChanged(false); panel.connectionChanged()
                    val count = transport.frames.size
                    client.connectionChanged(true); panel.connectionChanged()
                    check(transport.frames.size == count) // Reconnection in the background never reloads the page.
                    check(field(panel, "page") === retainedPage && field(panel, "timeline") === retainedTimeline)
                    check((field(panel, "editor") as android.widget.EditText).text.toString() == "background draft")
                    panel.resume()
                    val resumed = decodeLast(); check(resumed.getString("op") == "open")
                    client.onEvent(JSONObject(state.toString()).put("viewVersion", client.viewVersion))
                    check(field(panel, "ready") == true)
                    check(field(panel, "timeline") === retainedTimeline)
                    val editor = field(panel, "editor") as android.widget.EditText
                    editor.setText("draft preserved while stopping")
                    val stop = field(panel, "stopButton") as android.view.View
                    check(stop.isShown && stop.isEnabled); stop.performClick()
                    val request = decodeLast()
                    check(request.getString("op") == "interrupt" && request.getString("expectedTurnId") == "fixture-turn")
                    operation = request.getString("id")
                    reply(JSONObject().put("id", operation).put("ok", true).put("accepted", true))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check((field(panel, "editor") as android.widget.EditText).text.toString() == "draft preserved while stopping")
                    val state = ConversationReviewFixtures.conversation("approval").put("threadId", "thread").put("viewVersion", client.viewVersion).put("revision", 20)
                    panel.javaClass.getDeclaredMethod("showApproval", JSONObject::class.java).apply { isAccessible = true }.invoke(panel, state.getJSONArray("approvals").getJSONObject(0))
                    dialog = field(panel, "approvalDialog") as android.app.AlertDialog
                    views(dialog.window!!.decorView).first { it.contentDescription?.toString() == context.getString(R.string.session_deny) }.performClick()
                }
                SystemClock.sleep(180); test.waitForIdleSync()
                test.runOnMainSync {
                    check(!views(dialog.window!!.decorView).first { it.contentDescription?.toString() == context.getString(R.string.session_allow_once) }.isEnabled)
                    check(views(dialog.window!!.decorView).any { it.contentDescription?.toString() == context.getString(R.string.session_check_result) })
                    operation = client.uncertain("thread").first { it.optString("op") == "approve" }.getString("id")
                }
                reply(JSONObject().put("id", operation).put("ok", true).put("submitted", true)); test.waitForIdleSync()
                test.runOnMainSync { check(!dialog.isShowing) }
                lateinit var detail: JSONObject
                test.runOnMainSync {
                    val state = ConversationReviewFixtures.conversation("approval").put("threadId", "thread").put("viewVersion", client.viewVersion).put("revision", 21)
                    detail = state.getJSONArray("approvals").getJSONObject(0).put("fingerprint", "next-approval")
                    val summary = JSONObject(detail.toString()).put("detailsOnDemand", true); summary.remove("details")
                    state.put("approvals", org.json.JSONArray().put(summary)); client.onEvent(state)
                    panel.javaClass.getDeclaredMethod("showApproval", JSONObject::class.java).apply { isAccessible = true }.invoke(panel, summary)
                    operation = decodeLast().getString("id")
                    client.onEvent(JSONObject(state.toString()).put("revision", 22).put("approvals", org.json.JSONArray()))
                }
                reply(JSONObject().put("id", operation).put("ok", true).put("approval", detail)); test.waitForIdleSync()
                test.runOnMainSync {
                    check(field(panel, "approvalDialog") == null)
                    check((field(panel, "notice") as CanvasLabel).text.toString().contains(context.getString(R.string.session_the_approval_changed_or_expired_refresh_it)))
                    val summary = JSONObject(detail.toString()).put("detailsOnDemand", true); summary.remove("details")
                    panel.javaClass.getDeclaredMethod("showApproval", JSONObject::class.java).apply { isAccessible = true }.invoke(panel, summary)
                    operation = decodeLast().getString("id")
                }
                reply(JSONObject().put("id", operation).put("ok", false).put("error", "完整详情读取失败")); test.waitForIdleSync()
                test.runOnMainSync {
                    check(field(panel, "approvalDialog") == null)
                    check((field(panel, "notice") as CanvasLabel).text.toString().contains("读取失败"))
                    panel.close()
                    // The 80 ms timeout scenarios above are complete. Native layout/Keystore
                    // work below must not race that deliberately shortened request deadline.
                    client.close()
                    client = SessionClient(context, transport, 5_000).apply { connectionChanged(true) }
                    val count = transport.frames.size
                    client.invalidateLists() // Expired/invalidated lists still refresh while retaining visible cache.
                    panel = ConversationPanel(activity, client, {})
                    activity.setContentView(panel)
                    check(transport.frames.size > count && decodeLast().getString("op") == "list") // Cache is visible while an immediate refresh is pending.
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }.invoke(panel, "thread", "Cached session")
                    check((field(panel, "page") as JSONObject).has("messages"))
                    check(field(panel, "ready") == false) // Cached messages never authorize sending or approval.
                    check((field(panel, "status") as CanvasLabel).text.toString().contains(context.getString(R.string.session_saved_content_syncing_the_latest_state)))
                    val preview = ConversationReviewFixtures.conversation("approval").put("threadId", "thread").put("viewVersion", client.viewVersion).put("revision", 30)
                    val sequence = org.json.JSONArray()
                        .put(JSONObject().put("id", "prose-before").put("index", 0).put("kind", "text").put("text", "Before command").put("bodyVersion", "before"))
                        .put(JSONObject().put("id", "step0").put("index", 1).put("kind", "command").put("title", "printf first").put("status", "completed").put("bodyVersion", "24|completed").put("bodyDeferred", true))
                        .put(JSONObject().put("id", "prose-between").put("index", 2).put("kind", "text").put("text", "After command, before file").put("bodyVersion", "between"))
                        .put(JSONObject().put("id", "step1").put("index", 3).put("kind", "file").put("title", "later.swift").put("status", "completed").put("bodyVersion", "0|completed").put("bodyDeferred", true))
                        .put(JSONObject().put("id", "prose-after").put("index", 4).put("kind", "text").put("text", "After file").put("bodyVersion", "after"))
                    preview.put("messages", org.json.JSONArray().put(JSONObject().put("id", "preview-reply").put("role", "assistant").put("text", "Legacy aggregate must not repeat").put("sequence", sequence).put("partCount", 5)))
                    client.onEvent(preview)
                    val editor = field(panel, "editor") as android.widget.EditText
                    editor.setText("Queued requirement")
                    (field(panel, "sendButton") as android.view.View).performClick()
                    val send = decodeLast(); check(send.optString("op") == "send")
                    val queued = org.json.JSONArray().put(JSONObject().put("id", send.getString("id")).put("text", "Queued requirement").put("status", "queued").put("canSteer", true).put("canDelete", true))
                    reply(JSONObject().put("id", send.getString("id")).put("ok", true).put("accepted", true).put("queued", true).put("queuedMessages", queued))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check((field(panel, "editor") as android.widget.EditText).text.isEmpty())
                    val queued = (field(panel, "page") as JSONObject).getJSONArray("queuedMessages")
                    val id = queued.getJSONObject(0).getString("id")
                    check((field(panel, "outbox") as Map<*, *>).isEmpty())
                    (field(panel, "editor") as android.widget.EditText).setText("Keep separate draft")
                    views(panel).first { it.contentDescription?.toString() == context.getString(R.string.session_steer) }.performClick()
                    val steer = decodeLast(); check(steer.optString("op") == "queueSteer" && steer.optString("messageId") == id)
                    check(client.uncertain("thread").any { it.optString("id") == steer.getString("id") })
                    queued.getJSONObject(0).put("status", "pending").put("canSteer", false).put("canDelete", false)
                    reply(JSONObject().put("id", steer.getString("id")).put("ok", true).put("accepted", true).put("queuedMessages", queued))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(!views(panel).first { it.contentDescription?.toString() == context.getString(R.string.session_steer) }.isEnabled)
                    check((field(panel, "editor") as android.widget.EditText).text.toString() == "Keep separate draft")
                    client.onEvent(JSONObject().put("event", "queue").put("threadId", "thread").put("viewVersion", client.viewVersion).put("queuedMessages", org.json.JSONArray()))
                    check(views(panel).none { it.contentDescription?.toString() == context.getString(R.string.session_steer) })
                    val queue = org.json.JSONArray().put(JSONObject().put("id", "delete-queue").put("text", "Delete requirement").put("status", "queued").put("canSteer", true).put("canDelete", true))
                    client.onEvent(JSONObject().put("event", "queue").put("threadId", "thread").put("viewVersion", client.viewVersion).put("queuedMessages", queue))
                    views(panel).first { it.contentDescription?.toString() == context.getString(R.string.delete) }.performClick()
                    val deleted = decodeLast(); check(deleted.optString("op") == "queueDelete" && deleted.optString("messageId") == "delete-queue")
                    reply(JSONObject().put("id", deleted.getString("id")).put("ok", true).put("accepted", true).put("queuedMessages", org.json.JSONArray()))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check((field(panel, "editor") as android.widget.EditText).text.toString() == "Keep separate draft")
                    check(views(panel).none { it.contentDescription?.toString() == context.getString(R.string.session_steer) })
                    val scrolling = field(panel, "scroll") as android.widget.ScrollView
                    scrolling.scrollTo(0, 0)
                    check(views(panel).none { it.contentDescription?.toString() == "加载更早的消息" })
                    scrolling.performAccessibilityAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD, null)
                    val history = decodeLast(); check(history.optString("op") == "history")
                    val count = transport.frames.size
                    scrolling.performAccessibilityAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD, null)
                    check(transport.frames.size == count)
                    reply(JSONObject().put("id", history.getString("id")).put("ok", true).put("hasOlder", false).put("messages", org.json.JSONArray().put(JSONObject().put("id", "older-1").put("role", "user").put("text", "Earlier requirement"))))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check((field(panel, "olderMessages") as Map<*, *>).containsKey("older-1"))
                    check(views(panel).none { it.contentDescription?.toString()?.contains("查看处理过程") == true || it.contentDescription?.toString()?.contains("执行过程") == true })
                    check((field(panel, "auxiliaryDialogs") as Collection<*>).isEmpty())
                    val content = views(panel).filterIsInstance<CanvasLabel>().map { it.text.toString() }
                    val expected = listOf("Before command", "printf first", "After command, before file", "later.swift", "After file")
                    check(expected.map { content.indexOf(it) }.zipWithNext().all { (a, b) -> a >= 0 && b > a }) { "Desktop order lost: $content" }
                    check(content.none { it == "Legacy aggregate must not repeat" })
                    check(runCatching { decodeLast("message") }.isFailure) // Metadata does not read command output.
                    views(panel).first { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "printf first", "")) == true }.performClick()
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    val request = decodeLast("message"); check(request.getString("messageId") == "step0" && request.getInt("offset") == 0 && request.optBoolean("withPart"))
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("text", "First output").put("nextOffset", 12))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(views(panel).any { (it as? CanvasLabel)?.text.toString() == "First output" })
                    check(decodeLast("message").getInt("offset") == 0) // Long output is only continued on tap.
                    views(panel).first { it.contentDescription?.toString() == context.getString(R.string.continue_output) }.performClick()
                    val request = decodeLast("message"); check(request.getInt("offset") == 12)
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("text", " + second output").put("nextOffset", -1))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(views(panel).any { (it as? CanvasLabel)?.text.toString() == "First output + second output" })
                    val count = transport.frames.size
                    views(panel).first { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "printf first", "")) == true }.performClick()
                    views(panel).first { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "printf first", "")) == true }.performClick()
                    check(transport.frames.size == count)
                    check(views(panel).any { (it as? CanvasLabel)?.text.toString() == "First output + second output" })
                    val next = JSONObject((field(panel, "page") as JSONObject).toString()).put("event", "snapshot").put("revision", 31).put("hasOlder", false)
                    val sequence = next.getJSONArray("messages").getJSONObject(0).getJSONArray("sequence")
                    for (i in 0 until sequence.length()) sequence.getJSONObject(i).put("index", i + 8)
                    next.getJSONArray("messages").getJSONObject(0).put("partCount", 13)
                    client.onEvent(next)
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    val scrolling = field(panel, "scroll") as android.widget.ScrollView
                    scrolling.scrollTo(0, 0)
                    scrolling.performAccessibilityAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD, null)
                    val request = decodeLast("parts")
                    check(request.optBoolean("sequence") && request.getInt("offset") == 0 && request.getInt("before") == 8)
                    val count = transport.frames.size
                    scrolling.performAccessibilityAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD, null)
                    check(transport.frames.size == count)
                    val earlier = org.json.JSONArray((0..7).map { i -> JSONObject().put("id", "earlier-$i").put("index", i).put("kind", if (i % 2 == 0) "text" else "command").put("title", "older command $i").put("text", if (i % 2 == 0) "Older paragraph $i" else "").put("bodyVersion", "old-$i") })
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("parts", earlier).put("partCount", 13).put("nextOffset", 8))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    val content = views(panel).filterIsInstance<CanvasLabel>().map { it.text.toString() }
                    val expected = listOf("Older paragraph 0", "older command 1", "Older paragraph 2", "older command 3", "Before command", "printf first", "First output + second output", "After command, before file", "later.swift", "After file")
                    check(expected.map { content.indexOf(it) }.zipWithNext().all { (a, b) -> a >= 0 && b > a }) { "Prepend reordered desktop content: $content" }
                    check(decodeLast("message").getInt("offset") == 12) // Reading earlier titles did not download tool bodies.
                    check((field(panel, "auxiliaryDialogs") as Collection<*>).isEmpty())
                    val live = JSONObject((field(panel, "page") as JSONObject).toString()).put("event", "snapshot").put("revision", 32).put("cacheVersion", "same-content")
                    client.onEvent(live)
                    panel.suspend(); panel.resume()
                    val resumed = decodeLast("open")
                    check(resumed.optString("knownVersion") == "same-content")
                    val short = JSONObject(live.toString()).put("id", resumed.getString("id")).put("viewVersion", client.viewVersion).put("unchanged", true)
                    short.remove("messages"); reply(short)
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(field(panel, "ready") == true && (field(panel, "page") as JSONObject).getJSONArray("messages").length() == 1)
                    check(views(panel).any { (it as? CanvasLabel)?.text.toString() == "First output + second output" })
                    panel.suspend(); panel.resume()
                    val resumed = decodeLast("open")
                    val short = JSONObject((field(panel, "page") as JSONObject).toString()).put("id", resumed.getString("id")).put("viewVersion", client.viewVersion).put("unchanged", true).put("canSend", false)
                    short.remove("messages"); reply(short)
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(field(panel, "ready") == true && (field(panel, "page") as JSONObject).has("messages")) // Keep cached content readable when the live peer revokes sending.
                    check(!(field(panel, "page") as JSONObject).optBoolean("canSend"))
                    check(!(field(panel, "sendButton") as android.view.View).isEnabled)
                    check(!(field(panel, "stopButton") as android.view.View).isEnabled)
                    val readOnlyControls = field(panel, "composerControls") as ComposerControls
                    check(!readOnlyControls.mode.isEnabled && !readOnlyControls.model.isEnabled && !readOnlyControls.add.isEnabled)
                    panel.close()
                    client.listMode = "projects"
                    panel = ConversationPanel(activity, client, {}); activity.setContentView(panel)
                    val request = decodeLast(); check(request.getString("op") == "projects" && request.getInt("limit") == 8)
                    val projects = org.json.JSONArray()
                    for (i in 0..7) projects.put(JSONObject().put("cwd", "/p/$i").put("project", "Project$i").put("count", 1))
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("projects", projects).put("nextOffset", 8))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(views(panel).none { it.contentDescription?.toString() == "加载更多项目" })
                    val list = field(panel, "list") as android.view.View
                    val scrolling = list.parent as android.widget.ScrollView
                    scrolling.scrollTo(0, list.height)
                    // A second request during the same pagination operation is ignored.
                    val count = transport.frames.size
                    panel.javaClass.getDeclaredMethod("loadNextListPage").apply { isAccessible = true }.invoke(panel)
                    check(transport.frames.size == count)
                    val request = decodeLast(); check(request.getString("op") == "projects" && request.getInt("offset") == 8 && request.getInt("limit") == 8)
                    val projects = org.json.JSONArray()
                    for (i in 8..9) projects.put(JSONObject().put("cwd", "/p/$i").put("project", "Project$i").put("count", 1))
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("projects", projects).put("nextOffset", -1))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(field(panel, "listedCount") == 10)
                    check(views(panel).any { it.contentDescription?.toString()?.startsWith(context.getString(R.string.session_open_project_count, "Project0", 1)) == true })
                    check(views(panel).any { it.contentDescription?.toString()?.startsWith(context.getString(R.string.session_open_project_count, "Project9", 1)) == true })
                    val reads = client.networkReads
                    panel.suspend(); panel.resume()
                    check(client.networkReads == reads)
                    client.invalidateLists()
                    panel.suspend(); panel.resume()
                    check(field(panel, "listedCount") == 10)
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    val request = decodeLast(); check(request.getString("op") == "projects" && request.getInt("offset") == 0)
                    reply(JSONObject().put("id", request.getString("id")).put("ok", false).put("error", "refresh temporarily unavailable"))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(field(panel, "listedCount") == 10)
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    panel.close(); client.close() // Simulate the old process closing before constructing its replacement.
                    val restoredClient = SessionClient(context, transport, 80)
                    check(restoredClient.cachedList("projects", JSONObject().put("search", "").put("offset", 0).put("limit", 8))!!.getJSONArray("projects").length() == 10)
                    check(restoredClient.drawerState.has("scrollY"))
                    panel = ConversationPanel(activity, restoredClient, {}); activity.setContentView(panel)
                    check(field(panel, "listedCount") == 10) // A newly-created, disconnected client renders persisted cache immediately.
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    restoredClient.connectionChanged(true); panel.connectionChanged()
                    val request = decodeLast(); check(request.getString("op") == "projects" && request.getInt("offset") == 0)
                    val projects = org.json.JSONArray()
                    for (i in 0..7) projects.put(JSONObject().put("cwd", "/p/$i").put("project", "Updated$i").put("count", 2))
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("projects", projects).put("nextOffset", 8))
                    // Frame handler belongs to the restored client, whose page is still the cached 10 rows.
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    val request = decodeLast(); check(request.getString("op") == "projects" && request.getInt("offset") == 8 && request.getInt("limit") == 2)
                    val projects = org.json.JSONArray()
                    for (i in 8..9) projects.put(JSONObject().put("cwd", "/p/$i").put("project", "Updated$i").put("count", 2))
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("projects", projects).put("nextOffset", -1))
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(field(panel, "listedCount") == 10)
                    check(views(panel).any { it.contentDescription?.toString()?.startsWith(context.getString(R.string.session_open_project_count, "Updated9", 2)) == true })
                    val restoredClient = field(panel, "client") as SessionClient
                    panel.close(); restoredClient.close()
                    val persisted = SessionClient(context, transport, 80)
                    check(persisted.cachedPage("thread")?.has("messages") == true)
                    val cachedBody = persisted.cachedProcess("thread", "preview-reply")!!.getJSONObject("bodies").getJSONObject("step0")
                    check(cachedBody.optBoolean("loaded") && cachedBody.optString("text") == "First output + second output")
                    check(persisted.cachedProcess("thread", "preview-reply")!!.getJSONArray("rows").length() == 13)
                    persisted.close()
                }
            } finally { test.runOnMainSync { activity.finish() } }
            // Only adjacent commands/edits fold together. Expanding a group alone reads no bodies.
            val groupActivity = test.startActivitySync(android.content.Intent(test.targetContext, MainActivity::class.java).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
            lateinit var grouped: InlineReplyProcess
            val groupState = InlineReplyProcess.State()
            val outputReads = mutableListOf<String>()
            try {
                test.runOnMainSync {
                    val entries = org.json.JSONArray((0..6).map { i -> JSONObject().put("id", "group-$i").put("index", i)
                        .put("kind", when (i) { 0, 1, 3 -> "command"; 4, 5 -> "file"; else -> "text" })
                        .put("title", "item-$i").put("text", if (i in listOf(2, 6)) "paragraph-$i" else "").put("status", "completed").put("bodyVersion", "version-$i") })
                    groupState.accept(entries, 7)
                    grouped = InlineReplyProcess(groupActivity, groupState, { true }, { _, _, _ -> error("Already loaded headers must not be read again") }, { id, _, done ->
                        outputReads.add(id); done(JSONObject().put("ok", true).put("text", "body-$id").put("nextOffset", -1))
                    }, { android.view.View(groupActivity) })
                    groupActivity.setContentView(grouped)
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(views(grouped).any { it.contentDescription?.toString()?.contains(context.resources.getQuantityString(R.plurals.group_commands, 2, 2)) == true })
                    check(views(grouped).any { it.contentDescription?.toString()?.contains(context.resources.getQuantityString(R.plurals.group_edits, 2, 2)) == true })
                    check(views(grouped).none { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "item-0", "")) == true })
                    check(views(grouped).any { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "item-3", "")) == true }) // A paragraph prevents merging command 3 into the previous group.
                    views(grouped).first { it.contentDescription?.toString()?.contains(context.resources.getQuantityString(R.plurals.group_commands, 2, 2)) == true }.performClick()
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(outputReads.isEmpty())
                    views(grouped).first { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "item-0", "")) == true }.performClick()
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(outputReads == listOf("group-0"))
                    views(grouped).first { it.contentDescription?.toString()?.contains(context.resources.getQuantityString(R.plurals.group_commands, 2, 2)) == true }.performClick()
                    views(grouped).first { it.contentDescription?.toString()?.contains(context.resources.getQuantityString(R.plurals.group_commands, 2, 2)) == true }.performClick()
                    check(outputReads.size == 1)
                    val restored = InlineReplyProcess.State().apply { restore(groupState.snapshot()) }
                    check(restored.bodies.getValue("group-0").text == "body-group-0" && restored.groups.getValue("command:group-0"))
                    val content = views(grouped).filterIsInstance<CanvasLabel>().map { it.text.toString() }
                    check(content.indexOf("item-1") < content.indexOf("paragraph-2") && content.indexOf("paragraph-2") < content.indexOf("item-3"))
                    views(grouped).first { it.contentDescription?.toString()?.contains(context.resources.getQuantityString(R.plurals.group_edits, 2, 2)) == true }.performClick()
                }
                test.waitForIdleSync()
                test.runOnMainSync {
                    check(outputReads.size == 1)
                    views(grouped).first { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "item-4", "")) == true }.performClick()
                }
                test.waitForIdleSync()
                test.runOnMainSync { check(outputReads == listOf("group-0", "group-4")) }
            } finally { test.runOnMainSync { groupActivity.finish() } }
            // Fixed CryptoKit fixture verifies Apple/Android nonce+ciphertext+tag interoperability.
            val data = Base64.decode("AAAAAAAAAAAAAAAAiW8MVVA97mJB4iDiIs7ARhJ61iT6zCpIh6OawvCr/2iTyw==", Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, data.copyOfRange(0,12)))
            cipher.updateAAD("vibepier-session-v1|phone|device|packet".toByteArray())
            check(String(cipher.doFinal(data.copyOfRange(12,data.size))) == "跨端加密测试")
            return "PASS: read coalescing (2 callers / 1 RPC), 20 model-menu cache hits / 0 RPC, 20 large-image cache hits / 0 RPC, content-version invalidation and unchanged confirmations with fresh capability gating, durable conversation/output/earlier-header restore, adjacent command/file folds preserve paragraphs and load only a clicked item; durable app configuration/icon cache round trip, corrupt cache recovery, incomplete icon snapshot rejected, endpoint-scoped cache; Codex native queued send, steer with original message ID, sending-state gating, desktop queue event removal, delete and draft preservation; persisted offline cache restored in new client, fresh foreground cache avoids reads, invalidated cache refreshes without loading screen, failed refresh keeps rows, full visible window refreshed across pages, project first-page limit and next-offset append, background retains timeline and draft, no background reload, foreground resubscribes without page recreation, desktop interleaving without a dialog, metadata-only ordered pagination, command outputs fetched only on expansion, long outputs paged on explicit demand, collapse/reopen retains output, missing opening push recovered by sync, bounded opening timeout, obsolete reads canceled, cached drawer restored while list refreshes, automatic scroll pagination without duplicate requests, conversation top gesture/accessibility loads history without a button and preserves identities, automatic subscription recovery after reconnect, KeyStore pairing, timeout reservation, late receipt, scoped draft reconciliation, same-operation retry, edited draft preservation, CryptoKit interoperability, visible stop clicked with draft and expected turn verified, settings/interrupt same-ID unknown recovery and draft preservation, sent attachment subset cleanup, uncertain approval gating and late approval dismissal, expired approval details and load failure blocked\n"
        } finally {
            test.runOnMainSync { client.close() }
            DeviceKeys(context).clear()
            context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
        }
    }
}
