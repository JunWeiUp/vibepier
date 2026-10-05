package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.security.PrivatePreferences

import io.github.junweiup.vibepier.remote.core.ui.showProtected
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.security.RelaySettingsStore
import io.github.junweiup.vibepier.remote.core.transport.BluetoothLink
import io.github.junweiup.vibepier.remote.core.transport.RelayLink
import io.github.junweiup.vibepier.remote.core.transport.RemoteConnectionService
import io.github.junweiup.vibepier.remote.core.transport.RemoteSender
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.IconControl
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.protectControls
import io.github.junweiup.vibepier.remote.features.remote.AppShortcutView
import io.github.junweiup.vibepier.remote.features.remote.BindingProfiles
import io.github.junweiup.vibepier.remote.features.remote.BindingSync
import io.github.junweiup.vibepier.remote.features.remote.DockApplications
import io.github.junweiup.vibepier.remote.features.remote.KeyConfigPage
import io.github.junweiup.vibepier.remote.features.remote.Keys
import io.github.junweiup.vibepier.remote.features.remote.Pad
import io.github.junweiup.vibepier.remote.features.remote.Palette
import io.github.junweiup.vibepier.remote.features.remote.TalkPad
import io.github.junweiup.vibepier.remote.features.navigation.ConversationNavigation
import io.github.junweiup.vibepier.remote.features.settings.SettingsSheet
import io.github.junweiup.vibepier.remote.features.updates.ApkReceiver
import io.github.junweiup.vibepier.remote.features.updates.AppUpdatesSheet
import io.github.junweiup.vibepier.remote.features.settings.ConnectionDiagnosticsSheet
import io.github.junweiup.vibepier.remote.core.session.TaskCompletionNotifications
import io.github.junweiup.vibepier.remote.features.usage.AppUsageLabels
import io.github.junweiup.vibepier.remote.features.usage.AppUsageCache
import io.github.junweiup.vibepier.remote.features.usage.AppUsagePage
import io.github.junweiup.vibepier.remote.features.voice.PhoneVoiceController
import io.github.junweiup.vibepier.remote.features.voice.PhoneMicCapture

import android.app.Activity
import android.app.AlertDialog
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.text.Editable
import android.text.TextWatcher
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.EditText
import android.widget.GridLayout
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.Toast
import android.widget.CheckBox
import android.widget.HorizontalScrollView
import android.widget.BaseAdapter
import android.view.ViewGroup

