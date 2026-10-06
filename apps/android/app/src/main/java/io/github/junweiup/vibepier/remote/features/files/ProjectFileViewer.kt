package io.github.junweiup.vibepier.remote.features.files

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.files.BinaryFileClient
import io.github.junweiup.vibepier.remote.core.files.BinaryMediaClient
import io.github.junweiup.vibepier.remote.core.ui.ControlView
import io.github.junweiup.vibepier.remote.core.ui.IconControl
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.protectControls
import io.github.junweiup.vibepier.remote.core.ui.showProtected
import io.github.junweiup.vibepier.remote.features.markdown.ChatMarkdownView
import io.github.junweiup.vibepier.remote.features.remote.Palette
import io.github.junweiup.vibepier.remote.core.ui.ZoomableImagePreview

import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ScrollView
import org.json.JSONObject

/** What the browser and viewer need from the open conversation. Every call is guarded by `isCurrent`. */
private val mediaIO = java.util.concurrent.Executors.newFixedThreadPool(2)

internal class ProjectFileHost(
    val context: Context, val threadId: String, val provider: String,
    val request: (String, JSONObject, (JSONObject) -> Unit) -> Unit,
    val isCurrent: () -> Boolean,
    val canQuote: () -> Boolean, val quote: (String, Int?) -> Unit,
    val canAttach: () -> Boolean, val attach: (String) -> Unit,
    val binaryHost: () -> String? = { null },
) {
    private val prefs = io.github.junweiup.vibepier.remote.core.security.PrivatePreferences.open(context, "project-files")
    var rootPath = ""
    fun recent(): List<String> = ProjectFiles.parse(prefs.getString("recent.$rootPath", null))
    fun remember(path: String) { if (rootPath.isNotEmpty()) prefs.edit().putString("recent.$rootPath", ProjectFiles.remember(prefs.getString("recent.$rootPath", null), path)).apply() }
    fun call(op: String, fields: JSONObject, done: (JSONObject) -> Unit) {
        request(op, fields.put("threadId", threadId).put("provider", provider)) { if (isCurrent()) done(it) }
    }
    fun dp(value: Int) = Ui.dp(context, value)

    /** A dialog rising from the bottom edge, used for file actions. */
    fun sheet(content: View): AlertDialog {
        val dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).setView(ScrollView(context).apply { addView(content) }).create()
        dialog.window?.protectControls()
        dialog.show()
        dialog.window?.apply {
            setBackgroundDrawable(GradientDrawable().apply {
                setColor(Palette.surface2); val r = dp(24).toFloat(); cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
            })
            setGravity(Gravity.BOTTOM); setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        return dialog
    }

    /** Quote, attach, copy, open or reveal one file or folder. `onDone` runs after quoting so pages can close. */
    fun actions(path: String, directory: Boolean, line: Int? = null, notice: (String) -> Unit, onQuoted: () -> Unit = {}) {
        lateinit var dialog: AlertDialog
        val name = path.substringAfterLast('/').ifEmpty { path }
        val box = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; setPadding(0, dp(10), 0, dp(18))
            addView(View(context).apply { background = Ui.roundRect(context, Palette.surface4, 2) },
                LinearLayout.LayoutParams(dp(38), dp(4)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(10) })
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL; setPadding(dp(18), dp(2), dp(18), dp(10))
                addView(FileBadge(context, if (directory) null else name), LinearLayout.LayoutParams(dp(34), dp(34)).apply { marginEnd = dp(12) })
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(Ui.label(context, name, Ui.BODY).apply { typeface = Typeface.DEFAULT_BOLD; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE })
                    addView(Ui.label(context, path.substringBeforeLast('/', context.getString(R.string.files_project_root)), Ui.CAPTION, Palette.muted).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.START })
                }, LinearLayout.LayoutParams(0, -2, 1f))
            })
        }
        fun item(title: String, detail: String = "", enabled: Boolean = true, action: () -> Unit) {
            box.addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL; minimumHeight = dp(52); setPadding(dp(20), 0, dp(20), 0)
                isFocusable = true; alpha = if (enabled) 1f else .4f
                contentDescription = title + if (detail.isNotEmpty()) "，$detail" else ""
                addView(Ui.label(context, title, Ui.BODY).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO })
                addView(Ui.label(context, detail, Ui.CAPTION, Palette.faint).apply {
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO; maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.START; gravity = Gravity.END
                }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = dp(16) })
                setOnClickListener { if (enabled) { dialog.dismiss(); action() } }
            }, LinearLayout.LayoutParams(-1, -2))
        }
        val reference = path + (line?.let { ":$it" } ?: "")
        item(context.getString(R.string.files_quote_in_reply), if (canQuote()) reference.substringAfterLast('/') else context.getString(R.string.files_this_session_cannot_be_replied_to_from_the_phone), canQuote()) { quote(path, line); onQuoted() }
        if (!directory) item(context.getString(R.string.files_add_as_attachment), if (canAttach()) "" else context.getString(R.string.files_this_session_does_not_support_attachments), canAttach()) { attach(path); onQuoted() }
        item(context.getString(R.string.files_copy_relative_path), path.ifEmpty { "." }) {
            try {
                (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText(name, reference))
                notice(context.getString(R.string.files_path_copied))
            } catch (_: Exception) { notice(context.getString(R.string.files_could_not_write_to_clipboard)) }
        }
        if (!directory) item(context.getString(R.string.files_open_on_mac), context.getString(R.string.files_default_app)) { openOnMac(path, false, notice) }
        item(context.getString(R.string.files_show_in_finder)) { openOnMac(path, true, notice) }
        dialog = sheet(box)
    }

    fun openOnMac(path: String, reveal: Boolean, notice: (String) -> Unit) {
        notice(if (reveal) context.getString(R.string.files_showing_in_finder) else context.getString(R.string.files_opening_on_mac))
        call("openFile", JSONObject().put("path", path).put("reveal", reveal)) { result ->
            notice(when {
                !result.optBoolean("ok") -> result.optString("error", context.getString(R.string.files_mac_could_not_open_the_file))
                result.optBoolean("locked") -> context.getString(R.string.files_opened_on_mac_unlock_to_view)
                reveal -> context.getString(R.string.files_shown_in_finder)
                else -> context.getString(R.string.files_opened_on_mac)
            })
        }
    }
}

