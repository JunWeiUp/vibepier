package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.features.files.ProjectFiles
import io.github.junweiup.vibepier.remote.features.files.ProjectFilesPage
import io.github.junweiup.vibepier.remote.features.files.ProjectFileViewer
import io.github.junweiup.vibepier.remote.features.files.ProjectFileHost
import io.github.junweiup.vibepier.remote.core.ui.showProtected
import io.github.junweiup.vibepier.remote.BuildConfig
import io.github.junweiup.vibepier.remote.MainActivity
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft
import io.github.junweiup.vibepier.remote.core.session.SessionCreationWaitState
import io.github.junweiup.vibepier.remote.core.session.SessionExecutionModes
import io.github.junweiup.vibepier.remote.core.session.SessionProvider
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.IconControl
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.FullscreenImageDialog
import io.github.junweiup.vibepier.remote.features.markdown.ChatMarkdownView
import io.github.junweiup.vibepier.remote.features.markdown.MarkdownFileLinks
import io.github.junweiup.vibepier.remote.features.markdown.MarkdownFileViewer
import io.github.junweiup.vibepier.remote.features.remote.Palette
import io.github.junweiup.vibepier.remote.fixtures.ConversationReviewFixtures

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.MotionEvent
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import org.json.JSONArray
import org.json.JSONObject

