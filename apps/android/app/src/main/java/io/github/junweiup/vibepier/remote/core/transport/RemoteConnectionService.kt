package io.github.junweiup.vibepier.remote.core.transport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import io.github.junweiup.vibepier.remote.MainActivity
import io.github.junweiup.vibepier.remote.R

/** Keeps the user-started Mac connection alive while the Activity is in the background. */
class RemoteConnectionService : Service() {
    companion object {
        private const val CHANNEL = "mac_connection"
        private const val NOTIFICATION = 47800
        private const val DISCONNECT = "io.github.junweiup.vibepier.DISCONNECT"
        private var lifetime: ConnectionLifetime<RemoteSender>? = null

        // Main-thread ownership prevents duplicate sockets and stale Activities retaining callbacks.
        fun acquire(context: Context, owner: Any): RemoteSender {
            val app = context.applicationContext
            val state = lifetime ?: ConnectionLifetime(
                create = { RemoteSender(app) },
                pause = { it.watch(false) },
                detachUI = { it.detachUICallbacks() },
                dispose = { it.close() },
            ).also { lifetime = it }
            return state.acquire(owner)
        }

        fun release(owner: Any) { lifetime?.release(owner) }

        /** The authenticated session client of the live connection, for notification actions; null when disconnected. */
        internal fun activeSessionClient() = lifetime?.current?.sessionClient

        fun start(context: Context) {
            context.startForegroundService(Intent(context, RemoteConnectionService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == DISCONNECT) {
            stopSelf()
            return START_NOT_STICKY
        }
        val sender = lifetime?.retainService()
        if (sender == null) { stopSelf(); return START_NOT_STICKY }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, this.getString(R.string.connection_channel), NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val disconnect = PendingIntent.getService(this, 1, Intent(this, RemoteConnectionService::class.java)
            .setAction(DISCONNECT), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_monitor)
            .setContentTitle(this.getString(R.string.connection_notification_title))
            .setContentText(this.getString(R.string.connection_notification_body))
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, this.getString(R.string.connection_disconnect), disconnect).build())
            .setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_SERVICE).build()
        startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        sender.ensureWatching()
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the task away is an explicit exit; Home/app switching is not.
        stopSelf()
    }

    override fun onDestroy() {
        lifetime?.releaseService()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
