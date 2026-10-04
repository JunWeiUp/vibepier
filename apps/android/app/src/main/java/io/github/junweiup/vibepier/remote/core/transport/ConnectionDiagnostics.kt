package io.github.junweiup.vibepier.remote.core.transport

/** In-memory aggregate diagnostics. No endpoints, identities, pairing data or exception messages are accepted. */
internal class ConnectionDiagnostics {
    data class Snapshot(val mode: String, val path: String, val connected: Boolean, val authorized: Boolean,
        val restorations: Int, val recentEvent: String, val recentError: String, val warningCount: Int)
    private var mode = "wifi"
    private var path = "wifi"
    private var connected = false
    private var authorized = false
    private var sawConnection = false
    private var restorations = 0
    private var recentEvent = "none"
    private var recentError = "none"
    private var warnings = 0

    @Synchronized fun observe(mode: String, direct: Boolean, connected: Boolean, authorized: Boolean) {
        this.mode = mode.takeIf { it in setOf("wifi", "bluetooth", "relay") } ?: "unknown"
        path = if (this.mode == "relay" && direct) "direct" else this.mode
        if (connected && !this.connected) {
            if (sawConnection) restorations++
            sawConnection = true
        }
        this.connected = connected; this.authorized = authorized
    }
    @Synchronized fun record(event: TransportLog.Event, errorCategory: String?, warning: Boolean) {
        recentEvent = event.name.lowercase()
        if (warning) {
            warnings++
            recentError = errorCategory?.takeIf { it in setOf("invalid-payload", "timeout", "tls-failed", "io-failed", "permission-denied", "unexpected-error") } ?: "unspecified"
        }
    }
    @Synchronized fun snapshot() = Snapshot(mode, path, connected, authorized, restorations, recentEvent, recentError, warnings)
    companion object { val shared = ConnectionDiagnostics() }
}