class MainActivity : Activity() {
    // Review fixtures stay isolated unless a lifecycle probe explicitly opts in.
    private val backgroundConnection get() = !BuildConfig.DESIGN_REVIEW || intent.getBooleanExtra("backgroundConnectionProbe", false)
    private val sender by lazy {
        if (backgroundConnection) RemoteConnectionService.acquire(this, this)
        else RemoteSender(this, simulateLaunchLoss = BuildConfig.DESIGN_REVIEW && intent.getBooleanExtra("simulateLaunchLoss", false))
    }
    private val handler = Handler(Looper.getMainLooper())
    private val codex by lazy { if (backgroundConnection) sender.sessionClient else SessionClient(this, sender) }
    private val relayStore by lazy { RelaySettingsStore(this) }
    private var relaySetupPending = false
    private var relaySetupAfter = 0L
    private var settingsUpdateDot: View? = null
    private val appVersions by lazy {
        io.github.junweiup.vibepier.remote.features.updates.AppVersionUpdates(codex) {
            settingsUpdateDot?.visibility = if (appVersionsAvailable()) View.VISIBLE else View.GONE
            settingsSheet?.refresh()
            updateSheet?.refresh()
        }
    }
    private fun appVersionsAvailable(): Boolean = appVersions.available != null
    private val apkReceiver by lazy { ApkReceiver(this, codex) }
    private var updateSheet: AppUpdatesSheet? = null
    private lateinit var rootHost: FrameLayout
    internal val sessionNavigation by lazy {
        ConversationNavigation(this, { rootHost }, codex, codexFixture) {
            pads.values.forEach { it.releaseIfHeld() }; stopPhoneMic()
        }
    }
    private val codexFixture get() = if (BuildConfig.DESIGN_REVIEW) intent.getStringExtra("codexFixture") ?: "" else ""
    private lateinit var subtitle: CanvasLabel
    private lateinit var connectionTitle: CanvasLabel
    private lateinit var connectionDot: View
    private lateinit var profileHint: CanvasLabel
    private lateinit var appIcon: ImageView
    private lateinit var appLetter: CanvasLabel
    private var appIconSource = ""
    private val pads = mutableMapOf<String, Pad>()
    private val appSlots = mutableListOf<AppShortcutView>()
    private lateinit var applicationDockScroll: HorizontalScrollView
    private lateinit var applicationDockRow: LinearLayout
    private var appShortcuts = emptyList<RemoteSender.AppShortcut>()
    private var dockEntries = emptyList<RemoteSender.AppShortcut>()
    private var pendingDockAction = "activate"
    private lateinit var dockCaption: CanvasLabel
    private lateinit var homeViewport: io.github.junweiup.vibepier.remote.features.remote.HomeViewport
    private var pendingApplication: String? = null
    private var switchError = ""
    private var applicationPicker: io.github.junweiup.vibepier.remote.features.remote.ApplicationPickerPage? = null
    private var shortcutsSyncing = true
    private val switchTimeout = Runnable {
        pendingApplication = null
        switchError = if (pendingDockAction == "hide") getString(R.string.hide_failed) else getString(R.string.switch_failed)
        pendingDockAction = "activate"
        refreshBindings()
        dockCaption.announceForAccessibility(dockCaption.text)
    }
    private lateinit var applicationLabel: CanvasLabel
    private var application: RemoteSender.Application? = null
    private var settingsSheet: SettingsSheet? = null
    private var languageDialog: AlertDialog? = null
    private var keyConfigPage: KeyConfigPage? = null
    private var appUsagePage: AppUsagePage? = null
    private var pendingBluetoothSelection = false
    private val bindingSync by lazy { BindingSync(prefs, sender::sendBinding,
        beforeChange = { pads.values.forEach { it.releaseIfHeld() } },
        changed = { if (::applicationLabel.isInitialized) refreshBindings() },
        notice = { Toast.makeText(this, it, Toast.LENGTH_LONG).show() }, conflictMessage = getString(R.string.binding_conflict)) }
    private val phoneVoice by lazy {
        val capture = PhoneMicCapture(resources)
        PhoneVoiceController(
            transport = object : PhoneVoiceController.Transport {
                override fun begin(session: String, keys: String, app: String, rate: Int) = sender.microphone("begin", session, keys, app, rate)
                override fun end(session: String) = sender.microphone("end", session)
                override fun frame(session: String, sequence: Int, bytes: ByteArray) = sender.microphoneFrame(session, sequence, bytes)
            },
            capture = object : PhoneVoiceController.Capture {
                override fun start(rate: Int, packetMs: Int, frame: (ByteArray) -> Unit, failure: (String) -> Unit) = capture.start(rate, frame, failure, packetMs)
                override fun stop() = capture.stop()
            },
            scheduler = object : PhoneVoiceController.Scheduler {
                override fun post(task: Runnable, delayMs: Long) { handler.postDelayed(task, delayMs) }
                override fun cancel(task: Runnable) { handler.removeCallbacks(task) }
            },
            stateChanged = { state -> phoneVoiceState = state; refreshMicrophoneHint() },
            failed = { message -> pads["talk"]?.releaseIfHeld(); Toast.makeText(this, message, Toast.LENGTH_LONG).show() },
            timeoutMessage = getString(R.string.mic_connection_timeout),
        )
    }
    private var phoneVoiceState = PhoneVoiceController.State.IDLE
    private var activeMicrophoneSource: String? = null
    /** The relay carries no audio, so the phone button falls back to the Mac microphone there. */
    private fun usePhoneMic() = prefs.getString("microphoneSource", "mac") == "phone" && sender.phoneAudioSupported
    private fun refreshMicrophoneHint() {
        (pads["talk"] as? TalkPad)?.microphoneHint = when {
            phoneVoiceState == PhoneVoiceController.State.CONNECTING -> getString(R.string.phone_connecting)
            phoneVoiceState == PhoneVoiceController.State.RECORDING -> getString(R.string.phone_recording)
            activeMicrophoneSource == "mac" -> getString(R.string.mac_microphone)
            usePhoneMic() -> getString(R.string.phone_microphone)
            prefs.getString("microphoneSource", "mac") == "phone" -> getString(R.string.audit_mic_fallback)
            else -> getString(R.string.mac_microphone)
        }
    }
    private fun beginPhoneMic(keys: String, app: String?) {
        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            pads["talk"]?.releaseIfHeld()
            requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 42)
            return
        }
        phoneVoice.begin(keys, app, sender.mode == "bluetooth")
    }
    private fun stopPhoneMic() = phoneVoice.stop()
    private val prefs get() = PrivatePreferences.open(this, localClassName)

    /** The hotkey bound to a control, as the Mac will press it. */
    private fun profile() = application?.bundleID?.takeIf { it.isNotBlank() }
    private fun profileName(id: String?) = when {
        id == null -> getString(R.string.general_shortcuts)
        id == application?.bundleID -> application?.name ?: id
        else -> prefs.getString("appName.$id", null) ?: id
    }
    private fun preferenceKey(control: String, profile: String?) =
        BindingProfiles.key(control, profile)
    private fun keys(control: String, profile: String? = profile()): String =
        BindingProfiles.resolve(control, profile) { prefs.getString(it, null) }

    private fun controlTitle(control: String, scope: String?): String {
        val resource = when (control) {
            "knob-left" -> R.string.rotate_left
            "knob-right" -> R.string.rotate_right
            "cancel" -> R.string.cancel
            "confirm" -> R.string.confirm
            "talk" -> R.string.voice
            else -> R.string.delete
        }
        return BindingProfiles.resolveLabel(control, scope, getString(resource)) { prefs.getString(it, null) }
    }

    private fun overridden(control: String, profile: String?) =
        profile != null && prefs.getString(preferenceKey(control, profile), null)?.let(Keys::normalize) != null

    private fun refreshBindings() {
        showTarget()
        val app = profile()
        pads.forEach { (control, pad) ->
            pad.label = controlTitle(control, app)
            pad.binding = keys(control)
            pad.custom = overridden(control, app)
            pad.isEnabled = application != null && pendingApplication == null
            pad.alpha = if (pad.isEnabled) 1f else 0.72f
        }
        refreshApplicationDock()
        applicationLabel.text = application?.name ?: getString(R.string.awaiting_application)
        val custom = pads.values.count { it.custom }
        profileHint.text = when {
            application == null -> getString(R.string.connect_for_application)
            custom == 0 -> getString(R.string.using_general_bindings)
            else -> getString(R.string.custom_bindings_detail, custom)
        }
        showApplicationIcon()
        keyConfigPage?.refresh()
    }

    /** The current Mac application's own icon, or its initial on a neutral tile until one arrives. */
    private fun showApplicationIcon() {
        val encoded = application?.iconPNG.orEmpty()
        if (encoded != appIconSource) {
            appIconSource = encoded
            val bitmap = try {
                if (encoded.isBlank()) null else android.util.Base64.decode(encoded, android.util.Base64.DEFAULT).let { android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size) }
            } catch (_: IllegalArgumentException) { null }
            appIcon.setImageBitmap(bitmap)
            appIcon.visibility = if (bitmap == null) View.GONE else View.VISIBLE
        }
        appLetter.text = application?.name?.take(1)?.uppercase() ?: "·"
        appLetter.visibility = if (appIcon.visibility == View.VISIBLE) View.GONE else View.VISIBLE
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Protect this window and each dialog; hold gestures still belong to the controls.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.protectControls()
        sender.host = validHost(prefs.getString("host", "") ?: "")
        sender.lastKnownHost = validHost(prefs.getString("lastMac", "") ?: "")

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Palette.background)
            setPadding(dp(20), dp(4), dp(20), dp(12))
        }
        root.addView(header(), LinearLayout.LayoutParams(MATCH, WRAP))
        root.addView(profileHeader(), LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(6); bottomMargin = dp(8) })

        // The AU05 layout: the knob turns on top, then cancel and confirm, then talk.
        root.addView(row(
            rotatePad(R.drawable.ic_rotate_left, getString(R.string.rotate_left), "knob-left"),
            rotatePad(R.drawable.ic_rotate_right, getString(R.string.rotate_right), "knob-right"),
        ), LinearLayout.LayoutParams(MATCH, dp(if (resources.configuration.fontScale > 1.2f) 96 else 92)))

        root.addView(row(
            keyPad(R.drawable.ic_close, getString(R.string.cancel), Palette.red, "cancel"),
            keyPad(R.drawable.ic_check, getString(R.string.confirm), Palette.green, "confirm"),
        ), LinearLayout.LayoutParams(MATCH, dp(if (resources.configuration.fontScale > 1.2f) 96 else 92)).apply { topMargin = dp(10) })

        // All home controls share the same scale, including the circular voice target.
        val voice = talkPad()
        val talkArea = FrameLayout(this).apply {
            setPadding(dp(20), 0, dp(20), dp(8))
            addView(voice, FrameLayout.LayoutParams(MATCH, MATCH))
        }
        val dockBottom = if (resources.configuration.fontScale <= 1.2f) 32 else 8
        val dock = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), dp(dockBottom))
            background = panelBackground(Palette.background, 0, false)
            // Independent fixed action row: neither voice sizing nor shortcut scrolling can compress Delete.
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(CanvasLabel(context).apply {
                    text = getString(R.string.voice_finish_hint)
                    textSize = 12f; setTextColor(Palette.muted); maxLines = 2
                }, LinearLayout.LayoutParams(0, WRAP, 1f).apply { marginEnd = dp(12) })
                addView(deletePad(), LinearLayout.LayoutParams(dp(140), dp(48)))
            }, LinearLayout.LayoutParams(MATCH, dp(48)).apply { bottomMargin = dp(8) })
            dockCaption = CanvasLabel(context).apply {
                textSize = 11f
                text = getString(R.string.switch_apps_manage_mac)
                setTextColor(Palette.faint)
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(dockCaption, LinearLayout.LayoutParams(0, WRAP, 1f))
                addView(Ui.button(context, getString(R.string.app_picker_manage), Ui.Button.TEXT) { showApplicationPicker() })
            }, LinearLayout.LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(6) })
            addView(applicationDock(), LinearLayout.LayoutParams(MATCH, dp(68)))
        }
        val controls = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Palette.background)
            addView(root, LinearLayout.LayoutParams(MATCH, 0, 1f))
            addView(talkArea, LinearLayout.LayoutParams(MATCH, dp(if (resources.configuration.fontScale > 1.2f) 280 else 260)))
            addView(dock, LinearLayout.LayoutParams(MATCH, WRAP))
        }
        homeViewport = io.github.junweiup.vibepier.remote.features.remote.HomeViewport(this).apply {
            addView(controls)
            // System bars stay outside the scaled canvas, including in edge-to-edge mode.
            setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars() or android.view.WindowInsets.Type.displayCutout())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                insets
            }
        }
        rootHost = FrameLayout(this).apply { addView(homeViewport, FrameLayout.LayoutParams(MATCH, MATCH)) }
        setContentView(rootHost)
        refreshBindings()
        codex.onAPKAvailable = { apkReceiver.check(true); appVersions.check() }
        bindingSync // Capture existing local preferences before receiving the first Mac snapshot.
        sender.onMicrophoneState = { message -> handler.post {
            if (!isDestroyed) phoneVoice.receive(message.optString("session"), message.optBoolean("ready"),
                message.optInt("packetMs", 20), message.optString("error", getString(R.string.phone_voice_ended)))
        } }
        refreshMicrophoneHint()
        sender.onBindings = { data -> handler.post { if (!isDestroyed) bindingSync.snapshot(data) } }
        sender.onBindingAck = { data -> handler.post { if (!isDestroyed) bindingSync.acknowledge(data) } }
        sender.onBindingsReady = { handler.post { if (!isDestroyed) bindingSync.flush() } }
        sender.onApplication = { app ->
            handler.post {
                if (!isDestroyed) {
                    if (app == null) { bindingSync.disconnected(); pads.values.forEach { it.releaseIfHeld() } }
                    else if (app.bundleID != application?.bundleID) {
                        switchError = ""
                        pads["knob-press"]?.releaseIfHeld()
                        pads["knob-left"]?.releaseIfHeld()
                        pads["knob-right"]?.releaseIfHeld()
                    }
                    if (app == null || pendingApplication != null &&
                        (if (pendingDockAction == "hide") app.bundleID != pendingApplication else app.bundleID == pendingApplication)) {
                        pendingApplication = null
                        pendingDockAction = "activate"
                        handler.removeCallbacks(switchTimeout)
                    }
                    application = app
                    if (app != null && app.bundleID.isNotBlank() && prefs.getString("appName.${app.bundleID}", null) != app.name) {
                        prefs.edit().putString("appName.${app.bundleID}", app.name).apply()
                    }
                    if (app != null && prefs.getString("lastMac", "") != sender.lastKnownHost) {
                        prefs.edit().putString("lastMac", sender.lastKnownHost).apply()
                    }
                    refreshBindings()
                }
            }
        }
        sender.onShortcuts = { entries -> handler.post {
            if (!isDestroyed) { shortcutsSyncing = entries.isEmpty(); appShortcuts = entries; refreshApplicationDock() }
        } }
        sender.onConnectionChanged = { handler.post { if (!isDestroyed) showTarget() } }
        sender.relaySettings = try { relayStore.migrate(prefs) } catch (_: Exception) { null }
        val firstConnection = backgroundConnection && !prefs.contains("transport") && codexFixture.isBlank()
        val savedMode = prefs.getString("transport", if (firstConnection) "bluetooth" else "wifi")?.takeIf { it == "bluetooth" || it == "relay" } ?: "wifi"
        sender.changeMode(savedMode)
        if (firstConnection) handler.post { if (!isDestroyed) connectBluetooth() }
        sender.replayUIState()
        appShortcuts = sender.cachedShortcuts; shortcutsSyncing = appShortcuts.isEmpty(); refreshApplicationDock()
        val completedRoute = TaskCompletionNotifications.takeRoute(intent, sender.sessionClient.authorizationIdentity)
        if (completedRoute != null) sessionNavigation.showCompletion(completedRoute)
        else if (!sessionNavigation.restoreState(savedInstanceState) && codexFixture.isNotBlank()) handler.post { showCodex() }
        if (completedRoute == null && savedInstanceState?.getBoolean("settingsOpen") == true) handler.post {
            if (!isDestroyed && !isFinishing) showConnectionOptions()
        }
    }

    private fun showCodex() = sessionNavigation.show()
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        TaskCompletionNotifications.takeRoute(intent, sender.sessionClient.authorizationIdentity)?.let { sessionNavigation.showCompletion(it) }
    }
    fun pickCodexAttachment(images: Boolean) = sessionNavigation.pickAttachment(images)
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        sessionNavigation.activityResult(requestCode, resultCode, data)
    }
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (sessionNavigation.back()) return
        super.onBackPressed()
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code == 42) {
            val granted = checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                prefs.edit().putString("microphoneSource", "mac").apply()
                Toast.makeText(this, getString(R.string.recording_denied), Toast.LENGTH_LONG).show()
            } else prefs.edit().putString("microphoneSource", "phone").apply()
            refreshMicrophoneHint()
        }
        if (code == 41 && pendingBluetoothSelection) {
            pendingBluetoothSelection = false
            if (BluetoothLink.permissions().all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) connectBluetooth()
            else Toast.makeText(this, getString(R.string.nearby_denied), Toast.LENGTH_LONG).show()
        }
        showTarget()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) pads.values.forEach { it.releaseIfHeld() }
    }
    override fun onResume() {
        super.onResume()
        apkReceiver.resume()
        appVersions.resume()
        sessionNavigation.resume()
        appUsagePage?.resume()
        if (backgroundConnection) {
            sender.ensureWatching()
            if (backgroundConnection) try { RemoteConnectionService.start(this) }
            catch (_: IllegalStateException) { Toast.makeText(this, getString(R.string.background_start_denied), Toast.LENGTH_LONG).show() }
        }
    }
    override fun onPause() {
        updateSheet?.close()
        apkReceiver.pause()
        appVersions.pause()
        appUsagePage?.suspend()
        sessionNavigation.suspend()
        pads.values.forEach { it.releaseIfHeld() }
        stopPhoneMic()
        // Suspend UI work, not the transport: Wi-Fi/BLE/relay and in-flight receipts remain live.
        pendingApplication = null
        handler.removeCallbacks(switchTimeout)
        super.onPause()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("settingsOpen", settingsSheet?.isShowing == true)
        sessionNavigation.saveState(outState)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        languageDialog?.dismiss()
        applicationPicker?.dismiss()
        settingsSheet?.dismiss()
        keyConfigPage?.dismiss()
        appUsagePage?.dismiss()
        updateSheet?.close()
        handler.removeCallbacksAndMessages(null)
        apkReceiver.close()
        sessionNavigation.close(preservePendingAttachment = isChangingConfigurations)
        codex.onEvent = {}; codex.onState = {}; codex.onAPKAvailable = {}
        if (!backgroundConnection) codex.close()
        if (backgroundConnection) RemoteConnectionService.release(this) else sender.close()
        super.onDestroy()
    }

    private fun showApplicationPicker(slot: Int? = null) {
        if (applicationPicker?.dialog?.isShowing == true) return
        pads.values.forEach { it.releaseIfHeld() }; stopPhoneMic()
        applicationPicker = io.github.junweiup.vibepier.remote.features.remote.ApplicationPickerPage(this,
            request = { op, fields, reply -> codex.request(op, fields, callback = reply) },
            initialSlot = slot, source = { prefs.getString("bindingSync.server", "") ?: "" }, onDismiss = { applicationPicker = null }).also { it.show() }
    }

    private fun applicationDock() = HorizontalScrollView(this).apply {
        applicationDockScroll = this
        isFillViewport = true
        isHorizontalScrollBarEnabled = false
        isHorizontalFadingEdgeEnabled = true
        setFadingEdgeLength(dp(18))
        applicationDockRow = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
        addView(applicationDockRow, ViewGroup.LayoutParams(WRAP, MATCH))
        addOnLayoutChangeListener { _, left, _, right, _, oldLeft, _, oldRight, _ ->
            if (right - left != oldRight - oldLeft) sizeApplicationDock()
        }
        rebuildApplicationDock(5)
    }

    private fun rebuildApplicationDock(count: Int) {
        applicationDockRow.removeAllViews()
        appSlots.clear()
        for (index in 0 until count) {
            val tile = AppShortcutView(this).apply {
                setOnClickListener { clicked ->
                    if (clicked !in appSlots) return@setOnClickListener
                    val entry = dockEntries.getOrNull(index)
                    if (entry == null) {
                        if (application == null) showConnectionOptions()
                        else Toast.makeText(context, getString(R.string.icons_sync_wait), Toast.LENGTH_SHORT).show()
                    } else if (entry.bundleID.isBlank()) {
                        showApplicationPicker(entry.slot)
                    } else if (!entry.available) {
                        Toast.makeText(context, getString(R.string.application_missing), Toast.LENGTH_SHORT).show()
                    } else if (application == null) {
                        showConnectionOptions()
                    } else {
                        pads.values.forEach { it.releaseIfHeld() }
                        val action = DockApplications.action(entry, application) ?: return@setOnClickListener
                        stopPhoneMic()
                        switchError = ""
                        pendingDockAction = action
                        pendingApplication = entry.bundleID
                        refreshBindings()
                        dockCaption.text = if (action == "hide") getString(R.string.hiding_app, entry.name) else getString(R.string.switching_app, entry.name)
                        dockCaption.setTextColor(Palette.green)
                        handler.removeCallbacks(switchTimeout)
                        handler.postDelayed(switchTimeout, 5000)
                        sender.launchApplication(entry, action)
                    }
                }
            }
            tile.setOnLongClickListener {
                val entry = dockEntries.getOrNull(index)
                if (entry != null && entry.slot >= 0) { showApplicationPicker(entry.slot); true } else false
            }
            appSlots.add(tile)
            applicationDockRow.addView(tile, LinearLayout.LayoutParams(dp(52), MATCH).apply {
                if (index > 0) marginStart = dp(6)
            })
        }
        sizeApplicationDock()
    }

    private fun sizeApplicationDock() {
        if (!::applicationDockScroll.isInitialized || applicationDockScroll.width == 0) return
        val visible = minOf(5, appSlots.size)
        val width = ((applicationDockScroll.width - dp(6) * (visible - 1)) / visible).coerceAtLeast(dp(48))
        appSlots.forEach { tile ->
            val params = tile.layoutParams as LinearLayout.LayoutParams
            if (params.width != width) { params.width = width; tile.layoutParams = params }
        }
    }

    private fun refreshApplicationDock() {
        dockEntries = DockApplications.entries(appShortcuts, application)
        if (::applicationDockRow.isInitialized && appSlots.size != maxOf(5, dockEntries.size)) {
            rebuildApplicationDock(maxOf(5, dockEntries.size))
        }
        if (::dockCaption.isInitialized && pendingApplication == null) {
            dockCaption.text = when {
                application == null -> getString(R.string.connect_to_switch_apps)
                switchError.isNotEmpty() -> switchError
                shortcutsSyncing -> getString(R.string.icons_syncing)
                dockEntries.size > 5 -> getString(R.string.app_hide_scroll_hint)
                else -> getString(R.string.app_hide_hint)
            }
            dockCaption.setTextColor(if (switchError.isNotEmpty()) Palette.amber else Palette.faint)
        }
        appSlots.forEachIndexed { index, tile ->
            tile.update(dockEntries.getOrNull(index), application?.bundleID, pendingApplication, pendingDockAction)
            tile.isEnabled = pendingApplication == null && !DockApplications.isTemporaryPlaceholder(dockEntries.getOrNull(index))
            tile.alpha = if (application == null) 0.65f else 1f
        }
    }

    /** One line: the connection capsule (tap to change transport), then sessions and settings. */
    private fun header(): View {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(56)
        }
        connectionTitle = CanvasLabel(this).apply {
            textSize = 14f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(Palette.text)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        subtitle = CanvasLabel(this).apply {
            textSize = 11.5f
            setTextColor(Palette.muted)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        connectionDot = View(this)
        bar.addView(LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(52)
            setPadding(dp(12), dp(7), dp(6), dp(7))
            background = panelBackground(Palette.surface1, 14, false)
            isFocusable = true
            setOnClickListener { showTransportOptions() }
            addView(connectionDot, LinearLayout.LayoutParams(dp(15), dp(15)).apply { marginEnd = dp(10) })
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(connectionTitle, LinearLayout.LayoutParams(MATCH, WRAP))
                addView(subtitle, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(1) })
            }, LinearLayout.LayoutParams(0, WRAP, 1f))
            addView(CanvasLabel(context).apply {
                text = "›"; textSize = 18f; gravity = Gravity.CENTER; setTextColor(Palette.faint)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(dp(18), WRAP))
        }, LinearLayout.LayoutParams(0, WRAP, 1f))
        bar.addView(IconControl(this, IconControl.Icon.SESSIONS, getString(R.string.open_sessions_accessibility), Palette.muted) { showCodex() }.apply {
            background = panelBackground(Palette.surface1, 14, false)
        }, LinearLayout.LayoutParams(dp(48), dp(48)).apply { marginStart = dp(8) })
        bar.addView(FrameLayout(this).apply {
            addView(IconControl(this@MainActivity, IconControl.Icon.SETTINGS, getString(R.string.open_settings_accessibility), Palette.muted) { showConnectionOptions() }.apply {
                background = panelBackground(Palette.surface1, 14, false)
            }, FrameLayout.LayoutParams(MATCH, MATCH))
            settingsUpdateDot = View(this@MainActivity).apply {
                background = Ui.roundRect(this@MainActivity, 0xFFE45B65.toInt(), 4)
                visibility = if (appVersionsAvailable()) View.VISIBLE else View.GONE
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            addView(settingsUpdateDot, FrameLayout.LayoutParams(dp(8), dp(8), Gravity.TOP or Gravity.END).apply { topMargin = dp(7); marginEnd = dp(7) })
        }, LinearLayout.LayoutParams(dp(48), dp(48)).apply { marginStart = dp(8) })
        showTarget()
        return bar
    }

    private fun panelBackground(color: Int, radius: Int, border: Boolean = false) =
        Ui.roundRect(this, color, radius, if (border) Palette.outline else null)

    /** The current Mac application in one row; its key count says whether this app has its own bindings. */
    private fun profileHeader() = LinearLayout(this).apply {
        setPadding(dp(2), dp(4), 0, dp(4))
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(56)
        addView(FrameLayout(context).apply {
            appLetter = CanvasLabel(context).apply {
                textSize = 15f; gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD
                setTextColor(Palette.text); background = panelBackground(Palette.surface3, 11)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            appIcon = ImageView(context).apply { visibility = View.GONE; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
            addView(appLetter, FrameLayout.LayoutParams(MATCH, MATCH))
            addView(appIcon, FrameLayout.LayoutParams(MATCH, MATCH))
        }, LinearLayout.LayoutParams(dp(40), dp(40)).apply { marginEnd = dp(12) })
        val titleBlock = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setOnClickListener { showKeyConfig() }
            applicationLabel = CanvasLabel(context).apply {
                textSize = 20f
                setTextColor(Palette.text)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }
            addView(applicationLabel, LinearLayout.LayoutParams(MATCH, WRAP))
            profileHint = CanvasLabel(context).apply { textSize = 12f; setTextColor(Palette.muted); maxLines = 1; ellipsize = TextUtils.TruncateAt.END }
            addView(profileHint, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(2) })
        }
        addView(titleBlock, LinearLayout.LayoutParams(0, WRAP, 1f))
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            // An inset background replaces the view's padding, so the padding is set after it.
            background = Ui.inset(context, panelBackground(Palette.accentContainer, 13), 3)
            setPadding(dp(16), 0, dp(18), 0)
            isFocusable = true
            contentDescription = getString(R.string.edit_keys_accessibility)
            setOnClickListener { showKeyConfig() }
            addView(ImageView(context).apply {
                setImageResource(R.drawable.ic_edit)
                setColorFilter(Palette.accent)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(dp(16), dp(16)).apply { marginEnd = dp(8) })
            addView(CanvasLabel(context).apply {
                text = getString(R.string.keys); textSize = 14f; typeface = Ui.medium; setTextColor(Palette.accent)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            })
        }, LinearLayout.LayoutParams(WRAP, dp(48)).apply { marginStart = dp(12) })
    }

    private fun keyProfiles(): List<KeyConfigPage.Profile> {
        val saved = BindingProfiles.savedProfiles(prefs.all).associate { it.bundleID to it.overrideCount }.toMutableMap()
        application?.bundleID?.takeIf { it.isNotBlank() }?.let { saved.putIfAbsent(it, 0) }
        return listOf(KeyConfigPage.Profile(null, getString(R.string.general_bindings), getString(R.string.general_bindings_detail))) +
            saved.keys.sortedBy { profileName(it).lowercase() }.map { id ->
                val count = saved[id] ?: 0
                KeyConfigPage.Profile(id, profileName(id) + if (id == application?.bundleID) getString(R.string.current_app_suffix) else "",
                    if (count == 0) getString(R.string.inherited_bindings_detail) else getString(R.string.custom_binding_count, count))
            }
    }

    private fun showKeyConfig() {
        if (keyConfigPage?.dialog?.isShowing == true) return
        pads.values.forEach { it.releaseIfHeld() }
        stopPhoneMic()
        settingsSheet?.dismiss()
        keyConfigPage = KeyConfigPage(this, profile(), ::keyProfiles, ::profileName,
            resolve = { control, scope -> keys(control, scope) },
            title = ::controlTitle,
            overridden = ::overridden,
            save = ::saveKeys,
            onDismiss = { keyConfigPage = null }
        ).also { it.show() }
    }

    private fun optionRows(options: List<Pair<String, String>>) = object : BaseAdapter() {
        override fun getCount() = options.size
        override fun getItem(position: Int) = options[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getView(position: Int, recycled: View?, parent: ViewGroup): View = LinearLayout(this@MainActivity).apply {
            orientation = LinearLayout.VERTICAL
            minimumHeight = dp(72)
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(24), dp(12), dp(24), dp(12))
            addView(CanvasLabel(context).apply {
                text = options[position].first
                textSize = 16f
                setTextColor(Palette.text)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                maxLines = 2
            })
            addView(CanvasLabel(context).apply {
                text = options[position].second
                textSize = 12f
                setTextColor(Palette.muted)
            }, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(4) })
        }
    }

    private fun saveKeys(control: String, keys: String?, scope: String?, label: String) {
        val name = preferenceKey(control, scope)
        bindingSync.edit(name, keys, scope?.let(::profileName) ?: "", label)
    }

    private fun showTarget() {
        val connected = application != null && sender.connectedHost != null
        codex.connectionChanged(connected)
        phoneVoice.transportChanged(connected && usePhoneMic(), getString(R.string.audit_mic_path_lost))
        refreshMicrophoneHint()
        codex.requestAuthorizationIfNeeded()
        syncRelayFromAuthorizedMac()
        apkReceiver.check()
        appVersions.connectionChanged()
        sessionNavigation.connectionChanged()
        connectionTitle.text = when {
            connected -> getString(R.string.mac_connected)
            sender.enrollmentReady && !codex.paired -> getString(R.string.awaiting_mac_approval)
            else -> getString(R.string.connecting_mac)
        }
        subtitle.text = when (sender.mode) {
            "bluetooth" -> if (connected) getString(R.string.bluetooth_status, sender.connectedHost ?: getString(R.string.control_ready)) else if (sender.enrollmentReady && !codex.paired) codex.authorizationMessage else sender.bluetoothStatus
            "relay" -> if (!connected) sender.relayStatus else if (sender.isDirect) getString(R.string.direct_ready) else getString(R.string.relay_mac_voice)
            else -> if (connected) "Wi-Fi · ${sender.connectedHost}" else sender.wifiStatus
        }
        val color = if (connected) Palette.accent else Palette.amber
        connectionDot.background = android.graphics.drawable.LayerDrawable(arrayOf(
            GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color); alpha = 56 },
            GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color) },
        )).apply { setLayerInset(1, dp(4), dp(4), dp(4), dp(4)) }
        settingsSheet?.refresh()
        updateSheet?.refresh()
        appUsagePage?.connectionChanged()
    }

    /** Setup never travels through discovery or an untrusted relay; only the approved BLE channel. */
    private fun syncRelayFromAuthorizedMac() {
        if (codexFixture.isNotBlank() || !codex.online || !codex.paired || sender.mode != "bluetooth" ||
            relaySetupPending || android.os.SystemClock.elapsedRealtime() < relaySetupAfter) return
        relaySetupPending = true
        relaySetupAfter = android.os.SystemClock.elapsedRealtime() + 60_000
        codex.request("relaySetup") { result ->
            relaySetupPending = false
            if (isDestroyed || !result.optBoolean("ok")) return@request
            val settings = RelayLink.parsePairing(result.optString("code")) ?: return@request
            try {
                relayStore.save(settings)
                sender.relaySettings = settings
                settingsSheet?.refresh()
            } catch (_: Exception) {
                Toast.makeText(this, getString(R.string.relay_save_failed), Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun transportName() = when (sender.mode) { "bluetooth" -> getString(R.string.bluetooth); "relay" -> getString(R.string.cloud_relay); else -> "Wi-Fi" }

    private fun showConnectionOptions() {
        if (settingsSheet?.isShowing == true) return
        pads.values.forEach { it.releaseIfHeld() }
        stopPhoneMic()
        val sheet = SettingsSheet(this)
        settingsSheet = sheet
        val neutral = { icon: Int -> SettingsSheet.Badge(icon) }
        sheet.section(getString(R.string.general_settings), listOf(
            SettingsSheet.Row(getString(R.string.app_language), { languageLabel() },
                neutral(R.drawable.ic_language), ::showLanguagePicker)
        ))
        sheet.section(getString(R.string.connection), listOf(
            SettingsSheet.Choice(getString(R.string.connection_mode), {
                if (application != null && sender.connectedHost != null) getString(R.string.connected) else getString(R.string.disconnected)
            }, SettingsSheet.Badge(R.drawable.ic_wifi, Palette.accent, Palette.accentContainer),
                listOf("wifi" to "Wi-Fi", "bluetooth" to getString(R.string.bluetooth), "relay" to getString(R.string.relay)), { sender.mode }, ::selectTransport),
            SettingsSheet.Row(getString(R.string.connection_setup), {
                when (sender.mode) {
                    "bluetooth" -> sender.connectedHost ?: getString(R.string.bluetooth_setup_detail)
                    "relay" -> sender.relaySettings?.let { getString(R.string.relay_saved_room, it.room) } ?: getString(R.string.relay_not_configured)
                    else -> sender.host.ifBlank { sender.connectedHost?.let { getString(R.string.discovered_host, it) } ?: getString(R.string.discover_mac) }
                }
            }, neutral(R.drawable.ic_monitor), {
                when (sender.mode) {
                    "bluetooth" -> connectBluetooth()
                    "relay" -> editRelay()
                    else -> editHost()
                }
            }),
            SettingsSheet.Row(getString(R.string.reconnect), { getString(R.string.find_via, transportName()) }, neutral(R.drawable.ic_rotate_right), {
                sender.watch(true)
                showTarget()
                Toast.makeText(this, getString(R.string.reconnecting_via, transportName()), Toast.LENGTH_SHORT).show()
            }),
            SettingsSheet.Row(getString(R.string.audit_diagnostics_title), { getString(R.string.audit_diagnostics_summary) },
                neutral(R.drawable.ic_monitor)) { ConnectionDiagnosticsSheet.show(this) }
        ))
        sheet.section(getString(R.string.voice), listOf(
            SettingsSheet.Choice(getString(R.string.voice_input), {
                if (usePhoneMic()) getString(R.string.phone_mic_hold_detail)
                else if (prefs.getString("microphoneSource", "mac") == "phone") getString(R.string.relay_mic_fallback)
                else getString(R.string.mac_default_input)
            }, SettingsSheet.Badge(R.drawable.ic_mic, Palette.blue, Palette.blueContainer),
                listOf("mac" to "Mac", "phone" to getString(R.string.phone)), { prefs.getString("microphoneSource", "mac") ?: "mac" }) { chooseMicrophone(it == "phone") }
        ))
        sheet.section(getString(R.string.keys_and_apps), listOf(
            SettingsSheet.Row(getString(R.string.key_configuration), {
                val apps = BindingProfiles.savedProfiles(prefs.all).size
                if (apps > 0) resources.getQuantityString(R.plurals.key_config_apps, apps, apps) else getString(R.string.key_config_general)
            }, neutral(R.drawable.ic_keyboard)) { showKeyConfig() },
            SettingsSheet.Row(getString(R.string.application_slots), {
                resources.getQuantityString(R.plurals.application_slot_count, appShortcuts.size, appShortcuts.size)
            }, neutral(R.drawable.ic_grid)) {
                showApplicationPicker()
            }
        ))
        sheet.section(getString(R.string.usage_and_updates), listOf(
            SettingsSheet.Row(getString(R.string.task_notifications), { getString(R.string.task_notifications_detail) }, neutral(R.drawable.ic_monitor)) { configureTaskNotifications() },
            SettingsSheet.Row(getString(R.string.app_usage), { AppUsageLabels.summary(this, AppUsageCache(this).summarySnapshot(prefs.getString("bindingSync.server", "") ?: "")) },
                SettingsSheet.Badge(R.drawable.ic_clock, Palette.violet, Palette.violetContainer), ::showAppUsage),
            SettingsSheet.Row(getString(R.string.audit_updates_title), {
                appVersions.available?.let { getString(R.string.app_version_available, it.name, it.code) } ?: apkReceiver.statusSummary()
            }, neutral(R.drawable.ic_download)) { showUpdates() }
        ))
        sheet.versionFooter({
            val current = getString(R.string.app_version_current, BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE)
            appVersions.available?.let { current + "\n" + getString(R.string.app_version_available, it.name, it.code) } ?: current
        }, ::appVersionsAvailable, ::showUpdates)
        appVersions.check()
        sheet.show { if (settingsSheet === sheet) settingsSheet = null }
    }

    private fun showUpdates() {
        val sheet = updateSheet ?: AppUpdatesSheet(this, codex, appVersions, apkReceiver).also { updateSheet = it }
        sheet.show(requestUpdate = appVersions.available != null)
    }

    private fun configureTaskNotifications() {
        io.github.junweiup.vibepier.remote.core.session.TaskCompletionNotifications(this).createChannel()
        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !prefs.getBoolean("taskNotificationsAsked", false)) {
            prefs.edit().putBoolean("taskNotificationsAsked", true).apply()
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 43)
        } else {
            startActivity(android.content.Intent(android.provider.Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                .putExtra(android.provider.Settings.EXTRA_CHANNEL_ID, "task_completion"))
        }
    }

    private fun languageLabel(): String {
        val locales = getSystemService(android.app.LocaleManager::class.java).applicationLocales
        return when {
            locales.isEmpty -> getString(R.string.language_system)
            locales[0].language == "zh" -> getString(R.string.language_chinese)
            else -> getString(R.string.language_english)
        }
    }

    private fun showLanguagePicker() {
        if (languageDialog?.isShowing == true) return
        val manager = getSystemService(android.app.LocaleManager::class.java)
        val tags = listOf("", "zh-CN", "en")
        val labels = arrayOf(getString(R.string.language_system), getString(R.string.language_chinese),
            getString(R.string.language_english))
        val locales = manager.applicationLocales
        val selected = when {
            locales.isEmpty -> 0
            locales[0].language == "zh" -> 1
            else -> 2
        }
        languageDialog = AlertDialog.Builder(this, R.style.Theme_VibePier_Dialog)
            .setTitle(R.string.app_language)
            .setSingleChoiceItems(labels, selected) { dialog, index ->
                dialog.dismiss()
                val requested = android.os.LocaleList.forLanguageTags(tags[index])
                if (manager.applicationLocales != requested) {
                    // Android persists this app-only choice and recreates the localized activity.
                    // Normal lifecycle cleanup releases held controls before rebuilding the UI.
                    manager.applicationLocales = requested
                }
            }
            .setNegativeButton(R.string.cancel, null)
            .showProtected().also { it.setOnDismissListener { languageDialog = null } }
    }

    /** Switching transport in place; Wi-Fi keeps its saved address, the relay needs a pairing code first. */
    private fun selectTransport(mode: String) {
        when (mode) {
            "bluetooth" -> connectBluetooth()
            "relay" -> if (sender.relaySettings == null) editRelay() else {
                pads.values.forEach { it.releaseIfHeld() }; stopPhoneMic()
                prefs.edit().putString("transport", "relay").apply()
                if (sender.mode == "relay") sender.watch(true) else sender.changeMode("relay")
                refreshMicrophoneHint()
                showTarget()
            }
            else -> {
                pads.values.forEach { it.releaseIfHeld() }; stopPhoneMic()
                prefs.edit().putString("transport", "wifi").apply()
                if (sender.mode == "wifi") sender.watch(true) else sender.changeMode("wifi")
                refreshMicrophoneHint()
                showTarget()
            }
        }
    }

    private fun showAppUsage() {
        if (appUsagePage?.dialog?.isShowing == true) return
        appUsagePage = AppUsagePage(this,
            request = { op, fields, reply -> codex.request(op, fields, reply) },
            online = { codex.online }, paired = { codex.paired },
            source = { prefs.getString("bindingSync.server", "") ?: "" },
            authorize = { codex.pair() },
            onDismiss = { appUsagePage = null; settingsSheet?.refresh() }
        ).also { it.show() }
    }

    private fun showTransportOptions() {
        val modes = listOf("wifi", "bluetooth", "relay")
        val options = listOf(
            "Wi-Fi" to getString(R.string.wifi_option_detail),
            getString(R.string.bluetooth) to getString(R.string.bluetooth_option_detail),
            getString(R.string.cloud_relay) to if (sender.relaySettings != null) getString(R.string.relay_configured_detail) else getString(R.string.relay_unconfigured_detail)
        ).mapIndexed { index, row ->
            (if (sender.mode == modes[index]) "✓ ${row.first}" else row.first) to row.second
        }
        AlertDialog.Builder(this, R.style.Theme_VibePier_Dialog)
            .setTitle(getString(R.string.connection_mode))
            .setAdapter(optionRows(options)) { _, choice ->
                when (choice) {
                    0 -> editHost(connectWifi = true)
                    1 -> connectBluetooth()
                    2 -> selectTransport("relay")
                }
            }.setNegativeButton(getString(R.string.back), null).showProtected()
    }

    private fun connectBluetooth() {
        val missing = BluetoothLink.permissions().filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            pendingBluetoothSelection = true
            requestPermissions(missing.toTypedArray(), 41)
            return
        }
        pads.values.forEach { it.releaseIfHeld() }
        stopPhoneMic()
        prefs.edit().putString("transport", "bluetooth").apply()
        if (sender.mode == "bluetooth") sender.watch(true) else sender.changeMode("bluetooth")
        showTarget()
        refreshMicrophoneHint()
    }

    private fun chooseMicrophone(phone: Boolean) {
        pads["talk"]?.releaseIfHeld()
        stopPhoneMic()
        if (phone && checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 42)
        } else {
            prefs.edit().putString("microphoneSource", if (phone) "phone" else "mac").apply()
            refreshMicrophoneHint()
            showTarget()
        }
    }

    /** The relay is configured by pasting the code from VibePier → 云中继 → 复制手机配对码. */
    private fun editRelay() {
        val field = EditText(this).apply {
            hint = getString(R.string.relay_code_hint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            isSingleLine = true
        }
        val validation = Ui.label(this, "", Ui.CAPTION, Palette.red).apply {
            visibility = View.GONE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { validation.visibility = View.GONE }
            override fun afterTextChanged(s: Editable?) {}
        })
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(8), dp(22), 0)
            addView(field, LinearLayout.LayoutParams(MATCH, WRAP))
            addView(validation, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(8) })
        }
        val saved = sender.relaySettings
        val builder = AlertDialog.Builder(this, R.style.Theme_VibePier_Dialog)
            .setTitle(getString(R.string.cloud_relay))
            .setMessage(getString(R.string.relay_code_instructions) +
                (saved?.let { "\n" + getString(R.string.current_relay, java.net.URI(it.url).host, it.room) } ?: ""))
            .setView(box)
            .setPositiveButton(if (saved == null) getString(R.string.save_and_connect) else getString(R.string.use), null)
            .setNegativeButton(getString(R.string.cancel), null)
        val dialog = builder.showProtected()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val input = field.text.toString().trim()
            val settings = if (input.isEmpty()) saved else RelayLink.parsePairing(input)
            if (settings == null) {
                validation.text = getString(R.string.invalid_relay_code)
                validation.visibility = View.VISIBLE
                return@setOnClickListener
            }
            pads.values.forEach { it.releaseIfHeld() }
            stopPhoneMic()
            try { relayStore.save(settings) } catch (_: Exception) {
                validation.text = getString(R.string.relay_secure_save_failed)
                validation.visibility = View.VISIBLE
                return@setOnClickListener
            }
            sender.relaySettings = settings
            prefs.edit().putString("transport", "relay").apply()
            if (sender.mode == "relay") sender.watch(true) else sender.changeMode("relay")
            refreshMicrophoneHint()
            showTarget()
            dialog.dismiss()
        }
    }

    private fun editHost(connectWifi: Boolean = false) {
        val field = EditText(this).apply {
            hint = getString(R.string.host_hint)
            setText(sender.host)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            isSingleLine = true
        }
        val validation = Ui.label(this, "", Ui.CAPTION, Palette.red).apply {
            visibility = View.GONE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { validation.visibility = View.GONE }
            override fun afterTextChanged(s: Editable?) {}
        })
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(8), dp(22), 0)
            addView(field, LinearLayout.LayoutParams(MATCH, WRAP))
            addView(validation, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(8) })
        }
        val dialog = AlertDialog.Builder(this, R.style.Theme_VibePier_Dialog)
            .setTitle(getString(R.string.mac_address))
            .setMessage(getString(R.string.host_instructions) +
                (sender.connectedHost?.let { "\n" + getString(R.string.current_connection, it) } ?: ""))
            .setView(box)
            .setPositiveButton(if (connectWifi) getString(R.string.save_and_connect) else getString(R.string.save), null)
            .setNegativeButton(getString(R.string.cancel), null)
            .showProtected()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val input = field.text.toString().trim()
            val host = validHost(input)
            if (input.isNotEmpty() && host.isEmpty()) {
                validation.text = getString(R.string.invalid_host)
                validation.visibility = View.VISIBLE
            } else {
                pads.values.forEach { it.releaseIfHeld() }
                stopPhoneMic()
                sender.changeHost(host)
                prefs.edit().putString("host", sender.host).apply()
                if (connectWifi) {
                    prefs.edit().putString("transport", "wifi").apply()
                    if (sender.mode == "wifi") sender.watch(true) else sender.changeMode("wifi")
                }
                refreshMicrophoneHint()
                showTarget()
                dialog.dismiss()
            }
        }
    }

    /** Anything that is not an IP address or host name falls back to broadcast. */
    private fun validHost(text: String) = text.trim().takeIf { Regex("[A-Za-z0-9.-]+").matches(it) } ?: ""

    /** A tap turns one step. Holding repeats, like turning the knob. */
    private fun rotatePad(icon: Int, label: String, control: String) = Pad(this, icon, label, Palette.amber).apply {
        var heldKeys = ""
        var heldApp: String? = null
        val repeat = object : Runnable {
            override fun run() {
                sender.send(control, "step", heldKeys, heldApp)
                handler.postDelayed(this, 120)
            }
        }
        onPress = {
            heldKeys = binding
            heldApp = application?.bundleID
            sender.send(control, "step", heldKeys, heldApp)
            handler.postDelayed(repeat, 400)
        }
        onRelease = { handler.removeCallbacks(repeat) }
        pads[control] = this
    }

    private fun keyPad(icon: Int, label: String, accent: Int, control: String, compact: Boolean = false) = Pad(this, icon, label, accent, compact).apply {
        var heldKeys = ""
        onPress = { heldKeys = binding; sender.send(control, "down", heldKeys, application?.bundleID) }
        onRelease = { sender.send(control, "up", heldKeys) }
        pads[control] = this
    }

    private fun deletePad() = Pad(this, R.drawable.ic_backspace, getString(R.string.delete), Palette.muted, compact = true).apply {
        var heldKeys = ""
        var heldApp: String? = null
        val repeat = object : Runnable {
            override fun run() {
                sender.send("knob-press", "step", heldKeys, heldApp)
                handler.postDelayed(this, 100)
            }
        }
        onPress = {
            heldKeys = binding
            heldApp = application?.bundleID
            sender.send("knob-press", "step", heldKeys, heldApp)
            handler.postDelayed(repeat, 400)
        }
        onRelease = { handler.removeCallbacks(repeat) }
        pads["knob-press"] = this
    }

    /** Hold to talk. While held, "down" repeats every second so that the Mac
     *  can release the key by itself if the final "up" is lost. */
    private fun talkPad() = TalkPad(this).apply {
        var heldKeys = ""
        var heldApp: String? = null
        var heldPhoneMicrophone = false
        val keepAlive = object : Runnable {
            override fun run() {
                sender.send("talk", "down", heldKeys, heldApp)
                handler.postDelayed(this, 1000)
            }
        }
        onPress = {
            heldKeys = binding; heldApp = application?.bundleID
            heldPhoneMicrophone = usePhoneMic()
            activeMicrophoneSource = if (heldPhoneMicrophone) "phone" else "mac"
            refreshMicrophoneHint()
            if (heldPhoneMicrophone) beginPhoneMic(heldKeys, heldApp) else keepAlive.run()
        }
        onRelease = {
            handler.removeCallbacks(keepAlive)
            activeMicrophoneSource = null
            // Negotiation/path changes during a hold must not change which action this release completes.
            if (heldPhoneMicrophone) stopPhoneMic() else sender.send("talk", "up", heldKeys)
            heldPhoneMicrophone = false
            refreshMicrophoneHint()
        }
        pads["talk"] = this
    }

    private fun row(left: View, right: View) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(left, LinearLayout.LayoutParams(0, MATCH, 1f).apply { marginEnd = dp(6) })
        addView(right, LinearLayout.LayoutParams(0, MATCH, 1f).apply { marginStart = dp(6) })
    }

    private fun section(title: String) = CanvasLabel(this).apply {
        text = title
        textSize = Ui.OVERLINE
        typeface = Typeface.DEFAULT_BOLD
        letterSpacing = 0.08f
        setTextColor(Palette.faint)
        setPadding(dp(4), 0, 0, 0)
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private companion object {
        const val MATCH = LinearLayout.LayoutParams.MATCH_PARENT
        const val WRAP = LinearLayout.LayoutParams.WRAP_CONTENT
    }
}
