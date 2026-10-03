package io.github.junweiup.vibepier.remote.features.markdown

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.IconControl
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.protectControls
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import org.json.JSONObject
import java.util.UUID

/** Read-only session document, with generation-guarded, immutable snapshot paging. */
internal class MarkdownFileViewer(
    private val context: Context, private val threadId: String, path: String, private val provider: String,
    private val request: (String, JSONObject, (JSONObject) -> Unit) -> Unit,
    private val isCurrent: () -> Boolean = { true }, private val onClose: () -> Unit = {},
) {
    private val body = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val scroll = ScrollView(context).apply { isFillViewport = true; addView(body) }
    private val tabs = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val title = Ui.label(context, path.substringAfterLast('/'), Ui.TITLE).apply { typeface = Typeface.DEFAULT_BOLD; maxLines = 2 }
    private val location = Ui.label(context, path, Ui.CAPTION, Palette.muted).apply { maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE }
    private val status = Ui.label(context, context.getString(R.string.document_reading), Ui.CAPTION, Palette.muted)
    private val footer = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
    private val raw = StringBuilder()
    private var target = path
    private var version = ""
    private var offset = 0
    private var epoch = 0
    private var shown = false
    private var closed = false
    private var loading = false
    private var complete = false
    private var error = ""
    private var mode = "preview"
    private var displayLimit = 40_000
    private var previewBlock = 0
    private val previewHistory = mutableListOf<Int>()
    private val positions = mutableMapOf<String, Int>()
    val dialog: AlertDialog

    init {
        val box = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(12), dp(16), dp(12))
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(IconControl(context, IconControl.Icon.BACK, context.getString(R.string.document_close), Palette.text) { dismiss() }, LinearLayout.LayoutParams(dp(48), dp(48)))
                addView(title, LinearLayout.LayoutParams(0, -2, 1f))
            })
            addView(location, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6); bottomMargin = dp(6) })
            addView(tabs, LinearLayout.LayoutParams(-1, -2))
            addView(Ui.divider(context), LinearLayout.LayoutParams(-1, dp(1)))
            addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
            addView(status, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
            addView(footer, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4) })
        }
        dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).setView(box).create()
        dialog.setOnDismissListener {
            if (!closed) { closed = true; epoch++; onClose() }
        }
        render()
    }

    fun show() {
        if (shown || closed || !isCurrent()) return
        shown = true; dialog.window?.protectControls(); dialog.show()
        dialog.window?.setLayout((context.resources.displayMetrics.widthPixels - dp(16)).coerceAtLeast(dp(240)), (context.resources.displayMetrics.heightPixels * .9).toInt())
        reload()
    }

    fun dismiss() {
        if (closed) return
        closed = true; epoch++; dialog.dismiss(); onClose()
    }

    private fun dp(n: Int) = Ui.dp(context, n)
    private fun current(token: Int) = !closed && isCurrent() && epoch == token
    private fun reload() {
        if (closed || !isCurrent()) return
        epoch++; loading = false; raw.setLength(0); offset = 0; version = ""; complete = false; error = ""; displayLimit = 40_000; previewBlock = 0; previewHistory.clear(); positions.clear()
        load()
    }

    private fun load() {
        if (loading || closed || !isCurrent()) return
        val token = epoch; val expectedOffset = offset
        loading = true; error = ""; render()
        val params = JSONObject().put("threadId", threadId).put("path", target).put("provider", provider).put("offset", expectedOffset)
        if (version.isNotEmpty()) params.put("version", version)
        request("readMarkdownFile", params) { result ->
            if (!current(token)) return@request
            loading = false
            if (!result.optBoolean("ok")) {
                error = result.optString("error", context.getString(R.string.document_read_failed)); render(); return@request
            }
            val next = result.optInt("nextOffset", -2)
            val receivedVersion = result.optString("version")
            val chunk = result.optString("text")
            val bytes = chunk.toByteArray(Charsets.UTF_8).size
            if (result.optString("threadId") != threadId || receivedVersion.isEmpty() || (version.isNotEmpty() && receivedVersion != version) || next < -1 ||
                (next >= 0 && (next != expectedOffset + bytes || next <= expectedOffset)) || raw.length + chunk.length > 2 * 1024 * 1024 ||
                expectedOffset.toLong() + bytes > 2 * 1024 * 1024 || result.optLong("size") > 2 * 1024 * 1024 ||
                (next == -1 && expectedOffset.toLong() + bytes != result.optLong("size"))) {
                error = context.getString(R.string.document_incomplete); render(); return@request
            }
            version = receivedVersion; target = result.optString("path", target)
            title.text = result.optString("name", target.substringAfterLast('/')); location.text = target
            raw.append(chunk); offset = if (next < 0) expectedOffset + bytes else next
            complete = next == -1
            if (complete) render() else {
                status.text = context.getString(R.string.document_receiving, android.text.format.Formatter.formatShortFileSize(context, offset.toLong()))
                // Yield to scrolling and close controls between pages, also for synchronous test providers.
                body.post { if (current(token)) load() }
            }
        }
    }

    private fun render() {
        tabs.removeAllViews()
        tabs.addView(Ui.topTabs(context, listOf("preview" to context.getString(R.string.document_preview), "source" to context.getString(R.string.document_source)), mode, context.getString(R.string.document_kind)) { selected ->
            positions[mode] = scroll.scrollY; mode = selected; render(); scroll.post { scroll.scrollTo(0, positions[mode] ?: 0) }
        })
        body.removeAllViews(); body.setPadding(dp(4), dp(16), dp(4), dp(16))
        if (raw.isNotEmpty() && (!loading || complete || error.isNotEmpty())) {
            val text = raw.substring(0, minOf(raw.length, displayLimit))
            var blocks = 0
            var displayedBlocks = 0
            if (mode == "preview") body.addView(ChatMarkdownView(context, { link ->
                val resolved = MarkdownFileLinks.resolve(link, target)
                target = resolved.path; reload()
            }).apply { blocks = render(text, previewBlock, 120); displayedBlocks = renderedBlocks }, LinearLayout.LayoutParams(-1, -2))
            else body.addView(Ui.label(context, text, 13f).apply { typeface = Typeface.MONOSPACE; lineSpacingExtra = 3f }, LinearLayout.LayoutParams(-1, -2))
            if (mode == "preview" && previewBlock > 0) body.addView(Ui.button(context, context.getString(R.string.document_previous_page), Ui.Button.TEXT) { previewBlock = previewHistory.removeLastOrNull() ?: 0; render(); scroll.scrollTo(0, 0) })
            if (mode == "preview" && previewBlock + displayedBlocks < blocks) body.addView(Ui.button(context, context.getString(R.string.document_next_page)) { previewHistory.add(previewBlock); previewBlock += displayedBlocks; render(); scroll.scrollTo(0, 0) })
            else if (raw.length > displayLimit) body.addView(Ui.button(context, context.getString(R.string.document_show_more)) {
                positions[mode] = scroll.scrollY
                if (mode == "preview") { previewHistory.add(previewBlock); previewBlock = (blocks - 1).coerceAtLeast(0) }
                displayLimit += 40_000; render(); scroll.post { scroll.scrollTo(0, if (mode == "source") positions[mode] ?: 0 else 0) }
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(16) })
        } else if (complete) body.addView(Ui.label(context, context.getString(R.string.document_empty), Ui.BODY, Palette.muted))
        else body.addView(Ui.label(context, if (error.isNotBlank()) error else context.getString(R.string.document_reading_mac), Ui.BODY, Palette.muted))
        status.text = when {
            error.isNotBlank() && raw.isNotEmpty() -> context.getString(R.string.document_error_retained, error)
            error.isNotBlank() -> error
            loading -> context.getString(R.string.document_receiving, android.text.format.Formatter.formatShortFileSize(context, offset.toLong()))
            complete -> context.getString(R.string.document_read_only, android.text.format.Formatter.formatShortFileSize(context, offset.toLong()))
            else -> ""
        }
        footer.removeAllViews()
        footer.addView(Ui.button(context, if (error.isNotBlank()) context.getString(R.string.retry) else context.getString(R.string.reload), Ui.Button.TEXT) { if (error.isNotBlank()) load() else reload() }.apply { isEnabled = !loading; alpha = if (loading) .4f else 1f }, LinearLayout.LayoutParams(0, -2, 1f))
        if (error.isNotBlank()) footer.addView(Ui.button(context, context.getString(R.string.reload), Ui.Button.TEXT) { reload() }, LinearLayout.LayoutParams(0, -2, 1f))
        footer.addView(Ui.button(context, context.getString(R.string.document_copy_all), Ui.Button.TONAL) {
            if (raw.length > 200_000) status.text = context.getString(R.string.document_copy_large)
            else try {
                (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText(title.text, raw.toString()))
                status.text = context.getString(R.string.document_copied)
            } catch (_: Exception) { status.text = context.getString(R.string.document_copy_failed) }
        }.apply { isEnabled = complete && error.isEmpty(); alpha = if (isEnabled) 1f else .4f }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = dp(8) })
    }
}
