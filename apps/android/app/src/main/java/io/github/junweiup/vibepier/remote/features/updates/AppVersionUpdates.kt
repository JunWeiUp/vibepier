package io.github.junweiup.vibepier.remote.features.updates

import android.os.Handler
import android.os.Looper
import io.github.junweiup.vibepier.remote.BuildConfig
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import org.json.JSONObject

internal data class AvailableAppVersion(val code: Long, val name: String) {
    companion object {
        fun newer(value: JSONObject?, installed: Long): AvailableAppVersion? {
            if (value == null) return null
            val code = value.opt("versionCode") as? Number ?: return null
            val name = value.optString("versionName")
            if (code.toDouble() != code.toLong().toDouble() || code.toLong() !in 1..2_100_000_000L ||
                code.toLong() <= installed || name.isBlank() || name.length > 80 || name.any { it.isISOControl() }) return null
            return AvailableAppVersion(code.toLong(), name)
        }
    }
}

/** Only foreground polling; callbacks from an older connection cannot change the badge. */
internal class AppVersionUpdates(private val client: SessionClient, private val changed: () -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    private var foreground = false
    private var generation = 0
    private var connection: String? = null
    private var busy = false
    var available: AvailableAppVersion? = null; private set
    private val poll = object : Runnable {
        override fun run() { check(); if (foreground) handler.postDelayed(this, 30_000) }
    }
    fun resume() { foreground = true; handler.removeCallbacks(poll); poll.run() }
    fun pause() { foreground = false; generation++; busy = false; handler.removeCallbacks(poll) }
    fun connectionChanged() {
        val current = client.versionConnectionID
        if (current != connection) {
            connection = current; generation++; busy = false; available = null; changed()
            check()
        }
    }
    fun check() {
        if (!foreground || !client.online || !client.paired || busy || BuildConfig.DESIGN_REVIEW) return
        val identity = client.versionConnectionID ?: return
        val token = generation
        busy = true
        client.request("appVersion", JSONObject().put("packageName", BuildConfig.APPLICATION_ID)
            .put("versionCode", BuildConfig.VERSION_CODE).put("versionName", BuildConfig.VERSION_NAME)) { reply ->
            if (token != generation || identity != client.versionConnectionID || !foreground) return@request
            busy = false
            if (reply.optBoolean("ok")) {
                available = AvailableAppVersion.newer(reply.optJSONObject("latest"), BuildConfig.VERSION_CODE.toLong())
                changed()
            }
        }
    }
}
