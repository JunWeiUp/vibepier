package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.os.SystemClock
import android.util.Base64
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.core.session.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Register as session-cancellation. Real SessionClient, isolated preferences/keys, AES/GCM synthetic host only. */
internal object SessionCancellationProbe {
    private const val ADAPTER = "codex.currentV1"
    private const val THREAD = "cancellation-thread"
    private const val CWD = "/fixture/cancellation"
    private const val WORKSPACE = "cancellation-workspace"
    private const val REFRESHES = 120

    private class Transport : SessionTransport {
        override val mode = "bluetooth"
        override val enrollmentReady = true
        override var onSessionFrame: (JSONObject) -> Unit = {}
        override var onSessionPair: (ByteArray?) -> Unit = {}
        var packet: (List<JSONObject>) -> Unit = {}
        private val frames = mutableMapOf<String, MutableList<JSONObject>>()
        override fun sendBinding(message: JSONObject) {
            val id = message.getString("packet")
            val parts = frames.getOrPut(id) { mutableListOf() }
            parts.add(JSONObject(message.toString()))
            if (parts.size == message.getInt("parts")) {
                frames.remove(id)
                packet(parts.sortedBy { it.getInt("part") })
            }
        }
        override fun requestSessionPair(device: String, name: String) {}
        override fun readSessionPair() {}
    }

