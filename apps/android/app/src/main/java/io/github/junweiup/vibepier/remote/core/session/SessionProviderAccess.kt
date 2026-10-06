package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONObject

/** Authenticated Mac policy; drafts and unknown mutation receipts are independent of visibility. */
internal data class SessionProviderAccess(val revision: Long, val enabled: Set<String>) {
    val ids get() = SessionProvider.ids.filter { it in enabled }
    fun permits(provider: String, op: String): Boolean = SessionV1Contract.operation(op)?.providerPolicyExempt == true ||
        (if (op.startsWith("codexUsage")) "codex" else provider.ifBlank { "codex" }) in enabled
    fun replaces(previous: SessionProviderAccess?) = previous == null || revision > previous.revision || this == previous
    fun json() = JSONObject().put("revision", revision).put("enabled", JSONObject().apply {
        SessionProvider.ids.forEach { put(it, it in enabled) }
    })

    companion object {
        fun acceptsProfile(response: JSONObject, previous: SessionProviderAccess?): Boolean =
            response.opt("ok") == true && decode(response.optJSONObject("providerAccess"))?.replaces(previous) == true

        fun decode(value: JSONObject?): SessionProviderAccess? {
            val raw = value?.opt("revision") as? Number ?: return null
            val revision = raw.toString().takeIf { it.matches(Regex("[0-9]+")) }?.toLongOrNull() ?: return null
            val flags = value.optJSONObject("enabled") ?: return null
            if (SessionProvider.ids.any { flags.opt(it) !is Boolean }) return null
            return SessionProviderAccess(revision, SessionProvider.ids.filter { flags.getBoolean(it) }.toSet())
        }
        val receipts = setOf("receipt", "receiptCheck", "newReceiptCheck", "settingsReceiptCheck",
            "interruptReceiptCheck", "queueReceiptCheck", "codexUsageResetReceipt")
        val independent = setOf("providers", "notificationSubscribe", "close", "resend", "relaySetup", "appVersion",
            "androidUpdateStage", "fileCancel", "apkOffer", "apkStatus", "apkBinary", "apkProgress",
            "appUsage", "appUsageSet", "applications", "applicationShortcutSet", "screenLockStatus",
            "screenLockPassword", "lockScreen", "unlockScreen")
    }
}