/** A file's language tag on a tinted tile, or a folder glyph when `name` is null. */
@android.annotation.SuppressLint("ViewConstructor") // Constructed in code with file metadata.
internal class FileBadge(context: Context, private val name: String?, private val muted: Boolean = false) : ControlView(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD }
    private val kind = name?.let(ProjectFiles::kind)
    private val box = android.graphics.RectF()
    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }
    override fun onDraw(canvas: Canvas) {
        val d = resources.displayMetrics.density
        if (kind == null) {
            paint.style = Paint.Style.STROKE; paint.strokeWidth = 1.7f * d; paint.strokeJoin = Paint.Join.ROUND; paint.color = Palette.blue
            val w = width.toFloat(); val h = height.toFloat(); val top = h * .24f; val bottom = h * .8f
            box.set(w * .08f, top + h * .08f, w * .92f, bottom)
            canvas.drawRoundRect(box, 2.5f * d, 2.5f * d, paint)
            canvas.drawLine(w * .08f, top + h * .08f, w * .08f, top, paint); canvas.drawLine(w * .08f, top, w * .42f, top, paint)
            canvas.drawLine(w * .42f, top, w * .5f, top + h * .08f, paint)
            return
        }
        paint.style = Paint.Style.FILL; paint.color = if (muted) Palette.surface4 else kind.color
        box.set(0f, 0f, width.toFloat(), height.toFloat())
        canvas.drawRoundRect(box, width * .28f, width * .28f, paint)
        text.color = if (muted) Palette.faint else Palette.background
        text.textSize = height * (if (kind.tag.length > 2) .36f else .42f)
        canvas.drawText(kind.tag, width / 2f, height / 2f - (text.ascent() + text.descent()) / 2, text)
    }
}

