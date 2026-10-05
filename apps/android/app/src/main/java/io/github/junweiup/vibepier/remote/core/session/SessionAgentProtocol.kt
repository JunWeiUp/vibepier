package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

/** Profile 2 is a business contract inside the existing authenticated session envelope. */
internal object SessionAgentProtocol {
    const val VERSION = 2
    enum class Method(val wire: String, val mutation: Boolean = false) {
        DESCRIBE("agent.describe"), WORKSPACES("workspace.list"), LIST("session.list"),
        OPEN("session.open"), SNAPSHOT("session.snapshot"), ITEMS("session.items"),
        OBSERVE("session.observe"), UNOBSERVE("session.unobserve"), CREATION_OPTIONS("session.creationOptions"),
        CREATE("session.create", true), CONFIGURE("session.configure", true), SUBMIT("message.submit", true),
        CANCEL_QUEUE("queue.cancel", true), STEER_QUEUE("queue.steer", true), INTERRUPT("turn.interrupt", true),
        RESOLVE_APPROVAL("approval.resolve", true), ANSWER_QUESTION("question.answer", true),
        OPERATION("operation.get");
        companion object { fun parse(value: Any?) = entries.singleOrNull { it.wire == value } }
    }

    data class Profile(val methods: Set<Method>) {
        companion object {
            fun decode(value: JSONObject?): Profile? = runCatching {
                val raw = value ?: error("Missing profile")
                val versions = raw.getJSONArray("versions")
                require((0 until versions.length()).all { versions.opt(it) is Int })
                require((0 until versions.length()).any { versions.opt(it) == VERSION })
                val minimum = integer(raw.opt("minimumClientVersion")) ?: error("Invalid minimum version")
                require(minimum in 1..VERSION)
                val names = raw.getJSONArray("methods")
                require(names.length() in 1..Method.entries.size)
                val methods = (0 until names.length()).map { Method.parse(names.opt(it)) ?: error("Unknown method") }
                require(methods.distinct().size == methods.size)
                require(setOf(Method.DESCRIBE, Method.LIST, Method.OPEN, Method.SNAPSHOT, Method.OPERATION).all { it in methods })
                Profile(methods.toSet())
            }.getOrNull()
        }
    }

    sealed interface Target {
        fun json(): JSONObject
        data class Adapter(val adapterId: String) : Target {
            override fun json() = JSONObject().put("adapterId", adapterId)
        }
        data class Session(val sessionRef: String, val ownershipEpoch: String, val capabilityRevision: String) : Target {
            override fun json() = JSONObject().put("sessionRef", sessionRef).put("ownershipEpoch", ownershipEpoch)
                .put("capabilityRevision", capabilityRevision)
        }
        data class Creation(val adapterId: String, val workspaceRef: String, val draftId: String, val optionsRevision: String) : Target {
            override fun json() = JSONObject().put("adapterId", adapterId).put("workspaceRef", workspaceRef)
                .put("draftId", draftId).put("optionsRevision", optionsRevision)
        }
    }

    data class Request(val requestId: String, val method: Method, val target: Target?, val params: JSONObject,
                       val operationId: String? = null, val controlLease: String? = null) {
        init {
            require(SessionResponseInbox.uuid(requestId))
            require(if (method.mutation) operationId?.let(SessionResponseInbox::uuid) == true && !controlLease.isNullOrBlank()
                else operationId == null && controlLease == null)
            require(!method.mutation || target is Target.Session || target is Target.Creation)
            require(method != Method.CREATE || target is Target.Creation)
            require(method == Method.CREATE || target !is Target.Creation)
            require(params.keys().asSequence().all { it in parameters.getValue(method) })
            if (params.has("refreshOptions")) {
                require(params.opt("refreshOptions") is Boolean)
                require(method == Method.CREATION_OPTIONS || method == Method.ITEMS && params.opt("kind") == "composerOptions")
            }
            if (params.has("options")) {
                val options = params.getJSONObject("options")
                require(options.keys().asSequence().all { it in setOf("model", "mode", "effort", "executionMode", "serviceTier", "confirmation") })
                for (key in listOf("model", "mode", "effort", "executionMode", "serviceTier")) if (options.has(key)) require(options.opt(key) is String)
                if (options.has("serviceTier")) require(method in setOf(Method.CONFIGURE, Method.CREATE) && options.opt("serviceTier") in setOf("standard", "priority"))
                if (options.has("executionMode")) require(options.opt("executionMode") in SessionExecutionModes.ids)
                if (options.has("confirmation")) require(options.opt("confirmation") is Boolean)
            }
            require(canonical(json()).toByteArray(Charsets.UTF_8).size <= 256 * 1024)
        }
        fun json() = JSONObject().put("agentProtocol", VERSION).put("requestId", requestId).put("method", method.wire)
            .put("params", JSONObject(params.toString())).apply {
                // Profile 2 requires an object even for host-wide reads such as operation.get.
                // An empty read target conveys no session identity or write authority.
                put("target", target?.json() ?: JSONObject())
                operationId?.let { put("operationId", it) }
                controlLease?.let { put("controlLease", it) }
            }
    }

