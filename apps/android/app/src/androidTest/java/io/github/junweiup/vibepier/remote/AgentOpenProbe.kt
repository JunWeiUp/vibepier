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

/** Fresh production SessionClient reads over an encrypted synthetic Mac, for all three adapters. */
internal object AgentOpenProbe {
    private class Transport : SessionTransport {
        override val mode = "bluetooth"
        override val enrollmentReady = true
        override var onSessionFrame: (JSONObject) -> Unit = {}
        override var onSessionPair: (ByteArray?) -> Unit = {}
        val frames = CopyOnWriteArrayList<JSONObject>()
        var packet: (List<JSONObject>) -> Unit = {}
        override fun sendBinding(message: JSONObject) {
            frames.add(JSONObject(message.toString()))
            if (message.optInt("part") == message.optInt("parts") - 1)
                packet(frames.filter { it.opt("packet") == message.opt("packet") }.sortedBy { it.getInt("part") })
        }
        override fun requestSessionPair(device: String, name: String) {}
        override fun readSessionPair() {}
    }
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val prefix = "agent-open-${UUID.randomUUID()}"
        val context = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("$prefix-$name", Context.MODE_PRIVATE)
        }
        val transport = Transport(); val keyBytes = ByteArray(32) { 43 }; val key = SecretKeySpec(keyBytes, "AES")
        val requests = CopyOnWriteArrayList<JSONObject>(); val error = AtomicReference<Throwable?>()
        lateinit var client: SessionClient; var created = false
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (value: Throwable) { failure = value } }
            failure?.let { throw it }; error.get()?.let { throw it }
        }
        fun waitFor(description: String, condition: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 6_000
            while (SystemClock.elapsedRealtime() < deadline) {
                var ready = false; main { ready = condition() }; if (ready) return
                SystemClock.sleep(50); test.waitForIdleSync()
            }
            error("Timed out: $description")
        }
        fun actions() = JSONObject().apply { SessionV1Contract.capabilityKeys.forEach { put(it,
            JSONObject().put("supported", false).put("available", false).put("reason", "synthetic_read_only")) } }
        fun descriptor(provider: String, opened: Boolean = false) = JSONObject().put("sessionRef", "ref-$provider")
            .put("adapterId", "$provider.currentV1").put("nativeThreadId", "synthetic-$provider").put("cwd", "/fixture/$provider")
            .put("ownershipEpoch", "epoch-$provider").put("capabilityRevision", if (opened) "cap-$provider" else "unavailable")
        fun capabilities(provider: String) = JSONObject().put("version", 1).put("adapterId", "$provider.currentV1")
            .put("provider", provider).put("revision", "cap-$provider").put("actions", actions())
        fun respond(value: JSONObject) {
            val packet = UUID.randomUUID().toString(); val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key); cipher.updateAAD("vibepier-session-v1|mac|${client.device}|$packet".toByteArray())
            val data = Base64.encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray()), Base64.NO_WRAP)
            data.chunked(900).let { pieces -> pieces.forEachIndexed { index, text -> transport.onSessionFrame(JSONObject()
                .put("type", "vibepier-session1").put("sender", client.device).put("device", client.device).put("packet", packet)
                .put("part", index).put("parts", pieces.size).put("data", text)) } }
        }
        transport.packet = { frames -> try {
            val packet = frames.first().getString("packet")
            val sealed = Base64.decode(frames.joinToString("") { it.getString("data") }, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed.copyOfRange(0, 12)))
            cipher.updateAAD("vibepier-session-v1|phone|${client.device}|$packet".toByteArray())
            val request = JSONObject(String(cipher.doFinal(sealed.copyOfRange(12, sealed.size)))); requests.add(request)
            val reply = JSONObject().put("id", request.get("id")).put("ok", true)
            when (request.getString("op")) {
                "providers" -> reply.put("providerAccess", SessionProviderAccess(1, SessionProvider.ids.toSet()).json())
                    .put("agentCapabilities", JSONObject().put("version", 1).put("revision", "host-cap").put("adapters", JSONArray().apply {
                        SessionProvider.ids.forEach { put(JSONObject().put("id", "$it.currentV1").put("provider", it).put("default", true)
                            .put("backendKinds", JSONArray().put("desktopAttached")).put("actions", actions())) }
                    })).put("agentProfiles", JSONObject().put("versions", JSONArray().put(2)).put("minimumClientVersion", 2)
                        .put("methods", JSONArray(SessionAgentProtocol.Method.entries.map { it.wire })))
                "agentRequest" -> {
                    val body = request.getJSONObject("body"); val target = body.getJSONObject("target"); val params = body.getJSONObject("params")
                    check(!body.has("operationId") && !body.has("controlLease")) { "Open probe must remain read only" }
                    val provider = request.getString("provider"); check(provider in SessionProvider.ids)
                    val result = JSONObject()
                    when (body.getString("method")) {
                        "workspace.list", "session.list" -> {
                            check(params.opt("search") is String && params.getString("search").isEmpty()) { "Fresh discovery must preserve empty search" }
                            check(target.opt("adapterId") == "$provider.currentV1")
                            if (body.opt("method") == "session.list") result.put("sessions", JSONArray().put(descriptor(provider))).put("nextOffset", -1)
                            else result.put("workspaces", JSONArray().put(JSONObject().put("workspaceRef", "workspace-$provider")
                                .put("adapterId", "$provider.currentV1").put("cwd", "/fixture/$provider"))).put("nextOffset", -1)
                        }
                        "session.open", "session.snapshot" -> {
                            check(target.opt("sessionRef") == "ref-$provider" && target.opt("ownershipEpoch") == "epoch-$provider")
                            val partial = body.opt("method") == "session.open"
                            val page = JSONObject().put("threadId", "synthetic-$provider").put("status", if (partial) "opening" else "idle")
                                .put("contentState", if (partial) "partial" else "complete").put("canSend", false).put("agentCapabilities", capabilities(provider))
                            if (partial) page.put("opening", true) else page.put("messages", JSONArray().put(JSONObject()
                                .put("id", "recent-$provider").put("role", "user").put("text", "synthetic recent turn")))
                                .put("turns", JSONArray()).put("hasOlder", true)
                            result.put("session", descriptor(provider, true)).put("snapshot", page).put("streamEpoch", "stream-$provider").put("throughSequence", 0)
                        }
                        SessionAgentProtocol.Method.ITEMS.wire -> {
                            check(target.opt("sessionRef") == "ref-$provider" && target.opt("ownershipEpoch") == "epoch-$provider")
                            check(params.opt("kind") == "history")
                            val before = params.getString("before")
                            check(before in setOf("recent-$provider", "older-$provider"))
                            val more = before == "recent-$provider"
                            result.put("messages", JSONArray().put(JSONObject().put("id", if (more) "older-$provider" else "oldest-$provider")
                                .put("role", "user").put("text", "synthetic earlier turn")))
                                .put("hasOlder", more).put("consistency", "partial").put("contentState", "partial")
                        }
                        "session.observe" -> result.put("streamEpoch", "stream-$provider").put("throughSequence", 0).put("events", JSONArray()).put("resyncRequired", false)
                        "operation.get" -> { check(target.length() == 0); result.put("operation", JSONObject().put("status", "notFound")) }
                        "session.unobserve" -> check(target.opt("sessionRef") == "ref-$provider")
                        else -> error("Unexpected probe method")
                    }
                    reply.put("body", JSONObject().put("agentProtocol", 2).put("requestId", request.get("id")).put("result", result))
                }
            }
            respond(reply)
        } catch (failure: Throwable) { error.compareAndSet(null, failure) } }
        try {
            main {
                client = SessionClient(context, transport, 3_000); created = true
                check(client.cachedList("list", JSONObject().put("search", "").put("offset", 0).put("limit", 8)) == null)
                client.connectionChanged(true); client.pair()
                transport.onSessionPair(JSONObject().put("state", "approved").put("device", client.device)
                    .put("key", Base64.encodeToString(keyBytes, Base64.NO_WRAP)).toString().toByteArray())
            }
            waitFor("profile negotiation", { client.agent.negotiated && client.agentAdapters.isNotEmpty() })
            for (provider in SessionProvider.ids) {
                var projects: JSONObject? = null; var list: JSONObject? = null; var opened: JSONObject? = null; var refreshed: JSONObject? = null
                main {
                    client.provider = provider
                    check(client.agent.session(provider, "synthetic-$provider") == null)
                    client.request("projects", JSONObject().put("search", "").put("offset", 0).put("limit", 8)) { projects = it }
                    client.request("list", JSONObject().put("search", "").put("offset", 0).put("limit", 8)) { list = it }
                }
                waitFor("$provider fresh discovery", { projects != null && list != null })
                main {
                    check(projects!!.opt("ok") == true && list!!.opt("ok") == true)
                    val row = list!!.getJSONArray("threads").getJSONObject(0)
                    check(row.getString("id") == "synthetic-$provider" && row.getString("sessionRef") == "ref-$provider")
                    client.request("open", JSONObject().put("threadId", row.get("id"))) { opened = it }
                }
                waitFor("$provider partial open", { opened != null })
                main {
                    check(opened!!.opt("ok") == true && opened!!.opt("contentState") == "partial" && opened!!.getJSONArray("messages").length() == 0)
                    check(!opened!!.has("agentCapabilities") && opened!!.opt("canSend") == false)
                    client.request("sync", JSONObject().put("threadId", "synthetic-$provider")) { refreshed = it }
                }
                waitFor("$provider complete refresh", { refreshed != null })
                main {
                    check(refreshed!!.opt("ok") == true && refreshed!!.opt("contentState") == "complete")
                    check(refreshed!!.getJSONArray("messages").length() == 1 && refreshed!!.optBoolean("hasOlder") && refreshed!!.optLong("viewVersion", -1) == client.viewVersion)
                    check(!client.agentCapability("send", "synthetic-$provider"))
                }
                for ((before, expected, more) in listOf(Triple("recent-$provider", "older-$provider", true), Triple("older-$provider", "oldest-$provider", false))) {
                    var history: JSONObject? = null
                    main { client.request("history", JSONObject().put("threadId", "synthetic-$provider").put("before", before)) { history = it } }
                    waitFor("$provider earlier history $expected", { history != null })
                    main {
                        check(history!!.opt("ok") == true && history!!.getJSONArray("messages").getJSONObject(0).getString("id") == expected)
                        check(history!!.optBoolean("hasOlder") == more && history!!.getString("threadId") == "synthetic-$provider")
                        check(history!!.optLong("viewVersion", -1) == client.viewVersion && !client.agentCapability("send", "synthetic-$provider"))
                    }
                }
                var receiptRead = false
                main { client.agent.read(SessionAgentProtocol.Method.OPERATION, params = JSONObject().put("operationId", SessionAgentProtocol.id())) { receiptRead = it is SessionAgentProtocol.Reply.Read } }
                waitFor("$provider empty target read", { receiptRead })
                var closed = false; main { client.request("close") { closed = it.opt("ok") == true } }
                waitFor("$provider close", { closed })
            }
            check(requests.count { it.optJSONObject("body")?.opt("method") == "session.open" } == 3)
            check(requests.count { it.optJSONObject("body")?.opt("method") == "session.snapshot" } == 3)
            check(requests.count { it.optJSONObject("body")?.opt("method") == SessionAgentProtocol.Method.ITEMS.wire } == 6)
            return "PASS: agent-open fresh isolated client; Codex, Claude and ZCode empty-search workspace/session discovery → opaque target open → partial loading snapshot → complete refresh → two earlier history pages with oldest boundary; read-only gates retained; host receipt reads require target {}; AES/GCM loopback only, no host, real messages or device configuration."
        } finally {
            main { if (created) client.close() }
            if (created) DeviceKeys(context).clear()
            PrivatePreferences.open(context, "sessions").edit().clear().commit()
        }
    }
}