/** One numbered line of code or diff, wrapped to the width; the list recycles these. */
internal class CodeLineView(context: Context) : ControlView(context) {
    private val d = resources.displayMetrics.density
    private val numberPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.MONOSPACE; textSize = 11.5f * resources.displayMetrics.scaledDensity; textAlign = Paint.Align.RIGHT }
    private val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.MONOSPACE; textSize = 12f * resources.displayMetrics.scaledDensity; color = 0xFFCFD8DB.toInt() }
    private val fill = Paint()
    private var layout: StaticLayout? = null
    private var text: CharSequence = ""
    private var number = ""
    private var numberColor = 0
    private var tint = 0
    var gutter = 0
    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES }

    fun bind(number: String, text: CharSequence, background: Int, numberColor: Int, gutter: Int, plain: Boolean = false) {
        this.number = number; this.text = text; tint = background; this.numberColor = numberColor; this.gutter = gutter
        textPaint.color = if (plain) Palette.faint else 0xFFCFD8DB.toInt()
        contentDescription = (if (number.isNotBlank()) context.getString(R.string.files_line_1 ,number.trim()) else "") + text
        layout = null; requestLayout(); invalidate()
    }
    private fun textLeft() = gutter + 10 * d
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val available = (width - textLeft() - 10 * d).toInt().coerceAtLeast(1)
        layout = StaticLayout.Builder.obtain(text, 0, text.length, textPaint, available).setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setLineSpacing(3 * d, 1f).setIncludePad(false).build()
        setMeasuredDimension(width, (layout!!.height + 4 * d).toInt().coerceAtLeast((20 * d).toInt()))
    }
    override fun onDraw(canvas: Canvas) {
        if (tint != 0) { fill.color = tint; canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), fill) }
        numberPaint.color = numberColor
        canvas.drawText(number, gutter.toFloat(), 2 * d - numberPaint.ascent(), numberPaint)
        canvas.save(); canvas.translate(textLeft(), 2 * d); layout?.draw(canvas); canvas.restore()
    }
}

/**
 * One file, read-only: source with line numbers and light colouring, its diff against HEAD, and a preview for
 * Markdown and images. Pages arrive as immutable snapshot chunks, exactly like the Markdown reader.
 */
