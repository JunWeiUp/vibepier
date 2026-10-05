package io.github.junweiup.vibepier.remote

import android.Manifest
import android.app.Instrumentation
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.SystemClock
import io.github.junweiup.vibepier.remote.core.session.TaskCompletionNotifications
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

/** Explicit emulator-only synthetic notification test. Never sends a provider request. */
object TaskNotificationProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val context = test.targetContext
        val manager = context.getSystemService(NotificationManager::class.java)
        val notifier = TaskCompletionNotifications(context)
        fun event() = JSONObject().put("event", "taskCompleted").put("provider", "codex")
            .put("threadId", "synthetic-thread").put("eventId", MessageDigest.getInstance("SHA-256").digest(UUID.randomUUID().toString().toByteArray()).joinToString("") { "%02x".format(it) })
        fun active() = manager.activeNotifications.filter { it.id == 47802 && it.tag == "codex" }
        manager.cancel("codex", 47802)
        try {
            val first = event()
            notifier.receive(first, "synthetic-authorization")
            SystemClock.sleep(350)
            if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                check(active().isEmpty()) { "Notification appeared without permission" }
                return "PASS: permission denied suppresses synthetic task notification."
            }
            val initial = active().single()
            check(initial.notification.channelId == TaskCompletionNotifications.CHANNEL)
            check(initial.notification.extras.getString("android.title") == context.getString(R.string.task_notification_title, "Codex"))
            check(initial.notification.contentIntent != null)
            TaskCompletionNotifications(context).receive(first, "synthetic-authorization")
            SystemClock.sleep(350)
            check(active().single().postTime == initial.postTime) { "Duplicate or reconstructed notifier posted twice" }
            notifier.receive(event().put("provider", "untrusted"), "synthetic-authorization")
            SystemClock.sleep(350)
            check(active().single().postTime == initial.postTime) { "Malformed event posted" }
            notifier.receive(event(), "synthetic-authorization")
            SystemClock.sleep(350)
            check(active().single().postTime > initial.postTime) { "New turn failed to notify" }
            return "PASS: background notification channel/title/tap intent, persistent deduplication, invalid provider rejection and new-turn delivery. Synthetic emulator events only."
        } finally { manager.cancel("codex", 47802) }
    }
}