/** Full-height conversation surface; its drawer overlays, rather than resizes, the remote controls. */
@android.annotation.SuppressLint("ViewConstructor") // Created in code with required model/callback arguments, never XML-inflated.
class ConversationPanel(private val activity: Activity, private val client: SessionClient,
                 private val dismiss: () -> Unit, private val fixture: String = "") : FrameLayout(activity) {
    private val ui = Handler(Looper.getMainLooper())
    private var drawer = true
    private var foreground = true
    private var thread = ""
    private var title = ""
    private var generation = 0
    private var ready = false
    private var opening = false
    private var renderingCache = false
    private var openRecovery: Runnable? = null
    private var openDeadline: Runnable? = null
    private var savedDrawer: List<View> = emptyList()
    private var savedDrawerKey = ""
    private var drawerLoaded = false
    private var loadedDrawerKey = ""
    private var loadedDrawerInfo = ""
    private fun drawerKey() = listOf(client.provider, client.selectedAgentAdapter()?.id, client.listMode, search, projectCwd).joinToString("\u0000")
    private fun stopOpening() {
        opening = false
        openRecovery?.let(ui::removeCallbacks); openRecovery = null
        openDeadline?.let(ui::removeCallbacks); openDeadline = null
    }
    private fun openingFailed(error: String) {
        discardRestoredAttachment()
        restoredScrollY = null
        ready = false
        stopOpening(); client.cancelPageReads(); pauseProcessReads()
        if (!drawer && ::status.isInitialized) {
            status.text = context.getString(R.string.session_could_not_open_session_tap_refresh_to_retry)
            statusDot.background = background(Palette.red, 3)
            notice.text = error; updateComposer()
        }
    }
    private fun requestOpen() {
        closeMarkdownViewer()
        stopOpening(); stopSync(); opening = true; ready = false
        page.remove("revision") // A resumed desktop subscription may restart its revision counter.
        status.text = if (page.has("messages")) context.getString(R.string.session_saved_content_syncing_the_latest_state) else context.getString(R.string.session_loading_session)
        val token = generation
        openRecovery = Runnable {
            if (drawer || token != generation || !opening) return@Runnable
            // A large Bluetooth page is already arriving; requesting it again would double the queue.
            if (!reviews && client.receivingContent) {
                status.text = context.getString(R.string.session_receiving_the_latest_content)
                openRecovery?.let { ui.postDelayed(it, 3_000) }
                return@Runnable
            }
            call("sync", JSONObject().put("threadId", thread).put("knownVersion", page.optString("cacheVersion"))) { result ->
                if (!drawer && token == generation && opening && result.optBoolean("ok") && (result.has("messages") || result.optBoolean("unchanged"))) applyPage(result)
            }
        }.also { ui.postDelayed(it, 8_000) }
        openDeadline = Runnable {
            if (!drawer && token == generation && opening) {
                client.cancelPageReads()
                openingFailed(context.getString(R.string.session_no_session_content_received_refresh_to_retry_or_choose_another_s))
            }
        }.also { ui.postDelayed(it, if (client.bluetooth) 60_000 else 25_000) }
        call("open", JSONObject().put("threadId", thread).put("knownVersion", page.optString("cacheVersion")).put("updatesIntervalMs", if (client.bluetooth) 750 else 250)) { result ->
            if (drawer || token != generation || !opening) return@call
            if (!result.optBoolean("ok")) openingFailed(result.optString("error", context.getString(R.string.session_could_not_open_session)))
            else if (result.has("messages") || result.optBoolean("unchanged")) applyPage(result)
        }
    }

    private var sending = false
    private val syncState = ConversationSyncState()
    private var syncRetry: Runnable? = null
    private fun stopSync() { syncRetry?.let(ui::removeCallbacks); syncRetry = null; syncState.reset() }
    private var page = JSONObject()
    private var historyComplete = false
    private var loadingHistory = false
    private var nextOffset = -1
    private var restoredDrawer = client.drawerState
    private var search = restoredDrawer.optString("search")
    private var projectCwd = restoredDrawer.optString("projectCwd")
    private var projectName = restoredDrawer.optString("projectName")
    private var listGeneration = 0
    private var loadingList = false
    private var listSection = ""
    private var listedCount = 0
    private var searchWork: Runnable? = null
    private lateinit var list: LinearLayout
    private lateinit var info: CanvasLabel
    private lateinit var crumb: LinearLayout
    private lateinit var group: LinearLayout
    private lateinit var newSession: View
    private lateinit var timeline: LinearLayout
    private lateinit var timelineRows: ConversationTimeline
    private var restoredScrollY: Int? = null
    private data class RestoredAttachment(val uri: android.net.Uri, val target: ConversationViewState)
    private var restoredAttachment: RestoredAttachment? = null
    private lateinit var scroll: ScrollView
    private lateinit var editor: EditText
    private lateinit var sendButton: CanvasLabel
    private lateinit var composerControls: ComposerControls
    private lateinit var queuedBox: LinearLayout
    private var queueRendering = ""
    private var attachmentRendering = ""
    private var uploadProgressLabel: CanvasLabel? = null
    private var creationAttachment: ((android.net.Uri) -> Unit)? = null
    private var creationPickerToken = ""
    /** The open new-session dialog; it survives backgrounding so a pending creation can finish or be checked. */
    private var creationDialog: AlertDialog? = null
    private val autoChecks = listOf(3_000L, 8_000L, 20_000L, 45_000L, 90_000L)
    private var creationAttachmentIsCurrent: () -> Boolean = { false }
    private var uploading = false
    private var uploadLabel = ""
    private var uploadGeneration = 0
    private val auxiliaryDialogs = mutableSetOf<AlertDialog>()
    private var markdownViewer: MarkdownFileViewer? = null
    private fun closeMarkdownViewer() { closeFileViews(); markdownViewer?.dismiss(); markdownViewer = null }
    private lateinit var stopButton: CanvasLabel
    private lateinit var filesBadge: CanvasLabel
    private var filesButton: View? = null
    /** The newest turn's changed files from the Mac, keyed by the reply they belong to. */
    private var turnChanges: JSONObject? = null
    private var changesKey = ""
    private var changesHolder: LinearLayout? = null
    private var filesPage: ProjectFilesPage? = null
    private var fileViewer: ProjectFileViewer? = null
    private var settingsOperation = ""
    private var models = JSONArray()
    private var reviewAttachments = JSONArray()
    private lateinit var headerTitle: CanvasLabel
    private lateinit var statusRow: LinearLayout
    private lateinit var status: CanvasLabel
    private lateinit var statusDot: View
    private lateinit var waitBanner: LinearLayout
    private lateinit var waitMessage: CanvasLabel
    private lateinit var waitCancel: CanvasLabel
    private var stoppedWaitSignature: String? = null
    private var sendWaitGeneration = 0
    private var stopRequestedTurn = ""
    private var progressSignature = ""
    private var lastProgressAt = android.os.SystemClock.elapsedRealtime()
    private val waitCheck = object : Runnable {
        override fun run() {
            if (!foreground || drawer) return
            renderWaitState()
            ui.postDelayed(this, 5_000)
        }
    }
    private lateinit var notice: CanvasLabel
    private lateinit var newest: CanvasLabel
    private var lastMessages = ""
    private var olderMessages = linkedMapOf<String, JSONObject>()
    /**
     * Replies the Mac accepted but the page does not show yet, by thread. A busy desktop queues them until its turn ends,
     * and a lost push leaves the page stale, so each stays as a pending bubble until a user message newer than the send
     * carries its text.
     */
    private class Sent(val text: String, val known: Set<String>, val at: Long)
    private val outbox = mutableMapOf<String, MutableList<Sent>>()
    private val processStates = linkedMapOf<String, InlineReplyProcess.State>()
    private var timelineProcessKeys = emptySet<String>()
    private val renderedProcesses = mutableListOf<InlineReplyProcess>()
    private fun pauseProcessReads() { media.cancelReads(); processStates.values.forEach { it.pause(); it.changed() } }
    private val media by lazy { ConversationMedia(context,
        scope = { ConversationMedia.Scope(client.provider, thread, generation, authorizationSource()) },
        active = { foreground && !drawer }, version = ::imageVersion, request = ::call, imageViewer = ::imageViewer, binaryHost = { client.binaryHost }, allowLegacyImages = reviews) }
    private fun imageViewer(title: String) = FullscreenImageDialog(context, title).also { viewer ->
        auxiliaryDialogs.add(viewer.dialog)
        viewer.dialog.setOnDismissListener { auxiliaryDialogs.remove(viewer.dialog) }
    }
    private var prependAnchor: Pair<Int, Int>? = null
    private var approvalDialog: AlertDialog? = null
    private var openApproval = ""
    private var openApprovalId = ""
    private var loadingApproval = false
    private var submittingApproval = ""
    private var retryableOperation = ""
    private val approvedHere = mutableSetOf<String>()
    private val questionDrafts = mutableMapOf<String, MutableMap<String, String>>()
    private val reviews = BuildConfig.DESIGN_REVIEW && fixture.isNotBlank()
    private val connected get() = if (reviews) fixture != "offline" else client.online
    private var connectionAvailable = connected
    private val authorized get() = reviews || client.paired
    init {
        isClickable = true; isFocusable = true
        importantForContentCapture = IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
        setOnApplyWindowInsetsListener { view, insets ->
            val system = insets.getInsets(WindowInsets.Type.systemBars()); val keyboard = insets.getInsets(WindowInsets.Type.ime())
            view.setPadding(0, system.top, 0, maxOf(system.bottom, keyboard.bottom))
            if (!drawer && ::statusRow.isInitialized) statusRow.visibility = if (keyboard.bottom > 0) GONE else VISIBLE
            insets
        }
        client.onEvent = { value ->
            if (value.optString("event") == "providersChanged") {
                val first = client.enabledProviders.firstOrNull()
                savedDrawer = emptyList(); drawerLoaded = false
                if (!client.providerEnabled(client.provider) && first != null) switchProvider(first)
                else if (!client.providerEnabled(client.provider)) {
                    saveDraft(); thread = ""; title = ""; page = JSONObject()
                    uploadGeneration++; settingsOperation = ""; processStates.clear(); media.clear()
                    auxiliaryDialogs.toList().forEach { it.dismiss() }; approvalDialog?.dismiss()
                    showDrawer()
                } else if (drawer) showDrawer()
            }
            else if (value.optString("event") == "agentCapabilitiesChanged") {
                if (drawer) showDrawer() else { updateComposer(); if (foreground) requestOpen() }
            }
            else if (value.optString("event") == "agentOperationUpdated") {
                if (!drawer) updateComposer()
            }
            else if (value.optString("event") == "paired") {
                saveDraft(); processStates.clear(); media.clear(); outbox.clear(); olderMessages.clear()
                auxiliaryDialogs.toList().forEach { it.dismiss() }; auxiliaryDialogs.clear(); approvalDialog?.dismiss()
                questionDrafts.clear(); approvedHere.clear(); page = JSONObject(); thread = ""; title = ""
                savedDrawer = emptyList(); drawerLoaded = false; loadedDrawerKey = ""
                restoredDrawer = client.drawerState; search = ""; projectCwd = ""; projectName = ""
                showDrawer()
            }
            else if ((!value.has("provider") || value.optString("provider") == client.provider) && (value.optString("threadId").isEmpty() || value.optString("threadId") == thread)) {
                if (value.optString("event") == "lateReceipt" && !drawer) {
                    val original = value.optJSONObject("operation") ?: JSONObject()
                    if (original.optString("op") == "send" && value.optBoolean("accepted") && editor.text.toString().trim() == original.optString("text")) editor.setText("")
                    notice.text = if (value.optBoolean("ok")) context.getString(R.string.session_operation_confirmed, operationName(original.optString("op"))) else value.optString("error", context.getString(R.string.session_operation_incomplete_draft_retained))
                    if (value.optBoolean("submitted")) {
                        val fingerprint = original.optString("fingerprint")
                        approvedHere.add(fingerprint)
                        if (openApproval == fingerprint) { approvalDialog?.dismiss(); submittingApproval = "" }
                        questionDrafts.remove(fingerprint)
                        notice.text = if (original.has("answers")) context.getString(R.string.session_answer_submitted) else context.getString(R.string.session_decision_submitted_waiting_for_desktop_confirmation)
                    }
                    if (original.optString("op").startsWith("queue")) resync()
                    updateComposer()
                }
                else if (value.optString("event") == "queue") applyQueue(value)
                else if (value.optString("event") == "snapshot") applyPage(value)
                else if (value.optString("event") == "delta") applyDelta(value)
                else if (value.optString("event") == "stale") resync()
                else if (value.optString("event") == "unavailable" && !drawer && (!value.has("viewVersion") || value.optLong("viewVersion") == client.viewVersion)) openingFailed(value.optString("error", context.getString(R.string.session_session_unavailable)))
            }
        }
        client.onState = { text -> if (drawer && ::info.isInitialized) info.text = text else if (::notice.isInitialized) notice.text = text }
        if (!reviews && !client.providerEnabled(client.provider)) client.enabledProviders.firstOrNull()?.let { client.provider = it }
        showDrawer()
        if (!reviews) client.refreshProviderAccess()
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun background(color: Int, radius: Int = 14) = Ui.roundRect(context, color, radius)
    private fun column() = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private fun label(value: String, size: Float = 14f, color: Int = Palette.text) = Ui.label(context, value, size, color)
    private fun button(value: String, accent: Boolean = false, action: () -> Unit) =
        Ui.button(context, value, if (accent) Ui.Button.PRIMARY else Ui.Button.TONAL, action)
    private fun canvasDialog(heading: String, body: View, actions: LinearLayout, compact: Boolean = false): AlertDialog {
        val box = object : LinearLayout(context) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                if (!compact) { super.onMeasure(widthMeasureSpec, heightMeasureSpec); return }
                super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
                val height = minOf(measuredHeight, (resources.displayMetrics.heightPixels * .82).toInt())
                super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            }
        }.apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(14))
            addView(label(heading, Ui.TITLE).apply { typeface = Typeface.DEFAULT_BOLD }, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(14) })
            addView(body, LinearLayout.LayoutParams(-1, if (compact) -2 else 0, 1f))
            addView(actions, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12) })
        }
        return AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).setView(box).showProtected().also {
            auxiliaryDialogs.removeAll { old -> !old.isShowing }; auxiliaryDialogs.add(it)
            it.setOnDismissListener { auxiliaryDialogs.remove(it) }
            it.window?.setLayout((resources.displayMetrics.widthPixels - dp(32)).coerceAtLeast(dp(240)), if (compact) -2 else (resources.displayMetrics.heightPixels * .82).toInt())
        }
    }
    private fun row() = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
    private fun watch(field: EditText, action: (String) -> Unit) { field.addTextChangedListener(object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { action(s?.toString() ?: "") }
        override fun afterTextChanged(s: Editable?) {}
    }) }
    private fun hideKeyboard() { (context.getSystemService(Activity.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(windowToken, 0); clearFocus() }
    private fun saveDrawerState() {
        if (!drawer || reviews || !::list.isInitialized) return
        client.rememberDrawerState(JSONObject().put("listMode", client.listMode).put("search", search).put("projectCwd", projectCwd).put("projectName", projectName)
            .put("scrollY", if (loadedDrawerKey == drawerKey()) (list.parent as? ScrollView)?.scrollY ?: 0 else 0))
    }
    private fun drawerScroll(): Int? = when {
        drawerLoaded && loadedDrawerKey == drawerKey() -> (list.parent as? ScrollView)?.scrollY
        !drawerLoaded && restoredDrawer.optString("search") == search && restoredDrawer.optString("projectCwd") == projectCwd -> restoredDrawer.optInt("scrollY")
        else -> null
    }
    fun back(): Boolean {
        if (!drawer) { saveDraft(); hideKeyboard(); showDrawer() } else close()
        return true
    }
    /** Saved Android view state contains only navigation, never conversation or draft bodies. */
    fun navigationState(): JSONObject {
        saveDraft(); saveDrawerState()
        val y = if (drawer) drawerScroll() ?: 0 else if (::scroll.isInitialized) scroll.scrollY else 0
        return ConversationViewState(authorizationSource(), client.provider, drawer, thread, title, y).json()
            .put("agentAdapterId", client.selectedAgentAdapter()?.id).put("creationAttachment", creationAttachment != null).put("creationPickerToken", creationPickerToken).apply {
                restoredAttachment?.let { pending -> put("pendingUri", pending.uri.toString()); put("pendingTarget", pending.target.json()) }
            }
    }
    private fun authorizationSource() = if (reviews) "review:$fixture" else client.authorizationIdentity
    private fun renderingScope() = ConversationRenderScope(authorizationSource(), client.provider, thread, generation)
    fun restoreNavigationState(value: JSONObject): Boolean {
        val saved = ConversationViewState.read(value, authorizationSource()) ?: return false
        if (!reviews && !client.providerEnabled(saved.provider)) return false
        if (client.provider != saved.provider) switchProvider(saved.provider)
        if (!reviews && value.opt("agentAdapterId") != null && value.opt("agentAdapterId") != JSONObject.NULL && value.opt("agentAdapterId") != client.selectedAgentAdapter()?.id) return false
        if (!reviews && !value.has("agentAdapterId") && client.selectedAgentAdapter()?.isDefault == false) return false
        restoredDrawer = client.drawerState
        search = restoredDrawer.optString("search"); projectCwd = restoredDrawer.optString("projectCwd"); projectName = restoredDrawer.optString("projectName")
        if (saved.drawer) { showDrawer(); return true }
        restoredScrollY = saved.scrollY
        open(saved.thread, saved.title)
        val pendingUri = value.optString("pendingUri")
        if (pendingUri.isNotBlank() && pendingUri.length <= 4096) {
            val expected = value.optJSONObject("pendingTarget")
            val uri = android.net.Uri.parse(pendingUri)
            if (expected == null || !addRestoredPhoneAttachment(uri, expected)) {
                releasePickerPermission(uri)
                android.widget.Toast.makeText(context, R.string.conversation_attachment_reselect, android.widget.Toast.LENGTH_LONG).show()
            }
        }
        return true
    }
    /** A picker result waits for a verified page; changing source/provider/thread invalidates it. */
    fun addRestoredPhoneAttachment(uri: android.net.Uri, expectedNavigation: JSONObject): Boolean {
        if (expectedNavigation.optBoolean("creationAttachment") || creationAttachment != null) return false
        if (!reviews && expectedNavigation.opt("agentAdapterId") != navigationState().opt("agentAdapterId")) return false
        val expected = ConversationViewState.read(expectedNavigation, authorizationSource()) ?: return false
        val current = ConversationViewState.read(navigationState(), authorizationSource()) ?: return false
        if (!expected.sameConversation(current) || restoredAttachment != null || uploading || sending) return false
        restoredAttachment = RestoredAttachment(uri, expected)
        drainRestoredAttachment()
        return true
    }
    fun addPickedCreationAttachment(uri: android.net.Uri, expectedNavigation: JSONObject): Boolean {
        if (!reviews && expectedNavigation.opt("agentAdapterId") != navigationState().opt("agentAdapterId")) return false
        if (!ConversationPickerTarget.matchesCreation(expectedNavigation, navigationState(), authorizationSource()) ||
            !creationAttachmentIsCurrent()) return false
        val callback = creationAttachment ?: return false
        callback(uri)
        return true
    }
    private fun clearCreationAttachment(token: String) {
        if (creationPickerToken != token) return
        creationAttachment = null; creationPickerToken = ""; creationAttachmentIsCurrent = { false }
    }
    private fun releasePickerPermission(uri: android.net.Uri) {
        runCatching { context.contentResolver.releasePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION) }
    }
    private fun discardRestoredAttachment() {
        val pending = restoredAttachment ?: return
        restoredAttachment = null; releasePickerPermission(pending.uri)
        android.widget.Toast.makeText(context, R.string.conversation_attachment_reselect, android.widget.Toast.LENGTH_LONG).show()
    }
    private fun drainRestoredAttachment() {
        val pending = restoredAttachment ?: return
        val current = ConversationViewState(authorizationSource(), client.provider, drawer, thread, title, 0)
        if (!pending.target.sameConversation(current) || creationAttachment != null) { discardRestoredAttachment(); return }
        if (!foreground || !ready || !connected || uploading || sending) return
        if (!mutableReady || !supports("attachments") || entries().length() >= 6) { discardRestoredAttachment(); return }
        restoredAttachment = null
        addPhoneAttachment(pending.uri)
    }
    fun close(preservePendingAttachment: Boolean = false) {
        if (preservePendingAttachment) restoredAttachment = null else discardRestoredAttachment()
        saveDrawerState()
        foreground = false; generation++; listGeneration++
        closeMarkdownViewer()
        stopOpening(); stopSync(); client.cancelPageReads(); pauseProcessReads(); savedDrawer = emptyList()
        saveDraft(); hideKeyboard(); auxiliaryDialogs.toList().forEach { it.dismiss() }; auxiliaryDialogs.clear(); approvalDialog?.dismiss(); uploadGeneration++
        if (!reviews) client.flushContentCache()
        if (!reviews && thread.isNotEmpty() && client.online && client.paired) client.request("close") { }
        client.onEvent = {}; client.onState = {}; ui.removeCallbacksAndMessages(null); dismiss()
    }
    /** Keep the view, messages, loaded history, draft and scroll position while the app is backgrounded. */
    fun suspend() {
        closeMarkdownViewer()
        saveDrawerState()
        foreground = false; ui.removeCallbacks(waitCheck); saveDraft(); stopOpening(); client.cancelPageReads(); pauseProcessReads()
        if (!reviews) client.flushContentCache()
        ready = false; stopSync(); loadingHistory = false
        // A creation in flight keeps its dialog: locking the phone must not hide the result or strand its wait.
        auxiliaryDialogs.toList().filter { it !== creationDialog }.forEach { it.dismiss() }; auxiliaryDialogs.retainAll { it === creationDialog }
        approvalDialog?.dismiss(); openApproval = ""; loadingApproval = false
        updateComposer()
    }
    fun resume() {
        if (foreground) return
        foreground = true
        if (!reviews) client.refreshProviderAccess()
        ui.removeCallbacks(waitCheck); if (!drawer) ui.postDelayed(waitCheck, 5_000)
        if (drawer) {
            if (authorized) loadList(false)
        } else {
            updateComposer()
            if (reviews) applyPage(page)
            else if (connected && authorized) requestOpen()
        }
    }
    fun connectionChanged() {
        val restored = connected && !connectionAvailable
        connectionAvailable = connected
        if (!connected) { stopSync(); pauseProcessReads(); approvalDialog?.dismiss(); openApproval = "" }
        if (!drawer) { if (!connected) ready = false; updateComposer(); if (!connected) notice.text = context.getString(R.string.session_disconnected_draft_retained_reconnecting_when_available) }
        else if (::info.isInitialized && !connected) info.text = if (!authorized && client.canRequestAuthorization) client.authorizationMessage else context.getString(R.string.session_mac_disconnected_connect_to_view_sessions)
        if (foreground && restored && drawer && authorized) loadList(false)
        if (foreground && restored && !drawer && !reviews && authorized) {
            notice.text = context.getString(R.string.session_restoring_session_connection)
            requestOpen()
        }
    }
    private val claude get() = client.provider == "claude"
    private val zcode get() = client.provider == "zcode"
    private val agent get() = SessionProvider.name(client.provider)
    // A new action can restore its own control state. Cached availability is not an admission gate.
    private val mutableReady get() = foreground && !drawer && thread.isNotBlank() && connected && authorized &&
        (reviews || client.agentCapabilitiesKnown && client.sessionControlKnown(thread))
    private val queueSubmission get() = supports("queue") && (page.optString("status") == "active" || (page.optJSONArray("queuedMessages")?.length() ?: 0) > 0)
    private val canSend get() = mutableReady && supports("send")
    private fun supports(key: String, legacyDefault: Boolean = true): Boolean {
        if (reviews) return (page.optJSONObject("capabilities")?.opt(key) as? Boolean) ?: legacyDefault
        return client.agentActionSupported(key)
    }
    private fun threadKey(id: String = thread) = client.sessionScope(id)
    private fun switchProvider(value: String) {
        if (!reviews && !client.providerEnabled(value)) return
        if (value == client.provider) return
        if (drawer) saveDrawerState()
        if (!reviews && thread.isNotEmpty() && client.online && client.paired) client.request("close") { }
        saveDraft(); client.provider = value; thread = ""; title = ""; page = JSONObject(); nextOffset = -1; projectCwd = ""; projectName = ""
        auxiliaryDialogs.toList().forEach { it.dismiss() }; uploadGeneration++; settingsOperation = ""
        val state = client.drawerState; restoredDrawer = state
        search = state.optString("search"); projectCwd = state.optString("projectCwd"); projectName = state.optString("projectName")
        showDrawer()
    }
    private fun saveDraft() { if (::editor.isInitialized && thread.isNotEmpty() && !reviews) client.saveDraft(thread, editor.text.toString()) }
    private fun showDrawer() {
        discardRestoredAttachment()
        // Invalidate old view callbacks before pausing them: a change notification can otherwise start another read.
        drawer = true; generation++; listGeneration++; ready = false
        closeMarkdownViewer()
        stopOpening(); client.cancelPageReads(); pauseProcessReads()
        if (!reviews && thread.isNotEmpty() && client.online && client.paired) client.request("close") { }
        saveDraft(); stopSync(); lastMessages = ""; removeAllViews(); setBackgroundColor(Palette.background)
        if (savedDrawer.isNotEmpty() && drawerLoaded && savedDrawerKey == drawerKey() && loadedDrawerKey == savedDrawerKey) {
            savedDrawer.forEach { addView(it) }; savedDrawer = emptyList()
            info.text = if (connected) loadedDrawerInfo else context.getString(R.string.session_mac_disconnected_showing_saved_list)
            if (authorized) loadList(false)
            return
        }
        savedDrawer = emptyList(); drawerLoaded = false
        val sheet = column().apply { setPadding(dp(12), dp(6), dp(12), 0); isClickable = true }
        addView(sheet, LayoutParams(-1, -1))
        sheet.addView(row().apply {
            minimumHeight = dp(56)
            addView(IconControl(context, IconControl.Icon.BACK, context.getString(R.string.session_back_to_phone_remote), Palette.text) { close() }, LinearLayout.LayoutParams(dp(44), dp(48)))
            addView(label(context.getString(R.string.session_sessions), 22f).apply { typeface = Typeface.DEFAULT_BOLD }, LinearLayout.LayoutParams(0, -2, 1f))
            if (authorized) addView(IconControl(context, IconControl.Icon.REFRESH, context.getString(R.string.session_refresh_list)) { hideKeyboard(); loadList(false, useCache = false) }.apply {
                background = background(Palette.surface1, 12)
            }, LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginEnd = dp(8) })
            if (authorized) addView(IconControl(context, IconControl.Icon.MORE, context.getString(R.string.session_more_actions)) { showDrawerMenu() }.apply {
                background = background(Palette.surface1, 12)
            }, LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginEnd = dp(4) })
        })
        val visibleProviders = if (reviews) SessionProvider.ids else client.enabledProviders
        if (authorized && visibleProviders.isEmpty()) {
            info = label(context.getString(if (client.providerAccessKnown) R.string.providers_none_enabled else R.string.providers_loading), Ui.BODY, Palette.muted)
            sheet.addView(info, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(20) })
            if (connected && !client.providerAccessKnown) client.refreshProviderAccess()
            return
        }
        sheet.addView(Ui.topTabs(context, visibleProviders.map { it to SessionProvider.name(it) }, client.provider, context.getString(R.string.session_sessions)) { hideKeyboard(); switchProvider(it) },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(2); marginStart = dp(4); marginEnd = dp(4) })
        val searchField = EditText(context).apply {
            hint = context.getString(R.string.session_search_sessions_or_projects); textSize = Ui.BODY; setTextColor(Palette.text); setHintTextColor(Palette.faint)
            setSingleLine(); inputType = InputType.TYPE_CLASS_TEXT; background = null
            setPadding(dp(4), 0, dp(12), 0); setText(search); gravity = Gravity.CENTER_VERTICAL
        }
        sheet.addView(row().apply {
            background = background(Palette.surface1, 12)
            addView(IconControl(context, IconControl.Icon.SEARCH, context.getString(R.string.session_search), Palette.faint) { searchField.requestFocus() }.apply {
                importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO; minimumHeight = 0; minimumWidth = 0
            }, LinearLayout.LayoutParams(dp(40), dp(44)))
            addView(searchField, LinearLayout.LayoutParams(0, dp(44), 1f))
        }, LinearLayout.LayoutParams(-1, dp(44)).apply { topMargin = dp(10); marginStart = dp(4); marginEnd = dp(4) })
        watch(searchField) { value -> search = value; searchWork?.let { ui.removeCallbacks(it) }; searchWork = Runnable { loadList(false) }.also { ui.postDelayed(it, 300) } }
        sheet.addView(Ui.filterChips(context, listOf("recent" to context.getString(R.string.session_recent), "projects" to context.getString(R.string.session_by_project)), client.listMode, context.getString(R.string.session_list)) {
            hideKeyboard(); client.listMode = it; projectCwd = ""; nextOffset = -1; showDrawer()
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(2); marginStart = dp(4) })
        crumb = row().apply { minimumHeight = dp(40); setPadding(dp(8), 0, dp(4), 0) }
        info = label(if (client.canRequestAuthorization && !authorized) context.getString(R.string.session_waiting_for_mac_approval) else if (!connected) context.getString(R.string.session_mac_disconnected) else if (!authorized) context.getString(R.string.session_waiting_for_mac_approval) else context.getString(R.string.session_loading_recent_sessions), Ui.CAPTION, Palette.faint).apply { gravity = Gravity.CENTER_VERTICAL }
        crumb.addView(info, LinearLayout.LayoutParams(0, -2, 1f))
        sheet.addView(crumb, LinearLayout.LayoutParams(-1, -2))
        list = column()
        sheet.addView(object : ScrollView(context) {
            private var startY = 0f
            override fun dispatchTouchEvent(event: MotionEvent): Boolean {
                if (event.actionMasked == MotionEvent.ACTION_DOWN) startY = event.y
                if (event.actionMasked == MotionEvent.ACTION_UP && startY - event.y > dp(32) && !canScrollVertically(1)) loadNextListPage()
                return super.dispatchTouchEvent(event)
            }
            override fun performAccessibilityAction(action: Int, arguments: android.os.Bundle?): Boolean {
                if (action == android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_FORWARD && !canScrollVertically(1) && nextOffset >= 0) {
                    loadNextListPage(); return true
                }
                return super.performAccessibilityAction(action, arguments)
            }
        }.apply {
            isVerticalScrollBarEnabled = false; addView(list)
            clipToPadding = false; setPadding(0, 0, 0, dp(88))
            setOnScrollChangeListener { _, _, y, _, oldY ->
                if (y > oldY && list.height - height - y < dp(160)) loadNextListPage()
            }
        }, LinearLayout.LayoutParams(-1, 0, 1f))
        newSession = row().apply {
            gravity = Gravity.CENTER; visibility = GONE; isFocusable = true
            background = background(Palette.accent, 16); elevation = dp(6).toFloat()
            setPadding(dp(18), 0, dp(20), 0)
            setOnClickListener { showNewSession() }
            addView(IconControl(context, IconControl.Icon.PLUS, context.getString(R.string.session_new_session), Palette.onAccent) {}.apply {
                importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO; isClickable = false; isFocusable = false; minimumWidth = 0; minimumHeight = 0
            }, LinearLayout.LayoutParams(dp(22), dp(22)).apply { marginEnd = dp(6) })
            addView(label(context.getString(R.string.session_new_session), Ui.BODY, Palette.onAccent).apply { typeface = Typeface.DEFAULT_BOLD; importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO })
        }
        addView(newSession, LayoutParams(-2, dp(52), Gravity.BOTTOM or Gravity.END).apply { marginEnd = dp(18); bottomMargin = dp(22) })
        if (!authorized) list.addView(column().apply {
            gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(16), dp(28), dp(16), dp(16))
            background = background(Palette.surface1, 16)
            addView(label(context.getString(R.string.session_connect_provider, agent), Ui.HEADLINE).apply { typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER })
            addView(label(context.getString(R.string.session_on_the_first_bluetooth_connection_the_mac_asks_for_approval_auto), Ui.CAPTION, Palette.muted).apply { gravity = Gravity.CENTER },
                LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(6); bottomMargin = dp(16) })
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4) })
        if (authorized) loadList(false)
    }
    private var screenActionPending = false
    private fun showDrawerMenu() = menu(context.getString(R.string.session_session_menu), context.getString(R.string.session_request_authorization_again_if_mac_access_expires_or_you_replace), listOfNotNull(
        if (!reviews && client.agentAdapters.size > 1) context.getString(R.string.agent_choose_backend) to { showAgentBackends() } else null,
        if (reviews || client.providerEnabled("codex")) context.getString(R.string.codex_usage_title) to { showCodexUsage() } else null,
        context.getString(R.string.session_lock) to { changeScreenLock(true) },
        context.getString(R.string.session_unlock) to { changeScreenLock(false) },
        context.getString(R.string.session_mac_unlock_setup) to { showUnlockSettings() },
        context.getString(R.string.session_authorize_mac_access_again) to { client.pair() }
    ))
    private fun showAgentBackends() {
        val adapters = client.agentAdapters
        fun label(adapter: io.github.junweiup.vibepier.remote.core.session.SessionAgentAdapter) = adapter.name ?: context.getString(
            if (adapter.isDefault) R.string.agent_backend_current else if ("managedRuntime" in adapter.backendKinds) R.string.agent_backend_managed else R.string.agent_backend_extension)
        menu(context.getString(R.string.agent_choose_backend), context.getString(R.string.agent_backend_explanation), adapters.map { adapter ->
            (if (adapter.id == client.selectedAgentAdapter()?.id) "✓ " else "") + label(adapter) to {
                if (adapter.id != client.selectedAgentAdapter()?.id) {
                    if (connected && authorized && thread.isNotEmpty()) client.request("close") { }
                    saveDraft()
                    if (client.selectAgentAdapter(adapter.id)) {
                        thread = ""; title = ""; page = JSONObject(); projectCwd = ""; projectName = ""; search = ""; nextOffset = -1
                        savedDrawer = emptyList(); drawerLoaded = false; processStates.clear(); media.clear()
                        auxiliaryDialogs.toList().forEach { it.dismiss() }; approvalDialog?.dismiss(); uploadGeneration++; settingsOperation = ""
                        showDrawer()
                    }
                }
            }
        })
    }
    private fun showCodexUsage() {
        if (!connected || !authorized) { info.text = if (!connected) context.getString(R.string.session_connect_to_the_mac_first) else context.getString(R.string.session_approve_this_phone_on_the_mac_first); return }
        val sheet = CodexUsageSheet(context, ::call, { client.uncertain("", "codex") }, client::clearReceipt)
        lateinit var dialog: AlertDialog
        val actions = row().apply { addView(button(context.getString(R.string.codex_usage_close)) { dialog.dismiss() }) }
        dialog = canvasDialog(context.getString(R.string.codex_usage_title), sheet, actions)
        sheet.refresh()
    }
    private fun changeScreenLock(lock: Boolean) {
        if (!connected || !authorized) { info.text = if (!connected) context.getString(R.string.session_connect_to_the_mac_first) else context.getString(R.string.session_approve_this_phone_on_the_mac_first); return }
        if (screenActionPending) { info.text = context.getString(R.string.session_waiting_for_the_mac_to_confirm_the_previous_action); return }
        screenActionPending = true
        info.text = if (lock) context.getString(R.string.session_locking_mac) else context.getString(R.string.session_unlocking_mac)
        call(if (lock) "lockScreen" else "unlockScreen") { result ->
            screenActionPending = false
            if (result.optBoolean("ok")) {
                info.text = if (result.optBoolean("locked")) context.getString(R.string.session_mac_locked) else context.getString(R.string.session_mac_unlocked)
            } else {
                info.text = if (result.optBoolean("unknown")) context.getString(R.string.session_the_result_is_not_yet_confirmed_check_on_the_mac) else result.optString("error", context.getString(R.string.session_operation_failed_retry))
                if (!lock && result.has("configured") && !result.optBoolean("configured")) showUnlockSettings()
            }
        }
    }

    /**
     * The Mac's login password, so desktop actions (typing into Claude, creating a Codex session) work while it is locked.
     * It goes over the paired encrypted channel into the Mac's local unlock preferences; the phone keeps no copy.
     */
    private fun showUnlockSettings() {
        if (!connected || !authorized) return
        hideKeyboard()
        var busy = false
        val field = EditText(context).apply {
            hint = context.getString(R.string.session_mac_login_password); textSize = Ui.BODY; setTextColor(Palette.text); setHintTextColor(Palette.faint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD; setSingleLine()
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO; background = background(Palette.surfaceTop)
            setPadding(dp(12), dp(12), dp(12), dp(12))
        }
        val state = label(context.getString(R.string.session_reading_mac_state), Ui.CAPTION, Palette.faint)
        val body = column().apply {
            addView(label(context.getString(R.string.session_unlock_policy), 13f, Palette.muted),
                LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(12) })
            addView(field, LinearLayout.LayoutParams(-1, -2))
            addView(state, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
        }
        fun show(result: JSONObject) {
            if (!result.optBoolean("ok")) { state.text = result.optString("error", context.getString(R.string.session_mac_did_not_respond)); state.setTextColor(Palette.red); return }
            state.setTextColor(if (result.optBoolean("failed")) Palette.amber else Palette.faint)
            state.text = listOf(
                if (result.optBoolean("configured")) context.getString(R.string.session_unlock_configured) else context.getString(R.string.not_configured),
                if (result.optBoolean("locked")) context.getString(R.string.session_mac_is_currently_locked) else context.getString(R.string.session_mac_is_currently_unlocked),
                if (result.optBoolean("failed")) context.getString(R.string.session_the_previous_unlock_failed_attempts_are_paused_save_the_password) else ""
            ).filter { it.isNotEmpty() }.joinToString(" · ")
        }
        val footer = row(); val dialog = canvasDialog(context.getString(R.string.session_mac_unlock_setup), ScrollView(context).apply { addView(body) }, footer, compact = true)
        fun submit(password: String) {
            if (busy) return
            busy = true; field.isEnabled = false; state.setTextColor(Palette.faint)
            state.text = if (password.isEmpty()) context.getString(R.string.session_clearing) else context.getString(R.string.session_verifying_the_password_on_the_mac)
            call("unlockPassword", JSONObject().put("password", password)) { result ->
                if (!dialog.isShowing) return@call
                busy = false; field.isEnabled = true
                if (result.optBoolean("ok")) field.setText("")
                show(result)
            }
        }
        footer.addView(button(context.getString(R.string.session_clear)) { submit("") }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(8) })
        footer.addView(button(context.getString(R.string.close)) { dialog.dismiss() }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(8) })
        footer.addView(button(context.getString(R.string.save), true) {
            val password = field.text.toString()
            if (password.isEmpty()) { state.text = context.getString(R.string.session_enter_a_password); state.setTextColor(Palette.amber) } else submit(password)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        call("unlockStatus") { if (dialog.isShowing) show(it) }
    }
    /** The line above the list: a way back out of a project, then the count or the loading state. */
    private fun setCrumb(project: String?) {
        for (i in crumb.childCount - 1 downTo 0) if (crumb.getChildAt(i) !== info) crumb.removeViewAt(i)
        crumb.setOnClickListener(null); crumb.isFocusable = false; crumb.contentDescription = null
        newSession.visibility = GONE
        info.layoutParams = LinearLayout.LayoutParams(if (project == null) 0 else -2, -2, if (project == null) 1f else 0f)
        if (project == null) return
        crumb.isFocusable = true; crumb.contentDescription = context.getString(R.string.session_back_to_all_projects); crumb.minimumHeight = dp(48)
        crumb.setOnClickListener { hideKeyboard(); projectCwd = ""; loadList(false) }
        crumb.addView(label("‹", 22f, Palette.accent).apply { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }, 0, LinearLayout.LayoutParams(dp(18), -2))
        crumb.addView(label(project, Ui.LABEL, Palette.text).apply {
            typeface = Typeface.DEFAULT_BOLD; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
        }, 1, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(8) })
        val pendingCreation = client.uncertain("", client.provider).any { it.opt("cwd") == projectCwd && it.opt("op") == "new" }
        if (reviews || client.canPrepareCreation || pendingCreation) { newSession.visibility = VISIBLE; newSession.contentDescription = context.getString(R.string.session_new_in_project, project, agent) }
    }
    /** Starts a session in the open project with its first message, then opens it. */
    private fun showNewSession() { showNewSession(null) }
    private fun showNewSession(checkPending: JSONObject?) {
        val pendingCreation = client.uncertain("", client.provider).any { it.opt("cwd") == projectCwd && it.opt("op") == "new" }
        if (!connected || !authorized || projectCwd.isEmpty() || (!reviews && !client.canPrepareCreation && !pendingCreation)) return
        hideKeyboard()
        val cwd = projectCwd; val provider = client.provider; var busy = false
        val authorization = authorizationSource(); val pickerToken = java.util.UUID.randomUUID().toString()
        var original = checkPending?.takeIf { it.optString("op") == "new" && it.optString("cwd") == cwd && it.optString("provider") == provider }
        val waiting = SessionCreationWaitState()
        original?.let { waiting.begin(it) }

        var creation = try {
            if (original?.has("draftId") == true) SessionCreationDraft.restore(original.toString(), cwd, provider)
            else client.creationDraft(cwd, provider).let { previous ->
                val fresh = io.github.junweiup.vibepier.remote.core.session.SessionWaitingPolicy.freshCreationDraft(previous, client.uncertain("", provider))
                if (fresh != previous && !client.saveCreationDraft(fresh)) error("Creation draft unavailable")
                fresh
            }
        } catch (_: Exception) {
            menu(context.getString(R.string.session_new_session), context.getString(R.string.creation_draft_unavailable), emptyList()); return
        }
        lateinit var options: NewSessionOptionsView
        lateinit var dialog: AlertDialog
        var optionsRequest: String? = null
        lateinit var refreshCreationOptions: () -> Unit
        lateinit var resumeCreation: (SessionCreationDraft) -> Unit
        var creationFailure: String? = null
        // Automatic read-only checks after an uncertain result; they never resubmit the creation.
        var autoCheck = Runnable {}
        var autoCheckCount = 0
        var scheduleAutoCheck: () -> Unit = {}
        // Drawer refreshes and reconnects bump the panel generation; the creation dialog is scoped by provider and authorization only.
        fun sameCreationScope() = provider == client.provider && authorization == authorizationSource()

        val field = EditText(context).apply {
            hint = context.getString(R.string.session_first_message); textSize = Ui.BODY; setTextColor(Palette.text); setHintTextColor(Palette.faint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            minLines = 3; maxLines = 8; gravity = Gravity.TOP; background = background(Palette.surfaceTop)
            setPadding(dp(12), dp(12), dp(12), dp(12))
        }
        field.setText(creation.text)
        val hintText = when { claude -> context.getString(R.string.session_claude_new_explanation) + "\n" + context.getString(R.string.creation_claude_images); zcode -> context.getString(R.string.session_create_a_session_in_zcode_on_the_mac_and_send_the_first_message); else -> context.getString(R.string.session_codex_new_background_explanation) }
        val state = label(hintText, Ui.CAPTION, Palette.faint)
        val attachmentList = column()
        fun draftFields() = JSONObject().put("cwd", cwd).put("provider", provider).put("draftId", creation.id)
        fun attachmentIDsForDraft(): JSONArray {
            val entries = client.attachments(creation.attachmentScope, provider)
            return JSONArray((0 until entries.length()).map { entries.getJSONObject(it).getString("attachmentId") })
        }
        fun saveCreation(): Boolean {
            creation = creation.copy(text = field.text.toString())
            return try { client.saveCreationDraft(creation) } catch (_: Exception) { false }
        }
        fun readCreationDraft(): SessionCreationDraft? = try { client.creationDraft(cwd, provider) } catch (_: Exception) {
            state.text = context.getString(R.string.creation_draft_unavailable); null
        }
        val persistDraft = Runnable {
            if (dialog.isShowing && original == null && !saveCreation()) state.text = context.getString(R.string.creation_draft_unavailable)
        }
        fun renderAttachments() {
            attachmentList.removeAllViews()
            val items = client.attachments(creation.attachmentScope, provider)
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                attachmentList.addView(button("× " + item.optString("name")) {
                    if (busy || original != null || !sameCreationScope()) return@button
                    val kept = JSONArray((0 until items.length()).filter { it != i }.map { items.getJSONObject(it) })
                    if (!client.saveAttachments(creation.attachmentScope, kept, provider)) return@button
                    client.request("newAttachmentRemove", draftFields().put("attachmentId", item.optString("attachmentId"))) {}
                    item.optString("cachePath").takeIf { it.isNotBlank() }?.let { path ->
                        val file = java.io.File(path); val root = java.io.File(context.filesDir, "codex-drafts")
                        if (file.canonicalPath.startsWith(root.canonicalPath + "/")) file.delete()
                    }
                    renderAttachments()
                }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
            }
        }
        options = NewSessionOptionsView(context, creation, changed = {
            creation = it.copy(text = field.text.toString())
            ui.removeCallbacks(persistDraft); ui.postDelayed(persistDraft, 250)
        }, addAttachment = {
            if (busy || original != null || !sameCreationScope()) return@NewSessionOptionsView
            if (attachmentIDsForDraft().length() >= 6) { state.text = context.getString(R.string.session_limit_of_6_attachments_reached_remove_one_first); return@NewSessionOptionsView }
            if (!saveCreation()) { state.text = context.getString(R.string.creation_draft_unavailable); return@NewSessionOptionsView }
            menu(context.getString(R.string.session_add_attachments_and_context), context.getString(R.string.session_up_to_6_attachments_10_mb_each_they_are_submitted_to_this_sessio), listOf(
                context.getString(R.string.session_add_image_phone_gallery) to { (activity as? MainActivity)?.pickCodexAttachment(true) },
                context.getString(R.string.session_add_file_phone_files) to { (activity as? MainActivity)?.pickCodexAttachment(false) }
            ))
        }, permits = { key -> reviews || client.creationCapability(key, creation) }, refreshOptions = { refreshCreationOptions() })
        fun earlierCreations() = client.uncertain("", provider).filter { it.optString("op") == "new" && it.optString("cwd") == cwd }
        val earlierReceipts = button(context.getString(R.string.creation_pending_history)) {
            if (busy || !sameCreationScope()) return@button
            menu(context.getString(R.string.creation_pending_history), context.getString(R.string.creation_old_receipts_kept), earlierCreations().map { pending ->
                pending.optString("text").take(40).ifBlank { context.getString(R.string.session_check_result) } to {
                    dialog.dismiss(); showNewSession(pending)
                }
            })
        }
        val earlierHint = label(context.getString(R.string.creation_old_receipts_kept), Ui.CAPTION, Palette.muted)
        fun renderEarlierReceipts() {
            val visibility = if (original == null && earlierCreations().isNotEmpty()) VISIBLE else GONE
            earlierReceipts.visibility = visibility; earlierHint.visibility = visibility
        }
        val body = column().apply {
            addView(label("$agent · $projectName", Ui.LABEL, Palette.muted).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END },
                LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(10) })
            addView(field, LinearLayout.LayoutParams(-1, -2))
            addView(options, LinearLayout.LayoutParams(-1, -2))
            addView(attachmentList, LinearLayout.LayoutParams(-1, -2))
            addView(state, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
            addView(earlierReceipts, LinearLayout.LayoutParams(-1, -2))
            addView(earlierHint, LinearLayout.LayoutParams(-1, -2))
            addView(label(context.getString(R.string.creation_stop_waiting_detail), Ui.CAPTION, Palette.muted), LinearLayout.LayoutParams(-1, -2))
        }
        val footer = row(); dialog = canvasDialog(context.getString(R.string.session_new_session), ScrollView(context).apply { addView(body) }, footer, compact = true)
        creationDialog = dialog
        val cancelWaiting = button(context.getString(if (original == null) R.string.cancel else R.string.session_stop_waiting)) {
            val pending = original
            if (pending != null) {
                if (!sameCreationScope()) return@button
                val saved = if (reviews) client.saveCreationDraft(io.github.junweiup.vibepier.remote.core.session.SessionWaitingPolicy.freshCreationDraft(creation, listOf(pending)))
                    else client.stopCreationWaiting(pending)
                if (!saved) { state.text = context.getString(R.string.creation_draft_unavailable); return@button }
                val next = readCreationDraft() ?: return@button
                waiting.stop(); client.cancelCreationReceiptReads(pending.getString("id")); ui.removeCallbacks(autoCheck)
                original = null
                resumeCreation(next)
                return@button
            }
            dialog.dismiss()
        }
        footer.addView(cancelWaiting, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(8) })
        var retryOriginal = false
        if (original != null) {
            field.setText(original!!.optString("text")); field.isEnabled = false; options.setLocked(true)
            state.text = context.getString(R.string.session_result_still_unknown_check_on_the_mac_to_avoid_a_duplicate_opera)
        }
        lateinit var start: CanvasLabel
        fun loadCreationOptions(attempt: Int = 0, refresh: Boolean = false) {
            if (!dialog.isShowing || !sameCreationScope() || original != null) return
            client.cancelCreationOptions(optionsRequest)
            val id = java.util.UUID.randomUUID().toString(); optionsRequest = id
            val draftToken = waiting.draftToken(creation.id)
            if (creationFailure == null) state.text = context.getString(R.string.creation_loading_options)
            call("newOptions", draftFields().put("id", id).apply { if (refresh) put("refreshOptions", true) }) { result ->
                if (!dialog.isShowing || !sameCreationScope() || optionsRequest != id || !waiting.accepts(draftToken, creation.id)) return@call
                if (!result.optBoolean("ok")) {
                    if (attempt < 2 && result.optString("code") in setOf("agent_native_unavailable", "agent_state_not_ready", "agent_session_view_closed", "agent_session_not_open")) {
                        ui.postDelayed({ if (dialog.isShowing && sameCreationScope() && optionsRequest == id && waiting.accepts(draftToken, creation.id)) loadCreationOptions(attempt + 1, refresh) }, if (attempt == 0) 300 else 900)
                    } else state.text = result.optString("error").takeIf { it.isNotBlank() }?.let { "$it\n${context.getString(R.string.creation_options_unavailable)}" }
                        ?: context.getString(R.string.creation_options_unavailable)
                    return@call
                }
                options.applyOptions(result)
                state.text = creationFailure ?: if (reviews || client.creationCapability("new", creation)) hintText else context.getString(R.string.agent_upgrade_required)
                state.setTextColor(if (creationFailure != null) Palette.red else Palette.faint)
            }
        }
        refreshCreationOptions = { loadCreationOptions(refresh = true) }
        fun receive(result: JSONObject, callback: SessionCreationWaitState.CallbackToken) {
            if (!dialog.isShowing || !sameCreationScope() || !waiting.accepts(callback)) return
            busy = false; start.alpha = 1f; options.setLocked(original != null)
            val unknown = result.optBoolean("unknown") || (result.optBoolean("ok") && result.optString("threadId").isBlank())
            if (unknown || !result.optBoolean("ok")) {
                state.setTextColor(Palette.red)
                if (unknown) {
                    original = client.uncertain("", provider).firstOrNull { it.optString("id") == original?.optString("id") } ?: original
                    field.isEnabled = false; options.setLocked(true); retryOriginal = false
                    start.text = context.getString(R.string.session_check_result)
                    state.text = context.getString(R.string.session_result_still_unknown_check_on_the_mac_to_avoid_a_duplicate_opera)
                    scheduleAutoCheck()
                } else {
                    val next = readCreationDraft() ?: return
                    creationFailure = result.optString("error").takeIf { it.isNotBlank() } ?: context.getString(R.string.session_could_not_create_session)
                    waiting.stop(); original = null; resumeCreation(next)
                    state.setTextColor(Palette.red)
                    state.text = creationFailure ?: context.getString(R.string.session_could_not_create_session)
                }
                return
            }
            val sent = original
            if (sent?.has("draftId") == true) {
                if (!client.finishCreation(sent)) {
                    field.isEnabled = false; options.setLocked(true); start.text = context.getString(R.string.session_check_result)
                    state.text = context.getString(R.string.creation_draft_unavailable); return
                }
            }
            waiting.stop(); original = null
            if ((result.optJSONArray("warnings")?.length() ?: 0) > 0) {
                android.widget.Toast.makeText(context, context.getString(R.string.session_created_with_unverified_options), android.widget.Toast.LENGTH_LONG).show()
            }
            dialog.setOnDismissListener { client.cancelCreationOptions(optionsRequest); ui.removeCallbacks(persistDraft); ui.removeCallbacks(autoCheck); if (creationDialog === dialog) creationDialog = null; options.closeMenus(); clearCreationAttachment(pickerToken); auxiliaryDialogs.remove(dialog) }
            dialog.dismiss()
            if (drawer && client.provider == provider) open(result.optString("threadId"), result.optString("title").ifBlank { field.text.toString().take(40) })
        }
        /** Read-only lookup of the original operation; a retry of the same operation only follows an explicit notFound tap. */
        fun checkOriginal(automatic: Boolean) {
            val pending = original ?: return
            if (busy || !dialog.isShowing || !sameCreationScope() || (automatic && retryOriginal)) return
            busy = true; start.alpha = .5f
            val callback = waiting.begin(pending)
            if (retryOriginal) {
                if (reviews) call("new", pending) { receive(it, callback) } else client.retryPending(pending.getString("id")) { receive(it, callback) }
                return
            }
            call("receipt", JSONObject().put("operation", pending.getString("id")).put("provider", provider)) { result ->
                if (!dialog.isShowing || !sameCreationScope() || !waiting.accepts(callback)) return@call
                busy = false; start.alpha = 1f
                when (result.optString("state")) {
                    "complete" -> {
                        val receipt = result.optJSONObject("receipt")
                        if (receipt != null && receipt.has("ok") && !receipt.optBoolean("unknown") && (!receipt.optBoolean("ok") || receipt.optString("threadId").isNotBlank())) {
                            if (!pending.has("draftId") || !receipt.optBoolean("ok")) client.clearReceipt(pending.getString("id"))
                            receive(receipt, callback)
                        } else scheduleAutoCheck()
                    }
                    "notFound" -> {
                        retryOriginal = true; start.text = context.getString(R.string.session_retry_original_request)
                        state.text = context.getString(R.string.session_mac_has_not_received_it_tap_to_retry_the_original_operation)
                    }
                    else -> {
                        state.text = context.getString(R.string.session_result_still_unknown_check_on_the_mac_to_avoid_a_duplicate_opera)
                        scheduleAutoCheck()
                    }
                }
            }
        }
        autoCheck = Runnable { checkOriginal(true) }
        scheduleAutoCheck = {
            ui.removeCallbacks(autoCheck)
            autoChecks.getOrNull(autoCheckCount++)?.let { delay -> ui.postDelayed(autoCheck, delay) }
        }
        start = button(context.getString(if (original == null) R.string.session_start else R.string.session_check_result), true) {
            if (busy || !dialog.isShowing || !sameCreationScope()) return@button
            if (original != null) { checkOriginal(false); return@button }
            if (!options.loaded) { loadCreationOptions(); return@button }
            val text = field.text.toString().trim()
            if (text.isEmpty() && attachmentIDsForDraft().length() == 0) { state.text = context.getString(R.string.session_enter_the_first_message); state.setTextColor(Palette.amber); return@button }
            if (!reviews && !client.creationCapability("new", creation)) { state.text = context.getString(R.string.agent_capability_unavailable); return@button }
            if (!options.ready) { state.text = context.getString(R.string.creation_choose_options); return@button }
            if (!reviews && client.duplicateUnconfirmedCreation(cwd, text, attachmentIDsForDraft())) {
                state.text = context.getString(R.string.creation_duplicate_pending); return@button
            }
            if (!saveCreation()) { state.text = context.getString(R.string.creation_draft_unavailable); return@button }
            val intent = try { creation.request(java.util.UUID.randomUUID().toString(), attachmentIDsForDraft()) }
                catch (_: Exception) { state.text = context.getString(R.string.creation_invalid_prompt); return@button }
            creationFailure = null
            busy = true; start.alpha = .5f; field.isEnabled = false; state.setTextColor(Palette.faint); options.setLocked(true)
            state.text = if (claude) context.getString(R.string.session_starting_claude_code_in_the_background_on_the_mac) else context.getString(R.string.session_creating_in_provider, agent)
            original = intent; autoCheckCount = 0
            val callback = waiting.begin(intent)
            renderEarlierReceipts()
            cancelWaiting.text = context.getString(R.string.session_stop_waiting)
            call("new", intent) { receive(it, callback) }
        }
        footer.addView(start, LinearLayout.LayoutParams(0, -2, 1f))
        resumeCreation = { next ->
            client.cancelCreationOptions(optionsRequest); optionsRequest = null; ui.removeCallbacks(persistDraft)
            busy = false; retryOriginal = false
            creation = next
            field.setText(creation.text); field.isEnabled = true
            options.resetDraft(creation); renderAttachments(); renderEarlierReceipts()
            start.alpha = 1f; start.text = context.getString(R.string.session_start)
            cancelWaiting.text = context.getString(R.string.cancel); state.setTextColor(if (creationFailure != null) Palette.red else Palette.faint)
            loadCreationOptions(); field.requestFocus()
        }
        creationPickerToken = pickerToken
        creationAttachmentIsCurrent = { dialog.isShowing && authorization == authorizationSource() &&
            provider == client.provider && !busy && original == null }
        creationAttachment = { uri ->
            if (creationPickerToken == pickerToken && creationAttachmentIsCurrent()) {
                busy = true; options.setLocked(true); state.text = context.getString(R.string.session_reading_attachment)
                val target = creation
                val attachmentToken = waiting.draftToken(target.id)
                fun attachmentCurrent() = dialog.isShowing && sameCreationScope() && waiting.accepts(attachmentToken, creation.id)
                fun attachmentFields() = JSONObject().put("cwd", target.cwd).put("provider", target.provider).put("draftId", target.id)
                CodexFileUpload.prepare(context, uri) { file, name, mime, error ->
                    releasePickerPermission(uri)
                    if (!attachmentCurrent()) { file?.delete(); return@prepare }
                    if (file == null) { busy = false; options.setLocked(false); state.text = error ?: context.getString(R.string.attachment_unreadable); return@prepare }
                    CodexFileUpload.upload(resources, client, target.attachmentScope, file, name, mime, { progress ->
                        if (attachmentCurrent()) state.text = context.getString(R.string.session_upload_progress, name, progress.optInt("progress"))
                    }, cancelled = { !attachmentCurrent() }, creation = target) { result ->
                        val current = attachmentCurrent()
                        if (!current || !result.optBoolean("ok")) {
                            file.delete()
                            if (sameCreationScope()) client.request("newAttachmentRemove", attachmentFields().put("attachmentId", result.optString("attachmentId"))) {}
                        } else {
                            val entries = client.attachments(target.attachmentScope, provider); entries.put(result)
                            if (!client.saveAttachments(target.attachmentScope, entries, provider)) {
                                file.delete()
                                client.request("newAttachmentRemove", attachmentFields().put("attachmentId", result.optString("attachmentId"))) {}
                                state.text = context.getString(R.string.creation_draft_unavailable)
                            }
                            else state.text = context.getString(R.string.session_attachment_ready_tap_send_to_submit_it)
                            renderAttachments()
                        }
                        if (current) {
                            busy = false; options.setLocked(original != null)
                            if (!result.optBoolean("ok")) state.text = result.optString("error")
                        }
                    }
                }
            }
        }
        dialog.setOnDismissListener {
            client.cancelCreationOptions(optionsRequest); ui.removeCallbacks(persistDraft); ui.removeCallbacks(autoCheck)
            if (creationDialog === dialog) creationDialog = null
            if (original == null) saveCreation()
            options.closeMenus(); clearCreationAttachment(pickerToken); auxiliaryDialogs.remove(dialog)
        }
        watch(field) { if (original == null) { ui.removeCallbacks(persistDraft); ui.postDelayed(persistDraft, 250) } }
        renderAttachments()
        renderEarlierReceipts()
        if (original == null) loadCreationOptions() else ui.postDelayed(autoCheck, 300)
        field.requestFocus()
    }
    /** Starts a new rounded group of rows, under an overline when the list has named sections. */
    private fun startGroup(title: String?) {
        if (title != null) list.addView(Ui.label(context, title, Ui.CAPTION, Palette.faint).apply { typeface = Typeface.DEFAULT_BOLD },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(if (list.childCount == 0) 4 else 16); bottomMargin = dp(4); marginStart = dp(8) })
        group = column()
        list.addView(group, LinearLayout.LayoutParams(-1, -2))
    }
    /** Running in mint, approval in amber; an idle session shows nothing. */
    private fun statusLabel(status: String) = when (status) { "running" -> context.getString(R.string.running); "approval" -> context.getString(R.string.session_awaiting_approval); else -> "" }
    private fun listRow(primary: String, secondary: String, current: Boolean, description: String, status: String = "", time: String = "", action: () -> Unit) = row().apply {
        gravity = Gravity.TOP
        background = if (current) background(Palette.accentContainer, 14) else null
        setPadding(dp(8), dp(11), dp(8), dp(11)); minimumHeight = dp(60); isFocusable = true
        contentDescription = description; setOnClickListener { hideKeyboard(); action() }
        addView(SessionGlyph(context, when {
            status == context.getString(R.string.session_awaiting_approval) -> SessionGlyph.State.APPROVAL
            status.isNotBlank() -> SessionGlyph.State.RUNNING
            current -> SessionGlyph.State.CURRENT
            else -> SessionGlyph.State.IDLE
        }), LinearLayout.LayoutParams(dp(28), dp(28)).apply { marginEnd = dp(12); topMargin = dp(1) })
        addView(column().apply {
            addView(label(primary, Ui.BODY, if (current) Palette.accent else Palette.text).apply {
                typeface = Ui.medium; maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END; lineSpacingExtra = 2f
            })
            if (secondary.isNotBlank()) addView(label(secondary, Ui.CAPTION, Palette.muted).apply { maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE },
                LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(3) })
        }, LinearLayout.LayoutParams(0, -2, 1f))
        if (time.isNotBlank() || status.isNotBlank()) addView(column().apply {
            gravity = Gravity.END
            if (time.isNotBlank()) addView(label(time, Ui.OVERLINE, Palette.faint).apply { maxLines = 1 })
            if (status.isNotBlank()) addView(label(status, Ui.OVERLINE, if (status == context.getString(R.string.session_awaiting_approval)) Palette.amber else Palette.accent).apply {
                typeface = Typeface.DEFAULT_BOLD
                background = background(if (status == context.getString(R.string.session_awaiting_approval)) Palette.amberContainer else Palette.accentContainer, 6)
                setPadding(dp(6), dp(2), dp(6), dp(2))
            }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(if (time.isNotBlank()) 6 else 0) })
        }, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(8) })
    }
    private fun relativeTime(updated: Long) =
        if (updated > 0) android.text.format.DateUtils.getRelativeTimeSpanString(updated, System.currentTimeMillis(), android.text.format.DateUtils.MINUTE_IN_MILLIS).toString() else ""
    private fun loadNextListPage() {
        if (!foreground || !drawer || !connected || loadingList || nextOffset < 0 || loadedDrawerKey != drawerKey()) return
        (list.getChildAt(list.childCount - 1) as? CanvasLabel)?.takeIf { it.tag == "more" }?.text = context.getString(R.string.session_loading)
        loadList(true)
    }
    private fun addListFooter() {
        if (nextOffset >= 0) list.addView(label(context.getString(R.string.session_scroll_up_to_load_more), Ui.CAPTION, Palette.faint).apply {
            tag = "more"; gravity = Gravity.CENTER; setPadding(0, dp(14), 0, dp(14))
        }, LinearLayout.LayoutParams(-1, -2))
    }
    private fun loadProjects(useCache: Boolean = true, more: Boolean = false) {
        if (!drawer || (more && loadingList)) return
        val offset = if (more) nextOffset else 0
        if (offset < 0) return
        val current = ++listGeneration
        val savedScroll = if (more) null else drawerScroll()
        if (!drawerLoaded || loadedDrawerKey != drawerKey()) info.text = context.getString(R.string.session_loading_2)
        else info.text = loadedDrawerInfo
        callList("projects", JSONObject().put("search", search).put("offset", offset).put("limit", 8), useCache && !more) { result ->
            if (!drawer || current != listGeneration) return@callList
            if (!result.optBoolean("ok")) { info.text = result.optString("error"); return@callList }
            drawerLoaded = true
            if (!more) { list.removeAllViews(); listedCount = 0; setCrumb(null) }
            else if (list.childCount > 0 && list.getChildAt(list.childCount - 1).tag == "more") list.removeViewAt(list.childCount - 1)
            val entries = result.optJSONArray("projects") ?: JSONArray()
            if (!more && entries.length() > 0) startGroup(null)
            listedCount += entries.length()
            for (i in 0 until entries.length()) {
                val item = entries.getJSONObject(i)
                val cwd = item.optString("cwd"); val name = item.optString("project").ifBlank { context.getString(R.string.session_no_project) }
                val count = item.optInt("count"); val time = relativeTime(item.optLong("updatedAt", 0)); val running = item.optInt("running")
                val active = if (running > 0) context.getString(R.string.session_running_count, running) else ""
                group.addView(listRow(name, resources.getQuantityString(R.plurals.session_count, count, count) + "\n" + cwd, false,
                    context.getString(R.string.session_open_project_count, name, count) + (if (running > 0) "，$active" else ""), active, time) {
                    projectCwd = cwd; projectName = name; loadList(false)
                })
            }
            nextOffset = result.optInt("nextOffset", -1)
            addListFooter()
            info.text = if (listedCount == 0) (if (search.isBlank()) context.getString(R.string.session_no_projects_yet_create_a_session_on_the_mac_first) else context.getString(R.string.session_no_matching_projects)) else resources.getQuantityString(R.plurals.project_count, listedCount, listedCount)
            loadedDrawerInfo = info.text.toString(); loadedDrawerKey = drawerKey()
            savedScroll?.let { y -> (list.parent as? ScrollView)?.let { parent -> parent.post { parent.scrollTo(0, y) } } }
        }
    }
    private fun loadList(more: Boolean, useCache: Boolean = true) {
        if (!reviews && !more && !useCache) client.refreshProviderAccess()
        if (!reviews && !client.providerEnabled(client.provider)) {
            client.refreshProviderAccess()
            return
        }
        if (!drawer || (more && loadingList)) return
        if (!authorized) { info.text = context.getString(R.string.session_bluetooth_approval_required); return }
        if (client.listMode == "projects" && projectCwd.isEmpty()) { loadProjects(useCache, more); return }
        val savedScroll = if (more) null else drawerScroll()
        val offset = if (more) nextOffset else 0
        if (offset < 0) return
        val current = ++listGeneration
        if (!drawerLoaded || loadedDrawerKey != drawerKey()) info.text = context.getString(R.string.session_loading_2)
        else info.text = loadedDrawerInfo
        val params = JSONObject().put("search", search).put("offset", offset).put("limit", 8)
        if (client.listMode == "projects") params.put("cwd", projectCwd)
        callList("list", params, useCache && !more) { result ->
            if (!drawer || current != listGeneration) return@callList
            if (!result.optBoolean("ok")) { info.text = result.optString("error"); return@callList }
            drawerLoaded = true
            if (!more) {
                list.removeAllViews(); listSection = ""; listedCount = 0
                setCrumb(if (client.listMode == "projects") projectName else null)
            } else if (list.childCount > 0 && list.getChildAt(list.childCount - 1).tag == "more") list.removeViewAt(list.childCount - 1)
            val entries = result.optJSONArray("threads") ?: JSONArray()
            for (i in 0 until entries.length()) {
                val item = entries.getJSONObject(i)
                val section = if (client.listMode == "projects") context.getString(R.string.session_project_sessions) else if (item.optBoolean("pinned")) context.getString(R.string.session_pinned) else context.getString(R.string.session_recent)
                if (section != listSection || !::group.isInitialized || group.parent == null) {
                    startGroup(if (search.isBlank() && client.listMode != "projects") section else null); listSection = section
                }
                val currentThread = item.optString("id") == thread
                val project = item.optString("project").ifBlank { context.getString(R.string.session_no_project) }
                val time = relativeTime(item.optLong("updatedAt", 0))
                val metadata = if (client.listMode == "projects") "" else project
                val status = statusLabel(item.optString("status"))
                listedCount++
                group.addView(listRow(item.optString("title"), metadata, currentThread,
                    (if (currentThread) context.getString(R.string.session_current_session) else context.getString(R.string.session_open_session)) + "${item.optString("title")}，${item.optString("project")}" + (if (status.isNotBlank()) "，$status" else ""), status, time) {
                    open(item.optString("id"), item.optString("title"))
                })
            }
            nextOffset = result.optInt("nextOffset", -1)
            addListFooter()
            info.text = if (listedCount == 0) (if (search.isBlank()) context.getString(R.string.session_no_sessions_available_create_one_on_the_mac_first) else context.getString(R.string.session_no_matching_sessions)) else resources.getQuantityString(R.plurals.session_count, listedCount, listedCount)
            loadedDrawerInfo = info.text.toString(); loadedDrawerKey = drawerKey()
            savedScroll?.let { y -> (list.parent as? ScrollView)?.let { parent -> parent.post { parent.scrollTo(0, y) } } }
        }
    }
    private fun open(id: String, name: String) {
        discardRestoredAttachment()
        closeMarkdownViewer()
        turnChanges = null; changesKey = ""; changesHolder = null
        if (drawer) {
            saveDrawerState()
            savedDrawer = (0 until childCount).map { getChildAt(it) }; savedDrawerKey = drawerKey()
        }
        searchWork?.let(ui::removeCallbacks); searchWork = null
        client.cancelPageReads(); pauseProcessReads(); listGeneration++; stopOpening(); stopSync()
        stoppedWaitSignature = null; sendWaitGeneration++; stopRequestedTurn = ""; progressSignature = ""; lastProgressAt = android.os.SystemClock.elapsedRealtime()
        saveDraft(); thread = id; title = name; drawer = false; ready = false; sending = false; submittingApproval = ""; retryableOperation = ""; generation++
        uploading = false; uploadLabel = ""; uploadGeneration++; settingsOperation = ""; approvedHere.clear()
        if (reviews) reviewAttachments = JSONArray()
        page = JSONObject(); historyComplete = false; loadingHistory = false; olderMessages.clear(); media.cancelReads(); lastMessages = ""; removeAllViews(); setBackgroundColor(Palette.background)
        val layout = column().apply { setPadding(dp(10), dp(4), dp(10), dp(10)) }; addView(layout, LayoutParams(-1, -1))
        layout.addView(row().apply {
            minimumHeight = dp(56)
            addView(IconControl(context, IconControl.Icon.BACK, context.getString(R.string.session_open_session_list), Palette.text, action = { hideKeyboard(); showDrawer() }), LinearLayout.LayoutParams(dp(44), dp(48)))
            addView(column().apply {
                setPadding(dp(4), 0, dp(4), 0)
                headerTitle = label(title, 15.5f).apply {
                    maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END; typeface = Typeface.DEFAULT_BOLD
                    contentDescription = context.getString(R.string.session_full_title_description, title)
                    setOnClickListener {
                        val actions = row(); val dialog = canvasDialog(context.getString(R.string.session_session_title), ScrollView(context).apply { addView(label(title, 16f)) }, actions)
                        actions.addView(button(context.getString(R.string.close)) { dialog.dismiss() }, LinearLayout.LayoutParams(-1, -2))
                    }
                }
                addView(headerTitle)
                statusDot = View(context).apply { background = background(Palette.faint, 3) }
                status = label(context.getString(R.string.session_loading_session), Ui.CAPTION, Palette.muted).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }
                statusRow = row().apply {
                    addView(statusDot, LinearLayout.LayoutParams(dp(6), dp(6)).apply { marginEnd = dp(6) })
                    addView(status, LinearLayout.LayoutParams(0, -2, 1f))
                }
                addView(statusRow, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(2) })
            }, LinearLayout.LayoutParams(0, -2, 1f))
            stopButton = Ui.pill(context, context.getString(R.string.session_stop), Palette.red) { stopCurrentTurn() }.apply {
                visibility = GONE; contentDescription = context.getString(R.string.session_stop_current_task)
                background = Ui.inset(context, Ui.roundRect(context, Palette.redContainer, 12), 8)
                setPadding(dp(12), 0, dp(12), 0)
            }
            addView(stopButton, LinearLayout.LayoutParams(-2, dp(48)).apply { marginEnd = dp(2) })
            filesBadge = label("", 9.5f, Color.rgb(42, 29, 7)).apply {
                typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER; visibility = GONE; setPadding(dp(4), 0, dp(4), 0)
                background = background(Palette.amber, 8); importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            filesButton = FrameLayout(context).apply {
                addView(IconControl(context, IconControl.Icon.FOLDER, context.getString(R.string.files_project_files), action = { showProjectFiles() }), LayoutParams(-1, -1))
                addView(filesBadge, LayoutParams(-2, dp(16), Gravity.TOP or Gravity.END).apply { topMargin = dp(6); marginEnd = dp(2) })
            }.also { addView(it, LinearLayout.LayoutParams(dp(44), dp(48))) }
            addView(IconControl(context, IconControl.Icon.MORE, context.getString(R.string.session_more_session_actions), action = { menu(context.getString(R.string.session_session_actions), "", listOf(
                    (if (projectFiles) context.getString(R.string.files_project_files) to { showProjectFiles() } else context.getString(R.string.session_view_markdown_files) to { showMarkdownFiles("") }),
                    context.getString(R.string.session_refresh_session) to { media.clear(); client.clearImages(thread); open(thread, title) })) }), LinearLayout.LayoutParams(dp(44), dp(48)))
            addView(IconControl(context, IconControl.Icon.REMOTE, context.getString(R.string.session_back_to_phone_remote), action = { close() }), LinearLayout.LayoutParams(dp(44), dp(48)))
        })
        layout.addView(View(context), LinearLayout.LayoutParams(-1, dp(4)))
        timeline = column(); timelineRows = ConversationTimeline(timeline); renderedProcesses.clear()
        scroll = object : ScrollView(context) {
            private var startY = 0f
            override fun dispatchTouchEvent(event: MotionEvent): Boolean {
                if (event.actionMasked == MotionEvent.ACTION_DOWN) startY = event.y
                if (event.actionMasked == MotionEvent.ACTION_UP && event.y - startY > dp(32) && !canScrollVertically(-1)) loadOlder(explicitPull = true)
                return super.dispatchTouchEvent(event)
            }
            override fun performAccessibilityAction(action: Int, arguments: android.os.Bundle?): Boolean {
                if (action == android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD && !canScrollVertically(-1)) {
                    loadOlder(explicitPull = true); return true
                }
                return super.performAccessibilityAction(action, arguments)
            }
        }.apply {
            isFillViewport = true; addView(timeline)
            setOnScrollChangeListener { _, _, y, _, oldY -> if (!timelineRows.restoringPosition && y < oldY && y < dp(320)) loadOlder() }
        }
        newest = Ui.pill(context, context.getString(R.string.session_latest)) { scroll.fullScroll(ScrollView.FOCUS_DOWN); newest.visibility = GONE }.apply {
            visibility = GONE; background = Ui.inset(context, Ui.roundRect(context, Palette.surface4, 16), 8); elevation = dp(4).toFloat()
            setPadding(dp(16), 0, dp(16), 0)
        }
        layout.addView(FrameLayout(context).apply {
            addView(scroll, LayoutParams(-1, -1))
            addView(newest, LayoutParams(-2, dp(48), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = dp(4) })
        }, LinearLayout.LayoutParams(-1, 0, 1f))
        queuedBox = column(); queueRendering = ""
        layout.addView(object : ScrollView(context) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(dp(176), MeasureSpec.AT_MOST))
            }
        }.apply { addView(queuedBox); isVerticalScrollBarEnabled = false }, LinearLayout.LayoutParams(-1, -2))
        waitMessage = label("", Ui.CAPTION, Palette.amber).apply { accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }
        waitCancel = button(context.getString(R.string.session_stop_waiting)) { stopWaiting() }
        waitBanner = column().apply {
            visibility = GONE; setPadding(dp(12), dp(8), dp(12), dp(8)); background = background(Palette.surface3, 12)
            addView(waitMessage, LinearLayout.LayoutParams(-1, -2))
            addView(waitCancel, LinearLayout.LayoutParams(-1, dp(48)))
        }
        layout.addView(waitBanner, LinearLayout.LayoutParams(-1, -2))
        ui.removeCallbacks(waitCheck); ui.postDelayed(waitCheck, 5_000)
        notice = label(hint(), Ui.CAPTION, Palette.faint)
        layout.addView(notice, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6); bottomMargin = dp(6); marginStart = dp(8); marginEnd = dp(8) })
        editor = EditText(context).apply {
            hint = context.getString(R.string.session_reply_to_this_session); textSize = Ui.BODY; setTextColor(Palette.text); setHintTextColor(Palette.faint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            minLines = 1; maxLines = 5; gravity = Gravity.TOP; background = null
            setPadding(dp(12), dp(12), dp(12), dp(12)); setText(if (reviews) "" else client.draft(thread))
        }
        composerControls = ComposerControls(context, editor, ::showAddMenu, ::showModeMenu, ::showModelMenu, ::sendReply, ::showContextUsage, ::showExecutionModeMenu)
        sendButton = composerControls.send
        layout.addView(composerControls, LinearLayout.LayoutParams(-1, -2))
        attachmentRendering = ""
        watch(editor) { saveDraft(); updateComposer() }
        updateComposer()
        if (!reviews) client.cachedPage(thread)?.let { cached ->
            cached.put("viewVersion", client.viewVersion).put("canSend", false).put("approvals", JSONArray())
            cached.remove("revision")
            renderingCache = true
            try { applyPage(cached) } finally { renderingCache = false }
        }
        if (connected) requestOpen()
        else { status.text = context.getString(R.string.session_mac_disconnected_showing_saved_content); updateComposer() }
        if (!reviews) checkUncertain()
    }
    /**
     * Pages carry only the newest turns, so a message that a new turn pushes out of that window would vanish; keep it
     * with the earlier messages already loaded instead.
     */
    private fun retainScrolledOut(previous: JSONArray?, next: JSONArray?) {
        if (previous == null || next == null || next.length() == 0) return
        val kept = (0 until next.length()).map { next.getJSONObject(it).optString("id") }.toSet()
        val ids = (0 until previous.length()).map { previous.getJSONObject(it).optString("id") }
        val first = ids.indexOfFirst { it in kept }.takeIf { it >= 0 } ?: return
        for (i in 0 until first) if (ids[i] !in olderMessages) olderMessages[ids[i]] = previous.getJSONObject(i)
    }
    /** Earlier turns, a batch before the oldest message shown; scrolling near the top asks for them on its own. */
    private fun loadOlder(explicitPull: Boolean = false) {
        if (!foreground || drawer || !ready || !connected || loadingHistory) return
        if (renderedProcesses.firstOrNull()?.loadEarlier() == true) return
        // An explicit pull rechecks the desktop when the saved pagination hint is out of date.
        // Automatic near-top loading still stops at the last confirmed boundary.
        if (!explicitPull && (historyComplete || !page.optBoolean("hasOlder"))) return
        val before = olderMessages.keys.firstOrNull() ?: page.optJSONArray("messages")?.optJSONObject(0)?.optString("id") ?: return
        loadingHistory = true
        (timeline.getChildAt(0) as? CanvasLabel)?.text = context.getString(R.string.session_loading_earlier_messages)
        val token = generation
        call("history", JSONObject().put("threadId", thread).put("before", before)) { result ->
            if (token != generation) return@call
            loadingHistory = false
            if (result.optBoolean("ok")) {
                historyComplete = !result.optBoolean("hasOlder")
                val older = linkedMapOf<String, JSONObject>(); val entries = result.optJSONArray("messages") ?: JSONArray()
                for (i in 0 until entries.length()) { val item = entries.getJSONObject(i); older[item.optString("id")] = item }
                older.putAll(olderMessages); olderMessages = older
                page.put("hasOlder", result.optBoolean("hasOlder")); prependAnchor = scroll.scrollY to timeline.height
                lastMessages = ""; applyPage(page)
            } else {
                notice.text = result.optString("error")
                (timeline.getChildAt(0) as? CanvasLabel)?.text = context.getString(R.string.session_pull_down_to_retry_earlier_messages)
            }
        }
    }
    private fun applyPage(value: JSONObject) {
        if (value.has("provider") && value.optString("provider") != client.provider) return
        if (!foreground || drawer || value.optString("threadId") != thread || (!reviews && value.optLong("viewVersion", -1) != client.viewVersion)) return
        if (value.has("revision") && value.optLong("revision") < page.optLong("revision", -1)) return
        if (value.optBoolean("unchanged")) {
            if (value.optString("cacheVersion") != page.optString("cacheVersion") || !page.has("messages")) { resync(withCache = false); return }
            value.put("messages", page.getJSONArray("messages")); value.remove("unchanged")
        }
        if (historyComplete) value.put("hasOlder", false)
        retainScrolledOut(page.optJSONArray("messages"), value.optJSONArray("messages"))
        if (!renderingCache) {
            stopOpening()
            if (!reviews) client.rememberPage(thread, value)
        }
        if (!renderingCache) {
            if (value.optString("status") != "active" || value.optString("activeTurnId") != stopRequestedTurn) stopRequestedTurn = ""
            val progress = listOf(value.optString("activeTurnId"), value.optString("status"), value.optJSONArray("messages"), value.optJSONArray("approvals"), value.optJSONObject("blocker")).joinToString("\u0000")
            if (progress != progressSignature) { progressSignature = progress; lastProgressAt = android.os.SystemClock.elapsedRealtime() }
        }
        val previousHint = hint(); val wasReady = ready; page = value; ready = !renderingCache && connected
        if (::notice.isInitialized && notice.text.toString() == previousHint) notice.text = hint()
        status.text = when {
            !connected -> context.getString(R.string.session_mac_disconnected_2)
            (value.optJSONArray("approvals")?.length() ?: 0) > 0 -> context.getString(R.string.session_waiting_for_you_answer_or_review_on_the_phone)
            value.optString("status") == "active" -> if (supports("queue")) context.getString(R.string.session_provider_working_queue, agent) else context.getString(R.string.session_provider_working, agent)
            value.optString("status") == "idle" -> if (canSend) context.getString(R.string.session_connected_ready_to_reply) else context.getString(R.string.session_connected_viewing_session)
            else -> context.getString(R.string.session_session_synced)
        }
        statusDot.background = background(when {
            !connected -> Palette.red
            (value.optJSONArray("approvals")?.length() ?: 0) > 0 -> Palette.amber
            value.optString("status") == "active" -> Palette.amber
            else -> Palette.accent
        }, 3)
        val approvals = value.optJSONArray("approvals") ?: JSONArray()
        // A disappearing approval is not proof that our earlier decision was submitted.
        if (openApproval.isNotEmpty() && (0 until approvals.length()).none { approvals.getJSONObject(it).optString("fingerprint") == openApproval }) {
            val revised = (0 until approvals.length()).any { approvals.getJSONObject(it).optString("id") == openApprovalId }
            approvalDialog?.dismiss(); openApproval = ""; notice.text = if (revised) context.getString(R.string.session_the_request_changed_review_it_again) else context.getString(R.string.session_the_request_was_handled_or_is_no_longer_valid); submittingApproval = ""
        }
        val recent = value.optJSONArray("messages") ?: JSONArray()
        val combined = LinkedHashMap(olderMessages)
        for (i in 0 until recent.length()) { val item = recent.getJSONObject(i); combined[item.optString("id")] = item }
        val messages = JSONArray(combined.values.toList())
        settleOutbox(messages)
        val pending = outbox[threadKey()].orEmpty()
        val rendering = messages.toString() + approvals.toString() + value.optBoolean("hasOlder") + pending.joinToString { it.at.toString() } + value.optString("status")
        if (rendering != lastMessages) {
            val y = scroll.scrollY
            val prepend = prependAnchor; prependAnchor = null
            val restored = restoredScrollY; restoredScrollY = null
            val renderingGeneration = generation
            val atBottom = restored == null && prepend == null && (timeline.childCount == 0 || timeline.height - (scroll.height + y) < dp(80))
            timelineRows.preservePosition(scroll, atBottom, restored,
                { !drawer && foreground && renderingGeneration == generation },
                { if (restored == null && !atBottom) newest.visibility = VISIBLE })
            lastMessages = rendering
            timelineProcessKeys = (0 until messages.length()).map { messages.getJSONObject(it) }.filter { it.optString("role") != "user" }.map { "${client.provider}:$thread:${it.optString("id")}" }.toSet()
            val holder = changesHolder ?: column().apply { layoutParams = LinearLayout.LayoutParams(-1, -2) }.also { changesHolder = it }
            timelineRows.reconcile(timelineContent.rows(messages, approvals,
                pending.map { ConversationTimelineContent.Pending(it.text, it.at) }, value.optString("status") == "active",
                value.optBoolean("hasOlder"), loadingHistory, holder))
            renderedProcesses.clear()
            fun collect(view: View) {
                if (view is InlineReplyProcess) renderedProcesses.add(view)
                else if (view is ViewGroup) for (index in 0 until view.childCount) collect(view.getChildAt(index))
            }
            collect(timeline)
            renderChangesCard()
        }
        updateComposer()
        if (!wasReady && ready) processStates.values.forEach { it.changed() }
        drainRestoredAttachment()
        refreshTurnChanges()
    }
    /** A dirty event during a read schedules another read instead of being dropped. */
    private fun resync(withCache: Boolean = true) {
        if (!foreground || drawer || thread.isEmpty() || !connected || !authorized) return
        syncState.request(withCache)
        if (syncRetry == null) runSync()
    }
    private fun runSync() {
        if (!foreground || drawer || thread.isEmpty() || !connected || !authorized) { stopSync(); return }
        val read = syncState.begin() ?: return
        val token = generation; val source = client.provider; val selected = client.selectedAgentAdapter()?.id
        val authorization = authorizationSource(); val view = client.viewVersion
        call("sync", JSONObject().put("threadId", thread).apply { if (read.withCache) put("knownVersion", page.optString("cacheVersion")) }) { response ->
            if (token != generation || drawer || !foreground || source != client.provider || selected != client.selectedAgentAdapter()?.id ||
                authorization != authorizationSource() || view != client.viewVersion || !syncState.current(read)) return@call
            val success = response.optBoolean("ok") && (!response.has("contentState") || response.optString("contentState") == "complete")
            // Mark the read finished before rendering: applyPage can request a cache-free correction.
            val again = syncState.finish(read, success)
            if (success) applyPage(response)
            if (again) {
                syncRetry = Runnable { syncRetry = null; runSync() }.also { ui.postDelayed(it, if (success) 150L else 750L) }
            }
        }
    }
    private fun userIDs(messages: JSONArray?) = (0 until (messages?.length() ?: 0)).map { messages!!.getJSONObject(it) }
        .filter { it.optString("role") == "user" }.map { it.optString("id") }.toSet()
    /** Drops pending replies the page now shows (Claude may append attachment paths to the text) and ones older than 30 minutes. */
    private fun settleOutbox(messages: JSONArray) {
        val pending = outbox[threadKey()] ?: return
        val shown = (0 until messages.length()).map { messages.getJSONObject(it) }.filter { it.optString("role") == "user" }
        val now = System.currentTimeMillis()
        pending.removeAll { sent -> now - sent.at > 30 * 60_000 ||
            shown.any { it.optString("id") !in sent.known && it.optString("text").trim().startsWith(sent.text) } }
        if (pending.isEmpty()) outbox.remove(threadKey())
    }
    private val messageRenderer by lazy { ConversationMessageRenderer(context, { client.provider },
        ::inlineProcess, media::strip, ::openFileLink, ::showMessage, ::renderingScope, { foreground && !drawer }) }
    private val timelineContent by lazy { ConversationTimelineContent(context, messageRenderer, { agent }, ::openFileLink, ::showApproval,
        ::renderingScope, { foreground && !drawer }) }
    private fun applyDelta(delta: JSONObject) {
        if (delta.has("provider") && delta.optString("provider") != client.provider) return
        if (drawer || delta.optString("threadId") != thread || (!reviews && delta.optLong("viewVersion", -1) != client.viewVersion)) return
        if (delta.optLong("revision") <= page.optLong("revision", -1)) return
        if (delta.optLong("baseRevision", -1) != page.optLong("revision", -2)) { resync(); return }
        val items = linkedMapOf<String, JSONObject>()
        for (source in listOf(page.optJSONArray("messages"), delta.optJSONArray("messages"))) {
            if (source != null) for (i in 0 until source.length()) { val item = source.getJSONObject(i); items[item.optString("id")] = item }
        }
        val order = delta.optJSONArray("order") ?: JSONArray()
        val messages = JSONArray()
        for (i in 0 until order.length()) items[order.getString(i)]?.let { messages.put(it) }
        applyPage(JSONObject(delta.toString()).put("messages", messages))
    }
    private fun inlineProcess(message: JSONObject, sequence: JSONArray): View {
        val id = message.optString("id"); val target = thread; val token = generation
        val key = "${client.provider}:$target:$id"
        val sourceProvider = client.provider
        val sourceAuthorization = authorizationSource()
        val state = processStates.getOrPut(key) { InlineReplyProcess.State().apply {
            if (!reviews) client.cachedProcess(target, id)?.let { cached -> try { restore(cached) } catch (_: Exception) { rows.clear(); bodies.clear(); groups.clear(); this.count = 0 } }
            persist = { value -> if (!reviews && sourceAuthorization == authorizationSource()) client.rememberProcess(target, id, value, sourceProvider) }
        } }
        while (processStates.size > 64) {
            val oldest = processStates.keys.firstOrNull { it !in timelineProcessKeys } ?: break
            processStates.remove(oldest)
        }
        state.accept(sequence, message.optInt("partCount", sequence.length()))
        val current = { foreground && !drawer && ready && connected && token == generation && target == thread &&
            sourceProvider == client.provider && sourceAuthorization == authorizationSource() }
        return InlineReplyProcess(context, state, current, { offset, before, done ->
            call("parts", JSONObject().put("threadId", target).put("messageId", id).put("offset", offset).put("sequence", true).apply { if (before != null) put("before", before) }) { result ->
                if (current()) done(result)
            }
        }, { part, offset, done ->
            call("message", JSONObject().put("threadId", target).put("messageId", part).put("offset", offset).put("withPart", offset == 0)) { result ->
                if (current()) done(result)
            }
        }, media::strip, { if (current()) openFileLink(it) }).also { renderedProcesses.add(it) }
    }
    private fun imageVersion(id: String): String {
        val owner = id.substringBeforeLast('#')
        for ((key, state) in processStates) if (key.startsWith("${client.provider}:$thread:")) state.rows[owner]?.let { return it.optString("bodyVersion") }
        return owner
    }
    private fun showMessage(message: JSONObject) {
        var fullText = message.optString("text")
        val text = ChatMarkdownView(context, ::openFileLink, anyFile = true).apply { render(fullText) }
        val more = button(context.getString(R.string.session_load_full_text)) {}
        val box = column().apply { addView(text); addView(more) }
        val actions = row()
        val dialog = canvasDialog(context.getString(R.string.session_full_message), ScrollView(context).apply { addView(box) }, actions)
        actions.addView(button(context.getString(R.string.close)) { dialog.dismiss() }, LinearLayout.LayoutParams(-1, -2))
        var offset = message.optInt("nextOffset", message.optString("text").length)
        more.setOnClickListener {
            more.isEnabled = false
            call("message", JSONObject().put("threadId", thread).put("messageId", message.optString("id")).put("offset", offset).put("cacheVersion", page.optString("cacheVersion"))) { result ->
                if (!dialog.isShowing) return@call
                if (result.optBoolean("ok")) { fullText += result.optString("text"); text.render(fullText); offset = result.optInt("nextOffset", -1); more.visibility = if (offset < 0) GONE else VISIBLE }
                else more.text = result.optString("error")
                more.isEnabled = true
            }
        }
    }
    private fun showApproval(approval: JSONObject) {
        hideKeyboard()
        if (approval.optBoolean("detailsOnDemand")) {
            if (loadingApproval) return
            loadingApproval = true; val token = generation; notice.text = context.getString(R.string.session_loading_the_full_request)
            call("approvalDetails", JSONObject().put("threadId", thread).put("fingerprint", approval.optString("fingerprint"))) { result ->
                loadingApproval = false
                if (token != generation) return@call
                val detail = result.optJSONObject("approval")
                if (result.optBoolean("ok") && detail != null && detail.optString("fingerprint") == approval.optString("fingerprint")) {
                    val current = page.optJSONArray("approvals") ?: JSONArray()
                    if ((0 until current.length()).any { current.getJSONObject(it).optString("fingerprint") == detail.optString("fingerprint") }) showApproval(JSONObject(detail.toString()).apply { if (approval.has("revision")) put("revision", approval.get("revision")) })
                    else notice.text = context.getString(R.string.session_the_approval_changed_or_expired_refresh_it)
                } else notice.text = result.optString("error", context.getString(R.string.session_could_not_read_the_full_request_handle_it_on_the_mac))
            }
            return
        }
        val fingerprint = approval.optString("fingerprint"); val target = thread; val token = generation
        val actionScope = renderingScope()
        openApproval = fingerprint; openApprovalId = approval.optString("id")
        val isQuestion = approval.optString("kind") == "questions" && approval.optBoolean("canDecide") &&
            (approval.optJSONArray("questions")?.length() ?: 0) > 0
        val questions = approval.optJSONArray("questions") ?: JSONArray()
        if (isQuestion && fingerprint !in questionDrafts && questionDrafts.size >= 32) questionDrafts.remove(questionDrafts.keys.first())
        val answers = if (isQuestion) questionDrafts.getOrPut(fingerprint) { mutableMapOf() } else mutableMapOf()
        var onAnswersChanged: () -> Unit = {}
        val form = column()
        val inputs = mutableListOf<View>()
        if (isQuestion) for (index in 0 until questions.length()) {
            val question = questions.getJSONObject(index); val id = question.getString("id")
            form.addView(label("${index + 1}. ${question.optString("question")}", 16f),
                LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(16); bottomMargin = dp(8) })
            val options = question.optJSONArray("options") ?: JSONArray()
            val input = EditText(context).apply {
                hint = if (options.length() > 0) context.getString(R.string.session_or_enter_your_own_answer) else context.getString(R.string.session_enter_an_answer)
                setTextColor(Palette.text); setHintTextColor(Palette.muted); textSize = 15f
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                minLines = 2; maxLines = 6; gravity = Gravity.TOP
                background = background(Palette.surface, 10); setPadding(dp(12), dp(10), dp(12), dp(10))
                setText(answers[id].orEmpty())
            }
            val choices = mutableListOf<Pair<String, CanvasLabel>>()
            fun markSelection() {
                choices.forEach { (value, button) ->
                    val picked = answers[id] == value
                    button.text = (if (picked) "● " else "○ ") + value
                    button.contentDescription = value + if (picked) context.getString(R.string.session_selected) else context.getString(R.string.session_not_selected)
                    button.isSelected = picked
                    button.background = background(if (picked) Palette.accent else Palette.surface, 10)
                    button.setTextColor(if (picked) Palette.onAccent else Palette.text)
                }
            }
            for (i in 0 until options.length()) {
                val option = options.getJSONObject(i); val value = option.getString("label")
                val choice = button(value) {
                    answers[id] = value; input.setText(value); markSelection(); onAnswersChanged()
                }
                choices.add(value to choice); inputs.add(choice)
                form.addView(choice, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
                val description = option.optString("description")
                if (description.isNotBlank()) form.addView(label(description, 13f, Palette.muted),
                    LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4); bottomMargin = dp(4) })
            }
            if (question.optBoolean("freeform")) {
                inputs.add(input)
                form.addView(input, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
                input.addTextChangedListener(object : TextWatcher {
                    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                        answers[id] = s?.toString().orEmpty(); markSelection(); onAnswersChanged()
                    }
                    override fun afterTextChanged(s: Editable?) {}
                })
            }
            markSelection()
        } else form.addView(label(approval.optString("details"), 13f).apply {
            typeface = Typeface.MONOSPACE; setPadding(dp(18), dp(12), dp(18), dp(12))
        })
        val content = ScrollView(context).apply { addView(form) }
        val heading = context.getString(R.string.session_title_heading, title)
        val message = label(heading + if (isQuestion) context.getString(R.string.session_choose_or_enter_an_answer_then_submit_selecting_an_option_does_n) else context.getString(R.string.session_scroll_to_the_bottom_and_review_the_full_request_before_deciding), 13f, Palette.muted)
        val body = column().apply {
            addView(message, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(8) })
            addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        val actions = column()
        val dialog = canvasDialog(approval.optString("title"), body, actions); approvalDialog = dialog
        val allowLabel = if (isQuestion) context.getString(R.string.session_submit_answer) else approval.optString("allowLabel", context.getString(R.string.session_allow_once)); val denyLabel = approval.optString("denyLabel", context.getString(R.string.session_deny))
        val optionsArray = approval.optJSONArray("options")
        val optionLabels = (0 until (optionsArray?.length() ?: 0)).map { optionsArray!!.getString(it) }
        val allow = button(allowLabel, true) {}; val deny = button(denyLabel) {}
        val check = button(context.getString(R.string.session_check_result)) {}
        val optionButtons = optionLabels.map { label -> label to button(label) {} }
        if (optionLabels.isNotEmpty()) {
            optionButtons.forEach { (_, button) -> actions.addView(button, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) }) }
            actions.addView(check, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
        } else if (isQuestion) {
            actions.addView(allow, LinearLayout.LayoutParams(-1, -2))
            actions.addView(check, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
        } else if (approval.optBoolean("canDecide")) actions.addView(row().apply {
            addView(deny, LinearLayout.LayoutParams(0, -2, 1f))
            addView(allow, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = dp(8) })
        })
        actions.addView(button(context.getString(R.string.close)) { dialog.dismiss() }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
        var retryOriginal = false
        fun uncertain() = if (reviews) null else client.uncertain(target).firstOrNull { it.optString("op") == "approve" && it.optString("fingerprint") == fingerprint }
        fun current() = actionScope == renderingScope() && foreground && !drawer && token == generation &&
            target == thread && approvalDialog === dialog && dialog.isShowing
        fun update() {
            val unknown = uncertain() != null
            val canPick = actionScope == renderingScope() && foreground && !drawer && mutableReady && supports("approvals") &&
                (isQuestion || !content.canScrollVertically(1)) && submittingApproval.isEmpty() && fingerprint !in approvedHere && !unknown
            if (isQuestion) {
                val filled = (0 until questions.length()).count { answers[questions.getJSONObject(it).getString("id")]?.isNotBlank() == true }
                val complete = if (approval.optString("method") == "item/tool/requestUserInput") filled == questions.length() else filled > 0
                allow.isEnabled = canPick && complete; allow.alpha = if (allow.isEnabled) 1f else .4f
                inputs.forEach { it.isEnabled = mutableReady && !unknown && submittingApproval.isEmpty() }
                check.visibility = if (unknown) VISIBLE else GONE
                check.isEnabled = mutableReady && submittingApproval.isEmpty()
                check.text = if (retryOriginal) context.getString(R.string.session_retry_original_answer) else context.getString(R.string.session_check_result)
            } else if (optionLabels.isNotEmpty()) {
                optionButtons.forEach { (_, button) -> button.isEnabled = canPick; button.alpha = if (canPick) 1f else .4f }
                check.visibility = if (unknown) VISIBLE else GONE
                check.isEnabled = mutableReady && supports("approvals") && submittingApproval.isEmpty() && fingerprint !in approvedHere
                check.text = if (retryOriginal) context.getString(R.string.session_retry_original_choice) else context.getString(R.string.session_check_result)
                check.alpha = if (check.isEnabled) 1f else .4f
            } else {
                allow.isEnabled = canPick
                deny.text = if (unknown) (if (retryOriginal) context.getString(R.string.session_retry_original_choice) else context.getString(R.string.session_check_result)) else denyLabel
                deny.isEnabled = mutableReady && supports("approvals") && submittingApproval.isEmpty() && fingerprint !in approvedHere
                allow.alpha = if (allow.isEnabled) 1f else .4f
                deny.alpha = if (deny.isEnabled) 1f else .4f
            }
        }
        fun accepted(result: JSONObject) {
            if (actionScope != renderingScope() || token != generation || target != thread) return
            if (submittingApproval == fingerprint) submittingApproval = ""
            if (result.optBoolean("ok") && result.optBoolean("submitted")) {
                approvedHere.add(fingerprint); questionDrafts.remove(fingerprint)
                notice.text = if (isQuestion) context.getString(R.string.session_answer_submitted) else context.getString(R.string.session_decision_submitted_waiting_for_desktop_confirmation)
                if (current()) dialog.dismiss()
                if (reviews) applyPage(JSONObject(page.toString()).put("approvals", JSONArray()))
            } else if (current()) {
                message.text = heading + result.optString("error", context.getString(R.string.session_result_not_yet_confirmed)) + if (uncertain() != null) context.getString(R.string.session_ncheck_the_result_before_submitting_again) else ""
                update()
            }
            updateComposer()
        }
        fun checkOrRetry(describe: (JSONObject) -> String) {
            if (!current()) return
            val original = uncertain() ?: return
            if (retryOriginal) {
                submittingApproval = fingerprint; update(); message.text = heading + context.getString(R.string.session_retrying_the_original_choice) + describe(original)
                client.retryPending(original.getString("id"), ::accepted)
            } else {
                message.text = heading + context.getString(R.string.session_checking_the_original_submission_receipt)
                client.request("receipt", JSONObject().put("operation", original.getString("id"))) { result ->
                    if (!current()) return@request
                    when (result.optString("state")) {
                        "complete" -> { client.clearReceipt(original.getString("id")); accepted(result.optJSONObject("receipt") ?: JSONObject()) }
                        "notFound" -> { retryOriginal = true; message.text = heading + context.getString(R.string.session_the_mac_has_not_recorded_this_decision_you_can_retry_the_origina) }
                        else -> message.text = heading + context.getString(R.string.session_the_result_is_still_unknown_check_on_the_mac_submission_is_tempo)
                    }
                    update()
                }
            }
        }
        if (isQuestion) {
            allow.setOnClickListener {
                if (!current() || !allow.isEnabled || submittingApproval.isNotEmpty() || uncertain() != null) return@setOnClickListener
                val payload = JSONObject()
                answers.filterValues { it.isNotBlank() }.forEach { (id, answer) -> payload.put(id, answer.trim()) }
                submittingApproval = fingerprint; message.text = heading + context.getString(R.string.session_submitting_answer); hideKeyboard(); update()
                call("approve", JSONObject().put("threadId", target).put("fingerprint", fingerprint).put("expectedApprovalRevision", approval.opt("revision")).put("answers", payload), ::accepted)
            }
            check.setOnClickListener { checkOrRetry { context.getString(R.string.session_saved_answer) } }
        } else if (optionLabels.isNotEmpty()) {
            optionButtons.forEach { (label, button) ->
                button.setOnClickListener {
                    if (!current() || submittingApproval.isNotEmpty() || !mutableReady || !supports("approvals") || fingerprint in approvedHere || uncertain() != null) return@setOnClickListener
                    submittingApproval = fingerprint; message.text = heading + context.getString(R.string.session_submitting_choice, label); update()
                    call("approve", JSONObject().put("threadId", target).put("fingerprint", fingerprint).put("expectedApprovalRevision", approval.opt("revision")).put("option", label), ::accepted)
                }
            }
            check.setOnClickListener { checkOrRetry { it.optString("option") } }
        } else {
            fun submit(accepted: Boolean) {
                if (!current() || submittingApproval.isNotEmpty() || !mutableReady || !supports("approvals") || fingerprint in approvedHere || uncertain() != null) return
                submittingApproval = fingerprint; message.text = heading + context.getString(R.string.session_submitting_decision); update()
                call("approve", JSONObject().put("threadId", target).put("fingerprint", fingerprint).put("expectedApprovalRevision", approval.opt("revision")).put("allow", accepted), ::accepted)
            }
            allow.setOnClickListener { submit(true) }
            deny.setOnClickListener {
                if (uncertain() == null) submit(false) else checkOrRetry { if (it.optBoolean("allow")) allowLabel else denyLabel }
            }
        }
        onAnswersChanged = { update() }
        content.setOnScrollChangeListener { _, _, _, _, _ -> update() }; content.post { update() }
        dialog.setOnDismissListener { auxiliaryDialogs.remove(dialog); if (approvalDialog === dialog) { approvalDialog = null; openApproval = ""; openApprovalId = "" } }
    }
    private fun selection() = page.optJSONObject("composer") ?: JSONObject()
    private fun hint() = if (zcode) {
        if (page.optBoolean("canSend") && supports("send")) context.getString(R.string.session_replies_go_to_this_zcode_session)
        else page.optString("sendDisabledReason").ifBlank { page.optString("readOnlyReason").ifBlank { context.getString(R.string.session_viewing_zcode_session_phone_replies_are_currently_unavailable) } }
    } else if (!claude) context.getString(R.string.session_replies_go_only_to_this_session_permission_requests_need_separat) else when (page.optString("owner")) {
        "desktop" -> context.getString(R.string.session_replies_go_to_this_session_in_the_claude_desktop_app)
        "terminal" -> context.getString(R.string.session_this_session_is_running_in_a_mac_terminal_continue_on_the_mac)
        else -> context.getString(R.string.session_replies_continue_this_session_in_the_background_on_the_mac)
    }
    private fun modeName(mode: String) = if (zcode) selection().optString("modeLabel").ifBlank { when (mode) { "plan" -> context.getString(R.string.session_plan); "build" -> context.getString(R.string.session_ask_before_changes); "edit" -> context.getString(R.string.session_accept_edits); "yolo" -> context.getString(R.string.session_full_access); else -> mode.ifBlank { context.getString(R.string.session_permission_mode) } } } else if (claude) when (mode) { "default" -> context.getString(R.string.session_ask_before_changes); "acceptEdits" -> context.getString(R.string.session_accept_edits); "auto" -> context.getString(R.string.session_auto); "plan" -> context.getString(R.string.session_plan); "bypassPermissions" -> context.getString(R.string.session_skip_approvals); else -> context.getString(R.string.session_default_permissions) } else when (mode) { "auto" -> context.getString(R.string.session_ask_to_approve); "guardian-approvals" -> context.getString(R.string.session_approve_for_me); "full-access" -> context.getString(R.string.session_full_access); else -> context.getString(R.string.session_desktop_custom_settings) }
    private fun effortName(value: String) = when (value) { "default" -> context.getString(R.string.session_default); "low" -> context.getString(R.string.session_low); "medium" -> context.getString(R.string.session_medium); "high" -> context.getString(R.string.session_high); "xhigh" -> context.getString(R.string.session_extra_high); "max" -> context.getString(R.string.session_maximum); "ultra" -> context.getString(R.string.session_ultra); else -> value }
    private fun entries() = if (reviews) reviewAttachments else client.attachments(thread)
    private fun addAttachment(item: JSONObject) { if (entries().length() >= 6) { notice.text = context.getString(R.string.session_add_up_to_6_attachments); return }; val items = entries(); items.put(item); if (reviews) reviewAttachments = items else if (!client.saveAttachments(thread, items)) notice.text = context.getString(R.string.session_could_not_save_attachments_check_phone_storage_and_retry) }
    private fun attachmentIDs(): JSONArray { val result = JSONArray(); val entries = entries(); for (i in 0 until entries.length()) result.put(entries.getJSONObject(i).optString("attachmentId")); return result }
    private fun menu(heading: String, description: String, actions: List<Pair<String, () -> Unit>>) {
        val token = generation; val target = thread
        hideKeyboard(); val body = column().apply {
            if (description.isNotBlank()) addView(label(description, 13f, Palette.muted), LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(12) })
        }
        val footer = row(); val dialog = canvasDialog(heading, ScrollView(context).apply { addView(body) }, footer, compact = true)
        actions.forEach { (name, action) -> body.addView(button(name) { dialog.dismiss(); if (token == generation && target == thread) action() }, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(8) }) }
        footer.addView(button(context.getString(R.string.close)) { dialog.dismiss() }, LinearLayout.LayoutParams(-1, -2))
    }
    private fun showAddMenu() {
        if (!mutableReady || !supports("attachments") || uploading || sending) return
        if (entries().length() >= 6) { notice.text = context.getString(R.string.session_limit_of_6_attachments_reached_remove_one_first); return }
        menu(context.getString(R.string.session_add_attachments_and_context), context.getString(R.string.session_up_to_6_attachments_10_mb_each_they_are_submitted_to_this_sessio), listOf(
            context.getString(R.string.session_add_image_phone_gallery) to { (activity as? MainActivity)?.pickCodexAttachment(true) },
            context.getString(R.string.session_add_file_phone_files) to { (activity as? MainActivity)?.pickCodexAttachment(false) },
            context.getString(R.string.session_mac_files_and_folders) to { showMacFiles("") },
            context.getString(R.string.session_mac_app_screenshot) to { showAppshots() }
        ))
    }
    fun addPhoneAttachment(uri: android.net.Uri) {
        creationAttachment?.let { it(uri); return }
        if (drawer || !mutableReady || !supports("attachments") || uploading) return
        val token = generation; val target = thread; val provider = client.provider; val authorization = authorizationSource()
        val upload = ++uploadGeneration; uploading = true; uploadLabel = context.getString(R.string.session_reading_attachment); updateComposer()
        CodexFileUpload.prepare(context, uri) { file, name, mime, error ->
            releasePickerPermission(uri)
            if (token != generation || upload != uploadGeneration || authorization != authorizationSource() || provider != client.provider) { file?.delete(); return@prepare }
            if (file == null) { uploading = false; uploadLabel = ""; notice.text = error ?: context.getString(R.string.attachment_unreadable); updateComposer(); return@prepare }
            CodexFileUpload.upload(resources, client, target, file, name, mime, { progress ->
                if (token == generation && upload == uploadGeneration) { uploadLabel = context.getString(R.string.session_upload_progress, progress.optString("name"), progress.optInt("progress")); uploadProgressLabel?.text = uploadLabel }
            }, cancelled = { token != generation || upload != uploadGeneration || authorization != authorizationSource() || provider != client.provider }) { result ->
                if (token != generation || upload != uploadGeneration || authorization != authorizationSource() || provider != client.provider) {
                    file.delete()
                    if (authorization == authorizationSource()) client.request("attachmentRemove", JSONObject().put("threadId", target).put("attachmentId", result.optString("attachmentId")).put("provider", provider)) {}
                    return@upload
                }
                uploading = false; uploadLabel = ""
                if (result.optBoolean("ok")) { val items = client.attachments(target, provider); items.put(result); client.saveAttachments(target, items, provider); notice.text = context.getString(R.string.session_attachment_ready_tap_send_to_submit_it) }
                else { file.delete(); notice.text = result.optString("error"); client.request("attachmentRemove", JSONObject().put("threadId", target).put("attachmentId", result.optString("attachmentId")).put("provider", provider)) {} }
                updateComposer()
            }
        }
    }
    private fun showMacFiles(folder: String) {
        val token = generation
        call("browseFiles", JSONObject().put("threadId", thread).put("folder", folder)) { result ->
            if (token != generation) return@call
            if (!result.optBoolean("ok")) { notice.text = result.optString("error"); return@call }
            val actions = mutableListOf<Pair<String, () -> Unit>>()
            if (folder.isNotEmpty()) actions.add(context.getString(R.string.session_parent_folder) to { showMacFiles(folder.substringBeforeLast('/', "")) })
            val files = result.optJSONArray("entries") ?: JSONArray()
            for (i in 0 until files.length()) { val file = files.getJSONObject(i); actions.add((if (file.optBoolean("directory")) "▸ " else "") + file.optString("name") to {
                if (file.optBoolean("directory")) showMacFiles(file.optString("path"))
                else if (MarkdownFileLinks.isMarkdown(file.optString("name")) && supports("markdownFiles", false)) menu(file.optString("name"), context.getString(R.string.session_preview_the_document_or_attach_it_to_this_reply), listOf(
                    context.getString(R.string.session_view_document) to { showMarkdownFile(MarkdownFileLinks.Link(file.optString("name"), file.optString("path"))) },
                    context.getString(R.string.session_add_attachment) to { addMacFile(file.optString("path")) }))
                else addMacFile(file.optString("path"))
            }) }
            menu(context.getString(R.string.session_mac_files), if (files.length() == 0) context.getString(R.string.session_no_attachable_files_in_this_folder) else context.getString(R.string.session_project_folder, folder) + if (result.optBoolean("truncated")) context.getString(R.string.session_nshowing_the_first_200_entries) else "", actions)
        }
    }
    private val projectFiles get() = supports("projectFiles", false)

    private fun fileHost(): ProjectFileHost {
        val token = generation; val target = thread
        return ProjectFileHost(context, target, client.provider, { op, fields, done -> call(op, fields, done) },
            isCurrent = { token == generation && target == thread && !drawer && foreground },
            canQuote = { editor.isEnabled }, quote = ::quoteFile,
            canAttach = { mutableReady && supports("attachments") && !uploading && !sending && entries().length() < 6 }, attach = { path -> closeFileViews(); addMacFile(path) }, binaryHost = { client.binaryHost }, allowLegacyMedia = reviews)
    }

    private fun showProjectFiles(mode: String = "all") {
        if (drawer || !connected || !authorized) { menu(context.getString(R.string.files_project_files), context.getString(R.string.files_connect_to_the_mac_and_open_a_session_to_browse_project_files), emptyList()); return }
        if (!projectFiles) { menu(context.getString(R.string.files_project_files), context.getString(R.string.files_update_vibepier_on_the_mac_to_browse_project_files), listOf(context.getString(R.string.files_view_markdown_files) to { showMarkdownFiles("") })); return }
        if (filesPage != null) return
        hideKeyboard()
        filesPage = ProjectFilesPage(fileHost(), turnChanges, mode, onChanges = { result -> applyTurnChanges(result) }) { filesPage = null }.also {
            it.show(); auxiliaryDialogs.add(it.dialog)
        }
    }

    /** A file named in a message: Markdown keeps its own reader, which also follows the session's references outside the project. */
    private fun openFileLink(link: MarkdownFileLinks.Link) {
        if (MarkdownFileLinks.isMarkdown(link.path)) { showMarkdownFile(link); return }
        openProjectFile(link.path, link.line)
    }

    private fun openProjectFile(path: String, line: Int? = null, status: String = "", diff: Boolean = false) {
        if (drawer || !ready || !connected || !authorized) { notice.text = context.getString(R.string.files_connect_to_the_mac_and_open_a_session_to_view_files); return }
        if (!projectFiles) { notice.text = context.getString(R.string.files_update_vibepier_on_the_mac_to_view_this_file); return }
        if (ProjectFiles.isVideo(path) && !supports("videoFiles", false)) {
            notice.text = context.getString(R.string.video_update_mac); return
        }
        hideKeyboard(); fileViewer?.dismiss()
        fileViewer = ProjectFileViewer(fileHost(), path, line, status, diff) { fileViewer = null }.also { it.show(); auxiliaryDialogs.add(it.dialog) }
    }

    private fun closeFileViews() { fileViewer?.dismiss(); filesPage?.dismiss() }

    /** Puts `path:line` into the reply at the cursor, then returns to the conversation. */
    private fun quoteFile(path: String, line: Int?) {
        closeFileViews()
        if (!editor.isEnabled) { notice.text = context.getString(R.string.files_this_session_cannot_be_replied_to_from_the_phone); return }
        val (text, cursor) = ProjectFiles.quote(editor.text.toString(), editor.selectionEnd.coerceAtLeast(0), path, line)
        editor.setText(text); editor.setSelection(cursor.coerceAtMost(editor.text.length)); editor.requestFocus()
        (context.getSystemService(Activity.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(editor, 0)
        notice.text = context.getString(R.string.files_quoted_1 ,path.substringAfterLast('/'))
    }

    /** Asks for the newest turn's changed files once per reply, never while the drawer or a cached page shows. */
    private fun refreshTurnChanges() {
        if (drawer || renderingCache || !ready || !connected || !projectFiles) { updateFilesBadge(); return }
        val messages = page.optJSONArray("messages") ?: JSONArray()
        val last = if (messages.length() > 0) messages.getJSONObject(messages.length() - 1) else null
        val key = "${last?.optString("id")}|${page.optString("status")}|${last?.optString("status")}"
        if (key == changesKey) return
        changesKey = key
        val token = generation; val target = thread
        call("fileChanges", JSONObject().put("threadId", target)) { result ->
            if (token != generation || target != thread || drawer || !result.optBoolean("ok")) return@call
            applyTurnChanges(result)
        }
    }

    private fun applyTurnChanges(result: JSONObject) {
        turnChanges = result; updateFilesBadge(); renderChangesCard()
    }

    private fun updateFilesBadge() {
        if (!::filesBadge.isInitialized) return
        filesButton?.visibility = if (projectFiles || !ready) VISIBLE else GONE
        val count = turnChanges?.optJSONArray("files")?.length() ?: 0
        filesBadge.visibility = if (count > 0) VISIBLE else GONE
        filesBadge.text = if (count > 99) "99+" else count.toString()
        filesButton?.contentDescription = if (count > 0) context.resources.getQuantityString(R.plurals.files_project_files_1_files_changed_in_this_turn, count, count) else context.getString(R.string.files_project_files)
    }

    /** Under the newest reply once it finished: each file it changed, opening straight into its diff. */
    private fun renderChangesCard() {
        val holder = changesHolder ?: return
        holder.removeAllViews()
        val files = turnChanges?.optJSONArray("files") ?: return
        val messages = page.optJSONArray("messages") ?: JSONArray()
        val last = if (messages.length() > 0) messages.getJSONObject(messages.length() - 1) else null
        if (files.length() == 0 || page.optString("status") == "active" || last?.optString("role") == "user") return
        var plus = 0; var minus = 0
        for (i in 0 until files.length()) { plus += files.getJSONObject(i).optInt("added"); minus += files.getJSONObject(i).optInt("removed") }
        holder.addView(column().apply {
            background = background(Palette.surface1, 14)
            addView(row().apply {
                setPadding(dp(12), dp(10), dp(12), dp(8)); isFocusable = true
                contentDescription = context.resources.getQuantityString(R.plurals.files_1_files_changed_in_this_turn_open_project_files, files.length(), files.length())
                setOnClickListener { showProjectFiles("changes") }
                addView(label(context.resources.getQuantityString(R.plurals.files_1_files_changed_in_this_turn, files.length(), files.length()), Ui.LABEL).apply { typeface = Typeface.DEFAULT_BOLD }, LinearLayout.LayoutParams(0, -2, 1f))
                addView(label("+$plus", Ui.CAPTION, Palette.accent).apply { typeface = Typeface.MONOSPACE }, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(4) })
                addView(label("−$minus", Ui.CAPTION, Palette.red).apply { typeface = Typeface.MONOSPACE })
            })
            for (i in 0 until minOf(files.length(), 6)) {
                val file = files.getJSONObject(i); val path = file.optString("path")
                val status = file.optString("status").ifEmpty { if (file.optString("kind") == "add") "A" else "M" }
                addView(Ui.divider(context), LinearLayout.LayoutParams(-1, maxOf(1, dp(1) / 2)))
                addView(row().apply {
                    minimumHeight = dp(44); setPadding(dp(12), 0, dp(12), 0); isFocusable = true
                    contentDescription = context.getString(R.string.files_view_changes_to_1 ,path)
                    setOnClickListener { openProjectFile(path, status = status, diff = true) }
                    addView(label(status, Ui.CAPTION, if (status == "A") Palette.accent else if (status == "D") Palette.red else Palette.amber).apply {
                        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
                    }, LinearLayout.LayoutParams(dp(18), -2))
                    addView(label(path, Ui.CAPTION, Palette.text).apply { typeface = Typeface.MONOSPACE; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.START },
                        LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(8) })
                    addView(label("+${file.optInt("added")}", Ui.CAPTION, Palette.accent).apply { typeface = Typeface.MONOSPACE })
                })
            }
            if (files.length() > 6) addView(Ui.button(context, context.resources.getQuantityString(R.plurals.files_view_all_1_files, files.length(), files.length()), Ui.Button.TEXT) { showProjectFiles("changes") })
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(2); bottomMargin = dp(14) })
    }

    private fun showMarkdownFiles(folder: String) {
        if (drawer || !ready || !connected || !authorized) { menu(context.getString(R.string.session_view_markdown_files_2), context.getString(R.string.session_connect_to_the_mac_and_open_a_session_to_read_its_project_docume), emptyList()); return }
        if (!supports("markdownFiles", false)) { menu(context.getString(R.string.session_view_markdown_files_2), context.getString(R.string.session_update_vibepier_on_the_mac_to_read_documents), emptyList()); return }
        val token = generation; val target = thread; val source = client.provider
        notice.text = context.getString(R.string.session_reading_document_directory)
        call("browseFiles", JSONObject().put("threadId", target).put("folder", folder).put("provider", source)) { result ->
            if (token != generation || target != thread || source != client.provider || drawer) return@call
            if (!result.optBoolean("ok")) { menu(context.getString(R.string.session_document_directory), result.optString("error", context.getString(R.string.session_could_not_read_the_directory)), listOf(context.getString(R.string.retry) to { showMarkdownFiles(folder) })); return@call }
            notice.text = ""
            val actualFolder = result.optString("folder", folder)
            val actions = mutableListOf<Pair<String, () -> Unit>>()
            if (actualFolder.isNotEmpty()) actions.add(context.getString(R.string.session_parent_folder) to { showMarkdownFiles(actualFolder.substringBeforeLast('/', "")) })
            val files = result.optJSONArray("entries") ?: JSONArray(); var count = 0
            for (index in 0 until files.length()) {
                val file = files.getJSONObject(index); val directory = file.optBoolean("directory")
                if (!directory && !MarkdownFileLinks.isMarkdown(file.optString("name"))) continue
                count++
                actions.add((if (directory) "▸ " else "") + file.optString("name") to {
                    if (directory) showMarkdownFiles(file.optString("path"))
                    else showMarkdownFile(MarkdownFileLinks.Link(file.optString("name"), file.optString("path")))
                })
            }
            menu(context.getString(R.string.session_view_markdown_files_2), context.getString(R.string.session_project_folder, actualFolder) + (if (count == 0) context.getString(R.string.session_nno_markdown_files_or_subfolders_here) else "") +
                (if (result.optBoolean("truncated")) context.getString(R.string.session_nshowing_the_first_200_entries_open_a_subfolder_to_continue) else ""), actions)
        }
    }
    private fun showMarkdownFile(link: MarkdownFileLinks.Link) {
        if (drawer || !ready || !connected || !authorized) { menu(context.getString(R.string.session_view_markdown_files_2), context.getString(R.string.session_connect_to_the_mac_and_open_a_session_to_read_documents), emptyList()); return }
        if (!supports("markdownFiles", false)) { menu(context.getString(R.string.session_view_markdown_files_2), context.getString(R.string.session_update_vibepier_on_the_mac_to_read_documents), emptyList()); return }
        hideKeyboard(); closeMarkdownViewer()
        val token = generation; val target = thread; val provider = client.provider; val viewVersion = client.viewVersion
        lateinit var viewer: MarkdownFileViewer
        viewer = MarkdownFileViewer(context, target, link.path, provider, { op, fields, done -> call(op, fields.put("viewVersion", viewVersion), done) },
            isCurrent = { foreground && !drawer && token == generation && target == thread && provider == client.provider },
            onClose = { if (!reviews) client.cancelMarkdownReads(target, provider); if (markdownViewer === viewer) markdownViewer = null })
        markdownViewer = viewer; viewer.show()
    }
    private fun addMacFile(path: String) {
        val token = generation
        call("attachmentReference", JSONObject().put("threadId", thread).put("path", path).put("attachmentId", java.util.UUID.randomUUID().toString())) { result ->
            if (token != generation) return@call
            if (result.optBoolean("ok")) { addAttachment(result); notice.text = context.getString(R.string.session_mac_file_added) }
            else notice.text = result.optString("error")
            updateComposer()
        }
    }
    private fun showAppshots() {
        val token = generation
        call("appshotApps", JSONObject().put("threadId", thread)) { result ->
            if (token != generation) return@call
            if (!result.optBoolean("ok")) { notice.text = result.optString("error"); return@call }
            val apps = result.optJSONArray("apps") ?: JSONArray()
            val actions = (0 until apps.length()).map { apps.getJSONObject(it) }.map { app -> app.optString("name") to {
                val upload = ++uploadGeneration; val target = thread
                uploading = true; uploadLabel = context.getString(R.string.session_capturing_app, app.optString("name")); updateComposer()
                call("appshot", JSONObject().put("threadId", thread).put("bundleID", app.optString("id")).put("attachmentId", java.util.UUID.randomUUID().toString())) { reply ->
                    if (token != generation || upload != uploadGeneration) { client.request("attachmentRemove", JSONObject().put("threadId", target).put("attachmentId", reply.optString("attachmentId"))) {}; return@call }
                    uploading = false; uploadLabel = ""
                    if (reply.optBoolean("ok")) { addAttachment(reply); notice.text = context.getString(R.string.session_app_screenshot_added) }
                    else notice.text = reply.optString("error")
                    updateComposer()
                }
            } }
            menu(context.getString(R.string.session_choose_a_mac_app), context.getString(R.string.session_capture_only_a_visible_window_of_the_selected_app_first_allow_sc), actions)
        }
    }
    // Sessions open in the Claude desktop app keep the desktop's permission mode; the phone only shows it.
    private fun lockedNotice(key: String): Boolean {
        val reason = selection().optString("lockedReason")
        if (!selection().optBoolean(key)) return false
        menu(context.getString(R.string.session_change_in_the_mac_desktop_app), reason.ifBlank { context.getString(R.string.session_settings_on_mac, agent) }, emptyList()); return true
    }
    private fun settingsAvailable(capability: String): Boolean {
        if (mutableReady && supports("settings") && supports(capability)) return true
        val reason = if (!connected) context.getString(R.string.session_wait_disconnected)
            else if (!ready) context.getString(R.string.session_wait_loading)
            else page.optString("readOnlyReason").ifBlank { context.getString(R.string.agent_capability_unavailable) }
        menu(context.getString(R.string.session_session_settings), reason, emptyList())
        return false
    }
    private val composerOptionCatalogs = mutableMapOf<String, JSONObject>()
    private fun requestComposerOptions(fields: JSONObject, callback: (JSONObject) -> Unit) {
        val token = generation
        val catalogKey = "${authorizationSource()}|${client.provider}|${client.selectedAgentAdapter()?.id}|$thread"
        if (fields.opt("refreshOptions") != true) composerOptionCatalogs[catalogKey]?.let { cached ->
            val current = JSONObject(cached.toString()).put("composer", JSONObject(selection().toString()))
            for (key in listOf("executionModes", "executionModePermissionCoupled")) if (page.has(key)) current.put(key, page.get(key))
            callback(current); return
        }
        hideKeyboard()
        val loading = canvasDialog(context.getString(R.string.session_session_settings),
            label(context.getString(R.string.session_loading), 14f), row(), compact = true)
        call("composerOptions", fields) { result ->
            loading.dismiss()
            if (token != generation) return@call
            if (!result.optBoolean("ok")) {
                menu(context.getString(R.string.session_session_settings), result.optString("error").ifBlank {
                    context.getString(R.string.agent_state_not_ready)
                }, emptyList())
                return@call
            }
            if (composerOptionCatalogs.size >= 16) composerOptionCatalogs.clear()
            composerOptionCatalogs[catalogKey] = JSONObject().put("ok", true).apply {
                for (key in listOf("models", "modes", "permissionModes", "efforts", "executionModes", "executionModePermissionCoupled", "description")) if (result.has(key)) put(key, result.get(key))
            }
            callback(result)
        }
    }
    private fun refreshComposerOptions() {
        requestComposerOptions(JSONObject().put("threadId", thread).put("refreshOptions", true)) { result ->
            result.optJSONObject("composer")?.let { page.put("composer", it) }
            for (key in listOf("executionModes", "executionModePermissionCoupled")) if (result.has(key)) page.put(key, result.get(key))
            updateComposer()
        }
    }
    private fun executionName(id: String) = context.getString(when (id) {
        "plan" -> R.string.session_execution_plan
        "default" -> R.string.session_execution_run
        else -> R.string.session_choose_execution_mode
    })
    private fun showExecutionModeMenu() {
        if (!settingsAvailable("executionMode")) return
        requestComposerOptions(JSONObject().put("threadId", thread)) { result ->
            result.optJSONObject("composer")?.let { page.put("composer", it) }
            for (key in listOf("executionModes", "executionModePermissionCoupled")) if (result.has(key)) page.put(key, result.get(key))
            updateComposer()
            if (lockedNotice("executionModeLocked")) return@requestComposerOptions
            val choices = SessionExecutionModes.decode(result)
            val actions = choices.map { choice ->
                (if (selection().optString("executionMode") == choice.id) "✓ " else "") + executionName(choice.id) to {
                    applySettings(JSONObject().put("executionMode", choice.id))
                }
            }
            val permission = SessionExecutionModes.defaultPermissionLabel(result, choices)
            val description = if (permission != null) context.getString(R.string.session_execution_coupled_description, permission)
                else context.getString(if (choices.isEmpty()) R.string.session_execution_unavailable else R.string.session_execution_description)
            menu(context.getString(R.string.session_execution_mode), description, actions + (context.getString(R.string.creation_refresh_options) to { refreshComposerOptions() }))
        }
    }
    private fun showModeMenu() {
        if (!settingsAvailable("permissionMode")) return
        requestComposerOptions(JSONObject().put("threadId", thread)) { result ->
            result.optJSONObject("composer")?.let { page.put("composer", it) }
            for (key in listOf("executionModes", "executionModePermissionCoupled")) if (result.has(key)) page.put(key, result.get(key))
            updateComposer()
            if (SessionExecutionModes.coupled(page) && selection().optString("executionMode") == "plan" || lockedNotice("modeLocked")) return@requestComposerOptions
            showPermissionChoices(result)
        }
    }
    private fun showPermissionChoices(result: JSONObject) {
        val current = selection().optString("mode")
        if (zcode) {
                val modes = result.optJSONArray("permissionModes") ?: result.optJSONArray("modes") ?: JSONArray()
                val options = (0 until modes.length()).map { index ->
                    val value = modes.optJSONObject(index)
                    val id = value?.optString("id") ?: modes.optString(index)
                    val name = value?.let { option -> option.optString("name").ifBlank { option.optString("label").ifBlank { option.optString("title").ifBlank { id } } } } ?: id
                    (if (current == id) "✓ " else "") + name to {
                        if (value?.optBoolean("requiresConfirmation") == true) {
                            menu(context.getString(R.string.session_change_permission_mode), value.optString("confirmationText").ifBlank { context.getString(R.string.session_confirm_mode_change, title, name) }, listOf(
                                context.getString(R.string.session_confirm_change) to { applySettings(JSONObject().put("mode", id).put("confirmFullAccess", true)) }
                            ))
                        } else applySettings(JSONObject().put("mode", id))
                    }
                }
                menu(context.getString(R.string.session_permission_mode), result.optString("description", context.getString(R.string.session_use_the_permission_modes_available_for_this_zcode_session)), options + (context.getString(R.string.creation_refresh_options) to { refreshComposerOptions() }))
            return
        }
        if (claude) {
            fun option(mode: String, text: String) = (if (current == mode) "✓ " else "") + text to { applySettings(JSONObject().put("mode", mode)) }
            menu(context.getString(R.string.session_permission_mode), if (page.optString("owner") == "desktop") context.getString(R.string.session_sync_the_permission_mode_for_this_claude_desktop_session) else context.getString(R.string.session_used_for_subsequent_requests_from_the_phone_in_this_claude_code_), listOf(
                option("default", context.getString(R.string.session_ask_confirm_before_changes)),
                option("acceptEdits", context.getString(R.string.session_accept_edits_accept_file_changes_automatically)),
                option("auto", context.getString(R.string.session_auto_claude_code_evaluates_risk)),
                (if (current == "bypassPermissions") "✓ " else "") + context.getString(R.string.session_skip_approvals_do_not_ask_again) to {
                    if (current == "bypassPermissions") applySettings(JSONObject().put("mode", "bypassPermissions").put("confirmFullAccess", true))
                    else menu(context.getString(R.string.session_skip_all_permission_confirmations), context.getString(R.string.session_claude_full_access_warning, title), listOf(context.getString(R.string.session_enable_skip_approvals) to { applySettings(JSONObject().put("mode", "bypassPermissions").put("confirmFullAccess", true)) }))
                }
            ))
            return
        }
        menu(context.getString(R.string.approval_mode), context.getString(R.string.session_sync_permission_settings_for_this_codex_session), listOf(
            (if (current == "auto") "✓ " else "") + context.getString(R.string.session_ask_to_approve_you_confirm_when_needed) to { applySettings(JSONObject().put("mode", "auto")) },
            (if (current == "guardian-approvals") "✓ " else "") + context.getString(R.string.session_approve_for_me_use_the_codex_approval_agent) to { applySettings(JSONObject().put("mode", "guardian-approvals")) },
            (if (current == "full-access") "✓ " else "") + context.getString(R.string.session_full_access_no_sandbox_restrictions) to {
                if (current == "full-access") applySettings(JSONObject().put("mode", "full-access").put("confirmFullAccess", true))
                else menu(context.getString(R.string.session_enable_full_access), context.getString(R.string.session_codex_full_access_warning, title), listOf(context.getString(R.string.session_enable_full_access_2) to { applySettings(JSONObject().put("mode", "full-access").put("confirmFullAccess", true)) }))
            }
        ))
    }
    private fun showContextUsage() {
        if (!ready || !connected) return
        val token = generation
        notice.text = context.getString(R.string.session_reading_context_usage)
        call("contextUsage", JSONObject().put("threadId", thread)) { result ->
            if (token != generation) return@call
            if (!result.optBoolean("ok")) { notice.text = result.optString("error"); return@call }
            result.optJSONObject("composer")?.let { page.put("composer", it); updateComposer() }
            notice.text = ""
            val summary = result.optString("summary").removePrefix("Context ")
            val detail = result.optString("detail").removePrefix("Context window: ").replace("; ", "\n")
            menu(context.getString(R.string.session_session_context_usage), context.getString(R.string.session_context_summary, summary) + if (detail.isBlank()) "" else "\n\n$detail", emptyList())
        }
    }
    private fun showModelMenu() {
        if (!settingsAvailable("modelSelection")) return
        val token = generation
        val selectionVersion = JSONObject().apply { val current = selection(); for (key in listOf("model", "effort", "mode", "executionMode", "serviceTier")) put(key, current.optString(key)); put("owner", page.optString("owner")) }.toString()
        requestComposerOptions(JSONObject().put("threadId", thread).put("cacheVersion", selectionVersion)) { result ->
            if (token != generation) return@requestComposerOptions
            if (!result.optBoolean("ok")) { notice.text = result.optString("error"); return@requestComposerOptions }
            result.optJSONObject("composer")?.let { page.put("composer", it); updateComposer() }
            if (lockedNotice("locked")) return@requestComposerOptions
            models = result.optJSONArray("models") ?: JSONArray()
            val effortOptions = result.optJSONArray("efforts") ?: JSONArray()
            fun effortLabel(id: String): String = (0 until effortOptions.length()).mapNotNull { effortOptions.optJSONObject(it) }
                .firstOrNull { it.optString("id") == id }?.let { it.optString("label").ifBlank { it.optString("name") } }?.takeIf { it.isNotBlank() } ?: effortName(id)
            fun chooseSpeed(model: JSONObject, fields: JSONObject) {
                val tiers = model.optJSONArray("serviceTiers") ?: JSONArray()
                if (!selection().has("serviceTier")) { applySettings(fields); return }
                if ((0 until tiers.length()).none { tiers.optString(it) == "priority" }) {
                    applySettings(fields.put("serviceTier", "standard")); return
                }
                menu(context.getString(R.string.session_speed), context.getString(R.string.session_speed_description), listOf(
                    (if (selection().optString("serviceTier") == "standard") "✓ " else "") + context.getString(R.string.session_speed_standard) to { applySettings(JSONObject(fields.toString()).put("serviceTier", "standard")) },
                    (if (selection().optString("serviceTier") == "priority") "✓ " else "") + context.getString(R.string.session_speed_fast) to { applySettings(JSONObject(fields.toString()).put("serviceTier", "priority")) }
                ))
            }
            val actions = (0 until models.length()).map { models.getJSONObject(it) }.map { model ->
                (if (model.optString("id") == selection().optString("model")) "✓ " else "") + model.optString("name") to {
                    val efforts = model.optJSONArray("efforts") ?: JSONArray()
                    if (efforts.length() == 0) {
                        chooseSpeed(model, JSONObject().put("model", model.optString("id")))
                    } else if ((claude || zcode) && efforts.length() == 1) {
                        chooseSpeed(model, JSONObject().put("model", model.optString("id")).put("effort", efforts.getString(0)))
                    } else menu(context.getString(R.string.session_effort_for_model, model.optString("name")), if (claude && page.optString("owner") == "desktop") context.getString(R.string.session_sync_the_desktop_reasoning_effort_for_subsequent_requests_in_thi) else context.getString(R.string.session_choose_reasoning_effort_the_current_task_keeps_running_new_setti), (0 until efforts.length()).map { i ->
                        val effort = efforts.getString(i); (if (effort == selection().optString("effort")) "✓ " else "") + effortLabel(effort) to { chooseSpeed(model, JSONObject().put("model", model.optString("id")).put("effort", effort)) }
                    })
                }
            }
            val speedActions = if (selection().has("serviceTier")) {
                val currentModel = (0 until models.length()).map { models.getJSONObject(it) }.firstOrNull { it.optString("id") == selection().optString("model") }
                if (currentModel == null) emptyList() else listOf(
                    context.getString(R.string.session_speed) + " · " + context.getString(if (selection().optString("serviceTier") == "priority") R.string.session_speed_fast else R.string.session_speed_standard) to { chooseSpeed(currentModel, JSONObject()) }
                )
            } else emptyList()
            menu(context.getString(R.string.choose_model), if (claude || zcode) result.optString("description", context.getString(R.string.session_provider_models, agent)) else context.getString(R.string.session_use_the_models_currently_available_in_codex_on_the_mac), speedActions + actions + (context.getString(R.string.creation_refresh_options) to { refreshComposerOptions() }))
        }
    }
    private fun applySettings(fields: JSONObject) {
        if (!mutableReady || !supports("settings") || settingsOperation.isNotEmpty()) return
        val token = generation; val id = java.util.UUID.randomUUID().toString(); settingsOperation = id
        notice.text = context.getString(R.string.session_syncing_session_settings); updateComposer()
        call("settings", fields.put("threadId", thread).put("id", id)) { result ->
            if (token != generation || settingsOperation != id) return@call
            settingsOperation = ""
            result.optJSONObject("composer")?.let { page.put("composer", it) }
            notice.text = if (result.optBoolean("ok")) (if (result.optBoolean("queued")) context.getString(R.string.session_the_desktop_is_busy_the_change_takes_effect_after_the_current_ta) else context.getString(R.string.session_settings_synced_provider, agent)) else result.optString("error", context.getString(R.string.session_settings_result_not_yet_confirmed))
            if (reviews && result.optBoolean("ok")) { val value = selection(); listOf("model", "effort", "mode", "executionMode", "serviceTier").forEach { key -> if (fields.has(key)) value.put(key, fields.get(key)) }; page.put("composer", value) }
            updateComposer()
        }
    }
    private fun showAttachment(item: JSONObject) {
        if (item.optString("mime").startsWith("image/")) {
            val viewer = imageViewer(context.getString(R.string.session_named_image, item.optString("name")))
            val token = generation
            fun load() {
                viewer.loading()
                call("attachmentPreview", JSONObject().put("threadId", thread).put("attachmentId", item.optString("attachmentId"))) { result ->
                    if (token != generation || !viewer.isShowing) return@call
                    val bytes = try { android.util.Base64.decode(result.optString("image"), android.util.Base64.DEFAULT) } catch (_: Exception) { null }
                    val image = bytes?.let { android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size) }
                    if (image != null) viewer.display(image)
                    else viewer.failed(result.optString("error", context.getString(R.string.session_image_preview_unavailable)))
                }
            }
            viewer.retry = ::load; viewer.show(); load(); return
        }
        val body = column().apply {
            addView(label(item.optString("name"), 17f).apply { typeface = Typeface.DEFAULT_BOLD })
            addView(label(android.text.format.Formatter.formatShortFileSize(context, item.optLong("size")) + " · " + item.optString("mime"), 12f, Palette.muted), LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8); bottomMargin = dp(12) })
        }
        val footer = row(); val dialog = canvasDialog(context.getString(R.string.session_attachment_preview), ScrollView(context).apply { addView(body) }, footer, compact = true)
        footer.addView(button(context.getString(R.string.close)) { dialog.dismiss() }, LinearLayout.LayoutParams(-1, -2))
    }
    private fun renderAttachments() {
        val items = entries(); val signature = items.toString() + uploadLabel + sending + uploading + client.uncertain(thread).any { it.optString("op") == "send" }
        if (signature == attachmentRendering) return
        attachmentRendering = signature; uploadProgressLabel = null; val row = composerControls.attachments; row.removeAllViews()
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val chip = row().apply {
                background = background(Palette.surface, 10)
                addView(label(item.optString("name"), 12f).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(dp(8), 0, 0, 0); minimumHeight = dp(48); gravity = Gravity.CENTER_VERTICAL; contentDescription = context.getString(R.string.session_preview_attachment, item.optString("name")); setOnClickListener { showAttachment(item) } }, LinearLayout.LayoutParams(dp(125), -2))
                val canRemove = !sending && !uploading && !client.uncertain(thread).any { it.optString("op") == "send" }
                addView(button("×") {
                    if (sending || uploading || client.uncertain(thread).any { it.optString("op") == "send" }) return@button
                    val keep = JSONArray(); for (n in 0 until items.length()) if (n != i) keep.put(items.getJSONObject(n))
                    if (reviews) reviewAttachments = keep else client.saveAttachments(thread, keep)
                    if (supports("attachments")) client.request("attachmentRemove", JSONObject().put("threadId", thread).put("attachmentId", item.optString("attachmentId"))) {}
                    updateComposer()
                }.apply { contentDescription = context.getString(R.string.session_remove_attachment, item.optString("name")); isEnabled = canRemove; alpha = if (canRemove) 1f else .35f }, LinearLayout.LayoutParams(dp(48), dp(48)))
            }
            row.addView(chip, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(6) })
        }
        if (uploadLabel.isNotEmpty()) row.addView(row().apply {
            addView(label(uploadLabel.take(70), 12f, Palette.green).apply { uploadProgressLabel = this; maxLines = 2; setPadding(dp(8), dp(8), dp(8), dp(8)) }, LinearLayout.LayoutParams(dp(190), -2))
            addView(button(context.getString(R.string.cancel)) { uploadGeneration++; uploading = false; uploadLabel = ""; notice.text = context.getString(R.string.session_upload_cancelled); updateComposer() })
        })
        composerControls.attachmentScroll.visibility = if (row.childCount == 0) GONE else VISIBLE
    }
    private fun updateComposer() {
        if (drawer || !::sendButton.isInitialized) return
        val pendingOperations = if (reviews) emptyList() else client.uncertain(thread).filter { it.optString("op") in listOf("send", "interrupt", "settings", "queueSteer", "queueDelete") }
        val unresolved = pendingOperations.any { it.optString("op") != "send" || !client.waitingStopped(thread, it) } ||
            (!reviews && client.duplicateUnconfirmedSend(thread, editor.text.toString().trim(), attachmentIDs()))
        val selection = selection()
        composerControls.contextUsage.visibility = if (!zcode || selection.optString("contextUsage").isNotBlank()) VISIBLE else GONE
        composerControls.contextUsage.contentDescription = context.getString(R.string.context_usage_description) + selection.optString("contextUsage").let { if (it.isBlank()) "" else "：$it" }
        composerControls.contextUsage.isEnabled = ready && connected
        composerControls.mode.text = modeName(selection.optString("mode")) + " ▾"
        composerControls.mode.contentDescription = (if (claude || zcode) context.getString(R.string.session_permission_mode_2) else context.getString(R.string.session_approval_mode)) + "${modeName(selection.optString("mode"))}"
        val coupledPlan = SessionExecutionModes.coupled(page) && selection.optString("executionMode") == "plan"
        composerControls.mode.visibility = if (!coupledPlan && (supports("permissionMode") || selection.optString("mode").isNotBlank())) VISIBLE else GONE
        composerControls.execution.text = executionName(selection.optString("executionMode")) + " ▾"
        composerControls.execution.contentDescription = context.getString(R.string.session_execution_selection, executionName(selection.optString("executionMode")))
        composerControls.execution.visibility = if (supports("executionMode") || selection.optString("executionMode").isNotBlank()) VISIBLE else GONE
        val effort = selection.optString("effortLabel").ifBlank { effortName(selection.optString("effort")) }
        composerControls.model.text = selection.optString("modelLabel").ifBlank { selection.optString("model", context.getString(R.string.choose_model)).let { if (zcode && it.contains("/")) it.substringAfter("/").ifBlank { context.getString(R.string.choose_model) } else it } }.let { if (it == "default") context.getString(R.string.session_default_model) else it.replaceFirstChar { c -> c.uppercase() } }.replace("Gpt-", "GPT-").replace("gpt-", "GPT-") + (if (selection.optBoolean("locked") || effort.isBlank()) "" else " · " + effort) + (if (selection.optString("serviceTier") == "priority") " · " + context.getString(R.string.session_speed_fast) else "") + " ▾"
        composerControls.model.contentDescription = context.getString(R.string.session_model_description, selection.optString("model"), effortName(selection.optString("effort")))
        composerControls.model.visibility = if (supports("modelSelection") || selection.optString("model").isNotBlank()) VISIBLE else GONE
        val settingsUnknown = !reviews && client.uncertain(thread).any { it.optString("op") == "settings" }
        listOf(composerControls.mode, composerControls.model, composerControls.execution).forEach { view ->
            view.isEnabled = settingsOperation.isEmpty() && !settingsUnknown
            if (view === composerControls.execution) view.isEnabled = view.isEnabled && mutableReady && supports("executionMode") &&
                (!page.has("executionModes") || SessionExecutionModes.decode(page).isNotEmpty())
            view.alpha = if (view.isEnabled) 1f else .4f
        }
        composerControls.add.visibility = if (supports("attachments")) VISIBLE else GONE
        composerControls.add.isEnabled = mutableReady && supports("attachments") && !sending && !uploading
        editor.isEnabled = mutableReady
        renderAttachments()
        renderQueue()
        val submit = ConversationActions.submit(queueSubmission, supports("queue"),
            mutableReady, canSend, sending, uploading, unresolved, settingsOperation.isNotEmpty(),
            editor.text.toString().isNotBlank() || attachmentIDs().length() > 0)
        stopButton.visibility = if (supports("interrupt") && page.optString("status") == "active") VISIBLE else GONE
        stopButton.isEnabled = canStopCurrentTurn()
        stopButton.alpha = if (stopButton.isEnabled) 1f else .4f
        sendButton.isEnabled = submit.enabled
        sendButton.alpha = 1f
        sendButton.background = Ui.inset(context, background(if (submit.enabled) Palette.accent else Palette.surface3, 13), 4, 4)
        sendButton.setTextColor(if (submit.enabled) Palette.onAccent else Palette.faint)
        sendButton.text = context.getString(if (sending) R.string.session_sending else if (submit.queued) R.string.conversation_queue_send else R.string.conversation_send)
        sendButton.contentDescription = context.getString(if (sending) R.string.session_sending else if (submit.queued) R.string.session_add_to_the_send_queue else R.string.session_send_message)
        notice.minimumHeight = if (pendingOperations.isNotEmpty()) dp(48) else 0
        notice.gravity = Gravity.CENTER_VERTICAL
        notice.setOnClickListener {
            if (pendingOperations.isEmpty()) return@setOnClickListener
            if (retryableOperation.isEmpty()) checkUncertain()
            else {
                val token = generation
                val original = client.uncertain(thread).firstOrNull { it.optString("id") == retryableOperation }
                client.retryPending(retryableOperation) { result ->
                    if (token != generation) return@retryPending
                    if (result.optBoolean("accepted")) {
                        if (original?.optString("op") == "send" && editor.text.toString().trim() == original.optString("text")) editor.setText("")
                        notice.text = context.getString(R.string.session_operation_confirmed, operationName(original?.optString("op") ?: ""))
                    }
                    else notice.text = result.optString("error", context.getString(R.string.session_result_not_yet_confirmed))
                    retryableOperation = ""; updateComposer()
                }
            }
        }
        renderWaitState()
        if (pendingOperations.isNotEmpty()) notice.text = if (retryableOperation.isEmpty()) context.getString(R.string.session_operation_unknown, operationName(pendingOperations.first().optString("op"))) else context.getString(R.string.session_mac_has_not_received_it_tap_to_retry_the_original_operation)
    }
    private fun sendReply() {
        if (!sendButton.isEnabled) return
        val ids = attachmentIDs()
        if (!canSend) return
        val text = editor.text.toString().trim(); if (text.toByteArray().size > 32_000) { notice.text = context.getString(R.string.session_reply_is_too_long_send_it_in_parts); return }
        val target = thread; val token = generation; val waitToken = ++sendWaitGeneration; stoppedWaitSignature = null; sending = true; updateComposer(); notice.text = context.getString(R.string.session_sending_to, title)
        call("send", JSONObject().put("threadId", target).put("text", text).put("attachments", ids)) { result ->
            if (token != generation) return@call
            if (waitToken != sendWaitGeneration) { updateComposer(); return@call }
            sending = false
            if (result.optBoolean("ok") && result.optBoolean("accepted")) {
                if (editor.text.toString().trim() == text) editor.setText("")
                if (!reviews) client.clearSentAttachments(target, ids)
                saveDraft(); notice.text = if (result.optBoolean("queued")) context.getString(R.string.session_added_to_the_send_queue) else context.getString(R.string.session_received_by_mac)
                if (result.has("queuedMessages")) applyQueue(result.put("viewVersion", client.viewVersion).put("threadId", target))
                if (text.isNotEmpty() && target == thread && !result.optBoolean("queued")) {
                    val known = userIDs(page.optJSONArray("messages")) + olderMessages.keys
                    val outboxKey = threadKey(target)
                    outbox.getOrPut(outboxKey) { mutableListOf() }.add(Sent(text, known, System.currentTimeMillis()))
                    lastMessages = ""; applyPage(page)
                    // Recheck in case the push carrying the reply was lost; a queued reply simply stays pending.
                    for (delay in listOf(2_500L, 8_000L)) ui.postDelayed({ if (token == generation && outbox[outboxKey] != null) resync() }, delay)
                }
            } else notice.text = result.optString("error", context.getString(R.string.session_send_not_confirmed_draft_retained))
            updateComposer()
        }
    }
    private fun applyQueue(value: JSONObject) {
        if (!supports("queue") || !foreground || drawer || value.optString("threadId") != thread || (!reviews && value.optLong("viewVersion", -1) != client.viewVersion)) return
        page.put("queuedMessages", value.optJSONArray("queuedMessages") ?: JSONArray())
        if (!reviews) client.rememberPage(thread, page)
        renderQueue()
    }
    private fun renderQueue() {
        if (!::queuedBox.isInitialized) return
        val entries = if (supports("queue")) page.optJSONArray("queuedMessages") ?: JSONArray() else JSONArray()
        val uncertain = if (reviews) emptyList() else client.uncertain(thread).filter { it.optString("op").startsWith("queue") }
        val key = entries.toString() + ready + connected + sending + uncertain.toString()
        if (queueRendering == key) return
        queueRendering = key; queuedBox.removeAllViews()
        if (entries.length() == 0) return
        queuedBox.addView(label(context.getString(R.string.session_queue_count, entries.length()), Ui.CAPTION, Palette.faint))
        for (i in 0 until entries.length()) {
            val item = entries.getJSONObject(i); val id = item.optString("id")
            val blocked = !mutableReady || sending || uncertain.any { it.optString("messageId") == id }
            queuedBox.addView(column().apply {
                background = background(Palette.surface2, 12); setPadding(dp(12), dp(8), dp(12), dp(4))
                val status = when (item.optString("status")) { "pending", "sending" -> context.getString(R.string.session_sending_2); "outcome-unknown" -> context.getString(R.string.session_send_result_not_yet_confirmed); else -> context.getString(R.string.session_waiting_for_the_current_task_to_finish) }
                val text = item.optString("text").ifBlank { item.optJSONArray("attachments")?.join("、") ?: context.getString(R.string.session_attachment_message) }
                addView(label(text, Ui.BODY).apply { maxLines = 2 })
                addView(row().apply {
                    gravity = Gravity.CENTER_VERTICAL
                    addView(label(item.optString("pausedReason").ifBlank { status }, Ui.CAPTION, Palette.faint).apply { maxLines = 2 }, LinearLayout.LayoutParams(0, -2, 1f))
                    addView(button(context.getString(R.string.session_steer)) { queueAction("queueSteer", id) }.apply { isEnabled = !blocked && supports("queueSteer"); alpha = if (isEnabled) 1f else .4f }, LinearLayout.LayoutParams(-2, dp(48)))
                    addView(button(context.getString(R.string.delete)) { queueAction("queueDelete", id) }.apply { isEnabled = !blocked && supports("queueDelete"); alpha = if (isEnabled) 1f else .4f }, LinearLayout.LayoutParams(-2, dp(48)).apply { marginStart = dp(4) })
                })
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6); bottomMargin = dp(4) })
        }
    }
    private fun queueAction(op: String, id: String) {
        if (!mutableReady || !supports(op) || sending) return
        val token = generation; sending = true; updateComposer()
        val fields = JSONObject().put("threadId", thread).put("messageId", id)
        val queued = page.optJSONArray("queuedMessages") ?: JSONArray()
        val item = (0 until queued.length()).mapNotNull { queued.optJSONObject(it) }.singleOrNull { it.optString("id") == id }
        if (item != null) fields.put("expectedQueueDigest", io.github.junweiup.vibepier.remote.core.session.SessionControlPreparation.queueDigest(item))
        if (op == "queueSteer" && page.optString("status") == "active" && page.optString("activeTurnId").isNotBlank()) fields.put("expectedTurnId", page.optString("activeTurnId"))
        call(op, fields) { result ->
            if (token != generation || drawer) return@call
            sending = false
            if (result.optBoolean("ok")) {
                if (result.has("queuedMessages")) applyQueue(result.put("viewVersion", client.viewVersion).put("threadId", thread))
                else resync(withCache = false)
                notice.text = if (op == "queueSteer") context.getString(R.string.session_requested_steering_for_the_current_task) else context.getString(R.string.session_queued_message_deleted)
                if (op == "queueSteer") ui.postDelayed({
                    val queued = page.optJSONArray("queuedMessages") ?: JSONArray()
                    if (token == generation && foreground && !drawer && (0 until queued.length()).any { queued.getJSONObject(it).optString("id") == id }) resync()
                }, 5_000L)
            } else notice.text = result.optString("error", context.getString(R.string.session_operation_result_not_yet_confirmed))
            updateComposer()
        }
    }
    private fun operationName(op: String) = when (op) { "settings" -> context.getString(R.string.session_session_settings); "interrupt" -> context.getString(R.string.session_stop_request); "queueSteer" -> context.getString(R.string.session_steering_request); "queueDelete" -> context.getString(R.string.session_delete_request); else -> context.getString(R.string.session_send_result) }
    private fun canStopCurrentTurn() = SessionWaitState.canStop(
        connected, mutableReady, supports("interrupt"), page.optString("status") == "active",
        page.optString("activeTurnId"), sending || stopRequestedTurn.isNotEmpty(),
        !reviews && client.uncertain(thread).any { it.optString("op") == "interrupt" })

    private fun renderWaitState() {
        if (drawer || !::waitBanner.isInitialized) return
        val reason = SessionWaitState.reason(connected, ready, !reviews && client.waitingOperations(thread).isNotEmpty(),
            (page.optJSONArray("approvals")?.length() ?: 0) > 0, page.optJSONObject("blocker")?.optString("code") ?: "",
            page.optString("status"), android.os.SystemClock.elapsedRealtime() - lastProgressAt)
        val stopping = connected && stopRequestedTurn.isNotEmpty()
        val signature = waitSignature()
        waitBanner.visibility = if ((reason == null && !stopping) || stoppedWaitSignature == signature) GONE else VISIBLE
        if (waitBanner.visibility == GONE) return
        val message = if (stopping) R.string.session_wait_stopping else when (reason) {
            SessionWaitState.Reason.DISCONNECTED -> R.string.session_wait_disconnected
            SessionWaitState.Reason.UNKNOWN -> R.string.session_wait_unknown
            SessionWaitState.Reason.LOADING -> R.string.session_wait_loading
            SessionWaitState.Reason.APPROVAL -> R.string.session_wait_approval
            SessionWaitState.Reason.RATE_LIMIT -> R.string.session_wait_rate_limit
            SessionWaitState.Reason.API_ERROR -> R.string.session_wait_api_error
            SessionWaitState.Reason.BLOCKED -> R.string.session_wait_blocked
            SessionWaitState.Reason.SLOW -> R.string.session_wait_slow
            null -> R.string.session_wait_stopping
        }
        val canStop = canStopCurrentTurn()
        waitMessage.text = context.getString(message) + "\n" + context.getString(R.string.session_stop_waiting_detail) +
            if (canStop) "\n" + context.getString(R.string.conversation_stop_at_header) else ""
        waitCancel.text = context.getString(R.string.session_stop_waiting)
    }

    private fun waitSignature() = listOf(connected, ready, progressSignature,
        if (reviews) "" else client.waitingOperations(thread).map { it.optString("id") }.sorted()).joinToString("\u0000")

    private fun stopWaiting() {
        saveDraft(); hideKeyboard()
        if (canStopCurrentTurn()) { stopCurrentTurn(); return }
        if (!reviews && !client.stopWaiting(thread)) {
            notice.text = context.getString(R.string.client_receipt_save_failed); return
        }
        sendWaitGeneration++; sending = false
        stoppedWaitSignature = waitSignature()
        notice.text = context.getString(R.string.session_wait_stopped)
        updateComposer()
    }

    private fun stopCurrentTurn() {
        if (!canStopCurrentTurn()) return
        val token = generation; stopRequestedTurn = page.optString("activeTurnId"); sending = true; updateComposer()
        call("interrupt", JSONObject().put("threadId", thread).put("expectedTurnId", page.optString("activeTurnId"))) { result ->
            if (token != generation) return@call
            if (!result.optBoolean("ok") && !result.optBoolean("unknown")) stopRequestedTurn = ""
            sending = false; notice.text = if (result.optBoolean("ok")) context.getString(R.string.session_requested_stop_for_the_current_task) else result.optString("error"); updateComposer()
        }
    }
    private fun checkUncertain() {
        val target = thread; val token = generation
        client.uncertain(target).filter { it.optString("op") in listOf("send", "settings", "interrupt", "queueSteer", "queueDelete") }.forEach { original ->
            client.request("receipt", JSONObject().put("operation", original.getString("id"))) { result ->
                if (token != generation) return@request
                if (result.optString("state") == "complete") {
                    client.clearReceipt(original.getString("id"))
                    val receipt = result.optJSONObject("receipt") ?: JSONObject()
                    if (receipt.optBoolean("accepted")) {
                        if (original.optString("op") == "send" && editor.text.toString().trim() == original.optString("text")) editor.setText("")
                        if (original.optString("op") == "send") client.clearSentAttachments(target, original.optJSONArray("attachments"))
                        notice.text = context.getString(R.string.session_operation_confirmed, operationName(original.optString("op")))
                        if (original.optString("op").startsWith("queue")) resync()
                    } else notice.text = receipt.optString("error", context.getString(R.string.session_approval_submission_result_checked))
                } else if (result.optString("state") == "notFound") { retryableOperation = original.getString("id"); notice.text = context.getString(R.string.session_mac_has_not_recorded_this_operation_retry_with_the_original_oper) }
                else notice.text = context.getString(R.string.session_result_still_unknown_check_on_the_mac_to_avoid_a_duplicate_opera)
                updateComposer()
            }
        }
    }
    /** Show cached rows first, then refresh the visible window without clearing it while waiting. */
    private fun callList(op: String, params: JSONObject, useCache: Boolean, callback: (JSONObject) -> Unit) {
        val sourceProvider = client.provider; val token = listGeneration; val query = drawerKey()
        loadingList = true
        val name = if (op == "projects") "projects" else "threads"
        val cached = if (useCache && !reviews) client.cachedList(op, params) else null
        val keepVisible = drawerLoaded && loadedDrawerKey == drawerKey()
        val target = if (params.optInt("offset") == 0) maxOf(8, if (keepVisible) listedCount else 0, cached?.optJSONArray(name)?.length() ?: 0) else 8
        if (cached != null) client.rememberCapabilities(cached, sourceProvider)
        if (cached != null && !keepVisible) callback(cached)
        if (cached != null && client.freshList(op, params)) { loadingList = false; return }
        if (!connected && (cached != null || keepVisible)) { loadingList = false; return }
        val rows = linkedMapOf<String, JSONObject>()
        val id = if (op == "projects") "cwd" else "id"
        fun fetch(fields: JSONObject) {
            call(op, fields) { result ->
                if (!drawer || !foreground || token != listGeneration || query != drawerKey()) return@call
                if (!result.optBoolean("ok")) {
                    loadingList = false
                    (list.getChildAt(list.childCount - 1) as? CanvasLabel)?.takeIf { it.tag == "more" }?.text = context.getString(R.string.session_scroll_up_to_retry)
                    if (cached == null && !keepVisible) callback(result)
                    return@call
                }
                val entries = result.optJSONArray(name) ?: JSONArray()
                for (i in 0 until entries.length()) entries.getJSONObject(i).let { rows[it.optString(id)] = it }
                val next = result.optInt("nextOffset", -1)
                if (params.optInt("offset") == 0 && rows.size < target && next > fields.optInt("offset") && entries.length() > 0) {
                    fetch(JSONObject(params.toString()).put("offset", next).put("limit", minOf(8, target - rows.size)))
                } else {
                    loadingList = false
                    result.put(name, JSONArray(rows.values.toList()))
                    if (!reviews) client.rememberList(op, params, result, sourceProvider)
                    callback(result)
                }
            }
        }
        fetch(params)
    }
    private fun call(op: String, params: JSONObject = JSONObject(), callback: (JSONObject) -> Unit) {
        val provider = params.optString("provider").ifBlank { client.provider }
        val fields = JSONObject(params.toString()).put("provider", provider)
        if (!reviews) { client.request(op, fields) { result ->
            if (op in listOf("list", "projects")) client.rememberCapabilities(result, provider)
            callback(result)
        }; return }
        ui.postDelayed({
            val result = ConversationReviewFixtures.reply(op, fields, fixture).put("provider", provider)
            if (op == "attachmentPreview" || op == "image") try { result.put("image", android.util.Base64.encodeToString(context.assets.open("composer-preview.png").use { it.readBytes() }, android.util.Base64.NO_WRAP)) } catch (_: Exception) {}
            callback(result)
            if (op == "interrupt" && result.optBoolean("ok")) applyPage(JSONObject(page.toString()).put("status", "idle").put("activeTurnId", ""))
            if (op == "open" && result.optBoolean("ok")) applyPage(ConversationReviewFixtures.conversation(fixture).put("threadId", params.optString("threadId")))
        }, if (op == "send" && fixture == "pending") 4000 else 120)
    }
}
