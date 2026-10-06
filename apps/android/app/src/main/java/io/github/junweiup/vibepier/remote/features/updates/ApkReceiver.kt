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
import io.github.junweiup.vibepier.remote.core.files.BinaryFileClient
import android.widget.Toast
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Bounded authenticated download window; only contiguous, synced bytes become resumable progress. */
class ApkReceiver(
    private val activity: Activity,
    private val client: SessionClient,
    private val showResultNotice: (String) -> Unit = { Toast.makeText(activity, it, Toast.LENGTH_LONG).show() }
) {
    private val prefs = PrivatePreferences.open(activity, "apk-install")
    private val root = File(activity.filesDir, "apk-install").apply { mkdirs() }
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var foreground = false
    private val fileGuard = ApkDownloadGuard()
    private var binaryTransfer: BinaryFileClient? = null
    private var binaryTicket: String? = null
    private var downloadStarted = 0L
    private var downloadStartOffset = 0L
    @Volatile private var downloadConnection: String? = null
    private fun invalidateDownload() {
        binaryTransfer?.cancel(); binaryTransfer = null
        if (binaryTicket != null && client.online && downloadConnection == client.versionConnectionID)
            client.request("fileCancel", JSONObject().put("ticket", binaryTicket)) {}
        binaryTicket = null
        fileGuard.cancel()
        busy = false
        client.cancelAPKReads()
    }
    private fun downloadActive(token: Int) = active(token) && downloadConnection != null && downloadConnection == client.versionConnectionID
    private fun interruptDownload() {
        invalidateDownload()
        dialog?.dismiss(); dialog = null
    }
    private val generation get() = fileGuard.generation
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
        foreground = false; invalidateDownload(); installing = false
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
        client.request("apkOffer", JSONObject()) { value ->
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
                    synchronized(fileGuard) { root.listFiles()?.forEach { it.delete() } }
                    require(prefs.edit().putString("offer", value.toString()).putString("state", "receiving").remove("session").remove("confirmation").commit())
                }
                installing = false
                showProgress(value)
                startDownload(value, token)
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
                invalidateDownload()
                finish(value, "cancelled", activity.getString(R.string.apk_receive_cancelled))
            }.setCancelable(false).showProtected()
    }
    private fun startDownload(value: JSONObject, token: Int) {
        downloadConnection = client.versionConnectionID
        val path = file(value)
        busy = true
        io.execute {
            val result = runCatching {
                fileGuard.durableLength(token, path) { downloadActive(token) }
            }
            main.post {
                if (!active(token)) return@post
                if (!downloadActive(token)) { interruptDownload(); return@post }
                val offset = result.getOrElse { fail(value, activity.getString(R.string.apk_write_failed)); return@post }
                if (offset > value.getLong("size")) { fail(value, activity.getString(R.string.apk_invalid_length)); return@post }
                if (offset == value.getLong("size")) { verify(value, token); return@post }
                if (value.optInt("binaryVersion") == 1) {
                    client.request("apkBinary", JSONObject().put("transfer", value.getString("transfer")).put("offset", offset)) binaryOffer@{ response ->
                        if (!downloadActive(token)) return@binaryOffer
                        val profile = response.optJSONObject("binary")
                        if (response.optBoolean("ok") && profile != null) startBinary(value, token, offset, profile)
                        else fail(value, activity.getString(R.string.file_binary_required))
                    }
                    return@post
                }
                fail(value, activity.getString(R.string.file_binary_required))
            }
        }
    }
    private fun startBinary(value: JSONObject, token: Int, offset: Long, profile: JSONObject) {
        val transfer = BinaryFileClient { downloadActive(token) }; binaryTransfer = transfer; binaryTicket = profile.getString("id")
        val host = client.binaryHost
        downloadStarted = android.os.SystemClock.elapsedRealtime(); downloadStartOffset = offset
        watchConnection(token)
        var lastReport = 0L
        io.execute {
            var committed = offset
            val result = runCatching {
                transfer.download(profile, host, value.getLong("size"), offset) { bytes ->
                    fileGuard.append(token, file(value), committed, bytes) { downloadActive(token) }
                    committed += bytes.size
                    val confirmed = committed
                    main.post {
                        if (!downloadActive(token)) return@post
                        val now = android.os.SystemClock.elapsedRealtime()
                        if (now - lastReport >= 500) {
                            lastReport = now
                            client.request("apkProgress", JSONObject().put("transfer", value.getString("transfer"))
                                .put("binaryTicket", profile.getString("id")).put("durableOffset", confirmed)) {}
                        }
                        val elapsed = (android.os.SystemClock.elapsedRealtime() - downloadStarted).coerceAtLeast(1)
                        val rate = (confirmed - downloadStartOffset) * 1000 / elapsed
                        val speed = if (rate > 0) activity.getString(R.string.apk_transfer_speed, rate / 1024, (value.getLong("size") - confirmed + rate - 1) / rate) else ""
                        dialog?.setMessage("${value.optString("name")}\n${confirmed * 100 / value.getLong("size")}% · ${confirmed / 1024} / ${value.getLong("size") / 1024} KB" + speed)
                    }
                }
            }
            main.post {
                if (!downloadActive(token)) return@post
                binaryTransfer = null
                if (result.isSuccess) verify(value, token)
                else fail(value, activity.getString(R.string.file_transfer_interrupted))
            }
        }
    }
    private fun watchConnection(token: Int) {
        main.postDelayed({
            if (active(token) && binaryTransfer != null) {
                if (!downloadActive(token)) interruptDownload() else watchConnection(token)
            }
        }, 250)
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
                synchronized(fileGuard) {
                    check(active(token))
                    require(prefs.edit().putString("package", info.packageName).commit())
                }
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
        invalidateDownload(); installing = false
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
        synchronized(fileGuard) { file(value).delete() }; result()
    }
    private fun fail(value: JSONObject, detail: String) {
        invalidateDownload()
        dialog?.dismiss(); dialog = null; busy = false; installing = false
        finish(value, "failed", detail)
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
        if (state !in setOf("success", "failed", "cancelled")) return
        val completed = value.optString("transfer")
        // Local presentation is independent of the network receipt, including across process restarts.
        val notice = "$completed:$state"
        if (prefs.getString("notified", "") != notice) {
            if (!store(prefs.edit().putString("notified", notice))) return
            showResultNotice(when (state) {
                "success" -> activity.getString(R.string.apk_installed)
                "cancelled" -> activity.getString(R.string.apk_install_cancelled)
                else -> activity.getString(R.string.apk_install_failed, prefs.getString("detail", ""))
            })
        }
        if (prefs.getString("reported", "") != completed && !reporting) {
            installing = false; reporting = true
            if (!store(prefs.edit().putString("handled", completed))) { reporting = false; return }
            handled = completed
            synchronized(fileGuard) { file(value).delete() }
            report(value, state, prefs.getString("detail", "") ?: "") { ok ->
                reporting = false
                if (ok) store(prefs.edit().putString("reported", value.optString("transfer")))
            }
        }
    }
    fun statusSummary(): String {
        val state = prefs.getString("state", "") ?: ""
        return activity.getString(when (state) {
            "receiving" -> if (busy) R.string.apk_receiving else R.string.apk_waiting_resume
            "received" -> R.string.audit_update_ready_to_install
            "permission" -> R.string.audit_update_waiting_permission
            "installing" -> R.string.apk_awaiting_system
            "success" -> R.string.apk_last_success
            "failed" -> R.string.apk_last_failed
            "cancelled" -> R.string.apk_last_cancelled
            else -> R.string.apk_no_task
        })
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