internal class ProjectFileViewer(
    private val host: ProjectFileHost, path: String, private val line: Int? = null,
    private var status: String = "", private val preferDiff: Boolean = false, private val onClose: () -> Unit = {},
) {
    private val context = host.context
    private fun dp(value: Int) = host.dp(value)
    private var target = path
    private val name get() = target.substringAfterLast('/')
    private val raw = StringBuilder()
    private var version = ""; private var offset = 0; private var size = 0L
    private var loading = false; private var complete = false; private var error = ""; private var unavailable = ""
    private var epoch = 0; private var closed = false
    private var diffRows: List<ProjectFiles.DiffLine>? = null
    private var diffState = ""; private var diffLoading = false; private var untracked = false; private var diffTruncated = false
    private var added = 0; private var removed = 0
    private var image: android.graphics.Bitmap? = null
    private var imagePreview: ZoomableImagePreview? = null
    private var imageTransfer: BinaryFileClient? = null
    private var videoPreview: VideoFilePreview? = null
    private var htmlPreview: HtmlFilePreview? = null
    private var mode = ""
    private var highlight: Int? = line
    private var lines: List<String> = emptyList()
    private val title = Ui.label(context, name, 15.5f).apply { typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE }
    private val subtitle = Ui.label(context, "", Ui.CAPTION, Palette.muted).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.START }
    private val tabs = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
    private val content = FrameLayout(context)
    private val notice = Ui.label(context, "", Ui.CAPTION, Palette.muted).apply { gravity = Gravity.CENTER; visibility = View.GONE }
    private val list = ListView(context).apply {
        divider = null; dividerHeight = 0; selector = ColorDrawable(0); isVerticalScrollBarEnabled = true; setBackgroundColor(Palette.background)
        clipToPadding = false; setPadding(0, dp(4), 0, dp(16))
    }
    private val adapter = Rows()
    private val copy = action(context.getString(R.string.files_copy)) { copyAll() }
    private val openMac = action(context.getString(R.string.files_open_on_mac_19)) { host.openOnMac(target, false, ::say) }
    private val quote = action(context.getString(R.string.files_quote_in_reply), primary = true) { host.quote(target, highlight); dismiss() }
    private val root: LinearLayout
    val dialog: AlertDialog

    init {
        list.adapter = adapter
        list.setOnItemClickListener { _, _, position, _ -> adapter.number(position)?.let { highlight = if (highlight == it) null else it; adapter.notifyDataSetChanged(); refreshBar() } }
        root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; setBackgroundColor(Palette.background)
            if (ProjectFiles.isImage(name)) setOnApplyWindowInsetsListener { view, insets ->
                val safe = insets.getInsets(android.view.WindowInsets.Type.systemBars() or android.view.WindowInsets.Type.displayCutout())
                view.setPadding(safe.left, safe.top, safe.right, safe.bottom); insets
            }
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL; setPadding(dp(4), dp(8), dp(6), dp(2))
                addView(IconControl(context, IconControl.Icon.BACK, context.getString(R.string.files_back), Palette.text) { dismiss() }, LinearLayout.LayoutParams(dp(44), dp(48)))
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(title); addView(subtitle, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(2) })
                }, LinearLayout.LayoutParams(0, -2, 1f))
                addView(IconControl(context, IconControl.Icon.SEARCH, context.getString(R.string.files_find_in_file)) { find() }, LinearLayout.LayoutParams(dp(44), dp(48)))
                addView(IconControl(context, IconControl.Icon.MORE, context.getString(R.string.files_file_actions)) { host.actions(target, false, highlight, ::say) { dismiss() } }, LinearLayout.LayoutParams(dp(44), dp(48)))
            })
            addView(tabs, LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(12), dp(4), dp(12), dp(6)) })
            addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
            addView(notice, LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(12), dp(4), dp(12), 0) })
            addView(LinearLayout(context).apply {
                visibility = if (ProjectFiles.isVideo(name)) View.GONE else View.VISIBLE
                setPadding(dp(12), dp(8), dp(12), dp(12))
                addView(copy, LinearLayout.LayoutParams(0, dp(46), 1f).apply { marginEnd = dp(8) })
                addView(openMac, LinearLayout.LayoutParams(0, dp(46), 1.2f).apply { marginEnd = dp(8) })
                addView(quote, LinearLayout.LayoutParams(0, dp(46), 1.3f))
            })
        }
        dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).create().apply {
            setOnDismissListener { if (!closed) { closed = true; epoch++; imageTransfer?.cancel(); releaseHtml(); releaseVideo(); onClose() } }
        }
    }

    private fun action(text: String, primary: Boolean = false, click: () -> Unit) = Ui.label(context, text, Ui.LABEL, if (primary) Palette.onAccent else Palette.text).apply {
        typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER; maxLines = 1; isFocusable = true
        background = Ui.roundRect(context, if (primary) Palette.accent else Palette.surface2, 13)
        setOnClickListener { if (isEnabled) click() }
    }

    fun show() {
        host.remember(target)
        dialog.window?.protectControls(); dialog.show()
        // Set after show: an AlertDialog view wraps its height, while content set now fills the window.
        dialog.setContentView(root, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        dialog.window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(Palette.background))
            if (ProjectFiles.isImage(name)) setDecorFitsSystemWindows(false)
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }
        if (ProjectFiles.isImage(name)) root.requestApplyInsets()
        reload()
    }
    fun dismiss() { if (closed) return; closed = true; epoch++; imageTransfer?.cancel(); releaseHtml(); releaseVideo(); dialog.dismiss(); onClose() }
    private fun current(token: Int) = !closed && host.isCurrent() && epoch == token
    private fun say(text: String) { notice.text = text; notice.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE }

    private fun releaseHtml() {
        htmlPreview?.let { preview -> (preview.parent as? ViewGroup)?.removeView(preview); preview.release() }
        htmlPreview = null
    }

    private fun releaseVideo() { videoPreview?.release(); videoPreview = null }

    private fun reload() {
        releaseVideo()
        releaseHtml()
        imageTransfer?.cancel()
        epoch++; raw.setLength(0); version = ""; offset = 0; complete = false; error = ""; unavailable = ""; loading = false
        diffRows = null; diffState = ""; diffLoading = false; diffTruncated = false; untracked = false; image = null; imagePreview = null; lines = emptyList()
        if (ProjectFiles.isVideo(name)) {
            mode = "preview"
            videoPreview = VideoFilePreview(host, target)
            render()
        } else {
            load()
            if (status.isNotEmpty()) loadDiff()
        }
    }

    private fun load() {
        if (loading || closed) return
        val token = epoch; val expected = offset
        loading = true; render()
        val fields = JSONObject().put("path", target).put("offset", expected)
        if (version.isNotEmpty()) fields.put("version", version)
        host.call("readFile", fields) { result ->
            if (!current(token)) return@call
            loading = false
            if (!result.optBoolean("ok")) { error = result.optString("error", context.getString(R.string.files_could_not_read_retry)); render(); return@call }
            result.optString("rootPath").takeIf { it.isNotEmpty() }?.let { host.rootPath = it; host.remember(target) }
            target = result.optString("path", target); size = result.optLong("size", size)
            result.optString("status").takeIf { it.isNotEmpty() && status.isEmpty() }?.let { status = it; loadDiff() }
            unavailable = result.optString("unavailable")
            if (unavailable == "image") { loadImage(); render(); return@call }
            if (unavailable.isNotEmpty()) { render(); return@call }
            val chunk = result.optString("text"); val next = result.optInt("nextOffset", -2)
            val received = result.optString("version"); val bytes = chunk.toByteArray(Charsets.UTF_8).size
            if (received.isEmpty() || (version.isNotEmpty() && received != version) || next < -1 || (next >= 0 && next != expected + bytes) ||
                raw.length + chunk.length > 2 * 1024 * 1024) { error = context.getString(R.string.files_incomplete_file_response_reload); render(); return@call }
            version = received; raw.append(chunk); offset = if (next < 0) expected + bytes else next; complete = next == -1
            if (complete) { lines = raw.split('\n').let { if (it.size > 1 && it.last().isEmpty()) it.dropLast(1) else it }; render(); scrollToTarget() }
            else {
                render()
                // The source list is detached until all chunks arrive. Queue on the visible root;
                // posting to the list would wait for an attachment that itself requires this read.
                root.post { if (current(token)) load() }
            }
        }
    }

    private fun loadImage() {
        val token = epoch
        host.call("readImageFile", JSONObject().put("path", target).put("size", "large").put("binaryVersion", 1)) { result ->
            if (!current(token)) return@call
            val address = host.binaryHost()
            val transfer = BinaryFileClient { current(token) }.also { imageTransfer = it }
            mediaIO.execute {
                val bitmap = runCatching {
                    BinaryMediaClient.image(result, address, transfer)
                }.getOrNull()
                root.post {
                    result.optJSONObject("binary")?.optString("id")?.takeIf { it.isNotEmpty() }?.let { host.call("fileCancel", JSONObject().put("ticket", it)) {} }
                    if (!current(token)) return@post
                    image = bitmap
                    if (image == null) error = result.optString("error", context.getString(R.string.files_image_preview_unavailable))
                    render()
                }
            }
        }
    }

    private fun loadDiff() {
        if (diffLoading || diffRows != null) return
        val token = epoch; diffLoading = true
        host.call("fileDiff", JSONObject().put("path", target)) { result ->
            if (!current(token)) return@call
            diffLoading = false
            when {
                !result.optBoolean("ok") -> diffState = result.optString("error", context.getString(R.string.files_could_not_read_changes))
                !result.optBoolean("git", true) -> diffState = context.getString(R.string.files_this_project_is_not_a_git_repository)
                result.optBoolean("untracked") -> { untracked = true; diffRows = emptyList(); status = "A" }
                result.optBoolean("binary") -> diffState = context.getString(R.string.files_binary_file_changed_no_text_diff_available)
                else -> {
                    diffRows = ProjectFiles.diff(result.optString("diff")); added = result.optInt("added"); removed = result.optInt("removed")
                    diffTruncated = result.optBoolean("truncated")
                    if (diffRows!!.isEmpty()) diffState = context.getString(R.string.files_no_text_changes_compared_with_head)
                }
            }
            if (mode == "" || (mode == "source" && preferDiff)) mode = ""
            render()
        }
    }

    private fun modes(): List<Pair<String, String>> {
        val result = mutableListOf<Pair<String, String>>()
        if (ProjectFiles.isVideo(name) || ProjectFiles.isImage(name) || ProjectFiles.isMarkdown(name) || ProjectFiles.isHtml(name)) result.add("preview" to context.getString(R.string.files_preview))
        if (!ProjectFiles.isImage(name) && !ProjectFiles.isVideo(name)) result.add("source" to context.getString(R.string.files_source))
        if (status.isNotEmpty() || diffRows != null) result.add("diff" to when {
            untracked -> context.getString(R.string.files_changes_new_file)
            diffRows != null && (added > 0 || removed > 0) -> context.getString(R.string.files_changes_1_2 ,added, removed)
            else -> context.getString(R.string.files_changes)
        })
        return result
    }

    private fun render() {
        val available = modes()
        if (mode.isEmpty() || available.none { it.first == mode }) mode = when {
            preferDiff && available.any { it.first == "diff" } -> "diff"
            else -> available.first().first
        }
        tabs.removeAllViews()
        available.forEach { (id, label) ->
            val selected = id == mode
            tabs.addView(Ui.label(context, label, Ui.LABEL, if (selected) Palette.accent else Palette.muted).apply {
                typeface = if (selected) Typeface.DEFAULT_BOLD else Ui.medium; gravity = Gravity.CENTER; isFocusable = true
                background = Ui.inset(context, Ui.roundRect(context, if (selected) Palette.accentContainer else Palette.surface1, 10), 7)
                setPadding(dp(14), 0, dp(14), 0); minimumHeight = dp(48)
                contentDescription = if (selected) context.getString(R.string.files_1_selected ,label) else context.getString(R.string.files_switch_to_1 ,label)
                setOnClickListener { if (!selected) { mode = id; render(); if (id == "source") scrollToTarget() } }
            }, LinearLayout.LayoutParams(-2, dp(48)).apply { marginEnd = dp(6) })
        }
        val parts = mutableListOf(target.substringBeforeLast('/', context.getString(R.string.files_project_root)))
        if (size > 0) parts.add(ProjectFiles.size(size))
        if (complete) parts.add(context.resources.getQuantityString(R.plurals.files_1_lines, lines.size, lines.size))
        when (status) { "A" -> parts.add(context.getString(R.string.files_added)); "M" -> parts.add(context.getString(R.string.files_modified)); "D" -> parts.add(context.getString(R.string.files_deleted)) }
        subtitle.text = parts.joinToString(" · ")
        content.removeAllViews()
        htmlPreview?.onPause()
        when {
            mode == "preview" && ProjectFiles.isVideo(name) -> videoPreview?.let {
                (it.parent as? ViewGroup)?.removeView(it)
                content.addView(it, FrameLayout.LayoutParams(-1, -1))
            }
            mode == "diff" -> when {
                untracked && complete -> showLines(added = true)
                untracked -> state(context.getString(R.string.files_reading_from_mac), error)
                diffRows == null -> state(if (diffState.isEmpty()) context.getString(R.string.files_loading_changes) else diffState, "")
                diffRows!!.isEmpty() -> state(diffState.ifEmpty { context.getString(R.string.files_no_changes) }, "")
                else -> { adapter.diff(diffRows!!); attachList() }
            }
            unavailable == "tooLarge" -> state(context.getString(R.string.files_file_too_large), context.getString(R.string.files_1_exceeds_the_2_mb_preview_limit_open_it_on_the_mac_to_view ,ProjectFiles.size(size)))
            unavailable == "binary" -> state(context.getString(R.string.files_preview_unavailable), context.getString(R.string.files_this_is_a_binary_file_copy_its_path_or_show_it_in_finder))
            mode == "preview" && ProjectFiles.isImage(name) -> image?.let { bitmap ->
                val preview = imagePreview ?: ZoomableImagePreview(context, bitmap).apply {
                    contentDescription = context.getString(R.string.image_named_zoom_description, name)
                }.also { imagePreview = it }
                content.addView(preview, FrameLayout.LayoutParams(-1, -1))
            } ?: state(if (error.isNotEmpty()) context.getString(R.string.files_image_preview_unavailable) else context.getString(R.string.files_loading_image), error)
            error.isNotEmpty() -> state(context.getString(R.string.files_could_not_read), error, retry = true)
            !complete -> state(context.getString(R.string.files_reading_from_mac), if (offset > 0) context.getString(R.string.files_received_1 ,ProjectFiles.size(offset.toLong())) else "")
            mode == "preview" && ProjectFiles.isHtml(name) -> {
                try {
                    val preview = htmlPreview ?: HtmlFilePreview(context, raw.toString()).also { htmlPreview = it }
                    content.addView(preview, FrameLayout.LayoutParams(-1, -1))
                    preview.onResume()
                } catch (_: Exception) {
                    releaseHtml()
                    state(context.getString(R.string.files_preview_unavailable), context.getString(R.string.files_html_preview_unavailable))
                }
            }
            mode == "preview" -> content.addView(ScrollView(context).apply {
                addView(ChatMarkdownView(context).apply { render(raw.substring(0, minOf(raw.length, 60_000)), 0, 120); setPadding(dp(16), dp(4), dp(16), dp(24)) })
            })

            else -> showLines(added = false)
        }
        if (diffTruncated && mode == "diff") say(context.getString(R.string.files_large_diff_showing_the_first_128_kb)) else if (notice.text.startsWith(context.getString(R.string.files_large_diff))) say("")
        refreshBar()
    }

    private fun showLines(added: Boolean) { adapter.source(lines, ProjectFiles.extension(name), added); attachList() }
    private fun attachList() { (list.parent as? ViewGroup)?.removeView(list); content.addView(list, FrameLayout.LayoutParams(-1, -1)); adapter.notifyDataSetChanged() }

    private fun state(heading: String, detail: String, retry: Boolean = false) {
        content.addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(16), dp(16), dp(16))
            background = Ui.inset(context, Ui.roundRect(context, Palette.surface1, 14), dp(0))
            addView(Ui.label(context, heading, Ui.BODY).apply { typeface = Typeface.DEFAULT_BOLD })
            if (detail.isNotEmpty()) addView(Ui.label(context, detail, Ui.LABEL, Palette.muted), LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4) })
            if (retry) addView(Ui.button(context, context.getString(R.string.files_retry), Ui.Button.TEXT) { reload() }.apply { gravity = Gravity.START or Gravity.CENTER_VERTICAL })
        }, FrameLayout.LayoutParams(-1, -2).apply { setMargins(dp(12), dp(8), dp(12), 0) })
    }

    private fun refreshBar() {
        copy.isEnabled = complete && raw.isNotEmpty(); copy.alpha = if (copy.isEnabled) 1f else .4f
        quote.isEnabled = host.canQuote(); quote.alpha = if (quote.isEnabled) 1f else .4f
        quote.text = if (highlight != null) context.getString(R.string.files_quote_line_1 ,highlight) else context.getString(R.string.files_quote_in_reply)
    }

    private fun scrollToTarget() {
        val wanted = highlight ?: return
        if (mode != "source" || lines.isEmpty()) return
        list.post { list.setSelectionFromTop((wanted - 1).coerceIn(0, lines.lastIndex), dp(96)) }
    }

    private fun copyAll() {
        if (raw.length > 200_000) { say(context.getString(R.string.files_file_too_large_to_copy_here_copy_it_on_the_mac)); return }
        try {
            (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText(name, raw.toString()))
            say(context.getString(R.string.files_full_text_copied))
        } catch (_: Exception) { say(context.getString(R.string.files_could_not_write_to_clipboard)) }
    }

    /** Jumps to the next line holding the query, after the highlighted one. */
    private fun find() {
        if (!complete || lines.isEmpty()) return
        val field = EditText(context).apply {
            hint = context.getString(R.string.files_find_text); isSingleLine = true; setTextColor(Palette.text); setHintTextColor(Palette.faint)
            background = Ui.roundRect(context, Palette.surface3, 12); setPadding(dp(14), dp(12), dp(14), dp(12))
        }
        val box = LinearLayout(context).apply { setPadding(dp(20), dp(8), dp(20), 0); addView(field, LinearLayout.LayoutParams(-1, -2)) }
        val dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).setTitle(context.getString(R.string.files_find_in_1 ,name)).setView(box)
            .setPositiveButton(context.getString(R.string.files_find_next), null).setNegativeButton(context.getString(R.string.files_close), null).showProtected()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val query = field.text.toString(); if (query.isEmpty()) return@setOnClickListener
            val start = highlight ?: 0
            val index = (lines.indices.map { (start + it) % lines.size }).firstOrNull { lines[it].contains(query, ignoreCase = true) }
            if (index == null) { field.error = context.getString(R.string.files_no_matches); return@setOnClickListener }
            highlight = index + 1; mode = "source"; render(); scrollToTarget()
        }
    }

    /** Source lines or diff rows for the recycled list. */
    private inner class Rows : BaseAdapter() {
        private var source: List<String> = emptyList(); private var ext = ""; private var allAdded = false
        private var rows: List<ProjectFiles.DiffLine>? = null
        private var gutter = 0
        fun source(lines: List<String>, ext: String, added: Boolean) { source = lines; this.ext = ext; allAdded = added; rows = null; gutter = gutterFor(lines.size) }
        fun diff(rows: List<ProjectFiles.DiffLine>) { this.rows = rows; ext = ProjectFiles.extension(name); gutter = gutterFor(rows.maxOfOrNull { it.new ?: it.old ?: 0 } ?: 0) }
        private fun gutterFor(count: Int) = dp(14) + (count.toString().length * 7.4f * context.resources.displayMetrics.scaledDensity).toInt()
        fun number(position: Int): Int? = rows?.getOrNull(position)?.let { it.new } ?: if (rows == null) position + 1 else null
        override fun getCount() = rows?.size ?: source.size
        override fun getItem(position: Int): Any = rows?.get(position) ?: source[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getView(position: Int, recycled: View?, parent: ViewGroup): View {
            val view = recycled as? CodeLineView ?: CodeLineView(context)
            val diff = rows
            if (diff == null) {
                val number = position + 1
                val tint = when { number == highlight -> 0x1FE8B86F; allAdded -> 0x17_72D4B9; else -> 0 }
                view.bind(number.toString(), colour(source[position]), tint, if (allAdded) Palette.accent else 0xFF4A575D.toInt(), gutter)
            } else {
                val row = diff[position]
                when (row.kind) {
                    ProjectFiles.Row.HUNK, ProjectFiles.Row.NOTE -> view.bind("", row.text, Palette.surface1, Palette.faint, gutter, plain = true)
                    ProjectFiles.Row.ADD -> view.bind(row.new.toString(), colour("+ " + row.text, 2), if (row.new == highlight) 0x2FE8B86F else 0x17_72D4B9, Palette.accent, gutter)
                    ProjectFiles.Row.DEL -> view.bind(row.old.toString(), colour("− " + row.text, 2), 0x17_E8837C, Palette.red, gutter)
                    ProjectFiles.Row.CONTEXT -> view.bind(row.new.toString(), colour("  " + row.text, 2), 0, 0xFF4A575D.toInt(), gutter)
                }
            }
            return view
        }
        private fun colour(line: String, skip: Int = 0): CharSequence {
            val tokens = ProjectFiles.highlight(line.substring(skip), ext)
            if (tokens.isEmpty()) return line
            return SpannableString(line).apply {
                tokens.forEach { token ->
                    val color = when (token.tone) {
                        ProjectFiles.Tone.KEYWORD -> 0xFFB7A2EE.toInt(); ProjectFiles.Tone.STRING -> 0xFFE8B86F.toInt()
                        ProjectFiles.Tone.COMMENT -> 0xFF66747A.toInt(); ProjectFiles.Tone.NUMBER -> 0xFF86B4EE.toInt()
                        ProjectFiles.Tone.TYPE -> Palette.accent
                    }
                    setSpan(ForegroundColorSpan(color), token.start + skip, token.end + skip, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            }
        }
    }
}