    private class Host(private val test: Instrumentation) {
        private val prefix = "session-cancellation-${UUID.randomUUID()}"
        val context = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String?, mode: Int) =
                baseContext.getSharedPreferences("$prefix-$name", Context.MODE_PRIVATE)
        }
        val requests = CopyOnWriteArrayList<JSONObject>()
        private val failure = AtomicReference<Throwable?>()
        private val transport = Transport()
        private val keyBytes = ByteArray(32) { 71 }
        private val key = SecretKeySpec(keyBytes, "AES")
        lateinit var client: SessionClient
        private var created = false
        private val pendingField = SessionClient::class.java.getDeclaredField("pending").apply { isAccessible = true }
        private val timeoutMethod = SessionClient::class.java.declaredMethods.single {
            it.name == "timeout" && it.parameterCount == 2
        }.apply { isAccessible = true }

        fun main(block: () -> Unit) {
            var thrown: Throwable? = null
            test.runOnMainSync { try { block() } catch (error: Throwable) { thrown = error } }
            thrown?.let { throw it }
            failure.get()?.let { throw it }
        }
        fun waitFor(description: String, condition: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 6_000
            while (SystemClock.elapsedRealtime() < deadline) {
                var ready = false
                main { ready = condition() }
                if (ready) return
                SystemClock.sleep(10)
            }
            error("session-cancellation timed out: $description")
        }
        // Reflection only observes the production map; no test replacement of transport/policy/timers.
        @Suppress("UNCHECKED_CAST")
        fun pending(): Map<String, Any> = (pendingField.get(client) as Map<String, Any>).toMap()
        fun expire(id: String, original: Any) { timeoutMethod.invoke(client, id, original) }
        fun wire(method: String, after: Int): JSONObject {
            waitFor(method) { requests.drop(after).any { it.optJSONObject("body")?.opt("method") == method } }
            return requests.drop(after).first { it.optJSONObject("body")?.opt("method") == method }
        }
        fun barrier() {
            var completed = false
            main { client.request("notificationSubscribe") { check(it.opt("ok") == true); completed = true } }
            waitFor("encrypted host barrier") { completed }
        }
        fun start() {
            transport.packet = { frames -> try {
                val packet = frames.first().getString("packet")
                val sealed = Base64.decode(frames.joinToString("") { it.getString("data") }, Base64.NO_WRAP)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed.copyOfRange(0, 12)))
                cipher.updateAAD("vibepier-session-v1|phone|${client.device}|$packet".toByteArray())
                val request = JSONObject(String(cipher.doFinal(sealed.copyOfRange(12, sealed.size)), Charsets.UTF_8))
                requests.add(request)
                when (request.getString("op")) {
                    "providers" -> respond(JSONObject().put("id", request.get("id")).put("ok", true)
                        .put("providerAccess", SessionProviderAccess(1, setOf("codex")).json())
                        .put("agentCapabilities", JSONObject().put("version", 1).put("revision", "fixture-host")
                            .put("adapters", JSONArray().put(JSONObject().put("id", ADAPTER).put("provider", "codex")
                                .put("default", true).put("backendKinds", JSONArray().put("managedRuntime")).put("actions", actions()))))
                        .put("agentProfiles", JSONObject().put("versions", JSONArray().put(2)).put("minimumClientVersion", 2)
                            .put("methods", JSONArray(SessionAgentProtocol.Method.entries.map { it.wire }))))
                    "notificationSubscribe" -> respond(JSONObject().put("id", request.get("id")).put("ok", true))
                    "agentRequest" -> check(request.getString("provider") == "codex") // Explicitly held until the test answers.
                    else -> error("Unexpected synthetic request ${request.optString("op")}")
                }
            } catch (error: Throwable) { failure.compareAndSet(null, error) } }
            main {
                client = SessionClient(context, transport, 10_000); created = true
                client.provider = "codex"
                client.connectionChanged(true); client.pair()
                transport.onSessionPair(JSONObject().put("state", "approved").put("device", client.device)
                    .put("key", Base64.encodeToString(keyBytes, Base64.NO_WRAP)).toString().toByteArray())
            }
            waitFor("negotiation") { client.agent.negotiated && client.agentAdapters.size == 1 }
            barrier()
            main { check(pending().isEmpty()) { "Negotiation left pending work" } }
            var count = 0
            val before = requests.size
            main {
                client.request("list", JSONObject().put("search", "")) { check(it.opt("ok") == true); count++ }
                client.request("projects", JSONObject().put("search", "")) { check(it.opt("ok") == true); count++ }
            }
            read(wire("session.list", before), JSONObject().put("sessions", JSONArray().put(descriptor())))
            read(wire("workspace.list", before), workspace(CWD, WORKSPACE))
            waitFor("session/workspace discovery") { count == 2 }
            main { check(pending().isEmpty()) }
        }
        private fun respond(value: JSONObject) {
            val packet = UUID.randomUUID().toString()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            cipher.updateAAD("vibepier-session-v1|mac|${client.device}|$packet".toByteArray())
            val encoded = Base64.encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray()), Base64.NO_WRAP)
            val pieces = encoded.chunked(900)
            pieces.forEachIndexed { index, data -> transport.onSessionFrame(JSONObject().put("type", "vibepier-session1")
                .put("sender", client.device).put("device", client.device).put("packet", packet)
                .put("part", index).put("parts", pieces.size).put("data", data)) }
        }
        fun read(request: JSONObject, result: JSONObject) = respond(JSONObject().put("id", request.get("id")).put("ok", true)
            .put("body", JSONObject().put("agentProtocol", 2).put("requestId", request.get("id")).put("result", result)))
        fun mutationBody(request: JSONObject, status: String) = JSONObject().put("agentProtocol", 2)
            .put("requestId", request.get("id")).put("operationId", request.getJSONObject("body").get("operationId"))
            .put("target", request.getJSONObject("body").getJSONObject("target")).put("status", status)
            .put("result", JSONObject().put("code", "fixture_rejected"))
        fun mutation(request: JSONObject, status: String) = respond(JSONObject().put("id", request.get("id"))
            .put("ok", false).put("unknown", status == "unknown").put("body", mutationBody(request, status)))
        fun finish() {
            if (created) {
                // Always clean up even when a synthetic-host assertion failed.
                test.runOnMainSync { client.close() }
                DeviceKeys(context).clear()
                PrivatePreferences.open(context, "sessions").edit().clear().commit()
                context.getSharedPreferences("device-identity", Context.MODE_PRIVATE).edit().clear().commit()
            }
        }
    }

    private fun actions() = JSONObject().apply {
        SessionV1Contract.capabilityKeys.forEach { name ->
            val allowed = name in setOf("send", "new")
            put(name, JSONObject().put("supported", allowed).put("available", allowed)
                .put("reason", if (allowed) "available" else "fixture_unsupported"))
        }
    }
    private fun capabilities() = JSONObject().put("version", 1).put("adapterId", ADAPTER).put("provider", "codex")
        .put("revision", "fixture-caps").put("actions", actions())
    private fun descriptor() = JSONObject().put("adapterId", ADAPTER).put("nativeThreadId", THREAD)
        .put("sessionRef", "fixture-session").put("ownershipEpoch", "fixture-owner").put("capabilityRevision", "fixture-caps")
    private fun workspace(cwd: String, ref: String) = JSONObject().put("workspaces", JSONArray().put(JSONObject()
        .put("cwd", cwd).put("workspaceRef", ref).put("adapterId", ADAPTER))).put("nextOffset", -1)
    private fun snapshot() = JSONObject().put("session", descriptor()).put("controlLease", "fixture-lease")
        .put("snapshot", JSONObject().put("provider", "codex").put("threadId", THREAD).put("contentState", "complete")
            .put("status", "idle").put("canSend", true).put("messages", JSONArray()).put("queuedMessages", JSONArray())
            .put("agentCapabilities", capabilities()))
    private fun fields(cwd: String = CWD) = JSONObject().put("id", SessionAgentProtocol.id()).put("provider", "codex")
        .put("cwd", cwd).put("draftId", SessionAgentProtocol.id()).put("text", "synthetic cancellation fixture")
    private fun options(request: JSONObject): JSONObject {
        val params = request.getJSONObject("body").getJSONObject("params")
        val draft = params.getString("draftId")
        return JSONObject().put("options", JSONObject().put("creationVersion", 1).put("draftId", draft).put("cwd", CWD)
            .put("composer", JSONObject().put("model", "fixture-model").put("mode", "auto").put("effort", "medium"))
            .put("models", JSONArray().put(JSONObject().put("id", "fixture-model").put("efforts", JSONArray().put("medium"))))
            .put("permissionModes", JSONArray().put(JSONObject().put("id", "auto"))).put("agentCapabilities", capabilities()))
            .put("creationLease", JSONObject().put("controlLease", "fixture-creation-lease").put("target", JSONObject()
                .put("adapterId", ADAPTER).put("workspaceRef", params.get("workspaceRef")).put("draftId", draft)
                .put("optionsRevision", "fixture-options")))
    }

    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val host = Host(test)
        try {
            host.start()
            preparedSendAndReceipt(host)
            preparedCreation(host)
            cancelledWorkspace(host)
            pageCancelledOptionsCanReload(host)
            cancelledOptionsStress(host)
            host.barrier()
            host.main { check(host.pending().isEmpty()) { "Probe leaked pending transport work" } }
            return "PASS: session-cancellation; production Android SessionClient pending; prepared send/create and receipt survive page cancellation and callback exactly once; ordinary reads cancelled; logical options ID cancels v2 wire ID; unresolved workspace late reply cannot start options; explicit options reload after page cancellation succeeds; 120 encrypted refresh/cancel cycles stay below capacity; cancelled timers do not retry. Synthetic AES/GCM host only, no real agent or device configuration."
        } finally { host.finish() }
    }

    private fun preparedSendAndReceipt(host: Host) {
        val before = host.requests.size
        var sends = 0; var ordinary = 0
        host.main {
            host.client.request("send", JSONObject().put("threadId", THREAD).put("text", "synthetic send")) {
                check(it.opt("unknown") == true); sends++
            }
            host.client.request("list", JSONObject().put("search", "ordinary")) { ordinary++ }
        }
        val prepared = host.wire("session.snapshot", before)
        val disposable = host.wire("session.list", before)
        val preparedId = prepared.getString("id"); val disposableId = disposable.getString("id")
        lateinit var preparedTimer: Any; lateinit var disposableTimer: Any
        host.main {
            preparedTimer = host.pending().getValue(preparedId); disposableTimer = host.pending().getValue(disposableId)
            host.client.cancelPageReads()
            check(host.pending().keys == setOf(preparedId)) { "Prepared snapshot lost, or ordinary read retained" }
            host.expire(disposableId, disposableTimer)
        }
        host.read(disposable, JSONObject().put("sessions", JSONArray().put(descriptor())))
        host.read(prepared, snapshot())
        val submit = host.wire("message.submit", before)
        host.mutation(submit, "unknown")
        host.waitFor("send callback") { sends == 1 }
        val receiptStart = host.requests.size
        var receipts = 0
        host.main {
            host.client.agent.reconcile(submit.getJSONObject("body").getString("operationId")) {
                check(it is SessionAgentProtocol.Reply.Mutation && it.status == SessionAgentProtocol.Status.REJECTED)
                receipts++
            }
        }
        val receipt = host.wire("operation.get", receiptStart)
        val receiptId = receipt.getString("id")
        lateinit var receiptTimer: Any
        host.main {
            receiptTimer = host.pending().getValue(receiptId)
            host.client.cancelPageReads()
            check(host.pending().keys == setOf(receiptId)) { "Receipt read lost" }
        }
        val receiptResult = JSONObject().put("operation", host.mutationBody(submit, "rejected"))
        host.read(receipt, receiptResult)
        host.waitFor("receipt callback") { receipts == 1 }
        host.read(prepared, snapshot()); host.read(receipt, receiptResult) // Fresh encrypted packets, duplicate application replies.
        host.main { host.expire(preparedId, preparedTimer); host.expire(receiptId, receiptTimer) }
        host.barrier()
        host.main {
            check(sends == 1 && receipts == 1 && ordinary == 0) { "Callback lost or delivered more than once" }
            check(host.client.agent.pendingOperations().isEmpty()) { "Rejected synthetic receipt was not settled" }
            for (wire in listOf(prepared, disposable, submit, receipt)) {
                check(host.requests.count { it.opt("id") == wire.opt("id") } == 1) { "Cancelled/completed read retried" }
            }
        }
    }

    private fun preparedCreation(host: Host) {
        val before = host.requests.size
        var callbacks = 0
        host.main { host.client.request("new", fields()) { check(it.optString("code") == "fixture_rejected"); callbacks++ } }
        val prepared = host.wire("session.creationOptions", before)
        val id = prepared.getString("id")
        lateinit var timer: Any
        host.main {
            timer = host.pending().getValue(id)
            host.client.cancelPageReads()
            check(host.pending().keys == setOf(id)) { "Creation preparation was cancelled as UI options" }
        }
        host.read(prepared, options(prepared))
        val creation = host.wire("session.create", before)
        host.mutation(creation, "rejected")
        host.waitFor("creation callback") { callbacks == 1 }
        host.read(prepared, options(prepared)); host.mutation(creation, "rejected")
        host.main { host.expire(id, timer) }
        host.barrier()
        host.main {
            check(callbacks == 1 && host.pending().isEmpty())
            check(host.requests.drop(before).count { it.optJSONObject("body")?.opt("method") == "session.create" } == 1)
        }
    }

    private fun cancelledWorkspace(host: Host) {
        val before = host.requests.size
        val intent = fields("/fixture/unresolved-cancellation")
        val logicalId = intent.getString("id")
        var callbacks = 0
        host.main { check(host.client.request("newOptions", intent) { callbacks++ } == logicalId) }
        val wire = host.wire("workspace.list", before)
        val wireId = wire.getString("id")
        check(wireId != logicalId)
        host.main {
            val timer = host.pending().getValue(wireId)
            host.client.cancelCreationOptions(logicalId)
            check(host.pending().isEmpty()) { "Logical cancellation left workspace wire pending" }
            host.expire(wireId, timer)
        }
        host.read(wire, workspace(intent.getString("cwd"), "late-workspace"))
        host.barrier()
        host.main {
            check(callbacks == 0 && host.pending().isEmpty())
            check(host.client.agent.workspace("codex", intent.getString("cwd")) == null)
            check(host.requests.drop(before).count { it.opt("op") == "agentRequest" } == 1) { "Late workspace response started follow-up read" }
        }
    }

    /** The UI owns when to reload. The client must permit a fresh read of the same draft after page cancellation. */
    private fun pageCancelledOptionsCanReload(host: Host) {
        val before = host.requests.size
        val intent = fields()
        var oldCallbacks = 0; var freshCallbacks = 0
        host.main { host.client.request("newOptions", intent) { oldCallbacks++ } }
        val old = host.wire("session.creationOptions", before)
        val oldId = old.getString("id")
        lateinit var oldTimer: Any
        host.main {
            oldTimer = host.pending().getValue(oldId)
            host.client.cancelPageReads()
            check(host.pending().isEmpty()) { "Page cancellation retained UI options" }
            host.client.cancelPageReads() // A second navigation/capability refresh cancellation is idempotent.
        }
        val freshStart = host.requests.size
        val freshIntent = JSONObject(intent.toString()).put("id", SessionAgentProtocol.id())
        host.main {
            host.client.request("newOptions", freshIntent) {
                check(it.opt("ok") == true && it.optString("draftId") == intent.getString("draftId"))
                freshCallbacks++
            }
        }
        val fresh = host.wire("session.creationOptions", freshStart)
        val freshId = fresh.getString("id")
        check(freshId != oldId)
        host.read(old, options(old)) // The obsolete response arrives while the replacement is pending.
        host.main {
            host.expire(oldId, oldTimer)
            host.client.cancelCreationOptions(intent.getString("id"))
            check(oldCallbacks == 0 && freshCallbacks == 0)
            check(host.pending().keys == setOf(freshId)) { "Old scope interfered with the replacement read" }
        }
        host.read(fresh, options(fresh))
        host.waitFor("explicit options reload after page cancellation") { freshCallbacks == 1 }
        host.read(old, options(old)); host.read(fresh, options(fresh))
        host.barrier()
        host.main {
            check(oldCallbacks == 0 && freshCallbacks == 1 && host.pending().isEmpty())
            val reads = host.requests.drop(before).filter { it.opt("op") == "agentRequest" }
            check(reads.size == 2 && reads.all { it.getJSONObject("body").opt("method") == "session.creationOptions" }) {
                "Reload retried an old read or triggered mutation"
            }
        }
    }

    private fun cancelledOptionsStress(host: Host) {
        val before = host.requests.size
        var cancelledCallbacks = 0
        repeat(REFRESHES) { iteration ->
            val start = host.requests.size
            val intent = fields()
            val logicalId = intent.getString("id")
            host.main {
                check(host.client.request("newOptions", intent) { cancelledCallbacks++ } == logicalId)
                check(cancelledCallbacks == 0) { "Refresh $iteration failed synchronously (possibly pending capacity)" }
            }
            val wire = host.wire("session.creationOptions", start)
            val wireId = wire.getString("id")
            check(wireId != logicalId)
            host.main {
                check(host.pending().keys == setOf(wireId)) { "Refresh $iteration accumulated pending requests" }
                val timer = host.pending().getValue(wireId)
                host.client.cancelCreationOptions(logicalId)
                check(host.pending().isEmpty()) { "Refresh $iteration did not remove actual v2 pending" }
                host.expire(wireId, timer)
            }
            host.read(wire, options(wire)) // Even a valid late response must not complete a cancelled UI read.
        }
        host.barrier()
        host.main {
            check(cancelledCallbacks == 0)
            check(host.requests.drop(before).count { it.optJSONObject("body")?.opt("method") == "session.creationOptions" } == REFRESHES)
        }
        val lastStart = host.requests.size
        var completed = 0
        host.main { host.client.request("newOptions", fields()) { check(it.opt("ok") == true); completed++ } }
        val latest = host.wire("session.creationOptions", lastStart)
        host.read(latest, options(latest))
        host.waitFor("fresh options after cancellation stress") { completed == 1 }
        host.read(latest, options(latest))
        host.barrier()
        host.main { check(completed == 1 && cancelledCallbacks == 0 && host.pending().isEmpty()) }
    }
}
