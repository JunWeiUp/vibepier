package io.github.junweiup.vibepier.remote

import android.app.Activity
import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.session.TaskCompletionNotifications
import io.github.junweiup.vibepier.remote.core.transport.ConnectionDiagnostics
import io.github.junweiup.vibepier.remote.core.transport.TransportLog
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.settings.ConnectionDiagnosticsSheet
import io.github.junweiup.vibepier.remote.features.settings.SettingsSheet
import io.github.junweiup.vibepier.remote.features.updates.AvailableAppVersion
import io.github.junweiup.vibepier.remote.features.voice.PhoneVoiceController
import org.json.JSONObject
import java.io.File

/** Opt-in review-app test: fixture conversations and synthetic audio only; never reads a live Mac or records audio. */
object AuditRuntimeProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        var activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval")) as MainActivity
        fun field(value: Any, name: String) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }
        fun views(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) } else emptyList()
        fun main(block: () -> Unit) {
            var error: Throwable? = null
            test.runOnMainSync { try { block() } catch (failure: Throwable) { error = failure } }
            error?.let { throw it }
        }
        fun settle() { SystemClock.sleep(250); test.waitForIdleSync() }
        var monitor: Instrumentation.ActivityMonitor? = null
        val syntheticFile = File(test.targetContext.cacheDir, "audit-picker-${System.nanoTime()}.txt").apply { writeText("synthetic attachment") }
        try {
            settle()
            var selection = "wifi"
            lateinit var sheet: SettingsSheet
            lateinit var wifi: CanvasLabel
            main {
                sheet = SettingsSheet(activity)
                sheet.section("Synthetic", listOf(SettingsSheet.Choice("Connection", { selection },
                    SettingsSheet.Badge(R.drawable.ic_wifi), listOf("wifi" to "Wi-Fi", "relay" to "Relay"), { selection }, { selection = it; sheet.refresh() })))
                sheet.show {}
                val dialog = field(sheet, "dialog").get(sheet) as AlertDialog
                wifi = views(dialog.window!!.decorView).filterIsInstance<CanvasLabel>().first { it.text == "Wi-Fi" }
                wifi.isFocusableInTouchMode = true
                check(wifi.requestFocus())
                selection = "relay"; repeat(5) { sheet.refresh() }
                check(views(dialog.window!!.decorView).any { it === wifi }) { "Settings refresh replaced a focused choice" }
                check(wifi.isFocused)
                wifi.performClick(); check(selection == "wifi") { "Previously selected choice did not update after switching back" }
                sheet.dismiss()
            }
            lateinit var route: JSONObject
            main {
                val panel = activity.sessionNavigation.panel!!
                views(panel).first { it.contentDescription?.toString()?.startsWith(activity.getString(R.string.session_open_session)) == true }.performClick()
            }
            settle()
            main {
                route = activity.sessionNavigation.panel!!.navigationState()
                check(!route.getBoolean("drawer") && route.getString("thread").isNotBlank())
                val navigation = activity.sessionNavigation
                field(navigation, "pickingAttachment").setBoolean(navigation, true)
                field(navigation, "pickerState").set(navigation, JSONObject(route.toString()))
            }
            monitor = test.addMonitor(MainActivity::class.java.name, null, false)
            main { activity.recreate() }
            activity = test.waitForMonitorWithTimeout(monitor, 5_000) as? MainActivity ?: error("Activity recreation did not complete")
            test.removeMonitor(monitor); monitor = null
            settle()
            main {
                val navigation = activity.sessionNavigation
                val panel = navigation.panel!!
                val restored = panel.navigationState()
                check(restored.getString("thread") == route.getString("thread")) { "Activity lost the selected conversation" }
                check(navigation.pickingAttachment) { "Activity lost pending picker ownership" }
                check(!panel.restoreNavigationState(JSONObject(route.toString()).put("source", "other-authorization")))
                check(!panel.addRestoredPhoneAttachment(Uri.fromFile(syntheticFile), JSONObject(route.toString()).put("source", "other-authorization")))
                panel.suspend()
                navigation.activityResult(940, Activity.RESULT_OK, Intent().setData(Uri.fromFile(syntheticFile)))
                val pending = panel.navigationState()
                check(pending.optString("pendingUri") == Uri.fromFile(syntheticFile).toString()) { "Picker result was dropped before the verified page returned" }
                check(pending.getJSONObject("pendingTarget").getString("thread") == route.getString("thread"))
                panel.resume()
            }
            settle()
            main {
                val intent = Intent(activity, MainActivity::class.java)
                    .putExtra("io.github.junweiup.vibepier.completedProvider", "claude")
                activity.javaClass.getDeclaredMethod("onNewIntent", Intent::class.java).invoke(activity, intent)
                val panel = activity.sessionNavigation.panel!!
                check(panel.navigationState().getString("provider") == "claude")
                check(panel.navigationState().getBoolean("drawer"))
                check(TaskCompletionNotifications.takeRoute(Intent().putExtra("io.github.junweiup.vibepier.completedProvider", "untrusted"), "synthetic-authorization") == null)
                val versions = activity.javaClass.getDeclaredMethod("getAppVersions").apply { isAccessible = true }.invoke(activity)!!
                field(versions, "available").set(versions, AvailableAppVersion(BuildConfig.VERSION_CODE.toLong() + 1, "synthetic-next"))
                activity.javaClass.getDeclaredMethod("showUpdates").apply { isAccessible = true }.invoke(activity)
                val updates = field(activity, "updateSheet").get(activity)!!
                val dialog = field(updates, "dialog").get(updates) as AlertDialog
                val request = views(dialog.window!!.decorView).filterIsInstance<CanvasLabel>().first { it.text == activity.getString(R.string.audit_update_request) }
                check(!request.isEnabled) { "Offline update request was enabled" }
                check(views(dialog.window!!.decorView).any { it.contentDescription?.toString()?.contains(activity.getString(R.string.audit_update_offline)) == true ||
                    it.contentDescription?.toString()?.contains(activity.getString(R.string.audit_update_authorization_required)) == true })
                dialog.dismiss()
                val diagnostics = ConnectionDiagnostics().apply {
                    observe("relay", false, false, true)
                    record(TransportLog.Event.RELAY_CONNECTION, "tls-failed", true)
                }
                val report = ConnectionDiagnosticsSheet.report(activity, diagnostics.snapshot())
                check(report.contains("tls-failed"))
                check(!report.contains("synthetic-next"))
            }
            syntheticVoicePathLoss()
            savedAuthorizationBinding(test)
            return "PASS: stable settings choices/focus; Activity and pending picker route restoration; persistent authorization binding and re-pair rejection; provider notification navigation; offline update gating; sanitized diagnostics; synthetic audio-path loss cleanup. No microphone or live Mac used."
        } finally {
            monitor?.let(test::removeMonitor)
            main { activity.finish() }
            syntheticFile.delete()
        }
    }

    private fun syntheticVoicePathLoss() {
        val events = mutableListOf<String>()
        var capturedFrame: ((ByteArray) -> Unit)? = null
        val tasks = mutableSetOf<Runnable>()
        val voice = PhoneVoiceController(object : PhoneVoiceController.Transport {
            override fun begin(session: String, keys: String, app: String, rate: Int) { events += "begin" }
            override fun end(session: String) { events += "end" }
            override fun frame(session: String, sequence: Int, bytes: ByteArray) { events += "frame" }
        }, object : PhoneVoiceController.Capture {
            override fun start(rate: Int, packetMs: Int, frame: (ByteArray) -> Unit, failure: (String) -> Unit) { capturedFrame = frame }
            override fun stop() { events += "stop" }
        }, object : PhoneVoiceController.Scheduler {
            override fun post(task: Runnable, delayMs: Long) { tasks += task }
            override fun cancel(task: Runnable) { tasks -= task }
        }, {}, { events += "failure" }, "timeout", { "synthetic" })
        voice.begin("", "synthetic", false); voice.receive("synthetic", true, 20, "")
        voice.transportChanged(false, "path lost"); capturedFrame!!(byteArrayOf(1))
        check(!voice.active && tasks.isEmpty())
        check(events.takeLast(3) == listOf("stop", "end", "failure"))
        check("frame" !in events)
    }

    private fun savedAuthorizationBinding(test: Instrumentation) {
        val keys = DeviceKeys(test.targetContext)
        // This app id is the emulator-only review fixture. Do not alter any previously authorized fixture binding.
        if (keys.authorized) {
            val identity = keys.authorizationIdentity
            check(!identity.isNullOrBlank())
            check(DeviceKeys(test.targetContext).authorizationIdentity == identity)
            check(test.targetContext.getSharedPreferences("device-identity", Activity.MODE_PRIVATE).getString("authorizationIdentity", null) == identity)
            return
        }
        val root = ByteArray(32) { (it + 1).toByte() }
        try {
            keys.install(root)
            val identity = keys.authorizationIdentity
            check(!identity.isNullOrBlank())
            check(DeviceKeys(test.targetContext).authorizationIdentity == identity)
            check(test.targetContext.getSharedPreferences("device-identity", Activity.MODE_PRIVATE).getString("authorizationIdentity", null) == identity)
            keys.install(root)
            check(keys.authorizationIdentity != identity) { "Re-pairing preserved stale navigation authorization" }
        } finally { keys.clear(); root.fill(0) }
    }
}
