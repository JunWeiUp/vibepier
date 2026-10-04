package io.github.junweiup.vibepier.remote.core.session

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences


import android.content.Context
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import android.os.Handler
import android.os.Looper
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Encrypted, bounded RPC over either existing transport. No independent polling or background service. */
interface SessionTransport {
    val binaryHost: String? get() = null
    val mode: String
    /** Discovery is enough to request approval; private traffic still requires authorization. */
    val enrollmentReady: Boolean get() = false
    val enrollmentConnectionID: String? get() = if (enrollmentReady) "connected" else null
    var onSessionFrame: (JSONObject) -> Unit
    var onSessionPair: (ByteArray?) -> Unit
    fun sendBinding(message: JSONObject)
    fun requestSessionPair(device: String, name: String)
    fun readSessionPair()
    fun authorizationChanged() {}
}

class SessionClient(context: Context, private val sender: SessionTransport, private val replyTimeoutMs: Long = 0, private val completionNotifications: Boolean = false) {
    val receivingContent get() = inbox.receivingContent
    val relayDownload get() = sender.mode == "relay"
    val bluetooth get() = sender.mode == "bluetooth"
    val canRequestAuthorization get() = bluetooth && sender.enrollmentReady
    val binaryHost: String? get() = sender.binaryHost
    val attachmentFragmentChars get() = if (sender.mode == "wifi" || sender is io.github.junweiup.vibepier.remote.core.transport.RemoteSender && sender.isDirect) 512 else 7200
    val attachmentChunkBytes get() = if (sender.mode == "bluetooth") 8 * 1024 else 128 * 1024
    private val responseTimeout get() = if (replyTimeoutMs > 0) replyTimeoutMs else if (sender.mode == "bluetooth") 45_000L else 12_000L
    private val context = context.applicationContext
    private val prefs = PrivatePreferences.open(context, "sessions")
    private val taskNotifications = TaskCompletionNotifications(this.context)
    private val keys = DeviceKeys(context)
    val versionConnectionID get() = if (online && paired) "$versionConnectionEpoch:${sender.mode}" else null
    val device = keys.device
    private val main = Handler(Looper.getMainLooper())
    private val transmission = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val transmissionBytes = java.util.concurrent.atomic.AtomicInteger()
    private data class UploadTransmission(val request: String, val attachment: String, val authorization: String,
        val frames: List<String>, val created: Long, val bytes: Int, val resends: java.util.concurrent.atomic.AtomicInteger = java.util.concurrent.atomic.AtomicInteger())
    private val uploadTransmissions = java.util.concurrent.ConcurrentHashMap<String, UploadTransmission>()
    private val uploadTransmissionBytes = java.util.concurrent.atomic.AtomicInteger()
    private val cancelledUploads = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private fun clearUploadTransmissions(keep: (UploadTransmission) -> Boolean) {
        uploadTransmissions.entries.forEach { (packet, value) ->
            if (!keep(value) && uploadTransmissions.remove(packet, value)) uploadTransmissionBytes.addAndGet(-value.bytes)
        }
    }
    val paired get() = keys.authorized
    val authorizationIdentity: String get() = keys.authorizationIdentity.orEmpty()
    var viewVersion = prefs.getLong("viewVersion", 0); private set
    /** Pending retries retain the provider of the original request. */
    var provider = SessionProvider.normalize(prefs.getString("provider", "codex"))
        set(value) { field = SessionProvider.normalize(value); prefs.edit().putString("provider", field).apply() }
    fun capabilities(): JSONObject = try { JSONObject(prefs.getString("capabilities.$provider", "{}") ?: "{}") } catch (_: Exception) { JSONObject() }
    fun rememberCapabilities(value: JSONObject, sourceProvider: String = provider) {
        value.optJSONObject("capabilities")?.let { prefs.edit().putString("capabilities.$sourceProvider", it.toString()).apply() }
    }
    /** Session drawer grouping: "recent" or "projects". */
    var listMode = prefs.getString("listMode", "recent") ?: "recent"
        set(value) { field = value; prefs.edit().putString("listMode", value).apply() }
    @Volatile var online = false; private set
    var onAPKAvailable: () -> Unit = {}
    var onEvent: (JSONObject) -> Unit = {}
    var onState: (String) -> Unit = {}
    var authorizationMessage = context.getString(R.string.client_approval_prompt); private set
    private var automaticEnrollmentConnection: String? = null
    private fun reportAuthorization(message: String) { authorizationMessage = message; onState(message) }
    /** One automatic request per discovered BLE connection; denial never loops into another prompt. */
    fun requestAuthorizationIfNeeded() {
        val connection = sender.enrollmentConnectionID ?: return
        if (paired || !canRequestAuthorization || automaticEnrollmentConnection == connection) return
        automaticEnrollmentConnection = connection
        pair()
    }
    private var pairDeadline = 0L
    private val pairRetry = Runnable { if (System.currentTimeMillis() < pairDeadline) sender.readSessionPair() else { pairDeadline = 0; reportAuthorization(context.getString(R.string.client_approval_timeout)) } }
    private fun mutable(op: String) = op in setOf("send", "new", "approve", "settings", "interrupt", "queueSteer", "queueDelete", "lockScreen", "unlockScreen", "codexUsageReset")
    // Password verification is not retried, but must never enter durable phone storage.
    private fun uncertainOnTimeout(op: String) = mutable(op) || op in setOf("unlockPassword", "androidUpdateStage")
    private data class Request(val json: JSONObject, val callbacks: MutableList<(JSONObject) -> Unit>, val readKey: String? = null, val cacheKey: String? = null, var attempts: Int = 0, val byteSize: Int = json.toString().toByteArray(Charsets.UTF_8).size) {
        fun deliver(value: JSONObject) { callbacks.toList().forEach { it(JSONObject(value.toString())) } }
    }
    private val content = ConversationCache(prefs)
    var cacheHits = 0; private set
    var coalescedReads = 0; private set
    var networkReads = 0; private set
    private val pages = linkedMapOf<String, String>()
    private val lists = linkedMapOf<String, String>().apply {
        try {
            val saved = JSONArray(prefs.getString("listCacheV1", "[]"))
            for (i in 0 until minOf(saved.length(), 16)) {
                val entry = saved.getJSONObject(i); val value = entry.getJSONObject("value")
                if (value.optBoolean("ok")) put(entry.getString("key"), value.toString())
            }
        } catch (_: Exception) { clear() }
    }
    private fun listKey(op: String, params: JSONObject, sourceProvider: String = provider) = listOf(sourceProvider, op, params.optString("search"), params.optString("cwd"), params.optInt("offset"), params.optInt("limit", if (op == "projects") 100 else 20)).joinToString("\u0000")
    fun cachedList(op: String, params: JSONObject): JSONObject? = lists[listKey(op, params)]?.let(::JSONObject)
    fun freshList(op: String, params: JSONObject): Boolean {
        val at = cachedList(op, params)?.optLong("_cachedAt", 0) ?: return false
        val age = System.currentTimeMillis() - at
        return at > 0 && age >= 0 && age < if (op == "projects") 60_000 else 30_000
    }
    fun invalidateLists(sourceProvider: String = provider) {
        lists.keys.filter { it.startsWith(sourceProvider + "\u0000") }.forEach { key -> lists[key] = JSONObject(lists.getValue(key)).put("_cachedAt", 0).toString() }
        persistLists()
    }
    val drawerState: JSONObject get() = try {
        JSONObject(prefs.getString("drawerState.$provider", "{}") ?: "{}").takeIf { it.optString("listMode") == listMode } ?: JSONObject()
    } catch (_: Exception) { JSONObject() }
    fun rememberDrawerState(value: JSONObject) { prefs.edit().putString("drawerState.$provider", value.toString()).apply() }
    fun rememberList(op: String, params: JSONObject, value: JSONObject, sourceProvider: String = provider) {
        if (!value.optBoolean("ok")) return
        val key = listKey(op, params, sourceProvider); lists.remove(key); lists[key] = JSONObject(value.toString()).put("_cachedAt", System.currentTimeMillis()).toString()
        if (params.optInt("offset") > 0) {
            val headKey = listKey(op, JSONObject(params.toString()).put("offset", 0), sourceProvider)
            lists[headKey]?.let { text ->
                val head = JSONObject(text); val name = if (op == "projects") "projects" else "threads"
                val id = if (op == "projects") "cwd" else "id"
                val rows = linkedMapOf<String, JSONObject>()
                for (array in listOf(head.optJSONArray(name), value.optJSONArray(name))) {
                    if (array != null) for (i in 0 until array.length()) { val row = array.getJSONObject(i); rows[row.optString(id)] = row }
                }
                head.put(name, JSONArray(rows.values.toList())).put("nextOffset", value.optInt("nextOffset", -1))
                lists.remove(headKey); lists[headKey] = head.toString()
            }
        }
        while (lists.size > 16) lists.remove(lists.keys.first())
        persistLists()
    }
    private fun persistLists() {
        fun snapshot(): JSONArray = JSONArray(lists.map { (key, text) -> JSONObject().put("key", key).put("value", JSONObject(text)) })
        var saved = snapshot()
        while (saved.toString().toByteArray().size > 256 * 1024 && lists.isNotEmpty()) { lists.remove(lists.keys.first()); saved = snapshot() }
        prefs.edit().putString("listCacheV1", saved.toString()).apply()
    }
    fun cachedPage(thread: String): JSONObject? = pages["$provider:$thread"]?.let(::JSONObject) ?: content.get("page:$provider:$thread")
    fun cachedProcess(thread: String, reply: String) = content.get("process:$provider:$thread:$reply")
    fun rememberProcess(thread: String, reply: String, value: JSONObject, sourceProvider: String = provider) = content.put("process:$sourceProvider:$thread:$reply", value)
    fun clearImages(thread: String) = content.removePrefix("read:$provider:$thread:image:")
    fun flushContentCache() = content.flushAsync()
    fun rememberPage(thread: String, value: JSONObject) {
        val previous = cachedPage(thread)
        if (previous != null && (previous.optString("status") != value.optString("status") || previous.optString("title") != value.optString("title"))) invalidateLists()
        val key = "$provider:$thread"; pages.remove(key); pages[key] = value.toString()
        if (pages.size > 8) pages.remove(pages.keys.first())
        content.put("page:$key", value)
    }
    private val inbox = SessionResponseInbox(device, android.os.SystemClock::elapsedRealtime)
    private var apkDownloadToken: String? = null
    private var apkDownloadConnection: String? = null
    private val pending = java.util.concurrent.ConcurrentHashMap<String, Request>()
    @Volatile private var closed = false
    private val queuedFrameBytes = java.util.concurrent.atomic.AtomicInteger()
    private val queuedFrames = java.util.concurrent.atomic.AtomicInteger()
    init {
        sender.onSessionFrame = { frame ->
            if (!closed) {
                val encoded = frame.toString().replace("\\/", "/")
                val size = encoded.toByteArray(Charsets.UTF_8).size
                if (size <= 8192) {
                    val count = queuedFrames.incrementAndGet()
                    val bytes = queuedFrameBytes.addAndGet(size)
                    if (count <= 2048 && bytes <= 8 * 1024 * 1024) {
                        if (!main.post {
                            try { if (!closed) receive(JSONObject(encoded)) }
                            finally { queuedFrames.decrementAndGet(); queuedFrameBytes.addAndGet(-size) }
                        }) { queuedFrames.decrementAndGet(); queuedFrameBytes.addAndGet(-size) }
                    } else { queuedFrames.decrementAndGet(); queuedFrameBytes.addAndGet(-size) }
                }
            }
        }
        sender.onSessionPair = { data -> if (!closed && (data == null || data.size <= 4096)) { val copy = data?.copyOf(); main.post { if (!closed) pairReply(copy) } } }
    }
    @Volatile private var versionConnectionEpoch = 0L
    fun connectionChanged(connected: Boolean) {
        if (closed) return
        if (connected != online) versionConnectionEpoch++
        val restored = connected && !online
        online = connected
        if (restored && paired && completionNotifications) request("notificationSubscribe") { }
        if (!connected) {
            if (!sender.enrollmentReady) { pairDeadline = 0; main.removeCallbacks(pairRetry) }
            apkDownloadToken = null; apkDownloadConnection = null
            inbox.clearPartial()
            val requests = pending.toMap(); pending.clear()
            requests.values.forEach { it.deliver(JSONObject().put("ok", false).put("unknown", uncertainOnTimeout(it.json.optString("op"))).put("error", context.getString(R.string.client_disconnected))) }
        }
    }
    fun pair() {
        if (!canRequestAuthorization) { reportAuthorization(context.getString(R.string.client_bluetooth_first)); return }
        pairDeadline = System.currentTimeMillis() + 90_000
        reportAuthorization(context.getString(R.string.client_approve_on_mac))
        sender.requestSessionPair(device, android.os.Build.MODEL)
        main.removeCallbacks(pairRetry); main.postDelayed(pairRetry, 900)
    }
    private fun pairReply(bytes: ByteArray?) {
        if (pairDeadline == 0L) return
        val reply = try { bytes?.let { JSONObject(String(it, Charsets.UTF_8)) } } catch (_: Exception) { null }
        when (reply?.optString("state")) {
            "approved" -> try {
                check(reply.getString("device") == device)
                val key = Base64.decode(reply.getString("key"), Base64.NO_WRAP); check(key.size == 32)
                try { keys.install(key); versionConnectionEpoch++ } finally { key.fill(0) }
                sender.authorizationChanged()
                if (online && completionNotifications) request("notificationSubscribe") { }
                lists.clear(); pages.clear(); content.clear()
                prefs.edit().remove("listCacheV1").apply {
                    SessionProvider.ids.forEach { remove("drawerState.$it"); remove("capabilities.$it") }
                }.apply()
                pairDeadline = 0; reportAuthorization(context.getString(R.string.client_authorized)); onEvent(JSONObject().put("event", "paired"))
            } catch (_: Exception) { pairDeadline = 0; reportAuthorization(context.getString(R.string.client_key_save_failed)) }
            "pending", "none" -> main.postDelayed(pairRetry, 1500)
            "denied" -> { pairDeadline = 0; reportAuthorization(context.getString(R.string.client_authorization_denied)) }
            else -> { pairDeadline = 0; reportAuthorization(context.getString(R.string.client_pairing_invalid)) }
        }
    }
    private fun aad(packet: String, direction: String) = "vibepier-session-v1|$direction|$device|$packet".toByteArray()
    private fun secret(): SecretKey = keys.sessionKey()
    private fun readKey(value: JSONObject, withView: Boolean): String {
        val fields = value.keys().asSequence().filter { it !in setOf("id", "sentAt") && (withView || it != "viewVersion") }.sorted().map { it to value.get(it) }.toList()
        return JSONObject().apply { fields.forEach { (key, item) -> put(key, item) } }.toString()
    }
    fun request(op: String, fields: JSONObject = JSONObject(), callback: (JSONObject) -> Unit): String {
        val id = fields.optString("id").ifBlank { UUID.randomUUID().toString() }
        val request = JSONObject().apply {
            fields.keys().forEach { key ->
                val value = fields.get(key)
                put(key, when (value) { is JSONObject -> JSONObject(value.toString()); is JSONArray -> JSONArray(value.toString()); else -> value })
            }
        }.put("op", op).put("id", id).put("sentAt", System.currentTimeMillis())
        if (!request.has("provider")) request.put("provider", provider)
        if (!online && paired && (op == "image" || (op == "message" && request.optString("cacheVersion").isNotBlank()))) {
            val key = "read:${request.optString("provider")}:${request.optString("threadId")}:$op:" + readKey(request, false)
            content.get(key)?.let { value -> cacheHits++; callback(value.put("id", id).put("viewVersion", viewVersion)); return id }
        }
        if (closed || !online || !paired) { callback(JSONObject().put("ok", false).put("error", if (!online) context.getString(R.string.client_connect_first) else context.getString(R.string.client_authorize_first))); return id }
        if (!SessionResponseInbox.uuid(id)) { callback(JSONObject().put("ok", false).put("error", context.getString(R.string.client_request_id_conflict))); return id }
        val changesView = op == "open" || op == "close"
        if (changesView && viewVersion == Long.MAX_VALUE) { callback(JSONObject().put("ok", false).put("error", context.getString(R.string.client_state_save_failed))); return id }
        val nextView = if (changesView) viewVersion + 1 else viewVersion
        if (!request.has("viewVersion")) request.put("viewVersion", nextView)
        if (!request.has("provider")) request.put("provider", provider)
        val encodedRequest = request.toString().toByteArray(Charsets.UTF_8)
        val requestBytes = encodedRequest.size
        if (requestBytes > SessionResponseInbox.PLAINTEXT_LIMIT) { callback(JSONObject().put("ok", false).put("error", context.getString(R.string.client_request_too_large))); return id }
        pending[id]?.let { existing ->
            if (readKey(existing.json, true) != readKey(request, true)) {
                callback(JSONObject().put("ok", false).put("error", context.getString(R.string.client_request_id_conflict)))
            } else if (existing.callbacks.size >= 16) {
                callback(JSONObject().put("ok", false).put("unknown", uncertainOnTimeout(op)).put("error", context.getString(R.string.client_request_busy)))
            } else existing.callbacks.add(callback)
            return id
        }
        val reading = op in setOf("list", "projects", "sync", "history", "parts", "message", "image", "composerOptions", "contextUsage", "browseFiles", "readMarkdownFile", "approvalDetails", "fileChanges", "readFile", "readImageFile", "readVideoFile", "fileDiff", "searchFiles")
        val readIdentity = if (reading) readKey(request, true) else null
        val cacheAge = when {
            op == "image" -> 10 * 60_000L
            op == "composerOptions" -> 15_000L
            op == "message" && request.optString("cacheVersion").isNotBlank() -> 24 * 60 * 60_000L
            else -> 0L
        }
        val cacheKey = if (cacheAge > 0) "read:${request.optString("provider")}:${request.optString("threadId")}:$op:" + readKey(request, false) else null
        if (cacheKey != null) content.get(cacheKey, cacheAge)?.let { value ->
            cacheHits++; callback(value.put("id", id).put("viewVersion", viewVersion)); return id
        }
        if (readIdentity != null) pending.values.firstOrNull { it.readKey == readIdentity }?.let { item ->
            if (item.callbacks.size >= 16) callback(JSONObject().put("ok", false).put("error", context.getString(R.string.client_request_busy)))
            else { coalescedReads++; item.callbacks.add(callback) }
            return item.json.getString("id")
        }
        if (pending.size >= 64 || pending.values.sumOf { it.byteSize.toLong() } + requestBytes > 2 * 1024 * 1024) {
            callback(JSONObject().put("ok", false).put("error", context.getString(R.string.client_request_busy))); return id
        }
        if (mutable(op)) {
            try {
                val receipts = prefs.all.filterKeys { it.startsWith("pending.") }
                val old = receipts["pending.$id"]
                if (old != null && (old !is String || readKey(JSONObject(old), true) != readKey(request, true))) {
                    callback(JSONObject().put("ok", false).put("error", context.getString(R.string.client_request_id_conflict))); return id
                }
                if ((old == null && receipts.size >= 128) || receipts.filterKeys { it != "pending.$id" }.values.sumOf { (it as? String)?.toByteArray(Charsets.UTF_8)?.size?.toLong() ?: 8L * 1024 * 1024 } + requestBytes > 8L * 1024 * 1024) {
                    callback(JSONObject().put("ok", false).put("error", context.getString(R.string.client_receipt_storage_full))); return id
                }
                check(prefs.edit().putString("pending.$id", request.toString()).commit())
            } catch (_: Exception) {
                callback(JSONObject().put("ok", false).put("error", context.getString(R.string.client_receipt_save_failed))); return id
            }
        }
        if (changesView) {
            if (!prefs.edit().putLong("viewVersion", nextView).commit()) { callback(JSONObject().put("ok", false).put("error", context.getString(R.string.client_state_save_failed))); return id }
            viewVersion = nextView
        }
        val item = Request(request, mutableListOf(callback), readIdentity, cacheKey, byteSize = requestBytes)
        pending[id] = item
        if (reading) networkReads++
        transmit(request, encodedRequest)
        // Desktop actions may first unlock the Mac and switch apps, which takes several seconds.
        main.postDelayed({ timeout(id, item) }, if (replyTimeoutMs == 0L && op in listOf("send", "new", "approve", "settings", "interrupt", "queueSteer", "queueDelete", "lockScreen", "unlockScreen")) maxOf(responseTimeout, 30_000L) else responseTimeout)
        return id
    }
    private fun timeout(id: String, item: Request) {
        if (pending[id] !== item) return
        if (uncertainOnTimeout(item.json.optString("op"))) {
            pending.remove(id)
            item.deliver(JSONObject().put("ok", false).put("unknown", true).put("id", id).put("error", context.getString(R.string.client_unknown_result)))
        } else if (++item.attempts <= 2 && online) {
            item.json.put("sentAt", System.currentTimeMillis()); transmit(item.json); main.postDelayed({ timeout(id, item) }, responseTimeout)
        } else {
            pending.remove(id); item.deliver(JSONObject().put("ok", false).put("error", context.getString(R.string.client_mac_unresponsive)))
        }
    }
    /** Leaving a page cancels its reads, so their timeout retries cannot reopen an obsolete subscription. */
    internal fun cancelAttachmentRequests(attachment: String) {
        cancelledUploads[attachment] = android.os.SystemClock.elapsedRealtime() + 30_000
        clearUploadTransmissions { it.attachment != attachment }
        pending.entries.removeAll { it.value.json.optString("attachmentId") == attachment &&
            it.value.json.optString("op") in setOf("attachmentStart", "attachmentChunk", "attachmentComplete", "newAttachmentStart", "newAttachmentChunk", "newAttachmentComplete") }
    }
    fun cancelAPKReads() {
        pending.entries.removeAll { it.value.json.optString("op") in setOf("apkOffer", "apkChunk", "apkBinary") }
        apkDownloadToken = null; apkDownloadConnection = null
        inbox.clearFastPartial()
    }
    fun cancelMarkdownReads(thread: String, sourceProvider: String) {
        pending.entries.removeAll { it.value.json.optString("op") == "readMarkdownFile" && it.value.json.optString("threadId") == thread && it.value.json.optString("provider") == sourceProvider }
    }
    internal fun cancelCreationOptions(id: String?) {
        if (id != null && pending[id]?.json?.optString("op") == "newOptions") pending.remove(id)
    }
    fun cancelPageReads() {
        pending.entries.removeAll { it.value.json.optString("op") in setOf("open", "close", "list", "projects", "sync", "history", "parts", "message", "image", "composerOptions", "newOptions", "contextUsage", "browseFiles", "readMarkdownFile", "approvalDetails", "fileChanges", "readFile", "readImageFile", "readVideoFile", "fileDiff", "searchFiles") }
    }
    fun uncertain(thread: String, sourceProvider: String = provider): List<JSONObject> = prefs.all.filterKeys { it.startsWith("pending.") }.values.mapNotNull {
        try { JSONObject(it as String).takeIf { j -> j.optString("threadId") == thread && j.optString("provider", "codex") == sourceProvider } } catch (_: Exception) { null }
    }
    fun clearReceipt(id: String) { prefs.edit().remove("pending.$id").apply() }
    fun retryPending(id: String, callback: (JSONObject) -> Unit) {
        val saved = prefs.getString("pending.$id", null)
        if (saved == null) { callback(JSONObject().put("ok", false).put("unknown", true).put("error", context.getString(R.string.client_unknown_result))); return }
        val original = runCatching { JSONObject(saved) }.getOrNull()
        if (original == null) { callback(JSONObject().put("ok", false).put("unknown", true).put("error", context.getString(R.string.client_unknown_result))); return }
        request(original.getString("op"), original, callback) // Reuse the original operation and payload.
    }
    private fun scopedValue(kind: String, thread: String, fallback: String, sourceProvider: String): String {
        val key = "$kind.$sourceProvider.$thread"
        if (!prefs.contains(key) && sourceProvider != "zcode") {
            val legacy = "$kind.$thread"
            prefs.getString(legacy, null)?.let { prefs.edit().putString(key, it).remove(legacy).apply() }
        }
        return prefs.getString(key, fallback) ?: fallback
    }
    fun draft(thread: String, sourceProvider: String = provider) = scopedValue("draft", thread, "", sourceProvider)
    fun saveDraft(thread: String, text: String, sourceProvider: String = provider) { prefs.edit().putString("draft.$sourceProvider.$thread", text).apply() }
    internal fun creationDraft(cwd: String, sourceProvider: String = provider): SessionCreationDraft =
        SessionCreationDraft.restore(prefs.getString("creationDraft.$sourceProvider.${SessionCreationDraft.key(cwd)}", null), cwd, sourceProvider)
    internal fun saveCreationDraft(draft: SessionCreationDraft): Boolean {
        val value = draft.value().toString()
        SessionCreationDraft.restore(value, draft.cwd, draft.provider)
        return prefs.edit().putString("creationDraft.${draft.provider}.${SessionCreationDraft.key(draft.cwd)}", value).commit()
    }
    /** Clear the confirmed original atomically, even if its dialog was closed while Mac was creating it. */
    internal fun finishCreation(original: JSONObject): Boolean = try {
        val cwd = original.getString("cwd"); val source = original.getString("provider")
        val draftId = original.getString("draftId")
        val key = "creationDraft.$source.${SessionCreationDraft.key(cwd)}"
        val saved = prefs.getString(key, null)?.let { SessionCreationDraft.restore(it, cwd, source) }
        val attachmentsKey = "attachments.$source.creation:$draftId"
        val entries = JSONArray(prefs.getString(attachmentsKey, "[]") ?: "[]")
        val sent = original.optJSONArray("attachments") ?: JSONArray()
        val sentIDs = (0 until sent.length()).map { sent.getString(it) }.toSet()
        val keep = JSONArray(); val removed = mutableListOf<String>()
        for (i in 0 until entries.length()) {
            val entry = entries.getJSONObject(i)
            if (entry.getString("attachmentId") in sentIDs) removed.add(entry.optString("cachePath")) else keep.put(entry)
        }
        val edit = prefs.edit().putString(attachmentsKey, keep.toString()).remove("pending.${original.getString("id")}")
        if (saved?.matches(original) == true && keep.length() == 0) edit.remove(key)
        if (!edit.commit()) false else {
            val root = java.io.File(context.filesDir, "codex-drafts").canonicalPath + "/"
            for (path in removed.filter { it.isNotBlank() }) runCatching {
                val file = java.io.File(path); if (file.canonicalPath.startsWith(root)) file.delete()
            }
            true
        }
    } catch (_: Exception) { false }
    fun attachments(thread: String, sourceProvider: String = provider): JSONArray = try { JSONArray(scopedValue("attachments", thread, "[]", sourceProvider)) } catch (_: Exception) { JSONArray() }
    fun saveAttachments(thread: String, entries: JSONArray, sourceProvider: String = provider): Boolean = prefs.edit().putString("attachments.$sourceProvider.$thread", entries.toString()).commit()
    fun clearSentAttachments(thread: String, ids: JSONArray?, sourceProvider: String = provider) {
        val sent = (0 until (ids?.length() ?: 0)).map { ids!!.optString(it) }.toSet()
        val keep = JSONArray(); val current = attachments(thread, sourceProvider)
        for (i in 0 until current.length()) {
            val item = current.getJSONObject(i)
            if (item.optString("attachmentId") !in sent) keep.put(item)
            else item.optString("cachePath").takeIf { it.isNotEmpty() }?.let { path ->
                val file = java.io.File(path); val root = java.io.File(context.filesDir, "codex-drafts")
                if (file.canonicalPath.startsWith(root.canonicalPath + "/")) file.delete()
            }
        }
        saveAttachments(thread, keep, sourceProvider)
    }
    private fun transmit(value: JSONObject, encoded: ByteArray = value.toString().toByteArray(Charsets.UTF_8)) {
        val authorization = authorizationIdentity
        val requestID = value.optString("id")
        val requestToken = pending[requestID]
        val fragmentHint = value.optInt("uploadFragmentChars", 7200)
        val untrackedResend = value.optString("op") == "resend"
        val attachment = value.optString("attachmentId").takeIf { value.optString("op") in setOf("attachmentStart", "attachmentChunk", "attachmentComplete", "newAttachmentStart", "newAttachmentChunk", "newAttachmentComplete") }
        val upload = value.optString("attachmentId").takeIf {
            value.optInt("uploadVersion") == 1 && value.optString("op") in setOf("attachmentChunk", "newAttachmentChunk")
        }
        if (transmissionBytes.addAndGet(encoded.size) > 2 * 1024 * 1024) {
            transmissionBytes.addAndGet(-encoded.size)
            onState(context.getString(R.string.client_request_busy)); return
        }
        try { transmission.execute {
            try {
                if (closed || !online || authorizationIdentity != authorization || (!untrackedResend && pending[requestID] !== requestToken) || attachment != null && cancelledUploads.containsKey(attachment)) return@execute
                val packet = UUID.randomUUID().toString()
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, secret()); cipher.updateAAD(aad(packet, "phone"))
                val data = Base64.encodeToString(cipher.iv + cipher.doFinal(encoded), Base64.NO_WRAP)
                val fragmentChars = if (upload != null && !bluetooth) fragmentHint else 900
                val parts = (data.length + fragmentChars - 1) / fragmentChars
                val frames = (0 until parts).map { i ->
                    JSONObject().put("type", "vibepier-session1").put("device", device)
                        .put("packet", packet).put("part", i).put("parts", parts)
                        .put("data", data.substring(i * fragmentChars, minOf((i + 1) * fragmentChars, data.length)))
                        .apply { if (upload != null && !bluetooth) put("upload", upload).put("fragmentChars", fragmentChars) }.toString()
                }
                if (upload != null) {
                    val now = android.os.SystemClock.elapsedRealtime()
                    cancelledUploads.entries.removeAll { it.value <= now }
                    clearUploadTransmissions { now - it.created < 30_000 && it.request != requestID }
                    val bytes = frames.sumOf { it.toByteArray(Charsets.UTF_8).size }
                    if (uploadTransmissionBytes.addAndGet(bytes) > 2 * 1024 * 1024) {
                        uploadTransmissionBytes.addAndGet(-bytes); return@execute
                    }
                    uploadTransmissions[packet] = UploadTransmission(requestID, upload, authorization, frames, now, bytes)
                }
                for (frame in frames) {
                    if (closed || !online || authorizationIdentity != authorization || (!untrackedResend && pending[requestID] !== requestToken) || attachment != null && cancelledUploads.containsKey(attachment)) break
                    sender.sendBinding(JSONObject(frame))
                }
            } catch (_: Exception) { main.post { if (!closed) onState(context.getString(R.string.client_key_unavailable)) } }
            finally { transmissionBytes.addAndGet(-encoded.size) }
        } } catch (_: java.util.concurrent.RejectedExecutionException) { transmissionBytes.addAndGet(-encoded.size) }
    }
    private fun recoverUpload(value: JSONObject) {
        val packet = value.optString("packet")
        val saved = uploadTransmissions[packet] ?: return
        val waiting = pending[saved.request] ?: return
        val missing = value.optJSONArray("missing") ?: return
        if (saved.attachment != value.optString("attachmentId") || waiting.json.optString("attachmentId") != saved.attachment ||
            saved.authorization != authorizationIdentity || cancelledUploads.containsKey(saved.attachment) || missing.length() !in 1..256) return
        val indices = (0 until missing.length()).map { missing.opt(it) as? Int ?: return }
        if (indices.any { it !in saved.frames.indices } || indices.distinct().size != indices.size || saved.resends.incrementAndGet() > 3) return
        try { transmission.execute {
            if (closed || !online || saved.authorization != authorizationIdentity || cancelledUploads.containsKey(saved.attachment) ||
                uploadTransmissions[packet] !== saved || android.os.SystemClock.elapsedRealtime() - saved.created >= 30_000) return@execute
            indices.forEach { index ->
                if (!closed && !cancelledUploads.containsKey(saved.attachment)) sender.sendBinding(JSONObject(saved.frames[index]))
            }
        } } catch (_: java.util.concurrent.RejectedExecutionException) {}
    }
    private fun receive(frame: JSONObject) {
        if (closed || !paired) return
        try {
            val progress = inbox.receive(frame, decrypt = { packet, bytes ->
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, secret(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
                cipher.updateAAD(aad(packet, "mac"))
                cipher.doFinal(bytes.copyOfRange(12, bytes.size))
            }, acceptsFastRequest = { id ->
                val request = pending[id]?.json
                relayDownload && apkDownloadToken != null && apkDownloadConnection == versionConnectionID &&
                    request?.optString("op") == "apkChunk" && request.optString("downloadToken") == apkDownloadToken
            }) ?: return
            if (progress.started && progress.message == null) main.postDelayed({ missing(progress.ticket) }, 1800)
            val value = progress.message ?: return
            if (value.optString("event") == "uploadMissing") { recoverUpload(value); return }
            val id = value.optString("id")
            if (id.isNotEmpty()) {
                val original = prefs.getString("pending.$id", null)?.let { JSONObject(it) }
                val waiting = pending[id]
                if (waiting?.json?.optString("op") == "apkOffer") {
                    val profile = value.optJSONObject("download")
                    apkDownloadToken = if (relayDownload && waiting.json.optInt("downloadVersion") == 1 &&
                        profile?.optInt("version") == 1 && profile.optString("token") == id &&
                        profile.optInt("fragmentChars") == 7200 && profile.optInt("chunkBytes") == 128 * 1024 && profile.optInt("window") == 4) id else null
                    apkDownloadConnection = if (apkDownloadToken != null) versionConnectionID else null
                    if (apkDownloadToken == null) value.remove("download")
                }
                val intent = original ?: waiting?.json?.takeIf { mutable(it.optString("op")) }
                if (intent != null && !SessionResponseInbox.confirms(value, intent)) { onState(context.getString(R.string.client_message_invalid)); return }
                pending.remove(id)
                clearUploadTransmissions { it.request != id }
                val sourceProvider = waiting?.json?.optString("provider") ?: original?.optString("provider", "codex")
                if (!value.has("provider") && sourceProvider != null) value.put("provider", sourceProvider)
                if (!value.optBoolean("unknown")) {
                    if (original?.optString("op") == "send" && value.optBoolean("accepted")) {
                        val thread = original.optString("threadId")
                        val source = original.optString("provider", "codex")
                        if (draft(thread, source).trim() == original.optString("text")) saveDraft(thread, "", source)
                        clearSentAttachments(thread, original.optJSONArray("attachments"), source)
                    }
                    val created = original?.optString("op") == "new" && original.has("draftId") && value.optBoolean("ok")
                    if (!created || finishCreation(original!!)) clearReceipt(id)
                }
                if (waiting != null) {
                    if (waiting.json.optString("op") in listOf("list", "projects")) rememberCapabilities(value, waiting.json.optString("provider", "codex"))
                    if (value.optBoolean("ok") && waiting.cacheKey != null) content.put(waiting.cacheKey, JSONObject(value.toString()).apply {
                        remove("id"); remove("viewVersion")
                        if (waiting.json.optString("op") == "composerOptions") remove("composer") // Reuse model choices without rolling live usage/settings back.
                    })
                    if (value.optBoolean("ok") && waiting.json.optString("op") in setOf("send", "new", "settings", "interrupt", "queueSteer", "queueDelete", "lockScreen", "unlockScreen")) invalidateLists(waiting.json.optString("provider"))
                    waiting.deliver(value)
                }
                else if (original != null) {
                    value.put("event", "lateReceipt").put("operation", original)
                    if (original.optString("op") != "new") value.put("threadId", original.optString("threadId"))
                    onEvent(value)
                }
            } else if (value.optString("event") == "taskCompleted") { if (completionNotifications) taskNotifications.receive(value) }
            else if (value.optString("event") == "apkAvailable") onAPKAvailable() else onEvent(value)
        } catch (_: Exception) { onState(context.getString(R.string.client_message_invalid)) }
    }
    private fun missing(ticket: SessionResponseInbox.Ticket) {
        when (inbox.missing(ticket, online)) {
            SessionResponseInbox.Missing.GONE -> return
            SessionResponseInbox.Missing.WAIT -> main.postDelayed({ missing(ticket) }, 3000)
            SessionResponseInbox.Missing.EXPIRED -> {
                onState(context.getString(R.string.client_content_incomplete))
                if (online) onEvent(JSONObject().put("event", "stale"))
            }
            SessionResponseInbox.Missing.RESEND -> {
                transmit(JSONObject().put("op", "resend").put("id", UUID.randomUUID().toString()).put("sentAt", System.currentTimeMillis()).put("packet", ticket.packet))
                main.postDelayed({ missing(ticket) }, 2500)
            }
        }
    }
    fun close() { closed = true; transmission.shutdownNow(); uploadTransmissions.clear(); cancelledUploads.clear(); online = false; content.flush(); pairDeadline = 0; main.removeCallbacksAndMessages(null); inbox.clearPartial(); pending.clear() }
}