    private val parameters = mapOf(
        Method.DESCRIBE to emptySet(), Method.WORKSPACES to setOf("search", "offset", "limit"),
        Method.LIST to setOf("search", "offset", "limit", "workspaceRef"), Method.OPEN to emptySet(), Method.SNAPSHOT to emptySet(),
        Method.ITEMS to setOf("kind", "messageId", "before", "offset", "limit", "headersOnly", "sequence", "refreshOptions"),
        Method.OBSERVE to setOf("subscriptionId", "streamEpoch", "afterSequence"), Method.UNOBSERVE to setOf("subscriptionId"),
        Method.CREATION_OPTIONS to setOf("workspaceRef", "draftId", "refreshOptions"), Method.CREATE to setOf("initialMessage", "options"),
        Method.CONFIGURE to setOf("options"), Method.SUBMIT to setOf("mode", "content", "expectedTurnId"),
        Method.CANCEL_QUEUE to setOf("queueId"), Method.STEER_QUEUE to setOf("queueId", "expectedTurnId"),
        Method.INTERRUPT to setOf("expectedTurnId"),
        Method.RESOLVE_APPROVAL to setOf("approvalId", "fingerprint", "revision", "decision"),
        Method.ANSWER_QUESTION to setOf("questionId", "fingerprint", "revision", "answers"), Method.OPERATION to setOf("operationId"),
    )

    enum class Status(val wire: String) { REJECTED("rejected"), ACCEPTED("accepted"), CONFIRMED("confirmed"), UNKNOWN("unknown") }
    sealed interface Reply {
        data class Read(val result: JSONObject) : Reply
        data class Failure(val code: String, val diagnostic: String? = null) : Reply
        data class Mutation(val status: Status, val operationId: String, val target: JSONObject?, val result: JSONObject, val body: JSONObject) : Reply
    }

    fun reply(value: JSONObject, request: Request): Reply? = runCatching {
        require(value.opt("id") == request.requestId && SessionResponseInbox.validMessage(value))
        val body = value.getJSONObject("body")
        require(body.opt("agentProtocol") == VERSION && body.opt("requestId") == request.requestId)
        if (!request.method.mutation) {
            require(!body.has("operationId") && !body.has("status"))
            if (value.opt("ok") != true) return@runCatching Reply.Failure(value.optString("code", "agent_protocol_invalid"), body.opt("error") as? String)
            return@runCatching Reply.Read(JSONObject(body.getJSONObject("result").toString()))
        }
        require(body.opt("operationId") == request.operationId)
        val status = Status.entries.singleOrNull { it.wire == body.opt("status") } ?: error("Unknown status")
        require(when (status) {
            Status.CONFIRMED -> value.opt("ok") == true && value.opt("unknown") != true
            Status.REJECTED -> value.opt("ok") == false && value.opt("unknown") != true
            else -> value.opt("ok") == false && value.opt("unknown") == true
        })
        val target = body.optJSONObject("target")
        if (request.target is Target.Session) {
            require(target?.opt("sessionRef") == request.target.sessionRef && target.opt("ownershipEpoch") == request.target.ownershipEpoch)
        }
        if (request.target is Target.Creation) {
            val original = request.target.json()
            require(target != null && original.keys().asSequence().all { target.opt(it) == original.opt(it) })
        }
        val result = body.optJSONObject("result") ?: JSONObject()
        if (status == Status.CONFIRMED) require(confirmed(request, body.opt("effect"), target, result))
        Reply.Mutation(status, request.operationId!!, target, JSONObject(result.toString()), JSONObject(body.toString()))
    }.getOrNull()

