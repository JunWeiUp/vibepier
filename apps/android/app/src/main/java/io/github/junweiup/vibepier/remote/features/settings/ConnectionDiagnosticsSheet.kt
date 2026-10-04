package io.github.junweiup.vibepier.remote.features.settings

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.widget.ScrollView
import android.widget.Toast
import io.github.junweiup.vibepier.remote.BuildConfig
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.transport.ConnectionDiagnostics
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.showProtected

internal object ConnectionDiagnosticsSheet {
    fun show(activity: Activity) {
        val report = report(activity, ConnectionDiagnostics.shared.snapshot())
        val body = Ui.label(activity, report, Ui.CAPTION).apply {
            setPadding(Ui.dp(activity, 24), Ui.dp(activity, 8), Ui.dp(activity, 24), Ui.dp(activity, 12))
        }
        AlertDialog.Builder(activity, R.style.Theme_VibePier_Dialog)
            .setTitle(activity.getString(R.string.audit_diagnostics_title))
            .setView(ScrollView(activity).apply { addView(body) })
            .setPositiveButton(activity.getString(R.string.audit_diagnostics_copy)) { _, _ ->
                (activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                    .setPrimaryClip(ClipData.newPlainText(activity.getString(R.string.audit_diagnostics_title), report))
                Toast.makeText(activity, activity.getString(R.string.audit_diagnostics_copied), Toast.LENGTH_SHORT).show()
            }.setNegativeButton(activity.getString(R.string.close), null).showProtected()
    }

    internal fun report(context: Context, value: ConnectionDiagnostics.Snapshot): String {
        val path = context.getString(when (value.path) {
            "wifi" -> R.string.audit_diagnostics_wifi
            "bluetooth" -> R.string.bluetooth
            "direct" -> R.string.audit_diagnostics_direct
            "relay" -> R.string.cloud_relay
            else -> R.string.audit_diagnostics_unknown
        })
        val status = context.getString(if (value.connected) R.string.connected else R.string.disconnected)
        val authorization = context.getString(if (value.authorized) R.string.audit_diagnostics_authorized else R.string.audit_diagnostics_unauthorized)
        return listOf(context.getString(R.string.audit_diagnostics_scope),
            "VibePier ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) · Android ${Build.VERSION.SDK_INT}",
            context.getString(R.string.audit_diagnostics_path, path),
            context.getString(R.string.audit_diagnostics_state, status, authorization),
            context.getString(R.string.audit_diagnostics_restorations, value.restorations),
            context.getString(R.string.audit_diagnostics_last, value.recentEvent, value.recentError),
            context.getString(R.string.audit_diagnostics_warnings, value.warningCount),
            context.getString(R.string.audit_diagnostics_recovery)).joinToString("\n\n")
    }
}
