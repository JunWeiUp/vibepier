package io.github.junweiup.vibepier.remote.core.session

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import io.github.junweiup.vibepier.remote.MainActivity
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import io.github.junweiup.vibepier.remote.core.transport.RemoteConnectionService
import org.json.JSONArray
import org.json.JSONObject

/**
 * Lock-screen decisions for the conversation left open on the phone. Only plain allow/deny requests the Mac marked
 * decidable are offered; questions, option lists and partial details still require the app. Allow needs the phone
 * unlocked (device authentication); the decision is an ordinary journaled `approve` that is never resent.
 */
class ApprovalNotifications(context: Context) {
    private val context = context.applicationContext
    private val prefs by lazy { PrivatePreferences.open(this.context, "approval-notifications") }

    internal data class Offer(val provider: String, val thread: String, val fingerprint: String, val revision: Any?,
                              val title: String, val details: String)

    companion object {
        const val CHANNEL = "approval_requests"
        private const val ID = 47804
        internal const val ACTION_ALLOW = "io.github.junweiup.vibepier.APPROVAL_ALLOW"
        internal const val ACTION_DENY = "io.github.junweiup.vibepier.APPROVAL_DENY"
        internal const val EXTRA_PROVIDER = "io.github.junweiup.vibepier.approvalProvider"
        internal const val EXTRA_THREAD = "io.github.junweiup.vibepier.approvalThread"
        internal const val EXTRA_FINGERPRINT = "io.github.junweiup.vibepier.approvalFingerprint"
        internal const val EXTRA_REVISION = "io.github.junweiup.vibepier.approvalRevision"
        internal const val EXTRA_SOURCE = "io.github.junweiup.vibepier.approvalSource"

        /** Plain two-way requests only; anything that needs the full dialog is left to the app. */
        internal fun offers(provider: String, page: JSONObject): List<Offer> {
            val thread = page.optString("threadId")
            if (provider !in SessionProvider.ids || thread.isBlank() || thread.length > 512) return emptyList()
            val rows = page.optJSONArray("approvals") ?: JSONArray()
            return (0 until rows.length()).mapNotNull { rows.optJSONObject(it) }.filter { row ->
                val decisions = row.optJSONArray("allowedDecisions")
                val choices = decisions?.let { list -> (0 until list.length()).map { list.opt(it) } }
                row.optBoolean("canDecide") && row.optString("fingerprint").length in 1..256 &&
                    row.optString("kind") != "questions" && !row.optBoolean("detailsOnDemand") &&
                    (row.optJSONArray("options")?.length() ?: 0) == 0 &&
                    (choices == null || ("allow" in choices && "deny" in choices))
            }.map { row ->
                Offer(provider, thread, row.getString("fingerprint"), row.opt("revision"),
                    row.optString("title").take(120), row.optString("details").take(600))
            }
        }

        /** The decision request a notification action may send, bound to the authorization that posted it. */
        internal fun decision(provider: String?, thread: String?, fingerprint: String?, source: String?, authorization: String,
                              allow: Boolean, revision: String?): JSONObject? {
            if (provider !in SessionProvider.ids || authorization.isBlank() || source != authorization ||
                thread.isNullOrBlank() || thread.length > 512 || fingerprint.isNullOrBlank() || fingerprint.length > 256) return null
            return JSONObject().put("provider", provider).put("threadId", thread).put("fingerprint", fingerprint).put("allow", allow).apply {
                if (!revision.isNullOrBlank()) put("expectedApprovalRevision", revision)
            }
        }
    }

    private fun manager() = context.getSystemService(NotificationManager::class.java)

