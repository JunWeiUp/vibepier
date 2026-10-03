package io.github.junweiup.vibepier.remote.features.updates

import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences

import io.github.junweiup.vibepier.remote.core.ui.showProtected
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.session.SessionClient

import android.app.Activity
import android.app.AlertDialog
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Base64
import android.widget.Toast
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Pulls one authenticated chunk at a time. Files stay private, and resume by their actual durable length. */
class ApkReceiver(private val activity: Activity, private val client: SessionClient) {
    private val prefs = PrivatePreferences.open(activity, "apk-install")
    private val root = File(activity.filesDir, "apk-install").apply { mkdirs() }
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var foreground = false
    @Volatile private var generation = 0
    private var busy = false
    private var lastCheck = 0L
    private var dialog: AlertDialog? = null
    private var statusDialog: AlertDialog? = null
    private var installing = false
    private var reporting = false
    private var handled = prefs.getString("handled", "") ?: ""
    private fun file(value: JSONObject) = File(root, value.getString("transfer") + ".apk")
    private fun active(token: Int) = foreground && token == generation && !activity.isDestroyed
    fun resume() {
        foreground = true
        ApkInstallResult.changed = { main.post { if (foreground) result() } }
        result()
        if (prefs.getString("state", "") in setOf("permission", "received")) savedOffer()?.let { showInstall(it) }
        check(true)
    }
    fun pause() {
        foreground = false; generation++; busy = false; installing = false
        client.cancelAPKReads()
        dialog?.dismiss(); dialog = null
        statusDialog?.dismiss(); statusDialog = null
        ApkInstallResult.changed = null
    }
    fun close() { pause(); io.shutdownNow() }
    private fun savedOffer(): JSONObject? {
        val text = prefs.getString("offer", null) ?: return null
        return try { JSONObject(text) } catch (_: Exception) { null }
    }
    fun check(force: Boolean = false) {
        result()
        val state = prefs.getString("state", "")
        val awaitingConfirmation = state in setOf("permission", "received")
        if (!foreground || busy || (installing && !awaitingConfirmation) || !client.online || !client.paired || state == "installing") return
        val now = android.os.SystemClock.elapsedRealtime()
        if (!force && now - lastCheck < 8_000) return
        lastCheck = now; busy = true
        val token = generation
        client.request("apkOffer") { value ->
            if (!active(token)) return@request
            busy = false
            if (!value.optBoolean("ok") || value.optString("transfer").isEmpty() || value.optString("transfer") == handled) return@request
            if (awaitingConfirmation && savedOffer()?.optString("transfer") == value.optString("transfer")) return@request
            try {
                require(value.getString("transfer").matches(Regex("[a-fA-F0-9-]{36}")))
                require(value.getLong("size") in 1..512L * 1024 * 1024)
                require(value.getString("sha256").matches(Regex("[a-fA-F0-9]{64}")))
                val previous = savedOffer()
                if (previous?.optString("transfer") != value.getString("transfer")) {
                    root.listFiles()?.forEach { it.delete() }
                    require(prefs.edit().putString("offer", value.toString()).putString("state", "receiving").remove("session").remove("confirmation").commit())
                }
                installing = false
                showProgress(value)
                next(value, token)
            } catch (error: Exception) { fail(value, error.message ?: activity.getString(R.string.apk_invalid_task)) }
        }
    }
    private fun showProgress(value: JSONObject) {
        statusDialog?.dismiss(); statusDialog = null
        dialog?.dismiss()
        dialog = AlertDialog.Builder(activity, R.style.Theme_VibePier_Dialog)
            .setTitle(activity.getString(R.string.apk_receiving))
            .setMessage(value.optString("name") + activity.getString(R.string.apk_preparing))
            .setNegativeButton(activity.getString(R.string.apk_cancel_receive)) { _, _ ->
                generation++; busy = false; client.cancelAPKReads()
                finish(value, "cancelled", activity.getString(R.string.apk_receive_cancelled))
            }.setCancelable(false).showProtected()
    }
    private fun next(value: JSONObject, token: Int) {
        if (!active(token)) return
        val path = file(value); val size = value.getLong("size"); val offset = path.length()
        if (offset > size) { fail(value, activity.getString(R.string.apk_invalid_length)); return }
        dialog?.setMessage("${value.optString("name")}\n${offset * 100 / size}% · ${offset / 1024} / ${size / 1024} KB" + if (client.bluetooth) activity.getString(R.string.apk_ble_hint) else "")
        if (offset == size) { verify(value, token); return }
        busy = true
        client.request("apkChunk", JSONObject().put("transfer", value.getString("transfer")).put("offset", offset).put("limit", client.attachmentChunkBytes)) { reply ->
            if (!active(token)) return@request
            if (!reply.optBoolean("ok")) {
                busy = false; dialog?.dismiss(); dialog = null
                if (reply.optBoolean("cancelled")) { finish(value, "cancelled", activity.getString(R.string.apk_mac_cancelled)); return@request }
                Toast.makeText(activity, reply.optString("error", activity.getString(R.string.apk_interrupted)), Toast.LENGTH_LONG).show()
                // Keep durable partial bytes. Next connection/status resumes without trusting a remote offset.
                return@request
            }
            io.execute {
                val error = runCatching {
                    require(reply.getString("transfer") == value.getString("transfer") && reply.getLong("offset") == offset)
                    val bytes = Base64.decode(reply.getString("data"), Base64.NO_WRAP)
                    require(bytes.isNotEmpty() && bytes.size <= 128 * 1024 && offset + bytes.size <= size)
                    RandomAccessFile(path, "rw").use { out -> out.seek(offset); out.write(bytes); out.fd.sync() }
                }.exceptionOrNull()
                main.post {
                    if (active(token)) {
                        busy = false
                        if (error != null) fail(value, error.message ?: activity.getString(R.string.apk_write_failed)) else next(value, token)
                    }
                }
            }
        }
    }
    private fun verify(value: JSONObject, token: Int) {
        busy = true; dialog?.setMessage(activity.getString(R.string.apk_verifying, value.optString("name")))
        io.execute {
            val error = runCatching {
                val digest = MessageDigest.getInstance("SHA-256")
                file(value).inputStream().use { input ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
                }
                require(digest.digest().joinToString("") { "%02x".format(it) }.equals(value.getString("sha256"), true)) { activity.getString(R.string.apk_digest_failed) }
                @Suppress("DEPRECATION") val info = activity.packageManager.getPackageArchiveInfo(file(value).path, 0)
                require(info != null && info.splitNames.isNullOrEmpty()) { activity.getString(R.string.apk_invalid_file) }
                require(prefs.edit().putString("package", info.packageName).commit())
            }.exceptionOrNull()
            main.post {
                if (active(token)) {
                    busy = false; dialog?.dismiss(); dialog = null
                    if (error != null) fail(value, error.message ?: activity.getString(R.string.apk_verify_failed))
                    else if (setState(value, "received")) showInstall(value)
                }
            }
        }
    }
    private fun showInstall(value: JSONObject) {
        if (!foreground || dialog != null) return
        statusDialog?.dismiss(); statusDialog = null
        installing = true
        dialog = AlertDialog.Builder(activity, R.style.Theme_VibePier_Dialog)
            .setTitle(activity.getString(R.string.apk_install_title))
            .setMessage(activity.getString(R.string.apk_install_message, value.optString("name"), prefs.getString("package", "")))
            .setPositiveButton(activity.getString(R.string.apk_continue_install)) { _, _ ->
                dialog = null
                if (!activity.packageManager.canRequestPackageInstalls()) {
                    if (!setState(value, "permission")) return@setPositiveButton
                    try { activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))) }
                    catch (error: Exception) { fail(value, error.message ?: activity.getString(R.string.apk_permission_failed)) }
                } else commit(value)
            }
            .setNegativeButton(activity.getString(R.string.apk_cancel)) { _, _ -> dialog = null; installing = false; finish(value, "cancelled", activity.getString(R.string.apk_install_cancelled_user)) }
            .setCancelable(false).showProtected()
    }
    private fun commit(value: JSONObject) {
        busy = true
        val token = generation
        io.execute {
            val installer = activity.packageManager.packageInstaller
            var sessionId = -1
            val error = runCatching {
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                    setSize(value.getLong("size"))
                    setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                }
                sessionId = installer.createSession(params)
                installer.openSession(sessionId).use { session ->
                    session.openWrite("base.apk", 0, value.getLong("size")).use { out ->
                        file(value).inputStream().use { it.copyTo(out) }; session.fsync(out)
                    }
                }
            }.exceptionOrNull()
            val created = sessionId
            main.post {
                if (!active(token)) { if (created >= 0) installer.abandonSession(created); return@post }
                busy = false
                if (error != null) {
                    if (created >= 0) installer.abandonSession(created)
                    fail(value, error.message ?: activity.getString(R.string.apk_prepare_failed))
                } else {
                    try {
                        check(prefs.edit().putInt("session", created).putString("state", "installing").commit())
                        val intent = Intent(activity, ApkInstallResult::class.java)
                        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                        val callback = PendingIntent.getBroadcast(activity, created, intent, flags)
                        installer.openSession(created).use { it.commit(callback.intentSender) }
                        report(value, "installing")
                    } catch (e: Exception) { installer.abandonSession(created); fail(value, e.message ?: activity.getString(R.string.apk_request_failed)) }
                }
            }
        }
    }
    private fun store(editor: android.content.SharedPreferences.Editor): Boolean {
        if (editor.commit()) return true
        generation++; busy = false; installing = false
        client.cancelAPKReads()
        dialog?.dismiss(); dialog = null
        Toast.makeText(activity, activity.getString(R.string.apk_state_save_failed), Toast.LENGTH_LONG).show()
        return false
    }
    private fun setState(value: JSONObject, state: String, detail: String = ""): Boolean {
        if (!store(prefs.edit().putString("state", state).putString("detail", detail))) return false
        report(value, state, detail)
        return true
    }
    private fun report(value: JSONObject, state: String, detail: String = "", callback: (Boolean) -> Unit = {}) {
        if (!client.online || !client.paired) { callback(false); return }
        client.request("apkStatus", JSONObject().put("transfer", value.optString("transfer")).put("state", state).put("detail", detail)) { callback(it.optBoolean("ok")) }
    }
    private fun finish(value: JSONObject, state: String, detail: String) {
        val completed = value.optString("transfer")
        if (!store(prefs.edit().putString("handled", completed).putString("state", state).putString("detail", detail))) return
        handled = completed
        file(value).delete(); result()
    }
    private fun fail(value: JSONObject, detail: String) {
        dialog?.dismiss(); dialog = null; busy = false; installing = false
        finish(value, "failed", detail)
        Toast.makeText(activity, activity.getString(R.string.apk_install_failed, detail), Toast.LENGTH_LONG).show()
    }
    private fun result() {
        if (!foreground) return
        val value = savedOffer() ?: return
        val confirmation = prefs.getString("confirmation", null)
        if (confirmation != null) {
            if (!store(prefs.edit().remove("confirmation"))) return
            try { activity.startActivity(Intent.parseUri(confirmation, Intent.URI_INTENT_SCHEME)) }
            catch (error: Exception) { fail(value, error.message ?: activity.getString(R.string.apk_confirmation_failed)) }
            return
        }
        val state = prefs.getString("state", "") ?: ""
        if (state in setOf("success", "failed", "cancelled") && prefs.getString("reported", "") != value.optString("transfer") && !reporting) {
            installing = false; reporting = true
            val completed = value.optString("transfer")
            if (!store(prefs.edit().putString("handled", completed))) { reporting = false; return }
            handled = completed
            file(value).delete()
            report(value, state, prefs.getString("detail", "") ?: "") { ok ->
                reporting = false
                if (ok) store(prefs.edit().putString("reported", value.optString("transfer")))
            }
            Toast.makeText(activity, when (state) { "success" -> activity.getString(R.string.apk_installed); "cancelled" -> activity.getString(R.string.apk_install_cancelled); else -> activity.getString(R.string.apk_install_failed, prefs.getString("detail", "")) }, Toast.LENGTH_LONG).show()
        }
    }
    fun showStatus() {
        if (statusDialog?.isShowing == true) return
        check(true)
        if (dialog?.isShowing == true) return
        val value = savedOffer()
        val state = prefs.getString("state", "") ?: ""
        if (value != null && state in setOf("received", "permission")) {
            showInstall(value)
            return
        }
        val connection = when {
            !client.paired -> activity.getString(R.string.apk_first_authorization)
            !client.online -> activity.getString(R.string.apk_offline)
            else -> activity.getString(R.string.apk_help)
        }
        val status = when (state) {
            "receiving" -> activity.getString(R.string.apk_waiting_resume)
            "installing" -> activity.getString(R.string.apk_awaiting_system)
            "success" -> activity.getString(R.string.apk_last_success)
            "failed" -> activity.getString(R.string.apk_last_failed)
            "cancelled" -> activity.getString(R.string.apk_last_cancelled)
            else -> activity.getString(R.string.apk_no_task)
        }
        val detail = if (value == null) status else listOf(status, value.optString("name"),
            prefs.getString("detail", "") ?: "").filter { it.isNotBlank() }.joinToString("\n")
        statusDialog = AlertDialog.Builder(activity, R.style.Theme_VibePier_Dialog)
            .setTitle(activity.getString(R.string.apk_status_title))
            .setMessage("$detail\n\n$connection")
            .setNegativeButton(activity.getString(R.string.apk_back), null)
            .apply { if (client.paired && client.online) setPositiveButton(activity.getString(R.string.apk_check_tasks)) { _, _ -> check(true) } }
            .showProtected().also { it.setOnDismissListener { statusDialog = null } }
    }
}
