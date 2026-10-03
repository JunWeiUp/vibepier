package io.github.junweiup.vibepier.remote.core.transport

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.HandlerThread

/** A replacement network can be announced before the old network's loss callback. */
internal class RelayNetworkIdentity<T>(private var current: T?) {
    fun available(network: T): Boolean {
        if (current == network) return false
        current = network
        return true
    }
    fun lost(network: T): Boolean {
        if (current != network) return false
        current = null
        return true
    }
}

/** Active only while relay mode is running; reconnect work never runs on the UI thread. */
internal class RelayNetworkMonitor(context: Context) {
    private val manager = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var generation = 0L

    @Synchronized fun start(changed: () -> Unit) {
        stop()
        val manager = manager ?: return
        val current = generation
        val worker = HandlerThread("vibepier-relay-network").apply { start() }
        thread = worker
        val events = Handler(worker.looper)
        handler = events
        val identity = RelayNetworkIdentity(manager.activeNetwork)
        val reconnect = Runnable {
            val active = synchronized(this) { generation == current && callback != null }
            if (active) changed()
        }
        val listener = object : ConnectivityManager.NetworkCallback() {
            private fun observe(network: Network, available: Boolean) = synchronized(this@RelayNetworkMonitor) {
                if (generation != current) return@synchronized
                val moved = if (available) identity.available(network) else identity.lost(network)
                if (moved) {
                    events.removeCallbacks(reconnect)
                    // Coalesce a Wi-Fi loss and cellular availability into one reconnect.
                    events.postDelayed(reconnect, 250)
                }
            }
            override fun onAvailable(network: Network) { observe(network, true) }
            override fun onLost(network: Network) { observe(network, false) }
        }
        callback = listener
        try { manager.registerDefaultNetworkCallback(listener, events) }
        catch (error: Exception) {
            stop()
            TransportLog.warning(TransportLog.Event.RELAY_NETWORK, error)
        }
    }

    @Synchronized fun stop() {
        generation++
        callback?.let { runCatching { manager?.unregisterNetworkCallback(it) } }
        callback = null
        handler?.removeCallbacksAndMessages(null); handler = null
        thread?.quitSafely(); thread = null
    }
}
