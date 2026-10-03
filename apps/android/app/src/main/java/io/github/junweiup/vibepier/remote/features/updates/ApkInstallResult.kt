package io.github.junweiup.vibepier.remote.features.updates

import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller

/** Explicit private callback survives self-update/process death; never launches UI in the background. */
class ApkInstallResult : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = PrivatePreferences.open(context, "apk-install")
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            if (prefs.getString("package", "") == context.packageName && prefs.getString("state", "") == "installing") {
                if (!prefs.edit().putString("state", "success").putString("detail", "").remove("confirmation").commit()) return
            }
        } else {
            if (intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != prefs.getInt("session", -2)) return
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
            if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                @Suppress("DEPRECATION") val confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (!prefs.edit().putString("confirmation", confirmation?.toUri(Intent.URI_INTENT_SCHEME)).commit()) return
            } else {
                if (!prefs.edit().putString("state", when (status) {
                    PackageInstaller.STATUS_SUCCESS -> "success"
                    PackageInstaller.STATUS_FAILURE_ABORTED -> "cancelled"
                    else -> "failed"
                }).putString("detail", intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)?.take(180) ?: "")
                    .remove("confirmation").commit()) return
            }
        }
        changed?.invoke()
    }
    companion object { var changed: (() -> Unit)? = null }
}
