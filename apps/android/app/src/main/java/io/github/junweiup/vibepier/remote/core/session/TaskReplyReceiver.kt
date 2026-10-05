package io.github.junweiup.vibepier.remote.core.session

import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.transport.RemoteConnectionService
import org.json.JSONObject

/**
 * Sends a notification quick reply through the live, authenticated session client. The request is journaled like any
 * phone send; an uncertain result is reported as such and is never resent automatically.
 */
class TaskReplyReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "io.github.junweiup.vibepier.TASK_REPLY"
        const val TEXT = "reply"

        /** Pure validation of the notification payload against the current authorization; null means do not send. */
        internal fun request(provider: String?, thread: String?, source: String?, text: String?, authorization: String): JSONObject? {
            val body = text?.trim().orEmpty()
            if (provider !in SessionProvider.ids || authorization.isBlank() || source != authorization ||
                thread.isNullOrBlank() || thread.length > 512 || body.isEmpty() || body.toByteArray(Charsets.UTF_8).size > 32_000) return null
            return JSONObject().put("provider", provider).put("threadId", thread).put("text", body)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val notifications = TaskCompletionNotifications(context)
        val provider = intent.getStringExtra(TaskCompletionNotifications.EXTRA_PROVIDER) ?: return
        val client = RemoteConnectionService.activeSessionClient()
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(TEXT)?.toString()
        val fields = client?.let {
            request(provider, intent.getStringExtra(TaskCompletionNotifications.EXTRA_THREAD),
                intent.getStringExtra(TaskCompletionNotifications.EXTRA_SOURCE), text, it.authorizationIdentity)
        }
        if (client == null || fields == null || !client.online || !client.providerEnabled(provider)) {
            notifications.replyStatus(provider, context.getString(R.string.task_reply_open_app), open = true)
            return
        }
        notifications.replyStatus(provider, context.getString(R.string.task_reply_sending), open = false)
        val pending = goAsync()
        client.request("send", fields) { result ->
            val message = when {
                result.optBoolean("ok") -> context.getString(R.string.task_reply_sent)
                result.optBoolean("unknown") -> context.getString(R.string.task_reply_unknown)
                else -> result.optString("error").ifBlank { context.getString(R.string.task_reply_failed) }
            }
            notifications.replyStatus(provider, message, open = !result.optBoolean("ok"))
            pending.finish()
        }
    }
}
