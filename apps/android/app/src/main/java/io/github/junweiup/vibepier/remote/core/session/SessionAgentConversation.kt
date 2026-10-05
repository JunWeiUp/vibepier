package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONArray
import org.json.JSONObject

/** Existing renderers consume normalized projections; identity and effects stay in the typed client. */
internal class SessionAgentConversation(
    private val agent: SessionAgentClient,
    private val provider: () -> String,
    private val viewVersion: () -> Long,
    private val advanceView: () -> Long?,
    private val adapter: (String) -> String?,
    private val legacyPending: (String, String) -> Boolean,
    private val rememberCapabilities: (JSONObject, JSONObject) -> Unit,
    private val canMutate: (JSONObject, String) -> Boolean,
    private val errorText: (String) -> String,
    private val scheduleRead: (Long, () -> Unit) -> Unit = { _, block -> block() },
    private val readClock: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private val leases = mutableMapOf<String, Pair<SessionAgentProtocol.Target.Creation, String>>()
    private var active: SessionAgentClient.Session? = null
    private var subscriptionId: String? = null
    fun clearConnection() { leases.clear(); active = null; subscriptionId = null }
    private fun creationKey(source: String, cwd: String, draft: String) = "$source\u0000$cwd\u0000$draft"
    private fun projectionFields(fields: JSONObject, source: String) = JSONObject(fields.toString()).put("provider", source).put("viewVersion", viewVersion())

    private data class Scope(val identity: String, val currentProvider: String, val source: String, val adapter: String,
                             val view: Long, val thread: String, val ref: String?, val workspace: String?)
    private fun scope(fields: JSONObject): Scope? {
        if (fields.has("viewVersion") && SessionAgentProtocol.integer(fields.opt("viewVersion")) != viewVersion()) return null
        val source = fields.optString("provider").ifBlank(provider)
        val selected = adapter(source) ?: return null
        val thread = fields.optString("threadId")
        return Scope(agent.currentIdentity, provider(), source, selected, viewVersion(), thread,
            agent.session(source, thread)?.target?.sessionRef, agent.workspace(source, fields.optString("cwd")))
    }
    private fun current(scope: Scope) = agent.negotiated && agent.currentIdentity == scope.identity &&
        provider() == scope.currentProvider && adapter(scope.source) == scope.adapter && viewVersion() == scope.view &&
        (scope.ref == null || agent.session(scope.source, scope.thread)?.target?.sessionRef == scope.ref)
    private fun failure(fields: JSONObject, code: String) = JSONObject().put("id", fields.optString("id"))
        .put("ok", false).put("code", code).put("error", errorText(code))

    /** Renew read-only control evidence before the first write; never invokes an effect or reserves a journal row. */
    internal fun prepareSessionControl(fields: JSONObject, done: (JSONObject) -> Unit): String = prepareSessionControl(fields, true, done)
    private fun prepareSessionControl(fields: JSONObject, requireLease: Boolean, done: (JSONObject) -> Unit): String {
        val frozen = JSONObject(fields.toString()).apply { if (optString("id").isBlank()) put("id", SessionAgentProtocol.id()) }
        val scope = scope(frozen)
        val session = scope?.let { agent.session(it.source, it.thread) }
        if (scope == null || session == null || scope.ref == null) { done(failure(frozen, "stale_state")); return frozen.getString("id") }
        val context = projectionFields(frozen, scope.source)
        var attempts = 0
        val deadline = readClock() + preparationDeadline
        fun fetch() {
            if (!current(scope)) { done(failure(frozen, "stale_state")); return }
            if (readClock() >= deadline) { done(failure(frozen, "agent_state_not_ready")); return }
            attempts++
            fun retry(code: String) {
                val delay = preparationDelays.getOrNull(attempts - 1)
                if (delay == null || readClock() + delay >= deadline) done(failure(frozen, code))
                else scheduleRead(delay) { fetch() }
            }
            val generation = agent.controlGeneration(scope.ref)
            agent.read(SessionAgentProtocol.Method.SNAPSHOT, session.target) { reply ->
                if (!current(scope)) { done(failure(frozen, "stale_state")); return@read }
                if (readClock() >= deadline) { done(failure(frozen, "agent_state_not_ready")); return@read }
                val result = (reply as? SessionAgentProtocol.Reply.Read)?.result
                val page = result?.optJSONObject("snapshot")
                if (generation != agent.controlGeneration(scope.ref) || page?.opt("contentState") != "complete") {
                    val code = (reply as? SessionAgentProtocol.Reply.Failure)?.code ?: "content_incomplete"
                    if (generation != agent.controlGeneration(scope.ref) || page?.opt("contentState") in setOf("partial", "unavailable") ||
                        page?.opt("opening") == true || result == null && code in retryablePreparation) retry(code)
                    else done(failure(frozen, code))
                    return@read
                }
                val row = result.optJSONObject("session")
                val lease = result.opt("controlLease") as? String
                if (row?.opt("sessionRef") != scope.ref || row.opt("nativeThreadId") != scope.thread || row.opt("adapterId") != scope.adapter ||
                    page.opt("threadId") != scope.thread || (page.has("provider") && page.opt("provider") != scope.source) ||
                    lease != null && (lease.isBlank() || lease.length > 4096 || '\u0000' in lease)) {
                    done(failure(frozen, "agent_target_mismatch")); return@read
                }
                if (requireLease && lease == null) { retry("agent_state_not_ready"); return@read }
                val verified = agent.rememberSession(scope.source, row, lease, replaceControl = true)
                if (verified == null) { done(failure(frozen, "agent_protocol_invalid")); return@read }
                agent.rememberSnapshot(scope.source, scope.thread, page)
                active = verified
                renewObservation(verified, result)
                rememberCapabilities(context, page)
                if (!current(scope) || generation != agent.controlGeneration(scope.ref)) { done(failure(frozen, "stale_state")); return@read }
                done(JSONObject(page.toString()).put("ok", true).put("id", frozen.getString("id"))
                    .put("provider", scope.source).put("threadId", scope.thread).put("viewVersion", scope.view))
            }
        }
        fetch()
        return frozen.getString("id")
    }

    private fun prepareCreation(fields: JSONObject, done: (JSONObject) -> Unit) {
        val scope = scope(fields)
        val cwd = fields.optString("cwd"); val draft = fields.optString("draftId")
        if (scope == null || scope.workspace == null || cwd.isBlank() || draft.isBlank()) { done(failure(fields, "stale_state")); return }
        val context = projectionFields(fields, scope.source)
        var attempts = 0
        val deadline = readClock() + preparationDeadline
        fun fetch() {
            if (!current(scope) || agent.workspace(scope.source, cwd) != scope.workspace) { done(failure(fields, "stale_state")); return }
            if (readClock() >= deadline) { done(failure(fields, "agent_state_not_ready")); return }
            attempts++
            fun retry(code: String) {
                val delay = preparationDelays.getOrNull(attempts - 1)
                if (delay == null || readClock() + delay >= deadline) done(failure(fields, code)) else scheduleRead(delay) { fetch() }
            }
            agent.read(SessionAgentProtocol.Method.CREATION_OPTIONS, SessionAgentProtocol.Target.Adapter(scope.adapter),
                JSONObject().put("workspaceRef", scope.workspace).put("draftId", draft)) { reply ->
                if (!current(scope) || agent.workspace(scope.source, cwd) != scope.workspace) { done(failure(fields, "stale_state")); return@read }
                if (readClock() >= deadline) { done(failure(fields, "agent_state_not_ready")); return@read }
                val result = (reply as? SessionAgentProtocol.Reply.Read)?.result
                if (result == null) {
                    val code = (reply as? SessionAgentProtocol.Reply.Failure)?.code ?: "agent_protocol_invalid"
                    if (code in retryablePreparation) retry(code) else done(failure(fields, code))
                    return@read
                }
                val creation = result.optJSONObject("creationLease"); val target = creation?.optJSONObject("target")
                val options = result.optJSONObject("options")
                val revision = SessionAgentCapabilities.opaque(target?.opt("optionsRevision"))
                val lease = creation?.opt("controlLease") as? String
                if (creation == null || lease == null) { retry("agent_state_not_ready"); return@read }
                if (target?.opt("adapterId") != scope.adapter || target.opt("workspaceRef") != scope.workspace || target.opt("draftId") != draft ||
                    revision == null || options == null || options.opt("draftId") != draft ||
                    lease.isNullOrBlank() || lease.length > 4096 || '\u0000' in lease) {
                    done(failure(fields, "agent_options_changed")); return@read
                }
                leases[creationKey(scope.source, cwd, draft)] = SessionAgentProtocol.Target.Creation(scope.adapter, scope.workspace, draft, revision) to lease
                rememberCapabilities(context, options)
                if (!current(scope) || agent.workspace(scope.source, cwd) != scope.workspace) { done(failure(fields, "stale_state")); return@read }
                done(JSONObject(options.toString()).put("ok", true))
            }
        }
        fetch()
    }

    fun request(op: String, fields: JSONObject, callback: (JSONObject) -> Unit): String? {
        val source = fields.optString("provider").ifBlank(provider)
        if (agent.negotiated && op in preparedReads) return prepareItemRead(op, fields, callback)
        if (!agent.negotiated || op !in mutationOperations || legacyPending(source, fields.optString("threadId"))) return requestPrepared(op, fields, callback)
        val frozen = JSONObject(fields.toString()).put("id", fields.optString("id").ifBlank(SessionAgentProtocol::id))
        val id = frozen.getString("id")
        if (agent.hasPendingOperation(id)) {
            val original = agent.context(id)
            agent.reconcile(id) { reply -> callback(if (original == null) failure(frozen, "receipt_unknown") else legacyReply(reply, original)) }
            return id
        }
        val scope = scope(frozen)
        if (scope == null) { callback(failure(frozen, "stale_state")); return id }
        val intent = SessionControlPreparation.capture(op, frozen)
        if (intent == null) { callback(failure(frozen, "agent_state_changed")); return id }
        val desired = intent.fields
        val prepared: (JSONObject) -> Unit = { result ->
            if (!result.optBoolean("ok")) callback(result)
            else if (!current(scope)) callback(failure(frozen, "stale_state"))
            else {
                val resolved = SessionControlPreparation.resolvedFields(intent, result)
                if (resolved == null) callback(failure(frozen, "agent_state_changed"))
                else if (requestPrepared(op, resolved, callback) == null) callback(failure(frozen, "operation_conflict"))
            }
        }
        if (op == "new") prepareCreation(desired, prepared) else prepareSessionControl(desired, prepared)
        return id
    }

    private fun prepareItemRead(op: String, fields: JSONObject, callback: (JSONObject) -> Unit): String {
        val frozen = JSONObject(fields.toString()).put("id", fields.optString("id").ifBlank(SessionAgentProtocol::id))
        val scope = scope(frozen)
        if (scope == null || scope.ref == null) { callback(failure(frozen, "stale_state")); return frozen.getString("id") }
        prepareSessionControl(frozen, false) { page ->
            if (!page.optBoolean("ok")) { callback(page); return@prepareSessionControl }
            if (!current(scope)) { callback(failure(frozen, "stale_state")); return@prepareSessionControl }
            val params = JSONObject().put("kind", op)
            val approval = if (op == "approvalDetails") {
                val rows = page.optJSONArray("approvals") ?: JSONArray()
                (0 until rows.length()).mapNotNull { rows.optJSONObject(it) }.singleOrNull { it.opt("fingerprint") == frozen.opt("fingerprint") }
            } else null
            if (op == "approvalDetails") {
                if (approval == null || frozen.has("expectedApprovalRevision") && frozen.opt("expectedApprovalRevision") != approval.opt("revision")) {
                    callback(failure(frozen, "approval_expired")); return@prepareSessionControl
                }
                params.put("messageId", approval.opt("id"))
            }
            val session = agent.session(scope.source, scope.thread)
            if (session == null) { callback(failure(frozen, "stale_state")); return@prepareSessionControl }
            val generation = agent.controlGeneration(scope.ref)
            agent.read(SessionAgentProtocol.Method.ITEMS, session.target, params) { reply ->
                if (!current(scope) || generation != agent.controlGeneration(scope.ref)) { callback(failure(frozen, "stale_state")); return@read }
                if (reply !is SessionAgentProtocol.Reply.Read) { callback(legacyReply(reply, projectionFields(frozen, scope.source))); return@read }
                val result = JSONObject(reply.result.toString())
                if (result.has("threadId") && result.opt("threadId") != scope.thread) { callback(failure(frozen, "agent_target_mismatch")); return@read }
                if (approval != null) {
                    val details = result.optJSONObject("approval")
                    if (details == null || details.opt("fingerprint") != approval.opt("fingerprint")) { callback(failure(frozen, "approval_expired")); return@read }
                    // Full native prose/form data does not override the service's normalized authority.
                    for (key in listOf("id", "revision", "fingerprint", "nativeRequestId", "nativeRequestFingerprint", "title",
                        "decisionScope", "kind", "reason", "method", "plan", "planApprovalScope", "toolUseId")) {
                        if (approval.has(key)) details.put(key, approval.get(key)) else details.remove(key)
                    }
                    details.put("canDecide", approval.opt("canDecide") == true)
                    details.put("allowedDecisions", approval.optJSONArray("allowedDecisions") ?: JSONArray())
                }
                callback(result.put("ok", true).put("id", frozen.getString("id")).put("provider", scope.source)
                    .put("threadId", scope.thread).put("viewVersion", scope.view))
            }
        }
        return frozen.getString("id")
    }

    private fun renewObservation(session: SessionAgentClient.Session, result: JSONObject) {
        val id = subscriptionId ?: return
        val epoch = SessionAgentCapabilities.opaque(result.opt("streamEpoch")) ?: return
        val through = SessionAgentProtocol.integer(result.opt("throughSequence")) ?: return
        agent.refreshObservation(id, session.target.sessionRef, epoch, through)
    }

    /** A null return means this is an independent v1 service or an existing v1 pending scope. */
    private fun requestPrepared(op: String, fields: JSONObject, callback: (JSONObject) -> Unit): String? {
        val source = fields.optString("provider").ifBlank(provider)
        val originalOperation = fields.optString("operation")
        val pendingContext = if (op == "receipt") agent.context(originalOperation) else null
        if (pendingContext != null) {
            val id = fields.optString("id").ifBlank(SessionAgentProtocol::id)
            agent.reconcile(originalOperation) { reply ->
                val response = JSONObject().put("id", id).put("provider", pendingContext.optString("provider")).put("ok", true)
                if (reply is SessionAgentProtocol.Reply.Mutation && reply.status in setOf(SessionAgentProtocol.Status.CONFIRMED, SessionAgentProtocol.Status.REJECTED)) {
                    response.put("state", "complete").put("receipt", legacyReply(reply, pendingContext))
                } else response.put("state", "unknown")
                callback(response)
            }
            return id
        }
        if (!agent.negotiated || op !in routed) return null
        val thread = fields.optString("threadId")
        if (thread.isNotBlank() && legacyPending(source, thread)) return null
        if (op in setOf("new", "newOptions") && legacyPending(source, "")) return null
        val id = fields.optString("id").ifBlank(SessionAgentProtocol::id)
        fun fail(code: String) { callback(JSONObject().put("id", id).put("ok", false).put("code", code).put("error", errorText(code))) }
        val adapterId = adapter(source) ?: run { fail("agent_upgrade_required"); return id }
        if (op in setOf("open", "close") && advanceView() == null) { fail("capacity_exceeded"); return id }
        val context = projectionFields(fields, source).put("id", id).put("op", op).put("agentAdapterId", adapterId)
        val scope = scope(fields)
        val readGeneration = scope?.ref?.let(agent::controlGeneration)
        val session = if (op == "close") active else agent.session(source, thread)
        val target = session?.target
        val approval = if (op == "approve") {
            val approvals = agent.snapshot(source, thread)?.optJSONArray("approvals") ?: JSONArray()
            (0 until approvals.length()).mapNotNull { approvals.optJSONObject(it) }.singleOrNull { it.opt("fingerprint") == fields.opt("fingerprint") }
        } else null
        val answeringQuestion = fields.has("answers") || approval?.opt("kind") == "questions"
        val method = when (op) {
            "list" -> SessionAgentProtocol.Method.LIST
            "projects" -> SessionAgentProtocol.Method.WORKSPACES
            "open" -> SessionAgentProtocol.Method.OPEN
            "sync" -> SessionAgentProtocol.Method.SNAPSHOT
            "history", "parts", "message" -> SessionAgentProtocol.Method.ITEMS
            "newOptions" -> SessionAgentProtocol.Method.CREATION_OPTIONS
            "new" -> SessionAgentProtocol.Method.CREATE
            "send" -> SessionAgentProtocol.Method.SUBMIT
            "settings" -> SessionAgentProtocol.Method.CONFIGURE
            "interrupt" -> SessionAgentProtocol.Method.INTERRUPT
            "queueDelete" -> SessionAgentProtocol.Method.CANCEL_QUEUE
            "approve" -> if (answeringQuestion) SessionAgentProtocol.Method.ANSWER_QUESTION else SessionAgentProtocol.Method.RESOLVE_APPROVAL
            else -> SessionAgentProtocol.Method.UNOBSERVE
        }
        if (!agent.supports(method)) { fail("unsupported"); return id }
        if (op !in setOf("list", "projects", "newOptions", "new") && target == null) { fail("stale_state"); return id }
        val params = JSONObject()
        when (op) {
            "list", "projects" -> {
                for (key in listOf("search", "offset", "limit")) if (fields.has(key)) params.put(key, fields.get(key))
                if (op == "list" && fields.optString("cwd").isNotBlank()) {
                    val workspace = agent.workspace(source, fields.optString("cwd")) ?: run { fail("stale_state"); return id }
                    params.put("workspaceRef", workspace)
                }
            }
            "newOptions" -> {
                val workspace = agent.workspace(source, fields.optString("cwd")) ?: run { fail("stale_state"); return id }
                params.put("workspaceRef", workspace).put("draftId", fields.optString("draftId"))
            }
            "history", "parts", "message" -> {
                params.put("kind", op)
                for (key in listOf("messageId", "before", "offset", "limit", "headersOnly", "sequence")) if (fields.has(key)) params.put(key, fields.get(key))
            }
            "close" -> subscriptionId?.let { params.put("subscriptionId", it) }
        }
        if (method.mutation) {
            val capability = SessionV1Contract.operation(op)?.capability
            if (capability == null || !canMutate(context, capability)) { fail("agent_capability_unavailable"); return id }
            if (op in setOf("new", "settings") && fields.has("executionMode") && !canMutate(context, "executionMode")) { fail("agent_capability_unavailable"); return id }
            val lease = if (op == "new") leases[creationKey(source, fields.optString("cwd"), fields.optString("draftId"))]?.second else session?.controlLease
            val mutationTarget = if (op == "new") leases[creationKey(source, fields.optString("cwd"), fields.optString("draftId"))]?.first else target
            if (lease == null || mutationTarget == null) { fail("stale_state"); return id }
            when (op) {
                "send" -> {
                    val page = agent.snapshot(source, thread) ?: run { fail("stale_state"); return id }
                    params.put("mode", fields.optString("submissionMode").takeIf { it in setOf("start", "queue") } ?: if (page.opt("status") == "active" && page.optJSONObject("agentCapabilities")?.optJSONObject("actions")?.optJSONObject("queue")?.opt("available") == true) "queue" else "start")
                        .put("content", content(fields))
                }
                "new" -> params.put("initialMessage", JSONObject().put("content", content(fields))).put("options", options(fields))
                "settings" -> params.put("options", options(fields))
                "interrupt" -> params.put("expectedTurnId", fields.optString("expectedTurnId"))
                "queueDelete" -> params.put("queueId", fields.optString("messageId"))
                "approve" -> {
                    val pending = approval ?: run { fail("approval_expired"); return id }
                    val revision = SessionAgentCapabilities.opaque(pending.opt("revision")) ?: run { fail("stale_state"); return id }
                    params.put(if (answeringQuestion) "questionId" else "approvalId", pending.optString("id"))
                        .put("fingerprint", fields.optString("fingerprint")).put("revision", revision)
                    if (answeringQuestion) {
                        val answers = if (fields.has("answers")) fields.getJSONObject("answers") else {
                            val option = fields.optString("option"); val options = pending.optJSONArray("options") ?: JSONArray()
                            if ((0 until options.length()).none { options.opt(it) == option }) { fail("unsupported"); return id }
                            JSONObject().put(pending.optString("id"), option)
                        }
                        params.put("answers", answers)
                    }
                    else {
                        val decision = fields.optString("option").ifBlank { if (fields.opt("allow") == true) "allow" else "deny" }
                        val choices = pending.optJSONArray("allowedDecisions") ?: JSONArray()
                        if ((0 until choices.length()).none { choices.opt(it) == decision }) { fail("unsupported"); return id }
                        params.put("decision", decision)
                    }
                }
            }
            agent.mutate(method, mutationTarget, params, lease, operationId = id, context = context) { reply -> callback(legacyReply(reply, context)) }
            return id
        }
        val readTarget = if (op in setOf("list", "projects", "newOptions")) SessionAgentProtocol.Target.Adapter(adapterId) else target
        agent.read(method, readTarget, params) { reply ->
            if (op in setOf("list", "projects", "open", "sync", "newOptions", "close") && (scope == null || !current(scope) ||
                (op in setOf("open", "sync") && scope.ref != null && readGeneration != agent.controlGeneration(scope.ref)) ||
                (op == "newOptions" && scope.workspace != agent.workspace(source, fields.optString("cwd"))))) { fail("stale_state"); return@read }
            if (reply !is SessionAgentProtocol.Reply.Read) { callback(legacyReply(reply, context)); return@read }
            val result = reply.result
            val projected = when (op) {
                "list" -> {
                    val rows = result.optJSONArray("sessions") ?: JSONArray()
                    val converted = JSONArray()
                    for (index in 0 until rows.length()) {
                        val row = rows.optJSONObject(index) ?: continue
                        agent.rememberSession(source, row, preserveVerifiedControl = true)?.let { converted.put(JSONObject(row.toString()).put("id", it.nativeThreadId)) }
                    }
                    JSONObject(result.toString()).put("threads", converted)
                }
                "projects" -> {
                    val rows = result.optJSONArray("workspaces") ?: JSONArray()
                    val converted = JSONArray()
                    for (index in 0 until rows.length()) {
                        val row = rows.optJSONObject(index) ?: continue
                        if (agent.rememberWorkspace(source, row)) converted.put(JSONObject(row.toString()).put("name", row.optString("title").ifBlank { row.optString("name") }))
                    }
                    JSONObject(result.toString()).put("projects", converted)
                }
                "newOptions" -> {
                    val creation = result.optJSONObject("creationLease")
                    val creationTarget = creation?.optJSONObject("target")
                    val draft = fields.optString("draftId"); val cwd = fields.optString("cwd")
                    if (creation != null && creationTarget?.opt("draftId") == draft && creationTarget.opt("adapterId") == adapterId) {
                        val workspace = SessionAgentCapabilities.opaque(creationTarget.opt("workspaceRef"))
                        val revision = SessionAgentCapabilities.opaque(creationTarget.opt("optionsRevision"))
                        val lease = SessionAgentCapabilities.opaque(creation.opt("controlLease"))
                        if (workspace != null && workspace == agent.workspace(source, cwd) && revision != null && lease != null) {
                            leases[creationKey(source, cwd, draft)] = SessionAgentProtocol.Target.Creation(adapterId, workspace, draft, revision) to lease
                        }
                    }
                    val options = result.optJSONObject("options")?.let { JSONObject(it.toString()) } ?: JSONObject(result.toString())
                    options
                }
                "open", "sync" -> {
                    val row = result.optJSONObject("session")
                    val next = result.optJSONObject("snapshot")
                    if (row == null || next == null || row.opt("sessionRef") != scope?.ref || row.opt("adapterId") != adapterId ||
                        row.opt("nativeThreadId") != thread || next.opt("threadId") != thread ||
                        (next.has("provider") && next.opt("provider") != source)) { fail("agent_target_mismatch"); return@read }
                    if (next.opt("contentState") !in setOf("complete", "partial", "unavailable")) { fail("content_incomplete"); return@read }
                    if (next.opt("contentState") != "complete" || result.opt("controlLease") !is String) agent.invalidateControl(row.getString("sessionRef"))
                    val verified = agent.rememberSession(source, row, result.opt("controlLease") as? String)
                    if (verified == null || verified.nativeThreadId != thread) { fail("stale_state"); return@read }
                    active = verified
                    val page = mergePartial(agent.snapshot(source, thread), next)
                    agent.rememberSnapshot(source, thread, page)
                    if (op == "open") observe(source, thread, result) else if (next.opt("contentState") == "complete") renewObservation(verified, result)
                    page
                }
                else -> JSONObject(result.toString())
            }
            projected.put("ok", true).put("id", id).put("provider", source).put("viewVersion", context.getLong("viewVersion"))
            if (thread.isNotBlank()) projected.put("threadId", thread)
            if (op in setOf("open", "sync", "newOptions")) rememberCapabilities(context, projected)
            if (op == "close") { subscriptionId?.let(agent::unobserve); subscriptionId = null; active = null }
            callback(projected)
        }
        return id
    }
    private fun observe(source: String, thread: String, result: JSONObject) {
        val target = agent.session(source, thread)?.target ?: return
        val scope = scope(JSONObject().put("provider", source).put("threadId", thread)) ?: return
        if (!agent.supports(SessionAgentProtocol.Method.OBSERVE)) return
        val id = SessionAgentProtocol.id(); subscriptionId = id
        val initialEpoch = SessionAgentCapabilities.opaque(result.opt("streamEpoch"))
        val initialThrough = SessionAgentProtocol.integer(result.opt("throughSequence"))
        val params = JSONObject().put("subscriptionId", id)
        if (initialEpoch != null && initialThrough != null) {
            agent.observe(id, target, initialEpoch, initialThrough, result.optJSONObject("snapshot")?.opt("contentState") == "complete")
            params.put("streamEpoch", initialEpoch).put("afterSequence", initialThrough)
        }
        agent.read(SessionAgentProtocol.Method.OBSERVE, target, params) { reply ->
            if (subscriptionId != id || !current(scope)) return@read
            val snapshot = (reply as? SessionAgentProtocol.Reply.Read)?.result ?: return@read
            val epoch = SessionAgentCapabilities.opaque(snapshot.opt("streamEpoch")) ?: return@read
            val through = SessionAgentProtocol.integer(snapshot.opt("throughSequence")) ?: return@read
            val events = snapshot.optJSONArray("events") ?: JSONArray()
            if (events.length() > 256) { agent.onDirty(target.sessionRef); return@read }
            if (snapshot.opt("resyncRequired") == true) agent.onDirty(target.sessionRef)
            for (index in 0 until events.length()) {
                if (subscriptionId != id || !current(scope)) return@read
                val event = events.optJSONObject(index) ?: continue
                if (!agent.event(JSONObject().put("event", "agentEvent").put("body", event))) agent.onDirty(target.sessionRef)
            }
            if (subscriptionId == id && current(scope) && (initialEpoch == null || initialThrough == null)) agent.observe(id, target, epoch, through, false)
        }
    }
    private fun content(fields: JSONObject) = JSONArray().apply {
        fields.optString("text").takeIf { it.isNotBlank() }?.let { put(JSONObject().put("type", "text").put("text", it)) }
        val attachments = fields.optJSONArray("attachments") ?: JSONArray()
        for (index in 0 until attachments.length()) put(JSONObject().put("type", "attachment").put("attachmentId", attachments.getString(index)))
    }
    private fun options(fields: JSONObject) = JSONObject().apply {
        for (key in listOf("model", "mode", "effort", "executionMode")) if (fields.has(key)) put(key, fields.get(key))
        if (fields.has("confirmFullAccess")) put("confirmation", fields.get("confirmFullAccess"))
    }
    fun legacyReply(reply: SessionAgentProtocol.Reply, context: JSONObject): JSONObject {
        val value = JSONObject().put("id", context.optString("id")).put("provider", context.optString("provider"))
            .put("threadId", context.optString("threadId")).put("viewVersion", context.optLong("viewVersion", viewVersion()))
        when (reply) {
            is SessionAgentProtocol.Reply.Failure -> value.put("ok", false).put("code", reply.code).put("error", errorText(reply.code))
            is SessionAgentProtocol.Reply.Read -> value.put("ok", true).put("result", reply.result)
            is SessionAgentProtocol.Reply.Mutation -> {
                val confirmed = reply.status == SessionAgentProtocol.Status.CONFIRMED
                val unknown = reply.status in setOf(SessionAgentProtocol.Status.UNKNOWN, SessionAgentProtocol.Status.ACCEPTED)
                reply.result.keys().forEach { key -> if (key !in setOf("id", "provider", "threadId", "viewVersion", "ok", "accepted", "submitted", "unknown")) value.put(key, reply.result.get(key)) }
                value.put("ok", confirmed).put("accepted", confirmed).put("unknown", unknown)
                if (context.opt("op") == "approve") value.put("submitted", confirmed).put("fingerprint", context.opt("fingerprint"))
                if (context.opt("op") == "send") value.put("queued", reply.body.opt("effect") == "message.queued")
                if (context.opt("op") == "settings") reply.result.optJSONObject("effectiveOptions")?.let { value.put("composer", it) }
                if (context.opt("op") == "new") {
                    reply.result.optJSONObject("session")?.let { row -> agent.rememberSession(context.optString("provider"), row)?.let { value.put("threadId", it.nativeThreadId) } }
                    value.put("cwd", context.optString("cwd"))
                }
                if (!confirmed) value.put("error", errorText(if (unknown) "receipt_unknown" else reply.body.optString("code", "agent_capability_unavailable")))
            }
        }
        return value
    }
    companion object {
        private val mutationOperations = setOf("send", "new", "settings", "interrupt", "approve", "queueDelete")
        private val retryablePreparation = setOf("agent_session_not_open", "agent_session_view_closed", "agent_native_unavailable", "content_incomplete", "agent_state_not_ready")
        private val preparedReads = setOf("composerOptions", "approvalDetails")
        private val preparationDelays = listOf(250L, 500L, 1_000L, 1_500L, 2_000L, 2_500L)
        private const val preparationDeadline = 10_000L
        private val routed = setOf("list", "projects", "open", "close", "sync", "history", "parts", "message", "newOptions", "new", "send", "settings", "interrupt", "approve", "queueDelete")
        fun mergePartial(previous: JSONObject?, next: JSONObject): JSONObject {
            val result = JSONObject(next.toString())
            if (next.opt("contentState") == "complete") return result
            val rows = linkedMapOf<String, JSONObject>()
            for (values in listOf(previous?.optJSONArray("messages"), next.optJSONArray("messages"))) {
                if (values != null) for (index in 0 until values.length()) values.optJSONObject(index)?.let { item ->
                    val id = item.opt("id") as? String
                    if (!id.isNullOrBlank()) rows[id] = item
                }
            }
            result.put("messages", JSONArray(rows.values.toList())).put("canSend", false).remove("agentCapabilities")
            return result
        }
    }
}
