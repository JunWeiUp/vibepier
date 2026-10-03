package io.github.junweiup.vibepier.remote.features.navigation

import io.github.junweiup.vibepier.remote.R
import android.app.Activity
import android.content.Intent
import android.view.View
import android.widget.FrameLayout
import android.widget.Toast
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel

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

    fun show() {
        if (panel != null) return
        beforeOpen()
        root.getChildAt(0).importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        panel = ConversationPanel(activity, client, dismiss = ::removeOverlay, fixture = fixture).also {
            root.addView(it, FrameLayout.LayoutParams(-1, -1)); it.requestApplyInsets()
        }
    }

    fun pickAttachment(images: Boolean) {
        if (panel == null) return
        pickingAttachment = true
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE); type = if (images) "image/*" else "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try { @Suppress("DEPRECATION") activity.startActivityForResult(intent, PICK_ATTACHMENT) }
        catch (_: Exception) {
            pickingAttachment = false
            Toast.makeText(activity, activity.getString(R.string.picker_unavailable), Toast.LENGTH_SHORT).show()
        }
    }

    fun activityResult(request: Int, result: Int, data: Intent?) {
        if (request != PICK_ATTACHMENT) return
        pickingAttachment = false
        if (result == Activity.RESULT_OK) data?.data?.let { panel?.addPhoneAttachment(it) }
    }
    fun back() = panel?.back() == true
    fun connectionChanged() { panel?.connectionChanged() }
    fun resume() { panel?.resume() }
    fun suspend() { if (!pickingAttachment) panel?.suspend() }
    fun close() { pickingAttachment = false; panel?.close(); removeOverlay() }
    private fun removeOverlay() {
        val visible = panel ?: return
        root.removeView(visible); panel = null
        root.getChildAt(0)?.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
    }
    private companion object { const val PICK_ATTACHMENT = 940 }
}
