package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionTransport
import io.github.junweiup.vibepier.remote.features.updates.ApkInstallResult
import io.github.junweiup.vibepier.remote.features.updates.ApkReceiver
import io.github.junweiup.vibepier.remote.features.updates.AppUpdatesSheet
import io.github.junweiup.vibepier.remote.features.updates.AppVersionUpdates
import io.github.junweiup.vibepier.remote.features.updates.AvailableAppVersion

import android.app.Activity
import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.SystemClock
import android.util.Base64
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object ApkReceiverProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW && android.os.Build.MODEL.contains("sdk", ignoreCase = true)) { "Emulator review build required" }
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "offline"))
        val prefs = io.github.junweiup.vibepier.remote.core.security.PrivatePreferences.open(activity, "apk-install")
        prefs.edit().clear().commit()
        val bytes = test.context.assets.open("apk-probe.apk").use { it.readBytes() }
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val isolated = "apk-probe-${UUID.randomUUID()}"
        val context = object : ContextWrapper(test.targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String?, mode: Int) = baseContext.getSharedPreferences("$isolated-$name", mode)
        }
        val key = SecretKeySpec(ByteArray(32) { 7 }, "AES")
        lateinit var client: SessionClient
        lateinit var receiver: ApkReceiver
        var clientCreated = false
        var receiverCreated = false
        lateinit var initialUpdates: AppUpdatesSheet
        var transfer = UUID.randomUUID().toString()
        var corrupt = false
        var stopAtChunk = false
        var fastReordered = false
        var staged = false
        var updateRequests = 0
        val durableOffsets = java.util.concurrent.CopyOnWriteArrayList<Long>()
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        val offsets = java.util.concurrent.CopyOnWriteArrayList<Long>()
        val statuses = java.util.concurrent.CopyOnWriteArrayList<String>()
        val notices = java.util.concurrent.CopyOnWriteArrayList<String>()
        val frames = mutableMapOf<String, MutableMap<Int, String>>()
        fun respond(value: JSONObject, callback: (JSONObject) -> Unit, fastRequest: String? = null) {
            val packet = UUID.randomUUID().toString()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key); cipher.updateAAD("vibepier-session-v1|mac|${client.device}|$packet".toByteArray())
            val pieces = Base64.encodeToString(cipher.iv + cipher.doFinal(value.toString().toByteArray()), Base64.NO_WRAP).chunked(if (fastRequest == null) 900 else 7200)
            pieces.forEachIndexed { i, body -> callback(JSONObject().put("type", "vibepier-session1").put("sender", client.device).put("device", client.device).put("packet", packet).put("part", i).put("parts", pieces.size).put("data", body).apply { if (fastRequest != null) put("request", fastRequest) }) }
        }
        val transport = object : SessionTransport {
            override var mode = "bluetooth"
            override val enrollmentReady = true
            override var onSessionFrame: (JSONObject) -> Unit = {}
            override var onSessionPair: (ByteArray?) -> Unit = {}
            override fun requestSessionPair(device: String, name: String) {}
            override fun readSessionPair() {}
            override fun sendBinding(message: JSONObject) {
                val packet = message.getString("packet")
                val parts = frames.getOrPut(packet) { mutableMapOf() }; parts[message.getInt("part")] = message.getString("data")
                if (parts.size != message.getInt("parts")) return
                frames.remove(packet)
                val raw = Base64.decode((0 until parts.size).joinToString("") { parts.getValue(it) }, Base64.NO_WRAP)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, raw.copyOfRange(0, 12)))
                cipher.updateAAD("vibepier-session-v1|phone|${client.device}|$packet".toByteArray())
                val request = JSONObject(String(cipher.doFinal(raw.copyOfRange(12, raw.size))))
                val reply = JSONObject().put("id", request.getString("id")).put("ok", true)
                when (request.getString("op")) {
                    "androidUpdateStage" -> {
                        check(request.getString("packageName") == BuildConfig.APPLICATION_ID)
                        check(request.getInt("versionCode") == BuildConfig.VERSION_CODE)
                        staged = true; updateRequests++
                        reply.put("phase", "pending").put("transfer", transfer)
                    }
                    "apkOffer" -> {
                        if (!staged) { respond(reply, onSessionFrame); return }
                        reply.put("transfer", transfer).put("name", "VibePier.apk").put("size", bytes.size).put("sha256", if (corrupt) "0".repeat(64) else hash)
                        if (mode == "relay" && request.optInt("downloadVersion") == 1) reply.put("download", JSONObject()
                            .put("version", 1).put("token", request.getString("id")).put("fragmentChars", 7200).put("chunkBytes", 131072).put("window", 4))
                    }
                    "apkChunk" -> {
                        val offset = request.getInt("offset"); offsets.add(offset.toLong())
                        if (stopAtChunk && offset > 0) return
                        val end = minOf(bytes.size, offset + request.getInt("limit"))
                        reply.put("transfer", transfer).put("offset", offset).put("data", Base64.encodeToString(bytes.copyOfRange(offset, end), Base64.NO_WRAP))
                    }
                    "apkStatus" -> statuses.add(request.getString("state"))
                    else -> return
                }
                if (mode == "relay" && request.optString("op") == "apkChunk") {
                    check(request.has("downloadToken"))
                    durableOffsets.add(request.getLong("durableOffset"))
                    val offset = request.getInt("offset")
                    main.postDelayed({
                        if (offset == 0) fastReordered = offsets.size >= 4
                        respond(reply, onSessionFrame, request.getString("id"))
                    }, if (offset == 0) 150 else 0)
                } else respond(reply, onSessionFrame)
            }
        }
        fun waitUntil(condition: () -> Boolean) {
            val end = SystemClock.elapsedRealtime() + 30_000
            while (!condition() && SystemClock.elapsedRealtime() < end) SystemClock.sleep(100)
            check(condition()) { "Timed out: state=${prefs.getString("state", "")} detail=${prefs.getString("detail", "")} statuses=$statuses offsets=$offsets" }
        }
        fun dialog(): AlertDialog? = receiver.javaClass.getDeclaredField("dialog").apply { isAccessible = true }.get(receiver) as? AlertDialog
        fun clickSystem() {
            val labels = setOf("安装", "更新", "Install", "Update")
            val installers = setOf("com.android.packageinstaller", "com.google.android.packageinstaller")
            fun nodes() = labels.flatMap { text -> test.uiAutomation.rootInActiveWindow?.findAccessibilityNodeInfosByText(text) ?: emptyList() }.filter {
                it.packageName?.toString() in installers && it.text?.toString() in labels && it.isClickable && it.isEnabled
            }
            val end = SystemClock.elapsedRealtime() + 30_000
            while (SystemClock.elapsedRealtime() < end) {
                // PackageInstaller replaces its window during entry; keep the same observed node
                // for the click, then retry a fresh snapshot if that node already became stale.
                val button = nodes().lastOrNull()
                if (button?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) return
                SystemClock.sleep(100)
            }
            error("PackageInstaller confirmation button was not available")
        }
        var scanAttempts = 0
        var scanAttemptAt = 0L
        fun scanFixtureIfOffered() {
            if (scanAttempts >= 3 || SystemClock.elapsedRealtime() - scanAttemptAt < 1500) return
            val root = test.uiAutomation.rootInActiveWindow ?: return
            if (root.packageName?.toString() != "com.android.vending") return
            // This system prompt was observed on the disposable Google Play emulator.
            // Only submit our generated no-code/no-permission fixture for the normal scan.
            fun contains(text: String) = root.findAccessibilityNodeInfosByText(text).any { it.text?.toString() == text }
            if (!contains("VibePier Install Probe") || !contains("建议进行应用扫描")) return
            var button = root.findAccessibilityNodeInfosByText("扫描应用").firstOrNull { it.text?.toString() == "扫描应用" }
            while (button != null && !button.isClickable) button = button.parent
            if (button?.packageName?.toString() == "com.android.vending" && button.isEnabled) {
                // ACTION_CLICK only confirms dispatch, not that a transitioning window accepted it.
                // Re-read the exact fixture prompt before each bounded retry; never dismiss/bypass scanning.
                scanAttempts++
                scanAttemptAt = SystemClock.elapsedRealtime()
                button.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            }
        }
        try {
            test.runOnMainSync {
                client = SessionClient(context, transport); clientCreated = true
                client.connectionChanged(true); client.pair()
                transport.onSessionPair(JSONObject().put("state", "approved").put("device", client.device).put("key", Base64.encodeToString(ByteArray(32) { 7 }, Base64.NO_WRAP)).toString().toByteArray())
            }
            test.waitForIdleSync(); check(client.paired)
            test.runOnMainSync {
                transport.mode = "wifi"; receiver = ApkReceiver(activity, client, notices::add); receiverCreated = true
                stopAtChunk = true; receiver.resume()
                val versions = AppVersionUpdates(client) {}
                versions.javaClass.getDeclaredField("available").apply { isAccessible = true }
                    .set(versions, AvailableAppVersion(BuildConfig.VERSION_CODE.toLong() + 1, "synthetic-next"))
                val updates = AppUpdatesSheet(activity, client, versions, receiver)
                initialUpdates = updates
                updates.show(requestUpdate = true)
                updates.show(requestUpdate = true)
                repeat(3) { updates.refresh() }
            }
            // Session transmission is asynchronous; inspect only after the isolated host admits the request.
            waitUntil { updateRequests >= 1 }
            test.runOnMainSync {
                check(updateRequests == 1) { "Tapping a known update must stage it once without a Mac send action" }
                initialUpdates.close()
            }
            waitUntil { offsets.size >= 2 }
            test.runOnMainSync { receiver.pause(); client.connectionChanged(false) }
            val durable = java.io.File(activity.filesDir, "apk-install/$transfer.apk").length()
            check(durable > 0 && durable < bytes.size)
            test.runOnMainSync { stopAtChunk = false; offsets.clear(); client.connectionChanged(true); receiver.resume() }
            waitUntil { prefs.getString("state", "") == "received" }
            check(offsets.first() == durable) { "Did not resume durable length" }
            check(java.io.File(activity.filesDir, "apk-install/$transfer.apk").readBytes().contentEquals(bytes))
            // A fresh desktop task supersedes a downloaded APK which has not entered the system installer.
            transfer = UUID.randomUUID().toString()
            test.runOnMainSync { offsets.clear(); transport.mode = "relay"; client.connectionChanged(false); client.connectionChanged(true); receiver.check(true) }
            waitUntil { prefs.getString("state", "") == "received" && JSONObject(prefs.getString("offer", "{}")!!).optString("transfer") == transfer }
            check(fastReordered) { "Relay did not fill four slots before the first block arrived" }
            check(durableOffsets.take(4) == listOf(0L, 0L, 0L, 0L)) { "Requested offsets incorrectly acknowledged as durable" }
            check(java.io.File(activity.filesDir, "apk-install/$transfer.apk").readBytes().contentEquals(bytes))
            test.runOnMainSync { check(dialog() != null); dialog()!!.getButton(AlertDialog.BUTTON_NEGATIVE).performClick() }
            waitUntil { "cancelled" in statuses }
            check(!java.io.File(activity.filesDir, "apk-install/$transfer.apk").exists())
            test.runOnMainSync { corrupt = true; transfer = UUID.randomUUID().toString(); receiver.check(true) }
            waitUntil { "failed" in statuses }
            check(prefs.getString("detail", "") == activity.getString(R.string.apk_digest_failed))
            test.runOnMainSync { corrupt = false; transfer = UUID.randomUUID().toString(); receiver.check(true) }
            waitUntil { prefs.getString("state", "") == "received" }
            test.runOnMainSync { dialog()!!.getButton(AlertDialog.BUTTON_POSITIVE).performClick() }
            clickSystem()
            waitUntil { scanFixtureIfOffered(); prefs.getString("state", "") == "success" }
            // Callback can arrive while MainActivity is paused: persisted result is reported on return.
            test.runOnMainSync { receiver.resume() }
            waitUntil { "success" in statuses }
            val installed = test.uiAutomation.executeShellCommand("dumpsys package io.github.junweiup.vibepier.installprobe").use { descriptor -> java.io.FileInputStream(descriptor.fileDescriptor).bufferedReader().readText() }
            check(installed.contains("versionName=1.0")) // Arbitrary installed packages are hidden by package visibility rules.
            // Unacknowledged receipts retry without replaying local feedback, even after recreation.
            val successNotice = activity.getString(R.string.apk_installed)
            check(prefs.getString("notified", "") == "$transfer:success")
            // MainActivity also owns a receiver; seed a fresh local notice after its resume completed.
            val beforeNotice = notices.size
            test.runOnMainSync {
                client.connectionChanged(false)
                prefs.edit().remove("reported").remove("notified").commit()
                receiver.check(true)
            }
            check(notices.size == beforeNotice + 1 && notices.last() == successNotice)
            val noticeCount = notices.size
            test.runOnMainSync {
                repeat(5) { receiver.check(true); receiver.pause(); receiver.resume() }
                receiver.close()
                receiver = ApkReceiver(activity, client, notices::add)
                receiver.resume()
            }
            check(notices.size == noticeCount) { "Offline/recreated receiver repeated the installation notice" }
            val successReports = statuses.count { it == "success" }
            test.runOnMainSync { client.connectionChanged(true); receiver.check(true) }
            waitUntil { prefs.getString("reported", "") == transfer }
            check(statuses.count { it == "success" } > successReports) { "Suppressing notice suppressed receipt retry" }
            check(notices.size == noticeCount)
            check(notices.count { it == activity.getString(R.string.apk_install_failed, activity.getString(R.string.apk_digest_failed)) } == 1)
            // Self-replacement fallback only completes an active update of our own package.
            prefs.edit().putString("state", "installing").putString("package", "other.app").commit()
            test.runOnMainSync { ApkInstallResult().onReceive(activity, Intent(Intent.ACTION_MY_PACKAGE_REPLACED)) }
            check(prefs.getString("state", "") == "installing")
            prefs.edit().putString("package", activity.packageName).commit()
            test.runOnMainSync { ApkInstallResult().onReceive(activity, Intent(Intent.ACTION_MY_PACKAGE_REPLACED)) }
            check(prefs.getString("state", "") == "success")
            return "PASS: known update tap stages once without a Mac send action, negotiated relay APK, four-slot out-of-order receive and durable acknowledgments, encrypted APK RPC, durable offset resume after disconnect, exact file bytes/SHA256, new offer replaces downloaded/unconfirmed APK, cancellation cleanup, corrupt SHA256 blocked, PackageInstaller system confirmation and actual APK installation, persisted success ACK, single terminal notice across offline retries and receiver recreation, self-update replacement fallback scoped to active own-package install\n"
        } finally {
            test.runOnMainSync { if (receiverCreated) receiver.close(); if (clientCreated) client.close(); activity.finish() }
            if (clientCreated) io.github.junweiup.vibepier.remote.core.security.DeviceKeys(context).clear()
            for (name in listOf("sessions", "device-identity")) test.targetContext.deleteSharedPreferences("$isolated-$name")
            prefs.edit().clear().commit()
        }
    }
}
