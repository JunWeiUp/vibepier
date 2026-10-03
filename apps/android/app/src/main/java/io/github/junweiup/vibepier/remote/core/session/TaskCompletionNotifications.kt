package io.github.junweiup.vibepier.remote.core.session

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import io.github.junweiup.vibepier.remote.MainActivity
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences
import org.json.JSONObject

/** Called only after SessionClient authenticates and decrypts the Mac event. */
class TaskCompletionNotifications(context: Context) {
    private val context = context.applicationContext
    private val prefs by lazy { PrivatePreferences.open(this.context, "task-notifications") }
    fun createChannel() {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.task_notifications), NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    fun receive(value: JSONObject) {
        val identity = TaskCompletionIdentity.parse(value) ?: return
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
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_monitor)
            .setContentTitle(context.getString(R.string.task_notification_title, SessionProvider.name(identity.provider)))
            .setContentText(context.getString(R.string.task_notification_body))
            .setContentIntent(open).setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_STATUS)
            .build()
        // Keep at most one visible result per provider; each new completion may alert.
        try { manager.notify(identity.provider, 47802, notification) } catch (_: SecurityException) { /* Permission changed concurrently. */ }
    }
    companion object { const val CHANNEL = "task_completion" }
}

internal data class TaskCompletionIdentity(val id: String, val provider: String) {
    companion object {
        fun parse(value: JSONObject): TaskCompletionIdentity? {
            if (value.optString("event") != "taskCompleted") return null
            val id = value.optString("eventId")
            val provider = value.optString("provider")
            if (!id.matches(Regex("[0-9a-f]{64}")) || provider !in setOf("codex", "claude", "zcode")) return null
            return TaskCompletionIdentity(id, provider)
        }
        fun remember(previous: String, id: String): String? {
            val seen = previous.split('\n').filter { it.isNotEmpty() }
            if (id in seen) return null
            return (seen.takeLast(255) + id).joinToString("\n")
        }
    }
}
