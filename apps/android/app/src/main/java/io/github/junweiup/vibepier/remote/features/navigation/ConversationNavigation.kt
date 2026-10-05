package io.github.junweiup.vibepier.remote.features.navigation

import io.github.junweiup.vibepier.remote.R
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.FrameLayout
import android.widget.Toast
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import org.json.JSONObject

/** Owns the conversation overlay and document-picker lifecycle; transport ownership stays in the service. */
internal class ConversationNavigation(
    private val activity: Activity,
    private val rootHost: () -> FrameLayout,
    private val client: SessionClient,
    private val fixture: String,
    private val beforeOpen: () -> Unit,
) {
    private val root get() = rootHost()
    var panel: ConversationPanel? = null; private set
    var pickingAttachment = false; private set
    private var pickerState: JSONObject? = null
    private var pickerPanel: ConversationPanel? = null

    fun show() {
        if (panel != null) return
        beforeOpen()
        root.getChildAt(0).importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        panel = ConversationPanel(activity, client, dismiss = ::removeOverlay, fixture = fixture).also {
            root.addView(it, FrameLayout.LayoutParams(-1, -1)); it.requestApplyInsets()
        }
    }

    fun showProviderList(provider: String) {
        if (provider !in io.github.junweiup.vibepier.remote.core.session.SessionProvider.ids) return
        close()
        client.provider = provider
        client.listMode = "recent"
        client.rememberDrawerState(JSONObject().put("listMode", "recent"))
        show()
    }

    fun showCompletion(route: JSONObject) {
        if (io.github.junweiup.vibepier.remote.features.sessions.ConversationViewState.read(route, client.authorizationIdentity) == null) return
        close()
        show()
        panel?.restoreNavigationState(route)
    }

    /** Save routes and pending picker ownership only; conversation bodies stay in the private cache. */
    fun saveState(out: Bundle) {
        panel?.navigationState()?.let { out.putString("conversationNavigation", it.toString()) }
        if (pickingAttachment) pickerState?.let { out.putString("conversationPicker", it.toString()) }
    }

    fun restoreState(saved: Bundle?): Boolean {
        val navigation = saved?.getString("conversationNavigation")?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return false
        show()
        if (panel?.restoreNavigationState(navigation) != true) {
            navigation.optString("pendingUri").takeIf { it.isNotBlank() && it.length <= 4096 }?.let { release(Uri.parse(it)) }
            close(); Toast.makeText(activity, activity.getString(R.string.audit_navigation_changed), Toast.LENGTH_LONG).show(); return false
        }
        pickerState = saved.getString("conversationPicker")?.let { runCatching { JSONObject(it) }.getOrNull() }
        pickingAttachment = pickerState != null
        return true
    }

    fun pickAttachment(images: Boolean) {
        val current = panel ?: return
        pickingAttachment = true
        pickerState = current.navigationState()
        pickerPanel = current
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE); type = if (images) "image/*" else "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try { @Suppress("DEPRECATION") activity.startActivityForResult(intent, PICK_ATTACHMENT) }
        catch (_: Exception) {
            pickingAttachment = false; pickerState = null; pickerPanel = null
            Toast.makeText(activity, activity.getString(R.string.picker_unavailable), Toast.LENGTH_SHORT).show()
        }
    }

    fun activityResult(request: Int, result: Int, data: Intent?) {
        if (request != PICK_ATTACHMENT) return
        pickingAttachment = false
        val expected = pickerState; val original = pickerPanel
        pickerState = null; pickerPanel = null
        if (result != Activity.RESULT_OK) return
        val uri = data?.data ?: return
        runCatching { activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        val current = panel
        // A still-open creation dialog owns its original callback. Recreated creation dialogs require reselection.
        if (current != null && current === original && expected?.optBoolean("creationAttachment") == true) {
            if (current.addPickedCreationAttachment(uri, expected)) return
        }
        if (expected == null || current?.addRestoredPhoneAttachment(uri, expected) != true) {
            release(uri)
            Toast.makeText(activity, activity.getString(if (expected?.optBoolean("creationAttachment") == true)
                R.string.audit_creation_attachment_reselect else R.string.audit_attachment_reselect), Toast.LENGTH_LONG).show()
        }
    }
    fun back() = panel?.back() == true
    fun connectionChanged() { panel?.connectionChanged() }
    fun resume() { panel?.resume() }
    fun suspend() { if (!pickingAttachment) panel?.suspend() }
    fun close(preservePendingAttachment: Boolean = false) {
        pickingAttachment = false; pickerState = null; pickerPanel = null
        panel?.close(preservePendingAttachment); removeOverlay()
    }
    private fun release(uri: Uri) { runCatching { activity.contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) } }
    private fun removeOverlay() {
        val visible = panel ?: return
        root.removeView(visible); panel = null
        root.getChildAt(0)?.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
    }
    private companion object { const val PICK_ATTACHMENT = 940 }
}
