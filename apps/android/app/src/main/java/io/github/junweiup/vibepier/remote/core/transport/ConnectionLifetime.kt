package io.github.junweiup.vibepier.remote.core.transport

/** Activity and foreground service share one transport. Call only from the main thread. */
internal class ConnectionLifetime<T>(
    private val create: () -> T,
    private val pause: (T) -> Unit,
    private val detachUI: (T) -> Unit,
    private val dispose: (T) -> Unit,
) {
    private val owners = mutableSetOf<Any>()
    private var resource: T? = null
    private var service = false
    /** The live shared transport, if the user opened a connection; never creates one. */
    val current: T? get() = resource

    fun acquire(owner: Any): T {
        owners.add(owner)
        return resource ?: create().also { resource = it }
    }

    fun release(owner: Any) {
        if (!owners.remove(owner) || owners.isNotEmpty()) return
        resource?.let(detachUI)
        disposeIfUnused()
    }

    fun retainService(): T? {
        val value = resource ?: return null // No background start without a user-opened connection.
        service = true
        return value
    }

    fun releaseService() {
        if (!service) return
        service = false
        resource?.let(pause)
        disposeIfUnused()
    }

    private fun disposeIfUnused() {
        if (service || owners.isNotEmpty()) return
        val value = resource ?: return
        resource = null
        dispose(value)
    }
}
