package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONObject

/** Typed profile-2 transport. Its journal is separate from, and never rewrites, pending v1 bytes. */
internal class SessionAgentClient(
    private val identity: () -> String,
    private val send: (JSONObject, (JSONObject) -> Unit) -> Unit,
    private val storage: Storage,
    private val adapterAllowed: (String, String) -> Boolean = { _, _ -> false },
    private val selectedAdapter: (String) -> String? = { null },
) {
    interface Storage {
        fun pending(): Map<String, String>
        fun save(operationId: String, original: String): Boolean
        fun remove(operationId: String): Boolean
    }
    data class Session(val provider: String, val adapterId: String, val nativeThreadId: String,
                       val target: SessionAgentProtocol.Target.Session, val descriptor: JSONObject,
                       val controlLease: String? = null)
    private var profile: SessionAgentProtocol.Profile? = null
    private var negotiatedIdentity: String? = null
    private val sessions = mutableMapOf<String, Session>()
    private val workspaces = mutableMapOf<String, String>()
    private val observers = mutableMapOf<String, SessionAgentObservation>()
    private val snapshots = mutableMapOf<String, JSONObject>()
    private val controlChanges = mutableMapOf<String, Long>()
    internal val currentIdentity get() = identity()
    val negotiated get() = profile != null && negotiatedIdentity == identity()
    var onDirty: (String) -> Unit = {}
    var onContentChanged: (String) -> Unit = {}
    var onOperation: (String, SessionAgentProtocol.Reply.Mutation, JSONObject?) -> Unit = { _, _, _ -> }
    var beforeComplete: (SessionAgentProtocol.Reply.Mutation, JSONObject?) -> Boolean = { _, _ -> true }
    var onSession: (Session) -> Unit = {}

    fun discover(value: JSONObject?) {
        clearConnection()
        profile = SessionAgentProtocol.Profile.decode(value)
        negotiatedIdentity = if (profile == null) null else identity()
    }
    fun clearConnection() { profile = null; negotiatedIdentity = null; sessions.clear(); workspaces.clear(); observers.clear(); snapshots.clear(); controlChanges.clear() }
    fun supports(method: SessionAgentProtocol.Method) = negotiated && method in (profile?.methods ?: emptySet())
    private fun key(provider: String, thread: String, adapter: String? = selectedAdapter(provider)) = "$provider\u0000$adapter\u0000$thread"
    fun session(provider: String, thread: String) = sessions[key(provider, thread)]
    fun workspace(provider: String, cwd: String) = workspaces[key(provider, cwd)]
    fun snapshot(provider: String, thread: String) = snapshots[key(provider, thread)]?.let { JSONObject(it.toString()) }
    fun rememberSnapshot(provider: String, thread: String, value: JSONObject) { snapshots[key(provider, thread)] = JSONObject(value.toString()) }
    fun byReference(ref: String) = sessions.values.singleOrNull { it.target.sessionRef == ref }
    fun controlGeneration(ref: String) = controlChanges[ref] ?: 0L
    fun invalidateControl(ref: String) {
        controlChanges[ref] = controlGeneration(ref).let { if (it == Long.MAX_VALUE) it else it + 1 }
        sessions.keys.toList().forEach { key -> sessions[key]?.takeIf { it.target.sessionRef == ref }?.let { sessions[key] = it.copy(controlLease = null) } }
    }
    fun controlReady(provider: String, thread: String) = session(provider, thread)?.controlLease != null &&
        snapshot(provider, thread)?.opt("contentState") == "complete"
    fun hasPendingOperation(operation: String) = runCatching { storage.pending().containsKey(operation) }.getOrDefault(true)

    fun rememberWorkspace(provider: String, row: JSONObject): Boolean {
        val cwd = (row.opt("cwd") as? String)?.takeIf { it.startsWith('/') && '\u0000' !in it } ?: return false
        val reference = SessionAgentCapabilities.opaque(row.opt("workspaceRef")) ?: return false
        val adapterId = row.opt("adapterId") as? String ?: return false
        if (!adapterAllowed(provider, adapterId) || adapterId != selectedAdapter(provider)) return false
        workspaces[key(provider, cwd, adapterId)] = reference
        return true
    }
    fun rememberSession(provider: String, row: JSONObject, lease: String? = null, preserveVerifiedControl: Boolean = false,
                        replaceControl: Boolean = false): Session? = runCatching {
        require(provider in SessionV1Contract.providers)
        val adapter = SessionAgentCapabilities.opaque(row.opt("adapterId")) ?: error("Missing adapter")
        require(adapterAllowed(provider, adapter) && adapter == selectedAdapter(provider))
        fun field(name: String) = SessionAgentCapabilities.opaque(row.opt(name)) ?: error("Missing identity")
        val target = SessionAgentProtocol.Target.Session(field("sessionRef"), field("ownershipEpoch"), field("capabilityRevision"))
        val thread = field("nativeThreadId")
        val previous = session(provider, thread)
        if (preserveVerifiedControl && previous?.controlLease != null && snapshot(provider, thread)?.opt("contentState") == "complete") return@runCatching previous
        val controlLease = lease?.takeIf { it.isNotBlank() && it.length <= 4096 && '\u0000' !in it }
            ?: previous?.takeIf { !replaceControl && it.target == target }?.controlLease
        val session = Session(provider, adapter, thread, target, JSONObject(row.toString()), controlLease)
        sessions[key(provider, thread, adapter)] = session
        onSession(session)
        if (sessions.size > 256) sessions.keys.firstOrNull { it != key(provider, thread, adapter) }?.let(sessions::remove)
        session
    }.getOrNull()

    /** Called with the request ID of reads that a pending mutation or receipt depends on; page cancellation must keep them. */
    var onPreservedRead: (String) -> Unit = {}
    fun read(method: SessionAgentProtocol.Method, target: SessionAgentProtocol.Target? = null,
             params: JSONObject = JSONObject(), preserve: Boolean = false, callback: (SessionAgentProtocol.Reply) -> Unit) {
        if (!supports(method) || method.mutation) { callback(SessionAgentProtocol.Reply.Failure("protocol_incompatible")); return }
        val request = runCatching { SessionAgentProtocol.Request(SessionAgentProtocol.id(), method, target, JSONObject(params.toString())) }.getOrNull()
        if (request == null) { callback(SessionAgentProtocol.Reply.Failure("agent_request_invalid")); return }
        if (preserve) onPreservedRead(request.requestId)
        perform(request, callback)
    }
    fun mutate(method: SessionAgentProtocol.Method, target: SessionAgentProtocol.Target, params: JSONObject,
               controlLease: String, operationId: String = SessionAgentProtocol.id(), context: JSONObject? = null,
               callback: (SessionAgentProtocol.Reply) -> Unit) {
        if (!supports(method) || !method.mutation) { callback(SessionAgentProtocol.Reply.Failure("protocol_incompatible")); return }
        val request = runCatching { SessionAgentProtocol.Request(SessionAgentProtocol.id(), method, target,
            JSONObject(params.toString()), operationId, controlLease) }.getOrNull()
        if (request == null) { callback(SessionAgentProtocol.Reply.Failure("agent_protocol_invalid")); return }
        val original = JSONObject().put("identity", identity()).put("body", request.json()).apply {
            context?.let { put("legacy", JSONObject(it.toString()).put("id", operationId).put("agentOperationId", operationId)) }
        }.toString()
        val pending = runCatching { storage.pending() }.getOrNull()
        if (pending == null || pending.containsKey(operationId) || !runCatching { storage.save(operationId, original) }.getOrDefault(false)) {
            callback(SessionAgentProtocol.Reply.Failure("operation_conflict")); return
        }
        perform(request, callback)
    }
    private fun perform(request: SessionAgentProtocol.Request, callback: (SessionAgentProtocol.Reply) -> Unit) {
        val owner = identity()
        send(JSONObject().put("id", request.requestId).put("body", request.json())) { value ->
            if (owner != identity()) { callback(SessionAgentProtocol.Reply.Failure("owner_changed")); return@send }
            val reply = SessionAgentProtocol.reply(value, request)
            if (reply == null) {
                if (request.method.mutation) callback(SessionAgentProtocol.Reply.Mutation(SessionAgentProtocol.Status.UNKNOWN,
                    request.operationId!!, request.target?.json(), JSONObject(), request.json()))
                else callback(SessionAgentProtocol.Reply.Failure(value.optString("code", "agent_protocol_invalid")))
                return@send
            }
            callback(settle(reply))
        }
    }
    private fun settle(reply: SessionAgentProtocol.Reply): SessionAgentProtocol.Reply {
        if (reply is SessionAgentProtocol.Reply.Mutation) {
            val context = context(reply.operationId)
            if (reply.status in setOf(SessionAgentProtocol.Status.CONFIRMED, SessionAgentProtocol.Status.REJECTED)) {
                if (!beforeComplete(reply, context) || !runCatching { storage.remove(reply.operationId) }.getOrDefault(false)) return reply.copy(status = SessionAgentProtocol.Status.UNKNOWN)
            }
            onOperation(reply.operationId, reply, context)
        }
        return reply
    }
    private fun original(operationId: String): SessionAgentProtocol.Request? = runCatching {
        val stored = JSONObject(storage.pending()[operationId] ?: return null)
        require(stored.opt("identity") == identity())
        val body = stored.getJSONObject("body")
        require(body.opt("agentProtocol") == SessionAgentProtocol.VERSION && body.opt("operationId") == operationId)
        val method = SessionAgentProtocol.Method.parse(body.opt("method")) ?: error("Unknown method")
        val raw = body.getJSONObject("target")
        fun field(key: String) = SessionAgentCapabilities.opaque(raw.opt(key)) ?: error("Invalid target")
        val target: SessionAgentProtocol.Target = if (method == SessionAgentProtocol.Method.CREATE) {
            SessionAgentProtocol.Target.Creation(field("adapterId"), field("workspaceRef"), field("draftId"), field("optionsRevision"))
        } else SessionAgentProtocol.Target.Session(field("sessionRef"), field("ownershipEpoch"), field("capabilityRevision"))
        SessionAgentProtocol.Request(body.getString("requestId"), method, target, body.getJSONObject("params"), operationId, body.getString("controlLease"))
    }.getOrNull()

    fun context(operationId: String): JSONObject? = runCatching {
        val stored = JSONObject(storage.pending()[operationId] ?: return null)
        require(stored.opt("identity") == identity())
        JSONObject(stored.getJSONObject("legacy").toString())
    }.getOrNull()
    fun pendingLegacy(provider: String, thread: String) = runCatching { storage.pending().keys.mapNotNull { operation ->
        context(operation)?.takeIf { it.opt("provider") == provider && it.optString("threadId") == thread && it.opt("agentAdapterId") == selectedAdapter(provider) }
    } }.getOrDefault(emptyList())

    fun pending(provider: String, thread: String): List<String> {
        val target = session(provider, thread)?.target ?: return emptyList()
        return storage.pending().keys.filter { (original(it)?.target as? SessionAgentProtocol.Target.Session)?.sessionRef == target.sessionRef }
    }
    /** Local only: the user gave up on an unknown result. The Mac journal keeps its identity, so nothing is resent. */
    fun abandon(operationId: String): Boolean = runCatching { storage.remove(operationId) }.getOrDefault(false)
    /** Reconciliation is observational. There is intentionally no automatic mutation retry method. */
    fun reconcile(operationId: String, callback: (SessionAgentProtocol.Reply) -> Unit) {
        val request = original(operationId)
        if (request == null) { callback(SessionAgentProtocol.Reply.Failure("receipt_unknown")); return }
        read(SessionAgentProtocol.Method.OPERATION, params = JSONObject().put("operationId", operationId), preserve = true) { reply ->
            val operation = (reply as? SessionAgentProtocol.Reply.Read)?.result?.optJSONObject("operation")
            if (operation == null) { callback(if (reply is SessionAgentProtocol.Reply.Failure) reply else SessionAgentProtocol.Reply.Failure("receipt_unknown")); return@read }
            // The Mac journal has no record: the request never arrived. The phone keeps its pending intent for an explicit resend.
            if (operation.opt("status") == "notFound" && operation.opt("operationId") == operationId) {
                callback(SessionAgentProtocol.Reply.Failure(NOT_FOUND)); return@read
            }
            val body = JSONObject(operation.toString()).put("agentProtocol", SessionAgentProtocol.VERSION).put("requestId", request.requestId)
            val status = body.opt("status")
            val wrapper = JSONObject().put("id", request.requestId).put("ok", status == "confirmed").put("body", body)
            if (status in setOf("accepted", "unknown")) wrapper.put("unknown", true)
            val result = SessionAgentProtocol.reply(wrapper, request) ?: SessionAgentProtocol.Reply.Failure("receipt_unknown")
            callback(settle(result))
        }
    }
    /**
     * Only for an operation the Mac reported as never received. The original body and operation ID are reused, so the
     * Mac journal deduplicates if the first copy arrives after all; only the transport request ID is new.
     */
    fun resend(operationId: String, callback: (SessionAgentProtocol.Reply) -> Unit) {
        val request = original(operationId)
        if (request == null || !negotiated) { callback(SessionAgentProtocol.Reply.Failure("receipt_unknown")); return }
        perform(request.copy(requestId = SessionAgentProtocol.id()), callback)
    }
    fun pendingOperations(): List<String> = runCatching { storage.pending().keys.filter { original(it) != null } }.getOrDefault(emptyList())
    fun late(value: JSONObject): Boolean {
        val operation = value.optJSONObject("body")?.opt("operationId") as? String ?: return false
        val request = original(operation) ?: return false
        val reply = SessionAgentProtocol.reply(value, request) ?: return false
        settle(reply); return true
    }
    companion object { const val NOT_FOUND = "receipt_not_found" }
    fun observe(subscriptionId: String, target: SessionAgentProtocol.Target.Session, streamEpoch: String, through: Long, authoritative: Boolean): Boolean {
        val observation = SessionAgentObservation(subscriptionId, target.sessionRef)
        if (!observation.snapshot(streamEpoch, through, authoritative)) return false
        observers[subscriptionId] = observation
        if (observers.size > 8) observers.keys.firstOrNull { it != subscriptionId }?.let(observers::remove)
        return true
    }
    fun unobserve(subscriptionId: String) { observers.remove(subscriptionId) }
    fun refreshObservation(subscriptionId: String, ref: String, epoch: String, through: Long): Boolean {
        val known = observers[subscriptionId]?.takeIf { it.sessionRef == ref } ?: return false
        return known.snapshot(epoch, through, true)
    }
    fun event(value: JSONObject): Boolean {
        val event = SessionAgentProtocol.event(value)
        if (event == null) {
            val raw = value.optJSONObject("body") ?: return false
            val known = observers[raw.optString("subscriptionId")] ?: return false
            if (raw.opt("agentProtocol") != SessionAgentProtocol.VERSION || raw.opt("sessionRef") != known.sessionRef) return false
            onDirty(known.sessionRef); return true
        }
        val observer = observers[event.subscriptionId] ?: return false
        when (observer.accept(event)) {
            SessionAgentObservation.Decision.IGNORE -> Unit
            SessionAgentObservation.Decision.APPLY -> if (event.data.opt("controlDirty") == false) onContentChanged(event.sessionRef) else onDirty(event.sessionRef)
            SessionAgentObservation.Decision.RESYNC -> onDirty(event.sessionRef)
        }
        return true
    }
}