    private fun confirmed(request: Request, effect: Any?, target: JSONObject?, result: JSONObject): Boolean {
        fun evidence(key: String) = SessionAgentCapabilities.opaque(result.opt(key)) != null
        return when (request.method) {
            Method.SUBMIT -> if (request.params.opt("mode") == "queue") effect == "message.queued" && evidence("queueId")
                else effect == "message.submitted" && evidence("nativeMessageId") && evidence("turnId") &&
                    result.opt("turnIdentityKind") in setOf("nativeTurn", "nativeMessageAnchor", "managedRun")
            Method.CREATE -> effect == "session.created" && result.opt("sessionCreated") == true &&
                result.opt("initialInput") == (if (request.params.has("initialMessage")) "confirmed" else "none") &&
                // Native thread and turn identities prove creation; option readback mismatches arrive as warnings.
                (request.params.optJSONObject("options")?.takeIf { it.has("executionMode") }?.let {
                    result.opt("executionMode") == it.opt("executionMode")
                } ?: true) &&
                result.optJSONObject("session")?.let { session ->
                    SessionAgentCapabilities.opaque(session.opt("sessionRef")) != null &&
                        SessionAgentCapabilities.opaque(session.opt("nativeThreadId")) != null &&
                        session.opt("adapterId") == (request.target as? Target.Creation)?.adapterId &&
                        session.opt("workspaceRef") == (request.target as? Target.Creation)?.workspaceRef
                } == true
            Method.CONFIGURE -> effect == "session.configured" && result.optJSONObject("effectiveOptions")?.let { effective ->
                val requested = request.params.optJSONObject("options") ?: return@let false
                val fields = requested.keys().asSequence().filter { it != "confirmation" }.toList()
                fields.isNotEmpty() && fields.all { requested.opt(it) is String && effective.opt(it) == requested.opt(it) }
            } == true
            Method.CANCEL_QUEUE -> effect == "queue.cancelled" && result.opt("queueId") == request.params.opt("queueId")
            Method.STEER_QUEUE -> effect == "queue.steered" && result.opt("queueId") == request.params.opt("queueId") && result.opt("steered") == true
            Method.INTERRUPT -> effect == "turn.interruptRequested" && evidence("turnId") && result.opt("turnId") == request.params.opt("expectedTurnId")
            Method.RESOLVE_APPROVAL -> effect == "approval.resolved" && result.opt("approvalId") == request.params.opt("approvalId") &&
                evidence("fingerprint") && result.opt("fingerprint") == request.params.opt("fingerprint") && result.opt("submitted") == true
            Method.ANSWER_QUESTION -> effect == "question.answered" && result.opt("questionId") == request.params.opt("questionId") &&
                evidence("fingerprint") && result.opt("fingerprint") == request.params.opt("fingerprint") && result.opt("submitted") == true
            else -> false
        }
    }

    data class Event(val subscriptionId: String, val sessionRef: String, val streamEpoch: String, val sequence: Long,
                     val kind: String, val entityRevision: Long, val data: JSONObject)
    val eventKinds = setOf("session.stateChanged", "capabilities.changed", "turn.started", "turn.updated", "turn.completed",
        "turn.failed", "turn.interrupted", "item.updated", "approval.opened", "approval.resolved", "question.opened",
        "question.resolved", "operation.updated", "resync.required")
    fun event(value: JSONObject): Event? = runCatching {
        require(value.opt("event") == "agentEvent")
        val body = value.getJSONObject("body")
        require(body.opt("agentProtocol") == VERSION)
        fun opaque(key: String) = SessionAgentCapabilities.opaque(body.opt(key)) ?: error("Invalid identity")
        val sequence = integer(body.opt("sequence"))?.takeIf { it > 0 } ?: error("Invalid sequence")
        val revision = integer(body.opt("entityRevision")) ?: error("Invalid revision")
        val kind = body.opt("event") as? String ?: error("Invalid event")
        require(kind in eventKinds)
        Event(opaque("subscriptionId"), opaque("sessionRef"), opaque("streamEpoch"), sequence, kind, revision,
            JSONObject(body.getJSONObject("data").toString()))
    }.getOrNull()

