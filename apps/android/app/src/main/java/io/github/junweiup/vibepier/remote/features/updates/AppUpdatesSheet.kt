package io.github.junweiup.vibepier.remote.features.updates

import android.app.Activity
import android.app.AlertDialog
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.LinearLayout
import io.github.junweiup.vibepier.remote.BuildConfig
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.showProtected
import org.json.JSONObject

/** The registered APK on the authorized Mac is the only update source. Never resend an unknown request. */
internal class AppUpdatesSheet(
    private val activity: Activity,
    private val client: SessionClient,
    private val versions: AppVersionUpdates,
    private val receiver: ApkReceiver,
) {
    private val handler = Handler(Looper.getMainLooper())
    private var dialog: AlertDialog? = null
    private var label: CanvasLabel? = null
    private var request: CanvasLabel? = null
    private var busy = false
    private var message = ""
    private val poll = object : Runnable {
        override fun run() {
            if (dialog?.isShowing != true) return
            refresh(); handler.postDelayed(this, 1_000)
        }
    }

    fun show(requestUpdate: Boolean = false) {
        if (dialog?.isShowing == true) return
        versions.check(); receiver.check(true)
        val body = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(Ui.dp(activity, 24), Ui.dp(activity, 8), Ui.dp(activity, 24), 0)
        }
        label = Ui.label(activity, "", Ui.BODY).also { body.addView(it) }
        request = Ui.button(activity, activity.getString(R.string.audit_update_request), Ui.Button.PRIMARY, ::requestLatest).also {
            body.addView(it, LinearLayout.LayoutParams(-1, -2).apply { topMargin = Ui.dp(activity, 16) })
        }
        body.addView(Ui.button(activity, activity.getString(R.string.audit_update_status)) {
            dialog?.dismiss(); receiver.showStatus()
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = Ui.dp(activity, 8) })
        dialog = AlertDialog.Builder(activity, R.style.Theme_VibePier_Dialog)
            .setTitle(activity.getString(R.string.audit_updates_title)).setView(body)
            .setPositiveButton(activity.getString(R.string.audit_update_check), null)
            .setNegativeButton(activity.getString(R.string.close), null).showProtected().also {
                it.setOnDismissListener { handler.removeCallbacks(poll); dialog = null; label = null; request = null }
                it.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { versions.check(); receiver.check(true); refresh() }
            }
        poll.run()
        // A tap on the known-newer version is the user's request to receive it.
        // Keep this outside refresh/poll so opening or refreshing details never resends it.
        if (requestUpdate) requestLatest()
    }

    fun refresh() {
        val connection = when {
            !client.paired -> activity.getString(R.string.audit_update_authorization_required)
            !client.online -> activity.getString(R.string.audit_update_offline)
            else -> activity.getString(R.string.audit_update_registered_source)
        }
        val latest = versions.available?.let { activity.getString(R.string.app_version_available, it.name, it.code) }
            ?: activity.getString(R.string.audit_update_no_known_version)
        val value = listOf(activity.getString(R.string.app_version_current, BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE),
            latest, connection, receiver.statusSummary(), message).filter(String::isNotBlank).joinToString("\n\n")
        label?.let { if (it.text.toString() != value) it.text = value }
        dialog?.getButton(AlertDialog.BUTTON_POSITIVE)?.isEnabled = client.online && client.paired
        request?.apply {
            visibility = if (versions.available != null) View.VISIBLE else View.GONE
            isEnabled = client.online && client.paired && !busy
            alpha = if (isEnabled) 1f else .4f
            val text = activity.getString(if (busy) R.string.audit_update_requesting else R.string.audit_update_request)
            if (this.text.toString() != text) this.text = text
        }
    }

    private fun requestLatest() {
        if (busy || !client.online || !client.paired || versions.available == null) return
        val source = client.authorizationIdentity
        val connection = client.versionConnectionID
        busy = true; message = activity.getString(R.string.audit_update_preparing); refresh()
        client.request("androidUpdateStage", JSONObject().put("packageName", BuildConfig.APPLICATION_ID)
            .put("versionCode", BuildConfig.VERSION_CODE)) { reply ->
            busy = false
            if (activity.isDestroyed) return@request
            message = when {
                source != client.authorizationIdentity || connection != client.versionConnectionID -> activity.getString(R.string.audit_update_connection_changed)
                reply.optBoolean("unknown") -> activity.getString(R.string.audit_update_request_unknown)
                !reply.optBoolean("ok") -> reply.optString("error").ifBlank { activity.getString(R.string.audit_update_request_failed) }
                reply.optString("phase") == "preparing" -> activity.getString(R.string.audit_update_preparing)
                else -> activity.getString(R.string.audit_update_requested)
            }
            if (reply.optBoolean("ok") && source == client.authorizationIdentity && connection == client.versionConnectionID) receiver.check(true)
            refresh()
        }
    }

    fun close() { handler.removeCallbacks(poll); dialog?.dismiss() }
}
