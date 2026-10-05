package io.github.junweiup.vibepier.remote.features.sessions

/** Coalesce dirty events without losing one received while a read is in flight. */
internal class ConversationSyncState {
    data class Read(val token: Long, val withCache: Boolean)
    private var token = 0L
    private var pending = false
    private var force = false
    private var failures = 0
    var inFlight = false; private set

    fun request(withCache: Boolean) {
        if (!pending && !inFlight) failures = 0
        pending = true
        force = force || !withCache
    }
    fun begin(): Read? {
        if (inFlight || !pending) return null
        pending = false; inFlight = true
        return Read(++token, !force).also { force = false }
    }
    fun current(read: Read) = inFlight && read.token == token
    /** At most two retries for a failed read; writes never pass through this state. */
    fun finish(read: Read, success: Boolean): Boolean {
        if (!current(read)) return false
        inFlight = false
        if (success) failures = 0
        else {
            failures++
            pending = failures <= 2
            force = true
        }
        return pending
    }
    fun reset() {
        token++; pending = false; force = false; failures = 0; inFlight = false
    }
}
