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
        override var binaryHost: String? = null
        override var enrollmentReady = true
        override var onSessionFrame: (JSONObject) -> Unit = {}
        override var onSessionPair: (ByteArray?) -> Unit = {}
        val frames = CopyOnWriteArrayList<JSONObject>()
        var onCompletePacket: (() -> Unit)? = null
        val deliveringPacket = ThreadLocal.withInitial { false }
        override fun sendBinding(message: JSONObject) {
            frames.add(JSONObject(message.toString()))
            if (message.optInt("part") == message.optInt("parts") - 1) {
                deliveringPacket.set(true)
                try { onCompletePacket?.invoke() } finally { deliveringPacket.set(false) }
            }
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
        // These independent UI expectations must still fail the probe, but must not hide the
        // remaining history/cache coverage behind the already diagnosed production queue defect.
        val deferredAssertions = mutableListOf<Throwable>()
        fun expect(condition: Boolean, message: String) {
            if (!condition) deferredAssertions.add(AssertionError(message))
        }
        val key = SecretKeySpec(ByteArray(32) { 7 }, "AES")
        fun rawRequests(): List<JSONObject> = transport.frames.map { it.getString("packet") }.distinct().mapNotNull { packet ->
            val frames = transport.frames.filter { it.getString("packet") == packet }.sortedBy { it.getInt("part") }
            if (frames.size != frames.first().getInt("parts")) return@mapNotNull null
            val data = Base64.decode(frames.joinToString("") { it.getString("data") }, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, data.copyOfRange(0, 12)))
            cipher.updateAAD("vibepier-session-v1|phone|${client.device}|$packet".toByteArray())
            JSONObject(String(cipher.doFinal(data.copyOfRange(12, data.size)), Charsets.UTF_8))
        }
        fun wireReply(value: JSONObject) {
            val packet = UUID.randomUUID().toString(); val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key); cipher.updateAAD("vibepier-session-v1|mac|${client.device}|$packet".toByteArray())
            val data = Base64.encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray()), Base64.NO_WRAP)
            val pieces = data.chunked(900)
            pieces.forEachIndexed { i, part -> transport.onSessionFrame(JSONObject().put("type", "vibepier-session1").put("sender", client.device).put("device", client.device).put("packet", packet).put("part", i).put("parts", pieces.size).put("data", part)) }
        }
        val protocol = SessionProbeProtocolFixture(test, { client }, ::rawRequests, ::wireReply)
        fun main(block: () -> Unit) { protocol.main(block); protocol.settle() }
        fun decodeLast(expectedOp: String? = null, expectedID: String? = null): JSONObject {
            if (transport.deliveringPacket.get() != true) protocol.fence()
            for (raw in rawRequests().asReversed()) {
                if (raw.optString("op") in setOf("providers", "notificationSubscribe") || raw.optJSONObject("body")?.optString("method") == "session.observe") continue
                val value = protocol.project(raw)
                if ((expectedOp == null || value.optString("op") == expectedOp) && (expectedID == null || value.optString("id") == expectedID)) return value
            }
            error("No $expectedOp request for $expectedID")
        }
        fun reply(value: JSONObject) {
            val request = decodeLast(expectedID = value.getString("id"))
            if (value.optBoolean("ok")) {
                if (!value.has("threadId") && request.has("threadId")) value.put("threadId", request.get("threadId"))
                if (request.optString("op") == "new") value.put("cwd", request.get("cwd"))
                if (request.optString("op") == "approve") value.put("fingerprint", request.get("fingerprint"))
            }
            protocol.reply(value)
        }
        fun emit(value: JSONObject) { protocol.remember(value); client.onEvent(value) }
        fun pageReads(): Int {
            protocol.fence()
            return rawRequests().count { request ->
                request.optString("op") in setOf("list", "projects", "open", "sync", "history", "parts", "message") ||
                    request.optJSONObject("body")?.optString("method") in setOf("session.list", "workspace.list", "session.open", "session.snapshot", "session.items")
            }
        }
        fun sameIntent(first: JSONObject, retry: JSONObject) {
            check(first.getString("id") == retry.getString("id"))
            check(first.getString("_wireId") != retry.getString("_wireId"))
            val originalBody = rawRequests().single { it.getString("id") == first.getString("_wireId") }.getJSONObject("body")
            val retryBody = rawRequests().single { it.getString("id") == retry.getString("_wireId") }.getJSONObject("body")
            check(io.github.junweiup.vibepier.remote.core.session.SessionAgentProtocol.fingerprint(originalBody) ==
                io.github.junweiup.vibepier.remote.core.session.SessionAgentProtocol.fingerprint(retryBody))
        }
        fun notFound(id: String) {
            main { client.request("receipt", JSONObject().put("operation", id)) {
                if (it.optString("state") != "notFound") protocol.callbackFailures.add(AssertionError("Expected original operation notFound"))
            } }
            val lookup = decodeLast("receipt")
            check(lookup.getString("_method") == "operation.get" && lookup.getString("operation") == id)
            reply(JSONObject().put("id", lookup.getString("id")).put("ok", true)
                .put("operation", JSONObject().put("operationId", id).put("status", "notFound")))
            protocol.settle()
        }
        try {
            main {
                client = SessionClient(context, transport, 1_000); client.onEvent = { events.add(it) }
                transport.enrollmentReady = false; client.pair(); check(transport.pairRequests == 0)
                transport.enrollmentReady = true; client.pair(); check(transport.pairRequests == 1)
                check(!client.online)
                // Discovery updates while awaiting Mac approval must not cancel enrollment.
                client.connectionChanged(false)
                transport.onSessionPair(JSONObject().put("state", "approved").put("device", client.device).put("key", Base64.encodeToString(ByteArray(32) { 7 }, Base64.NO_WRAP)).toString().toByteArray())
            }
            test.waitForIdleSync(); check(client.paired); check(!client.online)
            main { client.connectionChanged(true) }
            protocol.discover("codex", "thread")
            var operation = ""
            main {
                client.saveDraft("thread", "hello")
                operation = client.request("send", JSONObject().put("threadId", "thread").put("text", "hello")) { replies.add(it) }
            }
            SystemClock.sleep(1_100); protocol.settle()
            check(replies.last().optBoolean("unknown")); check(client.uncertain("thread").size == 1)
            reply(JSONObject().put("id", operation).put("ok", true).put("accepted", true)); test.waitForIdleSync()
            val late = events.filter { it.optString("event") == "lateReceipt" && it.optJSONObject("operation")?.optString("id") == operation }
            check(late.size == 1 && late.single().getJSONObject("operation").optString("threadId") == "thread")
            check(client.draft("thread").isEmpty()); check(client.uncertain("thread").isEmpty())
            main {
                client.saveDraft("thread", "second")
                operation = client.request("send", JSONObject().put("threadId", "thread").put("text", "second")) { replies.add(it) }
            }
            SystemClock.sleep(1_100); protocol.settle()
            val original = decodeLast()
            notFound(operation)
            main { client.saveDraft("thread", "edited later"); client.retryPending(operation) { replies.add(it) } }
            val retry = decodeLast(); sameIntent(original, retry); check(original.getString("id") == retry.getString("id")); check(retry.getString("text") == "second")
            reply(JSONObject().put("id", operation).put("ok", true).put("accepted", true)); test.waitForIdleSync()
            check(client.draft("thread") == "edited later")
            // Settings and stop are mutable too: persist uncertainty, then reconcile without clearing text/attachments.
            for (op in listOf("settings", "interrupt")) {
                main {
                    client.saveDraft("thread", "keep this draft")
                    client.saveAttachments("thread", org.json.JSONArray().put(JSONObject().put("attachmentId", "keep")))
                    protocol.remember(ConversationReviewFixtures.conversation("approval").put("provider", "codex")
                        .put("threadId", "thread").put("activeTurnId", "old-turn"))
                    operation = client.request(op, JSONObject().put("threadId", "thread").put("mode", "auto").put("expectedTurnId", "old-turn")) { replies.add(it) }
                }
                SystemClock.sleep(1_100); protocol.settle()
                check(replies.last().optBoolean("unknown"))
                val reserved = decodeLast()
                notFound(operation)
                main { client.retryPending(operation) { replies.add(it) } }
                sameIntent(reserved, decodeLast())
                check(decodeLast().getString("id") == reserved.getString("id"))
                reply(JSONObject().put("id", operation).put("ok", true).put("accepted", true)); test.waitForIdleSync()
                check(client.draft("thread") == "keep this draft")
                check(client.attachments("thread").length() == 1 && client.uncertain("thread").isEmpty())
            }
            main {
                client.saveAttachments("thread", org.json.JSONArray().put(JSONObject().put("attachmentId", "sent")).put(JSONObject().put("attachmentId", "added-later")))
                client.clearSentAttachments("thread", org.json.JSONArray().put("sent"))
            }
            check(client.attachments("thread").getJSONObject(0).getString("attachmentId") == "added-later")
            // New sessions are durable mutations for every provider, and timeouts must not retransmit them.
            for (source in listOf("codex", "claude")) {
                val beforeFrames = transport.frames.size
                main {
                    client.provider = source
                    operation = client.request("new", JSONObject().put("provider", source).put("cwd", "/fixture/new").put("draftId", UUID.randomUUID().toString()).put("text", "original first message")) { replies.add(it) }
                }
                SystemClock.sleep(1_100); protocol.settle()
                check(replies.last().optBoolean("unknown"))
                val newPackets = transport.frames.drop(beforeFrames).map { it.getString("packet") }.toSet()
                check(rawRequests().count { it.optString("id").isNotBlank() &&
                    it.optJSONObject("body")?.optString("operationId") == operation } == 1) { "New session automatically retransmitted" }
                check(newPackets.isNotEmpty())
                check(client.uncertain("", source).single().getString("id") == operation)
                val originalNew = decodeLast("new")
                main {
                    client.close(); client = SessionClient(context, transport, 1_000); client.onEvent = { events.add(it) }; client.connectionChanged(true)
                }
                main { check(client.uncertain("", source).single().getString("id") == operation) }
                notFound(operation)
                main { client.retryPending(operation) { replies.add(it) } }
                val retryNew = decodeLast("new")
                sameIntent(originalNew, retryNew)
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
                    main {
                        check(client.saveCreationDraft(draft)); check(client.saveAttachments(draft.attachmentScope, entries, "claude"))
                        operation = client.request("new", draft.request(UUID.randomUUID().toString(), org.json.JSONArray().put(sentID))) { replies.add(it) }
                    }
                    SystemClock.sleep(1_100); protocol.settle()
                    check(client.uncertain("", "claude").any { it.optString("id") == operation })
                    main {
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
                        main { check(client.saveCreationDraft(draft)); check(client.agent.abandon(operation)) }
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
            main { client.provider = "codex" }
            protocol.negotiate = false // Media uploads remain independent of session negotiation.
            // Binary upload with encrypted metadata, pinned TLS, and draft/project/provider identity.
            val uploadDraft = io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft(UUID.randomUUID().toString(), "claude", "/fixture/upload")
            val uploadBytes = ByteArray(19_000) { (it % 251).toByte() }
            val uploadFile = java.io.File(draftRoot, "probe-" + UUID.randomUUID()).apply { writeBytes(uploadBytes) }
            val uploadServer = BinaryLoopbackFixture(uploadBytes)
            val uploadCapability = uploadServer.profile(kind = "upload", mime = "text/plain")
            transport.binaryHost = uploadServer.host
            val uploadedDone = java.util.concurrent.CountDownLatch(1)
            val uploadResult = java.util.concurrent.atomic.AtomicReference<JSONObject>()
            main {
                client.close(); client = SessionClient(context, transport, 5000); client.onEvent = { events.add(it) }; client.connectionChanged(true)
                check(client.provider == "codex")
            }
            main {
                client.provider = uploadDraft.provider
                transport.onCompletePacket = {
                    val request = decodeLast()
                    if (request.optString("op") == "fileCancel") {
                        check(request.getString("ticket") == uploadCapability.getString("id"))
                        reply(JSONObject().put("id", request.getString("id")).put("ok", true))
                    } else {
                        check(request.optString("draftId") == uploadDraft.id && request.optString("cwd") == uploadDraft.cwd && request.optString("provider") == "claude")
                        check(!request.has("threadId")) // Transport metadata may include the current view version; draft scope is independent.
                        when (request.optString("op")) {
                            "newAttachmentStart" -> {
                                check(request.optInt("size") == uploadBytes.size && request.optInt("binaryVersion") == 1)
                                check(!request.has("uploadVersion") && !request.has("uploadFragmentChars"))
                            }
                            "newAttachmentChunk" -> error("Retired text chunks must never be emitted")
                            "newAttachmentComplete" -> {
                                check(uploadServer.uploaded.get()?.contentEquals(uploadBytes) == true)
                                val digest = java.security.MessageDigest.getInstance("SHA-256").digest(uploadBytes).joinToString("") { "%02x".format(it) }
                                check(request.getString("sha256") == digest)
                                check(request.getString("binaryTicket") == uploadCapability.getString("id"))
                            }
                            else -> error("Unexpected upload operation")
                        }
                        reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("attachmentId", request.getString("attachmentId")).apply {
                            if (request.optString("op") == "newAttachmentStart") put("binary", uploadCapability)
                        })
                    }
                }
                io.github.junweiup.vibepier.remote.features.sessions.CodexFileUpload.upload(context.resources, client, uploadDraft.attachmentScope,
                    uploadFile, "example.txt", "text/plain", {}, creation = uploadDraft) { uploadResult.set(it); uploadedDone.countDown() }
            }
            try {
                check(uploadedDone.await(8, java.util.concurrent.TimeUnit.SECONDS)); check(uploadResult.get().optBoolean("ok"))
                check(uploadServer.uploaded.get()?.contentEquals(uploadBytes) == true)
            } finally {
                main {
                    transport.onCompletePacket = null; client.provider = "codex"; client.close(); client = SessionClient(context, transport, 1_000)
                    client.onEvent = { events.add(it) }; client.connectionChanged(true)
                }
                uploadServer.close(); transport.binaryHost = null; uploadFile.delete()
            }
            protocol.negotiate = true
            main { client.refreshProviderAccess() }
            val optionPackets = transport.frames.map { it.getString("packet") }.distinct().size
            main {
                val id = client.request("newOptions", uploadDraft.value()) { error("Dismissed options must not call back") }
                client.cancelCreationOptions(id)
            }
            SystemClock.sleep(1_200); protocol.settle()
            check(transport.frames.map { it.getString("packet") }.distinct().size in optionPackets..optionPackets + 1) { "Dismissed creation options retried" }
            // Independent file reads coalesce; current session options must obtain fresh profile-2 state.
            val coalescedResults = java.util.concurrent.atomic.AtomicInteger()
            main {
                val before = client.networkReads
                val fields = JSONObject().put("threadId", "cache-thread").put("path", "fixture.md")
                val first = client.request("readMarkdownFile", fields) { check(it.optBoolean("ok")); coalescedResults.incrementAndGet() }
                val second = client.request("readMarkdownFile", fields) { check(it.optBoolean("ok")); coalescedResults.incrementAndGet() }
                check(first == second && client.networkReads == before + 1 && client.coalescedReads > 0)
                reply(JSONObject().put("id", first).put("ok", true).put("models", org.json.JSONArray().put(JSONObject().put("id", "cached-model"))))
            }
            test.waitForIdleSync()
            main {
                check(coalescedResults.get() == 2)
            }
            protocol.discover("codex", "cache-thread")
            val beforeOptions = rawRequests().count { it.optJSONObject("body")?.optString("method") == "session.snapshot" }
            repeat(20) { iteration ->
                var received = false
                main { client.request("composerOptions", JSONObject().put("threadId", "cache-thread").put("cacheVersion", "models-v1")) {
                    check(it.getJSONArray("models").getJSONObject(0).optString("id") == "current-model-$iteration")
                    received = true
                } }
                val request = decodeLast("composerOptions")
                reply(JSONObject().put("id", request.getString("id")).put("ok", true)
                    .put("models", org.json.JSONArray().put(JSONObject().put("id", "current-model-$iteration"))))
                test.waitForIdleSync(); check(received)
            }
            check(rawRequests().count { it.optJSONObject("body")?.optString("method") == "session.snapshot" } == beforeOptions + 20)
            SessionProbeImageCache.run(test, client, ::main, { decodeLast("image") }, ::reply)
            protocol.negotiate = true
            main { client.refreshProviderAccess() }
            protocol.discover("codex", "thread")
            // Exercise uncertain approval state with real views and the isolated fake transport.
            val activity = test.startActivitySync(android.content.Intent(test.targetContext, MainActivity::class.java)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "offline"))
            lateinit var panel: ConversationPanel
            lateinit var dialog: android.app.AlertDialog
            fun field(value: Any, name: String): Any? = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
            fun views(root: android.view.View): List<android.view.View> = listOf(root) + if (root is android.view.ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
            try {
                main {
                    panel = ConversationPanel(activity, client, {})
                    activity.setContentView(panel)
                    reply(JSONObject().put("id", decodeLast().getString("id")).put("ok", true).put("threads", org.json.JSONArray()).put("nextOffset", -1))
                }
                test.waitForIdleSync()
                val initialList = field(panel, "list")
                main {
                    panel.javaClass.getDeclaredMethod("loadList", Boolean::class.javaPrimitiveType, Boolean::class.javaPrimitiveType).apply { isAccessible = true }.invoke(panel, false, false)
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }.invoke(panel, "thread", "Isolated approval test")
                    reply(JSONObject().put("id", decodeLast().getString("id")).put("ok", true).put("opening", true))
                }
                test.waitForIdleSync()
                main {
                    check(field(panel, "opening") == true && field(panel, "ready") == false)
                    (field(panel, "openRecovery") as Runnable).run()
                    val sync = decodeLast(); check(sync.getString("op") == "sync")
                    reply(ConversationReviewFixtures.conversation("approval").put("threadId", "thread").put("viewVersion", client.viewVersion).put("id", sync.getString("id")))
                }
                test.waitForIdleSync()
                val drawerParams = JSONObject().put("search", "").put("offset", 0).put("limit", 8)
                main {
                    check(field(panel, "opening") == false && field(panel, "ready") == true)
                    // The opening placeholder became an active native snapshot. That status/title
                    // transition correctly invalidates drawer rows, independently of persisted app data.
                    check(!client.freshList("list", drawerParams))
                    val readsBeforeRefresh = pageReads()
                    panel.back()
                    check(pageReads() == readsBeforeRefresh + 1) { "Invalidated drawer must issue exactly one refresh" }
                    check(field(panel, "list") === initialList)
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    val refresh = decodeLast("list")
                    check(refresh.getString("_method") == "session.list")
                    reply(JSONObject().put("id", refresh.getString("id")).put("ok", true)
                        .put("threads", org.json.JSONArray()).put("nextOffset", -1))
                }
                main {
                    check(client.freshList("list", drawerParams))
                    panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }
                        .invoke(panel, "thread", "Unchanged native session")
                    val open = decodeLast("open")
                    reply(protocol.page("codex", "thread").put("id", open.getString("id")).put("ok", true))
                }
                main {
                    check(field(panel, "opening") == false && field(panel, "ready") == true)
                    check(client.freshList("list", drawerParams))
                    val readsBeforeReturn = pageReads()
                    panel.back()
                    check(pageReads() == readsBeforeReturn) { "Fresh drawer read unexpectedly: before=$readsBeforeReturn after=${pageReads()}" } // Fresh list reuse sends no read request.
                    check(field(panel, "list") === initialList)
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    check(decodeLast().getString("op") == "close") // Fresh rows are reused; closing a subscription remains necessary.
                    panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }.invoke(panel, "thread", "Timeout test")
                    (field(panel, "openDeadline") as Runnable).run()
                    check(field(panel, "opening") == false && field(panel, "ready") == false)
                    check((field(panel, "status") as CanvasLabel).text.toString().contains(context.getString(R.string.session_could_not_open_session_tap_refresh_to_retry)))
                    val pending = field(client, "pending") as Map<*, *>
                    check(pending.values.none { field(it!!, "json").let { j -> (j as JSONObject).optString("op") == "open" || j.optJSONObject("body")?.optString("method") == "session.open" } })
                    panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }.invoke(panel, "thread", "Isolated approval test")
                    val state = ConversationReviewFixtures.conversation("approval").put("threadId", "thread").put("viewVersion", client.viewVersion).put("revision", 20)
                    emit(state)
                }
                main {
                    client.connectionChanged(false); panel.connectionChanged()
                    check(field(panel, "ready") == false)
                }
                main { client.connectionChanged(true); panel.connectionChanged() }
                main {
                    val reopen = decodeLast("open")
                    check(reopen.getString("_method") == "session.open" && reopen.getString("threadId") == "thread")
                    reply(protocol.page("codex", "thread").put("id", reopen.getString("id")).put("ok", true))
                }
                var retainedPage: Any? = null
                var retainedTimeline: Any? = null
                main {
                    check(field(panel, "ready") == true)
                    retainedPage = field(panel, "page"); retainedTimeline = field(panel, "timeline")
                    (field(panel, "editor") as android.widget.EditText).setText("background draft")
                    panel.suspend()
                    client.connectionChanged(false); panel.connectionChanged()
                }
                val backgroundReads = pageReads()
                main { client.connectionChanged(true); panel.connectionChanged() }
                main {
                    check(pageReads() == backgroundReads) // Discovery is allowed; no background page reads.
                    check(field(panel, "page") === retainedPage && field(panel, "timeline") === retainedTimeline)
                    check((field(panel, "editor") as android.widget.EditText).text.toString() == "background draft")
                    panel.resume()
                }
                // resume refreshes provider/profile authority; its reply triggers the current open.
                // Drain that handshake before selecting the request to answer.
                main {
                    val resumed = decodeLast("open"); check(resumed.getString("_method") == "session.open")
                    reply(protocol.page("codex", "thread").put("id", resumed.getString("id")).put("ok", true))
                }
                main {
                    check(field(panel, "ready") == true) { "Foreground resume did not apply the post-discovery session.open snapshot" }
                    check(field(panel, "timeline") === retainedTimeline)
                    val editor = field(panel, "editor") as android.widget.EditText
                    editor.setText("draft preserved while stopping")
                    val stop = field(panel, "stopButton") as android.view.View
                    check(stop.isShown && stop.isEnabled); stop.performClick()
                }
                main {
                    val request = decodeLast()
                    check(request.getString("op") == "interrupt" && request.getString("expectedTurnId") == "fixture-turn")
                    operation = request.getString("id")
                    reply(JSONObject().put("id", operation).put("ok", true).put("accepted", true))
                }
                test.waitForIdleSync()
                main {
                    check((field(panel, "editor") as android.widget.EditText).text.toString() == "draft preserved while stopping")
                    val state = ConversationReviewFixtures.conversation("approval").put("threadId", "thread").put("viewVersion", client.viewVersion).put("revision", 20)
                    panel.javaClass.getDeclaredMethod("showApproval", JSONObject::class.java).apply { isAccessible = true }.invoke(panel, protocol.enrich(state).getJSONArray("approvals").getJSONObject(0))
                    dialog = field(panel, "approvalDialog") as android.app.AlertDialog
                    views(dialog.window!!.decorView).first { it.contentDescription?.toString() == context.getString(R.string.session_deny) }.performClick()
                }
                SystemClock.sleep(1_100); protocol.settle()
                main {
                    check(!views(dialog.window!!.decorView).first { it.contentDescription?.toString() == context.getString(R.string.session_allow_once) }.isEnabled)
                    check(views(dialog.window!!.decorView).any { it.contentDescription?.toString() == context.getString(R.string.session_check_result) })
                    operation = client.uncertain("thread").first { it.optString("op") == "approve" }.getString("id")
                }
                val approvalSends = rawRequests().count { it.optJSONObject("body")?.optString("method") == "approval.resolve" }
                check(approvalSends == 1)
                protocol.approvalsSupported = false
                main { client.refreshProviderAccess() }
                main {
                    check(!client.agentActionSupported("approvals"))
                    check(client.uncertain("thread").any { it.optString("id") == operation })
                    val checkResult = views(dialog.window!!.decorView).filterIsInstance<CanvasLabel>().single {
                        it.text.toString() == context.getString(R.string.session_check_result)
                    }
                    check(checkResult.isEnabled) { "Unknown approval must remain queryable after write capability is revoked" }
                    check(checkResult.performClick())
                }
                val lookup = decodeLast("receipt")
                check(lookup.getString("_method") == "operation.get" && lookup.getString("operation") == operation)
                check(rawRequests().count { it.optJSONObject("body")?.optString("method") == "approval.resolve" } == approvalSends)
                reply(JSONObject().put("id", lookup.getString("id")).put("ok", true)
                    .put("operation", JSONObject().put("operationId", operation).put("status", "notFound")))
                protocol.settle()
                main {
                    val retryChoice = views(dialog.window!!.decorView).filterIsInstance<CanvasLabel>().single {
                        it.text.toString() == context.getString(R.string.session_retry_original_choice)
                    }
                    check(!retryChoice.isEnabled) { "Explicit approval retry still requires write capability" }
                    check(rawRequests().count { it.optJSONObject("body")?.optString("method") == "approval.resolve" } == approvalSends)
                }
                protocol.approvalsSupported = true
                main { client.refreshProviderAccess() }
                main {
                    val reopened = decodeLast("open")
                    reply(protocol.page("codex", "thread").put("id", reopened.getString("id")).put("ok", true))
                }
                reply(JSONObject().put("id", operation).put("ok", true).put("submitted", true)); test.waitForIdleSync()
                main { check(!dialog.isShowing) }
                lateinit var detail: JSONObject
                main {
                    val state = ConversationReviewFixtures.conversation("approval").put("threadId", "thread").put("viewVersion", client.viewVersion).put("revision", 21)
                    detail = state.getJSONArray("approvals").getJSONObject(0).put("fingerprint", "next-approval")
                    val summary = JSONObject(detail.toString()).put("detailsOnDemand", true); summary.remove("details")
                    state.put("approvals", org.json.JSONArray().put(summary)); emit(state)
                    panel.javaClass.getDeclaredMethod("showApproval", JSONObject::class.java).apply { isAccessible = true }.invoke(panel, summary)
                }
                main {
                    operation = decodeLast("approvalDetails").getString("id")
                    val state = JSONObject((field(panel, "page") as JSONObject).toString())
                    emit(state.put("revision", 22).put("approvals", org.json.JSONArray()))
                }
                // Deliberately deliver the old detail response after its approval disappeared.
                protocol.reply(JSONObject().put("id", operation).put("ok", true).put("approval", detail), allowObsoleteRead = true)
                test.waitForIdleSync()
                main {
                    check(field(panel, "approvalDialog") == null)
                    check((field(panel, "notice") as CanvasLabel).text.toString().contains(context.getString(R.string.session_the_approval_changed_or_expired_refresh_it)))
                    val summary = JSONObject(detail.toString()).put("detailsOnDemand", true); summary.remove("details")
                    val current = JSONObject((field(panel, "page") as JSONObject).toString()).put("revision", 23)
                        .put("approvals", org.json.JSONArray().put(summary))
                    emit(current)
                    panel.javaClass.getDeclaredMethod("showApproval", JSONObject::class.java).apply { isAccessible = true }.invoke(panel, summary)
                }
                main { operation = decodeLast("approvalDetails").getString("id") }
                reply(JSONObject().put("id", operation).put("ok", false).put("error", "完整详情读取失败")); test.waitForIdleSync()
                main {
                    check(field(panel, "approvalDialog") == null)
                    check((field(panel, "notice") as CanvasLabel).text.toString().contains("读取失败"))
                    panel.close()
                    // The short timeout scenarios above are complete. Native layout/Keystore
                    // work below must not race that deliberately shortened request deadline.
                    client.close()
                    client = SessionClient(context, transport, 5_000).apply { connectionChanged(true) }
                }
                main {
                    val count = transport.frames.size
                    client.invalidateLists() // Expired/invalidated lists still refresh while retaining visible cache.
                    panel = ConversationPanel(activity, client, {})
                    activity.setContentView(panel)
                    check(decodeLast().getString("op") == "list" && transport.frames.size > count) // Cache is visible while an immediate refresh is pending.
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                }
                // The new panel also discovers host capabilities. Let that finish before issuing
                // the open/write whose preparation must remain in one profile/view generation.
                main {
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
                    emit(preview)
                    val editor = field(panel, "editor") as android.widget.EditText
                    editor.setText("Queued requirement")
                    (field(panel, "sendButton") as android.view.View).performClick()
                }
                main {
                    val send = decodeLast(); check(send.optString("op") == "send")
                    val queued = org.json.JSONArray().put(JSONObject().put("id", send.getString("id")).put("text", "Queued requirement").put("status", "queued").put("canSteer", true).put("canDelete", true))
                    reply(JSONObject().put("id", send.getString("id")).put("ok", true).put("accepted", true).put("queued", true).put("queuedMessages", queued))
                }
                test.waitForIdleSync()
                main {
                    check((field(panel, "editor") as android.widget.EditText).text.isEmpty())
                    val queued = (field(panel, "page") as JSONObject).getJSONArray("queuedMessages")
                    val id = queued.getJSONObject(0).getString("id")
                    check((field(panel, "outbox") as Map<*, *>).isEmpty())
                    (field(panel, "editor") as android.widget.EditText).setText("Keep separate draft")
                    views(panel).first { it.contentDescription?.toString() == context.getString(R.string.session_steer) }.performClick()
                }
                main {
                    val queued = (field(panel, "page") as JSONObject).getJSONArray("queuedMessages")
                    val id = queued.getJSONObject(0).getString("id")
                    val steer = decodeLast(); check(steer.optString("op") == "queueSteer" && steer.optString("messageId") == id)
                    check(client.uncertain("thread").any { it.optString("id") == steer.getString("id") })
                    // An unconfirmed operation disables duplicate clicks until its receipt settles.
                    check(!views(panel).first { it.contentDescription?.toString() == context.getString(R.string.session_steer) }.isEnabled)
                    reply(JSONObject().put("id", steer.getString("id")).put("ok", true).put("accepted", true))
                }
                test.waitForIdleSync()
                val steerSync = protocol.awaitPageRead("session.snapshot", "codex:thread")
                main {
                    // The confirmed queue.steer receipt has no queuedMessages. Production must resync.
                    val sync = steerSync
                    check(sync.getString("_method") == "session.snapshot")
                    val native = protocol.page("codex", "thread")
                    val pendingQueue = native.getJSONArray("queuedMessages").getJSONObject(0)
                    check(pendingQueue.optString("status") == "pending" && !pendingQueue.getBoolean("canSteer") && !pendingQueue.getBoolean("canDelete"))
                    reply(native.put("id", sync.getString("id")).put("ok", true))
                }
                main {
                    val rendered = (field(panel, "page") as JSONObject).getJSONArray("queuedMessages").getJSONObject(0)
                    check(rendered.optString("status") == "pending" && !rendered.getBoolean("canSteer") && !rendered.getBoolean("canDelete"))
                    expect(!views(panel).first { it.contentDescription?.toString() == context.getString(R.string.session_steer) }.isEnabled,
                        "Fresh native pending queue row is rendered, but queueSteer is still enabled despite canSteer=false")
                    expect(!views(panel).first { it.contentDescription?.toString() == context.getString(R.string.delete) }.isEnabled,
                        "Fresh native pending queue row is rendered, but queueDelete is still enabled despite canDelete=false")
                    check((field(panel, "editor") as android.widget.EditText).text.toString() == "Keep separate draft")
                }
                main {
                    check((field(panel, "editor") as android.widget.EditText).text.toString() == "Keep separate draft")
                    emit(JSONObject().put("event", "queue").put("threadId", "thread").put("viewVersion", client.viewVersion).put("queuedMessages", org.json.JSONArray()))
                    check(views(panel).none { it.contentDescription?.toString() == context.getString(R.string.session_steer) })
                    val queue = org.json.JSONArray().put(JSONObject().put("id", "delete-queue").put("text", "Delete requirement").put("status", "queued").put("canSteer", true).put("canDelete", true))
                    emit(JSONObject().put("event", "queue").put("threadId", "thread").put("viewVersion", client.viewVersion).put("queuedMessages", queue))
                    views(panel).first { it.contentDescription?.toString() == context.getString(R.string.delete) }.performClick()
                }
                main {
                    val deleted = decodeLast(); check(deleted.optString("op") == "queueDelete" && deleted.optString("messageId") == "delete-queue")
                    reply(JSONObject().put("id", deleted.getString("id")).put("ok", true).put("accepted", true))
                }
                test.waitForIdleSync()
                val deleteSync = protocol.awaitPageRead("session.snapshot", "codex:thread")
                main {
                    val sync = deleteSync
                    check(sync.getString("_method") == "session.snapshot")
                    check(sync.getString("id") != steerSync.getString("id"))
                    val native = protocol.page("codex", "thread")
                    check(native.getJSONArray("queuedMessages").length() == 0)
                    reply(native.put("id", sync.getString("id")).put("ok", true))
                }
                main {
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
                main {
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
                main {
                    val request = decodeLast("message"); check(request.getString("messageId") == "step0" && request.getInt("offset") == 0 && request.optString("_method") == "session.items")
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("text", "First output").put("nextOffset", 12))
                }
                test.waitForIdleSync()
                main {
                    check(views(panel).any { (it as? CanvasLabel)?.text.toString() == "First output" })
                    check(decodeLast("message").getInt("offset") == 0) // Long output is only continued on tap.
                    views(panel).first { it.contentDescription?.toString() == context.getString(R.string.continue_output) }.performClick()
                    val request = decodeLast("message"); check(request.getInt("offset") == 12)
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("text", " + second output").put("nextOffset", -1))
                }
                test.waitForIdleSync()
                main {
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
                    emit(next)
                }
                test.waitForIdleSync()
                main {
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
                main {
                    val content = views(panel).filterIsInstance<CanvasLabel>().map { it.text.toString() }
                    val expected = listOf("Older paragraph 0", "older command 1", "Older paragraph 2", "older command 3", "Before command", "printf first", "First output + second output", "After command, before file", "later.swift", "After file")
                    check(expected.map { content.indexOf(it) }.zipWithNext().all { (a, b) -> a >= 0 && b > a }) { "Prepend reordered desktop content: $content" }
                    check(decodeLast("message").getInt("offset") == 12) // Reading earlier titles did not download tool bodies.
                    check((field(panel, "auxiliaryDialogs") as Collection<*>).isEmpty())
                    val live = JSONObject((field(panel, "page") as JSONObject).toString()).put("event", "snapshot").put("revision", 32).put("cacheVersion", "same-content")
                    emit(live)
                    panel.suspend(); panel.resume()
                }
                main {
                    val resumed = decodeLast("open")
                    check(resumed.optString("_method") == "session.open" && resumed.optString("threadId") == "thread")
                    check((field(panel, "page") as JSONObject).optString("cacheVersion") == "same-content")
                    val short = JSONObject((field(panel, "page") as JSONObject).toString()).put("id", resumed.getString("id")).put("viewVersion", client.viewVersion).put("unchanged", true)
                    short.remove("messages"); reply(short)
                }
                test.waitForIdleSync()
                main {
                    check(field(panel, "ready") == true && (field(panel, "page") as JSONObject).getJSONArray("messages").length() == 1)
                    check(views(panel).any { (it as? CanvasLabel)?.text.toString() == "First output + second output" })
                }
                protocol.unsupportedActions = setOf("send", "settings", "modelSelection", "permissionMode", "attachments")
                main { client.refreshProviderAccess() }
                main {
                    panel.suspend(); panel.resume()
                }
                main {
                    val resumed = decodeLast("open")
                    val short = JSONObject((field(panel, "page") as JSONObject).toString()).put("id", resumed.getString("id")).put("viewVersion", client.viewVersion).put("unchanged", true).put("canSend", false)
                    short.remove("messages"); reply(short)
                }
                test.waitForIdleSync()
                main {
                    check(field(panel, "ready") == true && (field(panel, "page") as JSONObject).has("messages")) // Keep cached content readable when the live peer revokes sending.
                    check(!(field(panel, "page") as JSONObject).optBoolean("canSend"))
                    check(!(field(panel, "sendButton") as android.view.View).isEnabled)
                    // Revoking send does not revoke a separately verified active-turn interrupt capability.
                    check((field(panel, "stopButton") as android.view.View).isEnabled)
                    val readOnlyControls = field(panel, "composerControls") as ComposerControls
                    check(!readOnlyControls.add.isEnabled)
                    // Selectors remain inspectable; supported-action authority, not cached canSend, gates effects.
                    check(readOnlyControls.mode.isEnabled && readOnlyControls.model.isEnabled)
                    check(!client.agentActionSupported("settings") && !client.agentActionSupported("send"))
                    check(client.agentActionSupported("interrupt"))
                    panel.close()
                    client.listMode = "projects"
                    panel = ConversationPanel(activity, client, {}); activity.setContentView(panel)
                }
                // Constructor discovery may replace its initial list read. Answer the current first
                // page only after that handshake settles, before exercising offset-8 pagination.
                main {
                    val request = decodeLast("projects")
                    check(request.getString("op") == "projects" && request.getInt("offset") == 0 && request.getInt("limit") == 8)
                    val projects = org.json.JSONArray()
                    for (i in 0..7) projects.put(JSONObject().put("cwd", "/p/$i").put("project", "Project$i").put("count", 1))
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("projects", projects).put("nextOffset", 8))
                }
                test.waitForIdleSync()
                main {
                    check(views(panel).none { it.contentDescription?.toString() == "加载更多项目" })
                    check(field(panel, "listedCount") == 8 && field(panel, "nextOffset") == 8 && field(panel, "loadingList") == false) {
                        "First project page must settle before pagination: rows=${field(panel, "listedCount")}, next=${field(panel, "nextOffset")}, loading=${field(panel, "loadingList")}"
                    }
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
                main {
                    check(field(panel, "listedCount") == 10)
                    check(views(panel).any { it.contentDescription?.toString()?.startsWith(context.getString(R.string.session_open_project_count, "Project0", 1)) == true })
                    check(views(panel).any { it.contentDescription?.toString()?.startsWith(context.getString(R.string.session_open_project_count, "Project9", 1)) == true })
                    val reads = pageReads()
                    panel.suspend(); panel.resume()
                    check(pageReads() == reads) // Fresh rows render without an immediate page read.
                }
                // Profile rediscovery then invalidates authority and refreshes the complete visible window.
                main {
                    val request = decodeLast("projects")
                    check(request.getInt("offset") == 0 && request.getInt("limit") == 8)
                    val projects = org.json.JSONArray()
                    for (i in 0..7) projects.put(JSONObject().put("cwd", "/p/$i").put("project", "Project$i").put("count", 1))
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("projects", projects).put("nextOffset", 8))
                }
                main {
                    val request = decodeLast("projects")
                    check(request.getInt("offset") == 8 && request.getInt("limit") == 2)
                    val projects = org.json.JSONArray()
                    for (i in 8..9) projects.put(JSONObject().put("cwd", "/p/$i").put("project", "Project$i").put("count", 1))
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("projects", projects).put("nextOffset", -1))
                }
                main {
                    check(field(panel, "listedCount") == 10)
                    client.invalidateLists()
                    panel.suspend(); panel.resume()
                }
                main {
                    check(field(panel, "listedCount") == 10)
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    val request = decodeLast(); check(request.getString("op") == "projects" && request.getInt("offset") == 0)
                    reply(JSONObject().put("id", request.getString("id")).put("ok", false).put("error", "refresh temporarily unavailable"))
                }
                test.waitForIdleSync()
                main {
                    check(field(panel, "listedCount") == 10)
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    panel.close(); client.close() // Simulate the old process closing before constructing its replacement.
                    val restoredClient = SessionClient(context, transport, 5_000)
                    client = restoredClient
                    check(restoredClient.cachedList("projects", JSONObject().put("search", "").put("offset", 0).put("limit", 8))!!.getJSONArray("projects").length() == 10)
                    check(restoredClient.drawerState.has("scrollY"))
                    panel = ConversationPanel(activity, restoredClient, {}); activity.setContentView(panel)
                    check(field(panel, "listedCount") == 10) // A newly-created, disconnected client renders persisted cache immediately.
                    check(!(field(panel, "info") as CanvasLabel).text.toString().contains(context.getString(R.string.session_loading_2)))
                    restoredClient.connectionChanged(true); panel.connectionChanged()
                }
                main {
                    val request = decodeLast(); check(request.getString("op") == "projects" && request.getInt("offset") == 0)
                    val projects = org.json.JSONArray()
                    for (i in 0..7) projects.put(JSONObject().put("cwd", "/p/$i").put("project", "Updated$i").put("count", 2))
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("projects", projects).put("nextOffset", 8))
                    // Frame handler belongs to the restored client, whose page is still the cached 10 rows.
                }
                test.waitForIdleSync()
                main {
                    val request = decodeLast(); check(request.getString("op") == "projects" && request.getInt("offset") == 8 && request.getInt("limit") == 2)
                    val projects = org.json.JSONArray()
                    for (i in 8..9) projects.put(JSONObject().put("cwd", "/p/$i").put("project", "Updated$i").put("count", 2))
                    reply(JSONObject().put("id", request.getString("id")).put("ok", true).put("projects", projects).put("nextOffset", -1))
                }
                test.waitForIdleSync()
                main {
                    check(field(panel, "listedCount") == 10)
                    check(views(panel).any { it.contentDescription?.toString()?.startsWith(context.getString(R.string.session_open_project_count, "Updated9", 2)) == true })
                    val restoredClient = field(panel, "client") as SessionClient
                    panel.close(); restoredClient.close()
                    val persisted = SessionClient(context, transport, 1_000)
                    check(persisted.cachedPage("thread")?.has("messages") == true)
                    val cachedBody = persisted.cachedProcess("thread", "preview-reply")!!.getJSONObject("bodies").getJSONObject("step0")
                    check(cachedBody.optBoolean("loaded") && cachedBody.optString("text") == "First output + second output")
                    check(persisted.cachedProcess("thread", "preview-reply")!!.getJSONArray("rows").length() == 13)
                    persisted.close()
                }
            } finally { main { activity.finish() } }
            // Only adjacent commands/edits fold together. Expanding a group alone reads no bodies.
            val groupActivity = test.startActivitySync(android.content.Intent(test.targetContext, MainActivity::class.java).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "offline"))
            lateinit var grouped: InlineReplyProcess
            val groupState = InlineReplyProcess.State()
            val outputReads = mutableListOf<String>()
            try {
                main {
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
                main {
                    check(views(grouped).any { it.contentDescription?.toString()?.contains(context.resources.getQuantityString(R.plurals.group_commands, 2, 2)) == true })
                    check(views(grouped).any { it.contentDescription?.toString()?.contains(context.resources.getQuantityString(R.plurals.group_edits, 2, 2)) == true })
                    check(views(grouped).none { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "item-0", "")) == true })
                    check(views(grouped).any { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "item-3", "")) == true }) // A paragraph prevents merging command 3 into the previous group.
                    views(grouped).first { it.contentDescription?.toString()?.contains(context.resources.getQuantityString(R.plurals.group_commands, 2, 2)) == true }.performClick()
                }
                test.waitForIdleSync()
                main {
                    check(outputReads.isEmpty())
                    views(grouped).first { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "item-0", "")) == true }.performClick()
                }
                test.waitForIdleSync()
                main {
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
                main {
                    check(outputReads.size == 1)
                    views(grouped).first { it.contentDescription?.toString()?.startsWith(context.getString(R.string.step_description_no_status, "item-4", "")) == true }.performClick()
                }
                test.waitForIdleSync()
                main { check(outputReads == listOf("group-0", "group-4")) }
            } finally { main { groupActivity.finish() } }
            // Fixed CryptoKit fixture verifies Apple/Android nonce+ciphertext+tag interoperability.
            val data = Base64.decode("AAAAAAAAAAAAAAAAiW8MVVA97mJB4iDiIs7ARhJ61iT6zCpIh6OawvCr/2iTyw==", Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, data.copyOfRange(0,12)))
            cipher.updateAAD("vibepier-session-v1|phone|device|packet".toByteArray())
            check(String(cipher.doFinal(data.copyOfRange(12,data.size))) == "跨端加密测试")
            check(deferredAssertions.isEmpty()) { "All remaining cases executed; ${deferredAssertions.size} queue UI assertion(s) still failed" }
            return "PASS: read coalescing (2 callers / 1 RPC), 20 model-menu reads each require fresh profile-2 snapshot/items, 20 decoded pinned-HTTPS large-image cache hits / 0 RPC; version invalidation and corrupt-hash cache rejection, content-version invalidation and unchanged confirmations with fresh capability gating, durable conversation/output/earlier-header restore, adjacent command/file folds preserve paragraphs and load only a clicked item; durable app configuration/icon cache round trip, corrupt cache recovery, incomplete icon snapshot rejected, endpoint-scoped cache; Codex native queued send, steer with original message ID, unconfirmed-operation gating, queue effect receipts followed by native resync and pending-row button gating, desktop queue event removal, delete and draft preservation; persisted offline cache restored in new client, fresh foreground cache avoids reads, invalidated cache refreshes without loading screen, failed refresh keeps rows, full visible window refreshed across pages, project first-page limit and next-offset append, background retains timeline and draft, no background reload, foreground resubscribes without page recreation, desktop interleaving without a dialog, metadata-only ordered pagination, command outputs fetched only on expansion, long outputs paged on explicit demand, collapse/reopen retains output, missing opening push recovered by sync, bounded opening timeout, obsolete reads canceled, cached drawer restored while list refreshes, automatic scroll pagination without duplicate requests, conversation top gesture/accessibility loads history without a button and preserves identities, automatic subscription recovery after reconnect, KeyStore pairing, timeout reservation, late receipt, scoped draft reconciliation, same-operation retry, edited draft preservation, CryptoKit interoperability, visible stop clicked with draft and expected turn verified, settings/interrupt same-ID unknown recovery and draft preservation, sent attachment subset cleanup, uncertain approval gating, capability-revoked read-only operation.get without another approval.resolve, write-gated explicit retry, and late approval dismissal, expired approval details and load failure blocked\n"
        } catch (failure: Throwable) {
            deferredAssertions.forEach(failure::addSuppressed)
            throw failure
        } finally {
            main { client.close() }
            DeviceKeys(context).clear()
            io.github.junweiup.vibepier.remote.core.security.PrivatePreferences.open(context, "sessions").edit().clear().commit()
        }
    }
}