    /** Posts each new decidable request once; requests that disappeared are withdrawn. */
    fun offer(provider: String, page: JSONObject, authorization: String) {
        if (authorization.isBlank()) return
        val offers = offers(provider, page)
        val thread = page.optString("threadId")
        if (offers.isEmpty()) { manager().cancel("approval:$provider:$thread", ID); return }
        val offer = offers.first()
        val seen = prefs.getString("seen", "") ?: ""
        val next = TaskCompletionIdentity.remember(seen, offer.fingerprint) ?: return
        if (!prefs.edit().putString("seen", next).commit()) return
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        manager().createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.approval_notifications), NotificationManager.IMPORTANCE_HIGH))
        fun action(name: String, code: Int) = PendingIntent.getBroadcast(context, code, Intent(context, ApprovalActionReceiver::class.java)
            .setAction(name).putExtra(EXTRA_PROVIDER, offer.provider).putExtra(EXTRA_THREAD, offer.thread)
            .putExtra(EXTRA_FINGERPRINT, offer.fingerprint).putExtra(EXTRA_SOURCE, authorization)
            .putExtra(EXTRA_REVISION, offer.revision?.toString()),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(context, 47805, Intent(context, MainActivity::class.java)
            .setData(Uri.Builder().scheme("vibepier").authority("approval").appendPath(offer.provider).appendPath(offer.thread).build())
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val code = offer.fingerprint.hashCode()
        val notification = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_monitor)
            .setContentTitle(context.getString(R.string.approval_notification_title, SessionProvider.name(offer.provider)))
            .setContentText(offer.title.ifBlank { context.getString(R.string.approval_notification_body) })
            .setStyle(Notification.BigTextStyle().bigText(listOf(offer.title, offer.details).filter { it.isNotBlank() }.joinToString("\n")))
            .setContentIntent(open).setAutoCancel(true).setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            // Approving runs work on the Mac, so it requires the phone owner to authenticate first.
            .addAction(Notification.Action.Builder(null, context.getString(R.string.approval_allow), action(ACTION_ALLOW, code))
                .setAuthenticationRequired(true).build())
            .addAction(Notification.Action.Builder(null, context.getString(R.string.approval_deny), action(ACTION_DENY, code + 1)).build())
            .build()
        try { manager().notify("approval:${offer.provider}:${offer.thread}", ID, notification) } catch (_: SecurityException) { /* Permission changed concurrently. */ }
    }

    /** The app is showing this conversation again; its own dialog takes over. */
    fun withdraw(provider: String, thread: String) { manager().cancel("approval:$provider:$thread", ID) }

    fun status(provider: String, thread: String, text: String) {
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val notification = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_monitor)
            .setContentTitle(SessionProvider.name(provider)).setContentText(text).setAutoCancel(true).setOnlyAlertOnce(true)
            .setContentIntent(PendingIntent.getActivity(context, 47806, Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            .setVisibility(Notification.VISIBILITY_PRIVATE).build()
        try { manager().notify("approval:$provider:$thread", ID, notification) } catch (_: SecurityException) { /* Permission changed concurrently. */ }
    }
}

class ApprovalActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val allow = when (intent.action) {
            ApprovalNotifications.ACTION_ALLOW -> true
            ApprovalNotifications.ACTION_DENY -> false
            else -> return
        }
        val notifications = ApprovalNotifications(context)
        val provider = intent.getStringExtra(ApprovalNotifications.EXTRA_PROVIDER) ?: return
        val thread = intent.getStringExtra(ApprovalNotifications.EXTRA_THREAD) ?: return
        val client = RemoteConnectionService.activeSessionClient()
        val fields = client?.let {
            ApprovalNotifications.decision(provider, thread, intent.getStringExtra(ApprovalNotifications.EXTRA_FINGERPRINT),
                intent.getStringExtra(ApprovalNotifications.EXTRA_SOURCE), it.authorizationIdentity, allow,
                intent.getStringExtra(ApprovalNotifications.EXTRA_REVISION))
        }
        if (client == null || fields == null || !client.online || !client.providerEnabled(provider)) {
            notifications.status(provider, thread, context.getString(R.string.task_reply_open_app)); return
        }
        notifications.status(provider, thread, context.getString(R.string.approval_submitting))
        val pending = goAsync()
        client.request("approve", fields) { result ->
            notifications.status(provider, thread, when {
                result.optBoolean("ok") && result.optBoolean("submitted", true) -> context.getString(R.string.approval_submitted)
                result.optBoolean("unknown") -> context.getString(R.string.approval_unknown)
                else -> result.optString("error").ifBlank { context.getString(R.string.approval_failed) }
            })
            pending.finish()
        }
    }
}
