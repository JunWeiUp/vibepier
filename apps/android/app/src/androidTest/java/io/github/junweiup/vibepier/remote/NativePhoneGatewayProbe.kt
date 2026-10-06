package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.os.Looper
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import org.json.JSONArray
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** No registration here. Main runner calls run(test, true) only after explicit emulator authorization.
 * Bootstrap: run-as <review-package> sh -c 'umask 077; cat > files/native-phone-bootstrap.json'
 * Feed Mac bootstrap.json through stdin, never an instrumentation argument/log/shared storage.
 * Forward the bootstrap port using adb -s <verified-emulator> reverse tcp:<port> tcp:<port>.
 * This is a real bridge read probe, not a fake peer: native failures remain failures.
 */
object NativePhoneGatewayProbe {
    fun run(test: Instrumentation, explicitlyAuthorized: Boolean): String {
        NativePhoneAuthorizationGuard.verifyPolicy()
        check(explicitlyAuthorized) { "Explicit native phone probe authorization required" }
        check(Looper.myLooper() != Looper.getMainLooper())
        check(Build.VERSION.SDK_INT == 37 &&
            (Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish")) { "Only authorized API37 emulator supported" }
        check(test.targetContext.packageName.endsWith(".review")) { "Review application required" }
        val file = File(test.targetContext.filesDir, "native-phone-bootstrap.json")
        val stat = Os.lstat(file.path)
        check(OsConstants.S_ISREG(stat.st_mode) && stat.st_uid == android.os.Process.myUid() &&
            stat.st_mode and 511 == 384 && stat.st_size in 1..8192) { "Private 0600 bootstrap required" }
        val bootstrap = file.inputStream().use { input ->
            val bytes = input.readNBytes(8193)
            check(bytes.size <= 8192)
            try { JSONObject(String(bytes, Charsets.UTF_8)) } finally { bytes.fill(0) }
        }
        check(file.delete()) { "Bootstrap must be consumed exactly once" }
        check(bootstrap.getInt("version") == 1)
        val mode = bootstrap.getString("mode")
        check(mode in setOf("onlyoptions", "create-send", "inspect")) { "Unsupported host mode" }
        val inspection = mode == "inspect"
        val lifecycle = mode != "onlyoptions"
        val device = UUID.fromString(bootstrap.getString("device")).toString()
        val port = bootstrap.getInt("port").also { check(it in 1024..65535) }
        val refs = bootstrap.getJSONObject("workspaces")
        val selectedProviders = providers(bootstrap)
        val namespace = "native-phone-$device"
        val directory = File(test.targetContext.filesDir, namespace)
        if (inspection) {
            check(directory.isDirectory) { "Original test namespace missing; cannot substitute a fresh identity" }
        } else check(!directory.exists() && directory.mkdir()) { "Cannot reuse a prior test identity" }
        val context = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getPackageName(): String = "${baseContext.packageName}.$namespace"
            override fun getFilesDir(): File = directory
            override fun getCacheDir(): File = File(directory, "cache").apply { mkdirs() }
            override fun getSharedPreferences(name: String?, mode: Int) =
                baseContext.getSharedPreferences("$namespace-$name", Context.MODE_PRIVATE)
        }
        val identityPreferences = context.getSharedPreferences("device-identity", Context.MODE_PRIVATE)
        if (inspection) check(identityPreferences.getString("device", null) == device) { "Original identity mismatch" }
        else check(identityPreferences.edit().putString("device", device).commit())
        val keys = DeviceKeys(context)
        var installedAuthorizationHere = false
        if (inspection) {
            check(keys.device == device && keys.authorized) { "Original Keystore authorization missing; no reenrollment" }
        } else {
            check(!keys.authorized) { "Refusing to replace an existing authorization" }
            val secret = Base64.decode(bootstrap.getString("key"), Base64.NO_WRAP)
            bootstrap.remove("key")
            if (lifecycle) {
                // This file has no raw pairing key. DeviceKeys keeps the test identity's non-exportable aliases.
                privateRecord(directory, "recovery.json", JSONObject().put("device", device)
                    .put("namespace", namespace).put("mode", mode).put("authorizationRetained", true)
                    .put("operations", bootstrap.getJSONObject("operations"))
                    .put("crossProcessRecoverySupported", false).put("automaticResubmit", false)
                    .put("state", "unresolved-until-receipts-inspected")
                    .put("boundary", "Do not reinstall, clear test app data/Keystore, reimport bootstrap, or use a new identity to retry. Listener and leases expire; cross-process query resume is not implemented.")
                    .put("cleanup", "Manual only after all original operation IDs are confirmed."))
            }
            try {
                check(secret.size == 32)
                keys.install(secret)
                installedAuthorizationHere = true
            } finally { secret.fill(0) }
        }
        val transport = TcpTransport(port, lifecycle, device)
        var client: SessionClient? = null
        fun main(action: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { action() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
        }
        try {
            val negotiated = CountDownLatch(1)
            main {
                client = SessionClient(context, transport, if (lifecycle) 100_000 else 50_000)
                check(client!!.device == device && client!!.paired)
                client!!.onEvent = { if (it.optString("event") == "agentCapabilitiesChanged") negotiated.countDown() }
            }
            transport.start()
            main { client!!.connectionChanged(true) }
            check(negotiated.await(20, TimeUnit.SECONDS)) { transport.diagnostic("negotiation_timeout") }
            main { check(client!!.agentCapabilitiesKnown && client!!.agent.negotiated) { transport.diagnostic("negotiation_rejected") } }
            if (inspection) {
                inspectOriginal(bootstrap, directory, { action -> main(action) }, { client!! })
                return "PASS: native-phone-gateway: providers=${selectedProviders.joinToString(",")} original confirmed session inspected read-only; no mutation resume"
            }
            val catalogs = mutableMapOf<String, JSONObject>()
            for (provider in selectedProviders) {
                val id = UUID.randomUUID().toString()
                val body = JSONObject().put("agentProtocol", 2).put("requestId", id)
                    .put("method", "session.creationOptions")
                    .put("target", JSONObject().put("adapterId", "$provider.currentV1"))
                    .put("params", JSONObject().put("workspaceRef", refs.getString(provider))
                        .put("draftId", UUID.randomUUID().toString()))
                val received = CountDownLatch(1)
                val reply = AtomicReference<JSONObject>()
                main {
                    client!!.request("agentRequest", JSONObject().put("id", id).put("provider", provider).put("body", body)) {
                        reply.set(it); received.countDown()
                    }
                }
                check(received.await(55, TimeUnit.SECONDS)) { "Native options timeout; no retry" }
                val response = checkNotNull(reply.get())
                // Never include native errors, paths, reply bodies or secrets in assertion output.
                check(response.opt("ok") == true) { "Native options rejected; inspect prerequisite locally" }
                val result = response.getJSONObject("body").getJSONObject("result")
                catalogs[provider] = result
                val options = result.getJSONObject("options")
                check(options.getInt("creationVersion") == 1)
                check(options.getString("draftId") == body.getJSONObject("params").getString("draftId"))
                check(options.optJSONArray("models")?.length()?.let { it > 0 } == true) { "No native models returned" }
            }
            if (lifecycle) {
                runLifecycle(bootstrap, directory, catalogs, { action -> main(action) }, { client!! })
                privateRecord(directory, "lifecycle-confirmed.json", JSONObject()
                    .put("status", "confirmed-and-snapshot-verified").put("providers", JSONArray(selectedProviders)).put("authorizationRetained", true)
                    .put("crossProcessRecoverySupported", false).put("cleanup", "manual-after-host-receipt-inspection"))
                return "PASS: native-phone-gateway: providers=${selectedProviders.joinToString(",")} real create/send receipts and native message snapshots verified; authorization retained; approvals untested"
            }
            return "PASS: native-phone-gateway: providers=${selectedProviders.joinToString(",")} real encrypted models/options passed; no mutations"
        } finally {
            try { main { client?.close() } } finally {
                try { transport.close() } finally {
                    // Never destroy the binding for an unresolved mutation. Success still needs host inspection.
                    if (!lifecycle && !inspection) {
                        NativePhoneAuthorizationGuard.release(mode, lifecycle, inspection, installedAuthorizationHere) {
                            keys.clear()
                        }
                    }
                }
            }
        }
    }

    private fun providers(bootstrap: JSONObject): List<String> {
        val values = bootstrap.getJSONArray("providers")
        check(values.length() in 1..2)
        val providers = (0 until values.length()).map { values.getString(it) }
        check(providers.distinct().size == providers.size && providers.all { it in setOf("codex", "claude") })
        check(providers.all { bootstrap.getJSONObject("workspaces").has(it) && bootstrap.getJSONObject("operations").has(it) })
        return providers
    }

    private fun messageMatches(row: JSONObject, provider: String, id: String, text: String): Boolean =
        row.optString(if (provider == "codex") "clientId" else "id") == id &&
            row.optString("role") == "user" && row.optString("text") == text

    private fun snapshotSummary(provider: String, page: JSONObject, result: JSONObject,
                                expected: List<Pair<String, String>>): JSONObject {
        val rows = page.optJSONArray("messages") ?: JSONArray()
        val identityField = if (provider == "codex") "clientId" else "id"
        val identities = expected.all { (id, _) -> (0 until rows.length()).any {
            rows.getJSONObject(it).optString(identityField) == id && rows.getJSONObject(it).optString("role") == "user"
        } }
        val matches = expected.all { (id, text) -> (0 until rows.length()).any {
            messageMatches(rows.getJSONObject(it), provider, id, text)
        } }
        return JSONObject().put("status", page.optString("status").takeIf { it in setOf("idle", "active", "interrupted", "error") } ?: "other")
            .put("contentState", page.optString("contentState").takeIf { it in setOf("complete", "partial") } ?: "other")
            .put("idle", page.optString("status") == "idle").put("contentComplete", page.optString("contentState") == "complete")
            .put("clientIdMatch", identities).put("messageMatch", matches).put("messageCount", rows.length())
            .put("expectedMessageCount", expected.size).put("hasOlder", page.optBoolean("hasOlder"))
            .put("controlLeasePresent", result.optString("controlLease").isNotBlank())
    }

    /** Snapshots contain only the newest turn. Earlier expected messages require real paginated history. */
    private fun historyMatches(provider: String, thread: String, page: JSONObject,
                               expected: List<Pair<String, String>>, read: (String) -> JSONObject,
                               record: (Int, JSONObject) -> Unit): Boolean {
        val matched = mutableSetOf<Int>()
        fun remember(rows: JSONArray) {
            expected.forEachIndexed { index, (id, text) ->
                if ((0 until rows.length()).any { messageMatches(rows.getJSONObject(it), provider, id, text) }) matched.add(index)
            }
        }
        var rows = page.optJSONArray("messages") ?: JSONArray()
        remember(rows)
        var older = page.optBoolean("hasOlder")
        val cursors = mutableSetOf<String>()
        repeat(4) { number ->
            if (matched.size == expected.size) return true
            if (!older || rows.length() == 0) return false
            val cursor = rows.getJSONObject(0).optString("id")
            if (cursor.isBlank() || !cursors.add(cursor)) return false
            val history = read(cursor)
            check(history.getString("threadId") == thread) { "history_scope_mismatch" }
            rows = history.optJSONArray("messages") ?: JSONArray()
            remember(rows)
            older = history.optBoolean("hasOlder")
            record(number, JSONObject().put("readKind", "history").put("messageMatch", matched.size == expected.size)
                .put("matchedMessageCount", matched.size).put("expectedMessageCount", expected.size)
                .put("messageCount", rows.length()).put("hasOlder", older))
        }
        return matched.size == expected.size
    }

    private fun inspectOriginal(bootstrap: JSONObject, original: File,
                                main: (() -> Unit) -> Unit, client: () -> SessionClient) {
        val evidence = File(original, "inspect-${UUID.randomUUID()}")
        check(evidence.mkdir())
        fun read(provider: String, method: String, target: JSONObject, params: JSONObject): JSONObject {
            check(method in setOf("operation.get", "session.open", "session.snapshot", "session.items"))
            val id = UUID.randomUUID().toString()
            val body = JSONObject().put("agentProtocol", 2).put("requestId", id).put("method", method)
                .put("target", target).put("params", params)
            val done = CountDownLatch(1)
            val reply = AtomicReference<JSONObject>()
            main {
                client().request("agentRequest", JSONObject().put("id", id).put("provider", provider)
                    .put("viewVersion", 1).put("body", body)) { reply.set(it); done.countDown() }
            }
            check(done.await(105, TimeUnit.SECONDS)) { "inspection_read_timeout" }
            val value = checkNotNull(reply.get())
            check(value.opt("ok") == true && value.getJSONObject("body").getString("requestId") == id) {
                "inspection_read_rejected"
            }
            return value.getJSONObject("body").getJSONObject("result")
        }
        val sessions = bootstrap.getJSONObject("inspectionSessions")
        val providers = sessions.keys().asSequence().toList().sorted()
        check(providers.isNotEmpty() && providers.toSet() == providers(bootstrap).toSet())
        for (provider in providers) {
            val fixture = bootstrap.getJSONObject("operations").getJSONObject(provider)
            val expected = mutableListOf<Pair<String, String>>()
            var thread = ""
            val ref = sessions.getString(provider)
            for (phase in listOf("create", "send")) {
                val operation = fixture.getString(phase)
                val receipt = read(provider, "operation.get", JSONObject(), JSONObject().put("operationId", operation))
                    .getJSONObject("operation")
                check(receipt.getString("operationId") == operation)
                privateRecord(evidence, "$operation.receipt.json", receipt)
                if (phase == "create") {
                    // Host and phone independently bind the restored scope to their original confirmed receipt.
                    val saved = File(original, "$operation.receipt.json")
                    check(saved.isFile && saved.length() <= 300_000)
                    val originalReceipt = JSONObject(saved.readText())
                    check(originalReceipt.getString("operationId") == operation &&
                        originalReceipt.getString("status") == "confirmed" && receipt.getString("status") == "confirmed")
                    val result = receipt.getJSONObject("result")
                    val prior = originalReceipt.getJSONObject("result")
                    val session = result.getJSONObject("session")
                    check(session.getString("sessionRef") == ref &&
                        session.getString("nativeThreadId") == prior.getJSONObject("session").getString("nativeThreadId") &&
                        result.getString("messageId") == prior.getString("messageId") && result.getString("turnId") == prior.getString("turnId"))
                    thread = session.getString("nativeThreadId")
                }
                // Unknown/notFound are evidence only; never resume or resubmit them.
                if (receipt.optString("status") == "confirmed") {
                    expected.add(receipt.getJSONObject("result").getString("messageId") to fixture.getString(phase + "Text"))
                }
            }
            var verified = false
            for (attempt in 0 until 35) {
                val value = read(provider, if (attempt == 0) "session.open" else "session.snapshot",
                    JSONObject().put("sessionRef", ref), JSONObject())
                val page = value.getJSONObject("snapshot")
                check(page.getString("threadId") == thread)
                val summary = snapshotSummary(provider, page, value, expected)
                privateRecord(evidence, "$provider-snapshot-$attempt.json", summary)
                if (summary.getBoolean("contentComplete") && summary.getBoolean("idle")) {
                    verified = historyMatches(provider, thread, page, expected,
                        { before -> read(provider, "session.items", JSONObject().put("sessionRef", ref),
                            JSONObject().put("kind", "history").put("before", before)) },
                        { number, metadata -> privateRecord(evidence, "$provider-history-$attempt-$number.json", metadata) })
                    // Once idle, paging is authoritative. Do not poll a one-turn snapshot hoping older rows appear.
                    check(verified) { "inspection_history_evidence_missing; no mutation retry" }
                    break
                }
                Thread.sleep(1_000)
            }
            check(verified) { "inspection_snapshot_incomplete; original authorization retained" }
        }
    }

    private fun privateRecord(directory: File, name: String, value: JSONObject) {
        val fd = Os.open(File(directory, name).path,
            OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW, 384)
        FileOutputStream(fd).use { output ->
            output.write(value.toString().toByteArray(Charsets.UTF_8)); output.fd.sync()
        }
    }

    private fun runLifecycle(
        bootstrap: JSONObject, directory: File, catalogs: Map<String, JSONObject>,
        main: (() -> Unit) -> Unit, client: () -> SessionClient,
    ) {
        fun privateRecord(name: String, value: JSONObject) = privateRecord(directory, name, value)
        fun call(provider: String, method: String, target: JSONObject, params: JSONObject,
                 operation: String? = null, lease: String? = null): JSONObject {
            val id = UUID.randomUUID().toString()
            val body = JSONObject().put("agentProtocol", 2).put("requestId", id).put("method", method)
                .put("target", target).put("params", params)
            if (operation != null) {
                body.put("operationId", operation).put("controlLease", checkNotNull(lease))
                // Persistent attempt identity precedes encryption/dispatch. Never delete or retry unknowns.
                privateRecord("$operation.attempt.json", JSONObject().put("operationId", operation)
                    .put("method", method).put("status", "attempted-or-unknown"))
            }
            val completed = CountDownLatch(1)
            val response = AtomicReference<JSONObject>()
            main {
                check(client().agent.negotiated)
                client().request("agentRequest", JSONObject().put("id", id).put("provider", provider)
                    .put("viewVersion", 1).put("body", body)) { response.set(it); completed.countDown() }
            }
            check(completed.await(105, TimeUnit.SECONDS)) { "Native lifecycle timeout; no retry" }
            val reply = checkNotNull(response.get())
            check(reply.opt("ok") == true) { "Native lifecycle request failed; no retry" }
            val envelope = reply.getJSONObject("body")
            check(envelope.getString("requestId") == id)
            if (operation != null) {
                privateRecord("$operation.receipt.json", envelope)
                check(envelope.optString("operationId") == operation && envelope.optString("status") == "confirmed") {
                    "Native lifecycle receipt not confirmed; retained without retry"
                }
                check(envelope.getString("effect") == if (method == "session.create") "session.created" else "message.submitted")
            }
            return envelope.getJSONObject("result")
        }
        fun content(text: String) = JSONArray().put(JSONObject().put("type", "text").put("text", text))
        fun proof(result: JSONObject, provider: String, thread: String): Pair<String, String> {
            val message = result.getString("messageId").also { check(it.isNotBlank()) }
            val turn = result.getString("turnId").also { check(it.isNotBlank()) }
            val kind = result.getString("turnIdentityKind")
            if (kind == "nativeMessageAnchor") {
                check(provider == "claude" && (turn == "transcript:$thread:$message" ||
                    (turn.startsWith("desktop:") && turn.endsWith(":$message"))))
            } else { check(kind == "nativeTurn") }
            return message to turn
        }
        fun snapshot(provider: String, ref: String, thread: String, expected: List<Pair<String, String>>): JSONObject {
            repeat(35) {
                val value = call(provider, "session.snapshot", JSONObject().put("sessionRef", ref), JSONObject())
                val page = value.getJSONObject("snapshot")
                check(page.getString("threadId") == thread)
                val summary = snapshotSummary(provider, page, value, expected)
                val stage = if (expected.size == 1) "after-create" else "after-send"
                privateRecord("$provider-$stage-snapshot-$it.json", summary)
                if (summary.getBoolean("contentComplete") && summary.getBoolean("idle") && summary.getBoolean("controlLeasePresent")) {
                    val matched = historyMatches(provider, thread, page, expected,
                        { before -> call(provider, "session.items", JSONObject().put("sessionRef", ref),
                            JSONObject().put("kind", "history").put("before", before)) },
                        { number, metadata -> privateRecord("$provider-$stage-history-$it-$number.json", metadata) })
                    check(matched) { "Native history evidence missing; no retry" }
                    return value
                }
                Thread.sleep(1_000) // bounded read polling only; never resubmit a mutation
            }
            error("Native message/idle snapshot evidence incomplete; no retry")
        }
        for (provider in providers(bootstrap)) {
            val fixture = bootstrap.getJSONObject("operations").getJSONObject(provider)
            val catalog = checkNotNull(catalogs[provider])
            val grant = catalog.getJSONObject("creationLease")
            val composer = catalog.getJSONObject("options").getJSONObject("composer")
            val options = JSONObject().put("mode", if (provider == "codex") "auto" else "default")
            for (key in listOf("model", "effort")) if (composer.has(key)) options.put(key, composer.get(key))
            val created = call(provider, "session.create", grant.getJSONObject("target"),
                JSONObject().put("options", options).put("initialMessage", JSONObject().put("content", content(fixture.getString("createText")))),
                fixture.getString("create"), grant.getString("controlLease"))
            check(created.optString("initialInput") == "confirmed")
            val session = created.getJSONObject("session")
            check(session.getString("adapterId") == "$provider.currentV1" &&
                session.getString("workspaceRef") == bootstrap.getJSONObject("workspaces").getString(provider))
            val thread = session.getString("nativeThreadId")
            UUID.fromString(thread)
            val ref = session.getString("sessionRef")
            val first = proof(created, provider, thread)
            val opened = snapshot(provider, ref, thread, listOf(first.first to fixture.getString("createText")))
            val descriptor = opened.getJSONObject("session")
            val target = JSONObject().put("sessionRef", ref).put("ownershipEpoch", descriptor.getString("ownershipEpoch"))
                .put("capabilityRevision", descriptor.getString("capabilityRevision"))
            val sent = call(provider, "message.submit", target,
                JSONObject().put("mode", "start").put("content", content(fixture.getString("sendText"))),
                fixture.getString("send"), opened.getString("controlLease"))
            val second = proof(sent, provider, thread)
            check(first.first != second.first && first.second != second.second)
            snapshot(provider, ref, thread, listOf(first.first to fixture.getString("createText"), second.first to fixture.getString("sendText")))
            privateRecord("$provider.verified.json", JSONObject().put("threadId", thread)
                .put("createMessageId", first.first).put("sendMessageId", second.first)
                .put("createTurnId", first.second).put("sendTurnId", second.second).put("approvals", "untested"))
        }
    }

    private class TcpTransport(private val port: Int, private val lifecycle: Boolean, private val device: String) : SessionTransport {
        override val mode = "wifi"
        override var onSessionFrame: (JSONObject) -> Unit = {}
        override var onSessionPair: (ByteArray?) -> Unit = {}
        private val socket = Socket()
        private lateinit var output: DataOutputStream
        private var reader: Thread? = null
        private var watchdog: Thread? = null
        @Volatile private var closed = false
        private var sent = 0
        @Volatile private var phase = "not_started"
        @Volatile private var failureCode = "none"
        private val sentFrames = java.util.concurrent.atomic.AtomicInteger()
        private val receivedFrames = java.util.concurrent.atomic.AtomicInteger()
        fun diagnostic(code: String): String = "native-phone phase=$phase code=$code transport=$failureCode sentFrames=${sentFrames.get()} receivedFrames=${receivedFrames.get()}"
        fun start() {
            phase = "connecting"
            try { socket.connect(InetSocketAddress("127.0.0.1", port), 5_000) }
            catch (_: Exception) { failureCode = "connect_failed"; error(diagnostic("transport_failure")) }
            phase = "connected"
            socket.soTimeout = if (lifecycle) 105_000 else 55_000
            output = DataOutputStream(socket.getOutputStream())
            // Absolute lifetime also bounds a blocked writer; never reconnect/retransmit.
            watchdog = Thread({
                try { Thread.sleep(if (lifecycle) 580_000 else 150_000); socket.close() } catch (_: InterruptedException) { }
            }, "native-phone-deadline").apply { isDaemon = true; start() }
            reader = Thread({
                try {
                    val input = DataInputStream(socket.getInputStream())
                    repeat(2048) {
                        phase = "frame_header"
                        val size = input.readInt()
                        if (size !in 1..4096) { failureCode = "frame_length"; error("frame_length") }
                        val frame = ByteArray(size)
                        phase = "frame_body"
                        input.readFully(frame)
                        receivedFrames.incrementAndGet()
                        phase = "client_delivery"
                        onSessionFrame(JSONObject(String(frame, Charsets.UTF_8)))
                    }
                } catch (error: Exception) {
                    if (!closed && failureCode == "none") failureCode = when (error) {
                        is java.net.SocketTimeoutException -> "read_timeout"
                        is java.io.EOFException -> "peer_eof"
                        is org.json.JSONException -> "frame_json"
                        else -> "read_failed"
                    }
                    // SessionClient owns timeout/unknown state; never synthesize a successful reply.
                } finally { socket.close() }
            }, "native-phone-frames").apply { isDaemon = true; start() }
        }
        @Synchronized override fun sendBinding(message: JSONObject) {
            try {
                phase = "frame_write"
                check(!closed && ++sent <= 2048 && ::output.isInitialized)
                check(message.optString("device") == device)
                check(!message.has("sender") || message.optString("sender") == device)
                // Same transport metadata as production RemoteSender.sendBinding; ciphertext/AAD untouched.
                val routed = JSONObject(message.toString()).put("sender", device)
                val bytes = routed.toString().toByteArray(Charsets.UTF_8)
                check(bytes.size in 1..4096)
                output.writeInt(bytes.size); output.write(bytes); output.flush()
                sentFrames.incrementAndGet()
            } catch (_: Exception) {
                failureCode = "write_failed"
                // Production SessionClient catches transport errors; retain a fixed code for the outer timeout.
                error(diagnostic("transport_failure"))
            }
        }
        override fun requestSessionPair(device: String, name: String) = error("Private bootstrap only")
        override fun readSessionPair() = Unit
        fun close() { closed = true; socket.close(); watchdog?.interrupt(); reader?.join(1_000) }
    }
}

/** Pure policy guard: never derive permission to destroy an existing identity from lifecycle alone. */
internal object NativePhoneAuthorizationGuard {
    fun release(mode: String, lifecycle: Boolean, inspection: Boolean, installedHere: Boolean, clear: () -> Unit) {
        if (mode == "onlyoptions" && !lifecycle && !inspection && installedHere) clear()
    }

    /** Runs without Android APIs; also executable on the host JVM from the compiled androidTest classes. */
    fun verifyPolicy() {
        for (mode in listOf("onlyoptions", "create-send", "inspect", "unknown")) {
            for (lifecycle in listOf(false, true)) for (inspection in listOf(false, true)) {
                for (installedHere in listOf(false, true)) {
                    var cleared = 0
                    release(mode, lifecycle, inspection, installedHere) { cleared++ }
                    val expected = if (mode == "onlyoptions" && !lifecycle && !inspection && installedHere) 1 else 0
                    check(cleared == expected) { "authorization_retention_policy_failed" }
                }
            }
        }
        // Regression: inspect must preserve authorization even if a future refactor sets lifecycle=false.
        release("inspect", lifecycle = false, inspection = true, installedHere = false) {
            error("inspection_authorization_destroyed")
        }
        // Mode and provenance remain independent safeguards if boolean flags become inconsistent.
        release("inspect", lifecycle = false, inspection = false, installedHere = true) {
            error("inspection_mode_authorization_destroyed")
        }
        release("onlyoptions", lifecycle = false, inspection = false, installedHere = false) {
            error("preexisting_authorization_destroyed")
        }
    }
}
