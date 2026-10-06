package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionAgentProtocol
import io.github.junweiup.vibepier.remote.core.session.SessionV1Contract
import io.github.junweiup.vibepier.remote.fixtures.ConversationReviewFixtures
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** Wire-format fixture adapter. Only synthetic host READS auto-reply; mutations always await the test's evidence. */
internal class SessionProbeProtocolFixture(
    private val test: Instrumentation,
    private val client: () -> SessionClient,
    private val raw: () -> List<JSONObject>,
    private val send: (JSONObject) -> Unit,
) {
    private val answered = mutableSetOf<String>()
    private val pages = mutableMapOf<String, JSONObject>()
    private val created = mutableMapOf<String, JSONObject>()
    var negotiate = true
    var approvalsSupported = true
    var unsupportedActions: Set<String> = emptySet()
    val callbackFailures = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
    fun main(block: () -> Unit) {
        var failure: Throwable? = null
        test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
        failure?.let { throw it }
        callbackFailures.poll()?.let { throw it }
    }
    fun fence() {
        val executor = client().javaClass.getDeclaredField("transmission").apply { isAccessible = true }.get(client()) as java.util.concurrent.ExecutorService
        if (!executor.isShutdown) executor.submit {}.get(3, TimeUnit.SECONDS)
    }
    fun actions() = JSONObject().apply {
        SessionV1Contract.capabilityKeys.forEach { key ->
            val supported = key !in unsupportedActions && (key != "approvals" || approvalsSupported)
            put(key, JSONObject().put("supported", supported).put("available", supported).put("reason", if (supported) "available" else "unsupported"))
        }
    }
    fun declaration(source: String) = JSONObject().put("version", 1).put("provider", source).put("adapterId", source)
        .put("revision", "fixture-capabilities").put("actions", actions())
    fun row(source: String, thread: String) = JSONObject().put("adapterId", source).put("nativeThreadId", thread)
        .put("sessionRef", "$source:$thread").put("ownershipEpoch", "fixture-owner").put("capabilityRevision", "fixture-capabilities")
    private fun host(request: JSONObject): JSONObject {
        val value = JSONObject().put("id", request.getString("id")).put("ok", true)
        if (!negotiate) return value.put("ok", false).put("code", "fixture_legacy_read_only")
        val adapters = JSONArray(listOf("codex", "claude").map { source -> JSONObject().put("id", source).put("provider", source)
            .put("default", true).put("backendKinds", JSONArray().put("desktopAttached")).put("actions", actions()) })
        return value.put("providerAccess", io.github.junweiup.vibepier.remote.core.session.SessionProviderAccess(0, setOf("codex", "claude")).json())
            .put("agentCapabilities", JSONObject().put("version", 1).put("revision", "fixture-host").put("adapters", adapters))
            .put("agentProfiles", JSONObject().put("versions", JSONArray().put(2)).put("minimumClientVersion", 2)
                .put("methods", JSONArray(SessionAgentProtocol.Method.entries.map { it.wire })))
    }
    fun page(source: String, thread: String): JSONObject = JSONObject(pages["$source:$thread"]?.toString()
        ?: ConversationReviewFixtures.conversation("approval").put("threadId", thread).put("status", "idle").toString())
        .put("provider", source).put("contentState", "complete").put("agentCapabilities", declaration(source)).let(::enrich)
    fun enrich(value: JSONObject): JSONObject {
        value.optJSONArray("approvals")?.let { rows ->
            for (i in 0 until rows.length()) rows.getJSONObject(i).apply {
                if (!has("revision")) put("revision", "fixture-approval-revision")
                if (!has("allowedDecisions")) put("allowedDecisions", JSONArray(listOf("allow", "deny")))
            }
        }
        return value
    }
    fun remember(value: JSONObject) {
        enrich(value)
        if (value.has("threadId") && value.has("messages")) pages["${value.optString("provider", client().provider)}:${value.getString("threadId")}"] = JSONObject(value.toString())
        if (value.optString("event") == "queue") {
            val key = "${value.optString("provider", client().provider)}:${value.getString("threadId")}"
            pages[key]?.put("queuedMessages", value.getJSONArray("queuedMessages"))
        }
    }
    private fun read(request: JSONObject, result: JSONObject): JSONObject {
        val id = request.getString("id")
        return JSONObject().put("id", id).put("ok", true).put("body", JSONObject().put("agentProtocol", 2).put("requestId", id).put("result", result))
    }
    private fun snapshot(request: JSONObject, value: JSONObject): JSONObject {
        val projected = project(request)
        val source = projected.getString("provider"); val thread = projected.getString("threadId")
        val next = JSONObject(value.toString()).put("provider", source).put("threadId", thread)
            .put("contentState", if (value.opt("opening") == true) "partial" else "complete").put("agentCapabilities", declaration(source))
        remember(next)
        val result = JSONObject().put("session", row(source, thread)).put("snapshot", next)
            .put("streamEpoch", "fixture-stream").put("throughSequence", 0)
        if (next.optString("contentState") == "complete") result.put("controlLease", "fixture-lease")
        return read(request, result)
    }
    private fun options(request: JSONObject): JSONObject {
        val body = request.getJSONObject("body"); val target = body.getJSONObject("target"); val params = body.getJSONObject("params")
        val source = target.getString("adapterId"); val draft = params.getString("draftId")
        val options = ConversationReviewFixtures.reply("newOptions", JSONObject(), "approval")
            .put("draftId", draft).put("agentCapabilities", declaration(source))
        options.put("models", JSONArray().put(JSONObject().put("id", "sonnet").put("efforts", JSONArray(listOf("high", "medium"))))
            .put(JSONObject().put("id", "gpt-6.1-sol").put("efforts", JSONArray(listOf("high", "medium")))))
        options.getJSONArray("permissionModes").put(JSONObject().put("id", "plan"))
        val creationTarget = JSONObject().put("adapterId", source).put("workspaceRef", params.getString("workspaceRef"))
            .put("draftId", draft).put("optionsRevision", "fixture-options")
        return read(request, JSONObject().put("options", options).put("creationLease", JSONObject().put("target", creationTarget).put("controlLease", "fixture-create-lease")))
    }
    /** Drain asynchronous preparation without running a nested Android main loop. */
    fun settle() {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper())
        repeat(16) {
            fence(); test.waitForIdleSync(); fence()
            val outgoing = raw()
            var count = 0
            main {
                @Suppress("UNCHECKED_CAST")
                val preserved = client().javaClass.getDeclaredField("preservedAgentReads").apply { isAccessible = true }.get(client()) as Set<String>
                outgoing.forEach { request ->
                    val id = request.getString("id")
                    if (id in answered) return@forEach
                    val body = request.optJSONObject("body")
                    val method = body?.optString("method")
                    val response = when {
                        request.optString("op") == "providers" -> host(request)
                        request.optString("op") == "notificationSubscribe" -> JSONObject().put("id", id).put("ok", true)
                        method == "session.observe" -> read(request, JSONObject().put("streamEpoch", "fixture-stream").put("throughSequence", 0).put("events", JSONArray()))
                        method == "session.unobserve" -> read(request, JSONObject())
                        id in preserved && method == "session.snapshot" -> project(request).let { snapshot(request, page(it.getString("provider"), it.getString("threadId"))) }
                        id in preserved && method == "session.creationOptions" -> options(request)
                        id in preserved && method == "workspace.list" -> {
                            val source = body!!.getJSONObject("target").getString("adapterId")
                            val cwd = body.getJSONObject("params").getString("search")
                            read(request, JSONObject().put("workspaces", JSONArray().put(JSONObject().put("adapterId", source).put("cwd", cwd).put("workspaceRef", "$source:$cwd"))).put("nextOffset", -1))
                        }
                        else -> null
                    }
                    if (response != null) { answered.add(id); send(response); count++ }
                }
            }
            test.waitForIdleSync()
            if (count == 0) return
        }
        error("Synthetic preparation did not quiesce")
    }
    /** Wait for a live page read, not the last historical (often already consumed preparation) packet.
     * UI resync coalesces dirty notifications and may post its next read after the main queue is idle.
     */
    fun awaitPageRead(method: String, sessionRef: String, timeoutMs: Long = 3_000): JSONObject {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper())
        val deadline = android.os.SystemClock.elapsedRealtime() + timeoutMs
        var pendingMethods: List<String> = emptyList()
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            settle()
            var selected: JSONObject? = null
            main {
                val pending = client().javaClass.getDeclaredField("pending").apply { isAccessible = true }.get(client()) as Map<*, *>
                val preserved = client().javaClass.getDeclaredField("preservedAgentReads").apply { isAccessible = true }.get(client()) as Set<*>
                val requests = raw()
                pendingMethods = requests.filter { pending.containsKey(it.optString("id")) }
                    .map { it.optJSONObject("body")?.optString("method") ?: it.optString("op") }.distinct()
                selected = requests.lastOrNull { request ->
                    val id = request.getString("id")
                    val body = request.optJSONObject("body")
                    id !in answered && id !in preserved && pending.containsKey(id) &&
                        request.optLong("viewVersion", -1) == client().viewVersion &&
                        body?.optString("method") == method && body.optJSONObject("target")?.optString("sessionRef") == sessionRef
                }
            }
            selected?.let { return project(it) }
            android.os.SystemClock.sleep(10)
        }
        error("No current $method page read for $sessionRef; live methods=$pendingMethods")
    }

    fun discover(source: String, thread: String) {
        main { client().provider = source; client().request("list") { if (it.opt("ok") != true) callbackFailures.add(AssertionError("Discovery failed: ${it.optString("code")}")) } }
        fence()
        val request = raw().last { it.optJSONObject("body")?.optString("method") == "session.list" }
        answered.add(request.getString("id"))
        send(read(request, JSONObject().put("sessions", JSONArray().put(row(source, thread))).put("nextOffset", -1)))
        test.waitForIdleSync()
        main { check(client().agent.session(source, thread) != null) }
    }
    /** Existing UI assertions inspect a projection, but IDs and parameters come from the captured v2 request. */
    fun project(request: JSONObject): JSONObject {
        val body = request.optJSONObject("body") ?: return request
        check(request.optString("op") == "agentRequest" && body.optInt("agentProtocol") == 2)
        check(request.getString("id") == body.getString("requestId"))
        val operation = body.optString("operationId")
        if (operation.isNotBlank()) {
            check(body.optString("controlLease").isNotBlank())
            val context = client().agent.context(operation) ?: created[operation] ?: error("Missing durable mutation context")
            created[operation] = JSONObject(context.toString())
            return JSONObject(context.toString()).put("_wireId", request.getString("id")).put("_method", body.getString("method"))
        }
        val params = body.getJSONObject("params"); val target = body.getJSONObject("target")
        val ref = target.optString("sessionRef")
        val source = if (ref.isNotBlank()) ref.substringBefore(':') else target.optString("adapterId", client().provider)
        val method = body.getString("method")
        val op = when (method) {
            "session.list" -> "list"; "workspace.list" -> "projects"; "session.open" -> "open"; "session.snapshot" -> "sync"
            "session.items" -> params.getString("kind"); "session.creationOptions" -> "newOptions"
            "session.unobserve" -> "close"; "operation.get" -> "receipt"; else -> method
        }
        return JSONObject(params.toString()).put("id", request.getString("id")).put("op", op).put("provider", source)
            .put("_method", method).apply {
                if (ref.isNotBlank()) put("threadId", ref.substringAfter(':'))
                if (op == "receipt") put("operation", params.getString("operationId"))
            }
    }
    fun reply(value: JSONObject, allowObsoleteRead: Boolean = false) {
        val id = value.getString("id")
        val request = raw().last { it.getString("id") == id || it.optJSONObject("body")?.optString("operationId") == id }
        answered.add(request.getString("id"))
        val body = request.optJSONObject("body")
        if (body == null) { send(value); return }
        if (!body.has("operationId") && !allowObsoleteRead) {
            val pending = client().javaClass.getDeclaredField("pending").apply { isAccessible = true }.get(client()) as Map<*, *>
            check(pending.containsKey(request.getString("id"))) {
                "Fixture is replying to an obsolete ${body.optString("method")} read; finish discovery/cancellation before selecting the request"
            }
        }
        val projected = project(request)
        val method = body.getString("method")
        if (body.has("operationId")) {
            val operation = body.getString("operationId")
            val params = body.getJSONObject("params")
            // Queue receipts prove an effect; the new queue state belongs to the native snapshot.
            val result = if (method in setOf("queue.steer", "queue.cancel")) JSONObject() else JSONObject(value.toString())
            val effect = when (method) {
                "message.submit" -> if (params.getString("mode") == "queue") {
                    check(value.opt("queued") == true)
                    result.put("queueId", value.getJSONArray("queuedMessages").getJSONObject(0).getString("id")); "message.queued"
                } else { result.put("nativeMessageId", "native-$operation").put("turnId", "turn-$operation").put("turnIdentityKind", "nativeTurn"); "message.submitted" }
                "session.configure" -> { result.put("effectiveOptions", JSONObject(params.getJSONObject("options").toString())); "session.configured" }
                "turn.interrupt" -> { result.put("turnId", params.getString("expectedTurnId")); "turn.interruptRequested" }
                "approval.resolve" -> { result.put("approvalId", params.getString("approvalId")).put("fingerprint", params.getString("fingerprint")).put("submitted", true); "approval.resolved" }
                "queue.steer", "queue.cancel" -> {
                    val queueId = params.getString("queueId")
                    val native = pages["${projected.getString("provider")}:${projected.getString("threadId")}"]
                        ?: error("Queue mutation has no synthetic native session")
                    val rows = native.getJSONArray("queuedMessages")
                    val items = (0 until rows.length()).map { JSONObject(rows.getJSONObject(it).toString()) }
                    val selected = items.single { it.optString("id") == queueId }
                    if (value.opt("ok") == true) {
                        if (method == "queue.steer") {
                            check(selected.opt("canSteer") == true)
                            selected.put("status", "pending").put("canSteer", false).put("canDelete", false)
                            native.put("queuedMessages", JSONArray(items))
                        } else {
                            check(selected.opt("canDelete") == true)
                            native.put("queuedMessages", JSONArray(items.filterNot { it.optString("id") == queueId }))
                        }
                    }
                    result.put("queueId", queueId)
                    if (method == "queue.steer") { result.put("steered", true); "queue.steered" } else "queue.cancelled"
                }
                "session.create" -> {
                    val target = body.getJSONObject("target")
                    result.put("sessionCreated", true).put("initialInput", "confirmed")
                        .put("session", row(projected.getString("provider"), value.getString("threadId"))
                            .put("cwd", projected.getString("cwd")).put("workspaceRef", target.getString("workspaceRef")))
                    params.getJSONObject("options").opt("executionMode")?.let { result.put("executionMode", it) }
                    "session.created"
                }
                else -> error("Unimplemented synthetic mutation evidence: $method")
            }
            if (result.has("queuedMessages")) pages["${projected.getString("provider")}:${projected.optString("threadId")}"]?.put("queuedMessages", result.getJSONArray("queuedMessages"))
            val wireId = request.getString("id")
            send(JSONObject().put("id", wireId).put("ok", value.get("ok")).put("body", JSONObject().put("agentProtocol", 2).put("requestId", wireId)
                .put("operationId", operation).put("target", JSONObject(body.getJSONObject("target").toString()))
                .put("status", if (value.opt("ok") == true) "confirmed" else "rejected").put("effect", effect).put("result", result)))
            return
        }
        if (value.opt("ok") != true) {
            send(JSONObject().put("id", request.getString("id")).put("ok", false).put("code", value.optString("code", "fixture_read_failed"))
                .put("body", JSONObject().put("agentProtocol", 2).put("requestId", request.getString("id")).put("error", value.optString("error"))))
            return
        }
        val result = JSONObject(value.toString())
        when (method) {
            "session.open", "session.snapshot" -> { send(snapshot(request, result)); return }
            "session.list" -> {
                val rows = result.optJSONArray("threads") ?: JSONArray()
                result.put("sessions", JSONArray((0 until rows.length()).map { i ->
                    val original = rows.getJSONObject(i); val row = row(projected.getString("provider"), original.getString("id"))
                    original.keys().forEach { key -> row.put(key, original.get(key)) }; row
                }))
            }
            "workspace.list" -> {
                val rows = result.getJSONArray("projects")
                result.put("workspaces", JSONArray((0 until rows.length()).map { i -> JSONObject(rows.getJSONObject(i).toString())
                    .put("adapterId", projected.getString("provider")).put("workspaceRef", "${projected.getString("provider")}:${rows.getJSONObject(i).getString("cwd")}") }))
            }
        }
        send(read(request, result))
    }
}
