package io.github.junweiup.vibepier.remote.core.session

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import io.github.junweiup.vibepier.remote.MainActivity
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import org.json.JSONObject

/** Called only after SessionClient authenticates and decrypts the Mac event. */
class TaskCompletionNotifications(context: Context) {
    private val context = context.applicationContext
    private val prefs by lazy { PrivatePreferences.open(this.context, "task-notifications") }
    fun cancelProvider(provider: String) {
        context.getSystemService(NotificationManager::class.java).cancel(provider, 47802)
    }
    fun createChannel() {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.task_notifications), NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    fun receive(value: JSONObject, authorization: String) {
        val identity = TaskCompletionIdentity.parse(value) ?: return
        if (authorization.isBlank()) return
        // Persist before posting: repeated transport delivery or process recreation cannot alert twice.
        // A denied permission consumes the event too; enabling notifications does not replay history.
        val previous = prefs.getString("seen", "") ?: ""
        val next = TaskCompletionIdentity.remember(previous, identity.id) ?: return
        if (!prefs.edit().putString("seen", next).commit()) return
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        createChannel()
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled() || manager.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) return
        val open = PendingIntent.getActivity(context, 47802, Intent(context, MainActivity::class.java)
            .setData(Uri.Builder().scheme("vibepier").authority("completed").appendPath(identity.provider).appendPath(identity.id).build())
            .putExtra(EXTRA_PROVIDER, identity.provider)
            .putExtra(EXTRA_THREAD, identity.threadId)
            .putExtra(EXTRA_SOURCE, authorization)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        // Quick reply from the shade or lock screen: the text goes through the same authorized, journaled send path.
        val reply = PendingIntent.getBroadcast(context, identity.provider.hashCode(), Intent(context, TaskReplyReceiver::class.java)
            .setAction(TaskReplyReceiver.ACTION).putExtra(EXTRA_PROVIDER, identity.provider)
            .putExtra(EXTRA_THREAD, identity.threadId).putExtra(EXTRA_SOURCE, authorization),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
        val input = android.app.RemoteInput.Builder(TaskReplyReceiver.TEXT).setLabel(context.getString(R.string.task_notification_reply_hint)).build()
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_monitor)
            .setContentTitle(context.getString(R.string.task_notification_title, SessionProvider.name(identity.provider)))
            .setContentText(context.getString(R.string.task_notification_body))
            .setContentIntent(open).setAutoCancel(true)
            .addAction(Notification.Action.Builder(null, context.getString(R.string.task_notification_reply), reply)
                .addRemoteInput(input).setAllowGeneratedReplies(false).build())
            .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_STATUS)
            .build()
        // Keep at most one visible result per provider; each new completion may alert.
        try { manager.notify(identity.provider, 47802, notification) } catch (_: SecurityException) { /* Permission changed concurrently. */ }
    }
    /** Replaces the posted notification with the reply's actual state; never claims success without a receipt. */
    fun replyStatus(provider: String, text: String, open: Boolean) {
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val builder = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_monitor)
            .setContentTitle(SessionProvider.name(provider)).setContentText(text).setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_STATUS).setOnlyAlertOnce(true)
        if (open) builder.setContentIntent(PendingIntent.getActivity(context, 47803, Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        try { manager.notify(provider, 47802, builder.build()) } catch (_: SecurityException) { /* Permission changed concurrently. */ }
    }
    companion object {
        const val CHANNEL = "task_completion"
        internal const val EXTRA_PROVIDER = "io.github.junweiup.vibepier.completedProvider"
        internal const val EXTRA_THREAD = "io.github.junweiup.vibepier.completedThread"
        internal const val EXTRA_SOURCE = "io.github.junweiup.vibepier.completedSource"
        fun takeRoute(intent: Intent, authorization: String): JSONObject? {
            val provider = intent.getStringExtra(EXTRA_PROVIDER)
            val thread = intent.getStringExtra(EXTRA_THREAD)
            val source = intent.getStringExtra(EXTRA_SOURCE)
            intent.removeExtra(EXTRA_PROVIDER)
            intent.removeExtra(EXTRA_THREAD)
            intent.removeExtra(EXTRA_SOURCE)
            if (provider !in SessionProvider.ids || authorization.isBlank() || source != authorization ||
                thread.isNullOrBlank() || thread.length > 512) return null
            return JSONObject().put("source", source).put("provider", provider).put("thread", thread)
                .put("drawer", false).put("title", "").put("scrollY", 0)
        }
    }
}

internal data class TaskCompletionIdentity(val id: String, val provider: String, val threadId: String) {
    companion object {
        fun parse(value: JSONObject): TaskCompletionIdentity? {
            if (value.optString("event") != "taskCompleted") return null
            val id = value.optString("eventId")
            val provider = value.optString("provider")
            if (!id.matches(Regex("[0-9a-f]{64}")) || provider !in SessionProvider.ids) return null
            val thread = value.opt("threadId") as? String ?: return null
            if (thread.isBlank() || thread.length > 512) return null
            return TaskCompletionIdentity(id, provider, thread)
        }
        fun remember(previous: String, id: String): String? {
            val seen = previous.split('\n').filter { it.isNotEmpty() }
            if (id in seen) return null
            return (seen.takeLast(255) + id).joinToString("\n")
        }
    }
}