    internal fun integer(value: Any?): Long? = when (value) {
        is Int -> value.toLong().takeIf { it >= 0 }
        is Long -> value.takeIf { it >= 0 }
        else -> null
    }
    /** Scalar-key ordering and finite safe integers match the Mac's committed canonical vectors. */
    fun canonical(value: Any?, depth: Int = 0): String {
        require(depth <= 16)
        val result = when (value) {
            null, JSONObject.NULL -> "null"
            is String -> JSONObject.quote(value).replace("\\/", "/")
            is Boolean -> value.toString()
            is Number -> {
                val number = value.toDouble()
                require(number.isFinite() && kotlin.math.abs(number) <= 9_007_199_254_740_991.0 && number.toLong().toDouble() == number)
                number.toLong().toString()
            }
            is JSONArray -> {
                require(value.length() <= 4096)
                (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it), depth + 1) }
            }
            is JSONObject -> {
                val keys = value.keys().asSequence().toList()
                require(keys.size <= 4096 && keys.all { it.toByteArray(Charsets.UTF_8).size <= 256 })
                keys.sortedWith { a, b ->
                    val left = a.codePoints().toArray(); val right = b.codePoints().toArray()
                    val mismatch = (0 until minOf(left.size, right.size)).firstOrNull { left[it] != right[it] }
                    if (mismatch == null) left.size.compareTo(right.size) else left[mismatch].compareTo(right[mismatch])
                }.joinToString(",", "{", "}") { canonical(it, depth + 1) + ":" + canonical(value.get(it), depth + 1) }
            }
            else -> error("Unsupported canonical value")
        }
        require(result.toByteArray(Charsets.UTF_8).size <= 256 * 1024)
        return result
    }
    fun fingerprint(body: JSONObject): String {
        val semantic = JSONObject(body.toString()).apply { remove("requestId"); remove("controlLease") }
        return MessageDigest.getInstance("SHA-256").digest(canonical(semantic).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
    fun id() = UUID.randomUUID().toString()
}

/** A gap or epoch change requests an authoritative refresh; events never clear an unknown operation. */
internal class SessionAgentObservation(val subscriptionId: String, val sessionRef: String) {
    enum class Decision { APPLY, IGNORE, RESYNC }
    private var epoch: String? = null
    private var through = 0L
    private val revisions = linkedMapOf<String, Long>()
    var needsSnapshot = true; private set
    fun snapshot(streamEpoch: String, throughSequence: Long, authoritative: Boolean): Boolean {
        if (!authoritative || SessionAgentCapabilities.opaque(streamEpoch) == null || throughSequence < 0) return false
        epoch = streamEpoch; through = throughSequence; revisions.clear(); needsSnapshot = false; return true
    }
    fun accept(event: SessionAgentProtocol.Event): Decision {
        if (event.subscriptionId != subscriptionId || event.sessionRef != sessionRef) return Decision.IGNORE
        if (needsSnapshot || event.streamEpoch != epoch || event.kind == "resync.required" || through == Long.MAX_VALUE || event.sequence > through + 1) {
            needsSnapshot = true; return Decision.RESYNC
        }
        if (event.sequence <= through) return Decision.IGNORE
        through = event.sequence
        val entity = event.data.optString("itemId").ifBlank { event.data.optString("turnId").ifBlank { event.data.optString("approvalId").ifBlank { event.kind } } }
        val prior = revisions[entity]
        if (prior != null && event.entityRevision <= prior) return Decision.IGNORE
        revisions[entity] = event.entityRevision
        if (revisions.size > 1024) { needsSnapshot = true; return Decision.RESYNC }
        return Decision.APPLY
    }
}
