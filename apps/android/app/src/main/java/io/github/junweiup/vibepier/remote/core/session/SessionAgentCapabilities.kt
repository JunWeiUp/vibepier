package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONObject

/** Declarations come only from the current authenticated connection, never a saved UI cache. */
internal data class SessionAgentAction(val supported: Boolean, val available: Boolean, val reason: String)

internal data class SessionAgentAdapter(
    val id: String, val provider: String, val backendKinds: Set<String>, val actions: Map<String, SessionAgentAction>,
    val isDefault: Boolean = false, val name: String? = null,
)

internal data class SessionAgentCapabilities(val revision: String, val adapters: List<SessionAgentAdapter>) {
    fun adapter(provider: String, id: String? = null) = if (!id.isNullOrBlank()) adapters.singleOrNull { it.provider == provider && it.id == id }
        else adapters.singleOrNull { it.provider == provider && it.isDefault }

    companion object {
        const val VERSION = 1
        fun decode(value: JSONObject?): SessionAgentCapabilities? = runCatching {
            val raw = value ?: error("Missing declaration")
            require(raw.opt("version") == VERSION)
            val revision = opaque(raw.opt("revision")) ?: error("Invalid revision")
            val rows = raw.getJSONArray("adapters")
            require(rows.length() <= 16)
            val adapters = (0 until rows.length()).map { index ->
                val row = rows.getJSONObject(index)
                val id = opaque(row.opt("id")) ?: error("Invalid adapter")
                val provider = row.opt("provider") as? String ?: error("Invalid provider")
                require(provider in SessionV1Contract.providers)
                val kinds = row.getJSONArray("backendKinds")
                require(kinds.length() in 1..2)
                val backendKinds = (0 until kinds.length()).map { kinds.getString(it) }
                require(backendKinds.distinct().size == backendKinds.size && backendKinds.all { it in backendKindsAllowed })
                val default = if (row.has("default")) row.opt("default") as? Boolean ?: error("Invalid default") else false
                SessionAgentAdapter(id, provider, backendKinds.toSet(), actions(row.getJSONObject("actions")), default,
                    (row.opt("name") as? String)?.takeIf { it.isNotBlank() && it.length <= 256 })
            }
            require(adapters.map { it.id }.distinct().size == adapters.size)
            require(adapters.filter { it.isDefault }.map { it.provider }.distinct().size == adapters.count { it.isDefault })
            SessionAgentCapabilities(revision, adapters)
        }.getOrNull()

        internal val backendKindsAllowed = setOf("desktopAttached", "managedRuntime")
        internal fun opaque(value: Any?): String? = (value as? String)?.takeIf {
            it.isNotBlank() && it.length <= 256 && '\u0000' !in it
        }
        internal fun actions(value: JSONObject): Map<String, SessionAgentAction> = value.keys().asSequence().associateWith { key ->
            require(key in SessionV1Contract.capabilityKeys)
            val row = value.getJSONObject(key)
            val supported = row.opt("supported") as? Boolean ?: error("Invalid supported flag")
            val available = row.opt("available") as? Boolean ?: error("Invalid available flag")
            val reason = opaque(row.opt("reason")) ?: error("Invalid reason")
            require(!available || supported)
            SessionAgentAction(supported, available, reason)
        }
    }
}

internal data class SessionAgentTargetCapabilities(
    val adapterId: String, val provider: String, val revision: String, val actions: Map<String, SessionAgentAction>,
) {
    fun allows(key: String) = actions[key]?.let { it.supported && it.available } == true
    fun fields() = JSONObject().put("agentCapabilityVersion", SessionAgentCapabilities.VERSION)
        .put("agentAdapterId", adapterId).put("agentCapabilityRevision", revision)

    companion object {
        fun decode(value: JSONObject?, host: SessionAgentCapabilities?): SessionAgentTargetCapabilities? = runCatching {
            val raw = value ?: error("Missing declaration")
            require(raw.opt("version") == SessionAgentCapabilities.VERSION)
            val provider = raw.opt("provider") as? String ?: error("Invalid provider")
            val id = SessionAgentCapabilities.opaque(raw.opt("adapterId")) ?: error("Invalid adapter")
            require(host?.adapter(provider, id)?.id == id)
            val revision = SessionAgentCapabilities.opaque(raw.opt("revision")) ?: error("Invalid revision")
            SessionAgentTargetCapabilities(id, provider, revision, SessionAgentCapabilities.actions(raw.getJSONObject("actions")))
        }.getOrNull()
    }
}

/** No negotiation data is written into old pending requests or provider preferences. */
internal class SessionAgentNegotiation {
    var host: SessionAgentCapabilities? = null; private set
    private val targets = mutableMapOf<String, SessionAgentTargetCapabilities>()
    fun clear() { host = null; targets.clear() }
    fun clearTargets() { targets.clear() }
    fun discover(value: JSONObject?): Boolean {
        val next = SessionAgentCapabilities.decode(value)
        if (next == null || next != host) targets.clear()
        host = next
        return next != null
    }
    private fun key(request: JSONObject): String? {
        val provider = request.opt("provider") as? String ?: return null
        if (provider !in SessionV1Contract.providers) return null
        val thread = request.opt("threadId") as? String
        if (!thread.isNullOrBlank()) {
            val view = request.opt("viewVersion") as? Number ?: return null
            return "$provider\u0000session\u0000$thread\u0000$view"
        }
        val cwd = request.opt("cwd") as? String ?: return null
        val draft = request.opt("draftId") as? String ?: return null
        return "$provider\u0000creation\u0000$cwd\u0000$draft"
    }
    fun remember(request: JSONObject, declaration: JSONObject?): Boolean {
        val key = key(request) ?: return false
        val next = SessionAgentTargetCapabilities.decode(declaration, host)
        if (next == null || next.provider != request.opt("provider")) { targets.remove(key); return false }
        targets[key] = next
        // Old view generations can display history but cannot authorize another write.
        if (targets.size > 32) targets.keys.firstOrNull { it != key }?.let(targets::remove)
        return true
    }
    fun target(request: JSONObject) = key(request)?.let(targets::get)
    fun permits(request: JSONObject, capability: String) = target(request)?.allows(capability) == true
    fun hostAllows(provider: String, capability: String, adapterId: String? = null) = host?.adapter(provider, adapterId)?.actions?.get(capability)?.let {
        it.supported && it.available
    } == true
}
