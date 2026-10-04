package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.session.ReplyPartGrouping
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.features.markdown.ChatMarkdownView
import io.github.junweiup.vibepier.remote.features.markdown.MarkdownFileLinks
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.content.Context
import android.graphics.Typeface
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import org.json.JSONArray
import org.json.JSONObject

/** Desktop order: paragraphs, individual commands, more paragraphs. Only a tapped step reads its output. */
@android.annotation.SuppressLint("ViewConstructor") // Created in code with required model/callback arguments, never XML-inflated.
internal class InlineReplyProcess(
    context: Context, private val state: State, private val canLoad: () -> Boolean,
    private val headers: (Int, Int?, (JSONObject) -> Unit) -> Unit,
    private val output: (String, Int, (JSONObject) -> Unit) -> Unit,
    private val images: (JSONArray) -> View,
    private val openMarkdown: ((MarkdownFileLinks.Link) -> Unit)? = null,
) : LinearLayout(context) {
    class Body {
        var expanded = false; var loaded = false; var loading = false
        var text = ""; var nextOffset = 0; var error = ""; var request = 0
    }
    class State {
        var epoch = 0; var count = 0; var loading = false; var error = ""
        var retryOffset = 0; var retryBefore: Int? = null
        val rows = linkedMapOf<String, JSONObject>()
        val bodies = linkedMapOf<String, Body>()
        val groups = linkedMapOf<String, Boolean>()
        var persist: (JSONObject) -> Unit = {}
        fun snapshot() = JSONObject().put("count", count).put("rows", JSONArray(rows.values.toList())).put("groups", JSONObject(groups))
            .put("bodies", JSONObject().apply { bodies.forEach { (id, body) -> put(id, JSONObject().put("expanded", body.expanded).put("loaded", body.loaded).put("text", body.text).put("nextOffset", body.nextOffset)) } })
        fun restore(value: JSONObject) {
            accept(value.optJSONArray("rows") ?: JSONArray(), value.optInt("count"))
            value.optJSONObject("bodies")?.let { saved -> saved.keys().forEach { id ->
                val item = saved.getJSONObject(id); bodies[id]?.apply { expanded = item.optBoolean("expanded"); loaded = item.optBoolean("loaded"); text = item.optString("text"); nextOffset = item.optInt("nextOffset") }
            } }
            value.optJSONObject("groups")?.let { saved -> saved.keys().forEach { groups[it] = saved.optBoolean(it) } }
        }
        private val listeners = mutableSetOf<() -> Unit>()
        fun listen(listener: () -> Unit) { listeners.add(listener) }
        fun unlisten(listener: () -> Unit) { listeners.remove(listener) }
        fun changed() { persist(snapshot()); listeners.toList().forEach { it() } }
        fun pause() { epoch++; loading = false; bodies.values.forEach { it.loading = false } }
        fun accept(entries: JSONArray, count: Int) {
            this.count = count
            val incoming = (0 until entries.length()).map { entries.getJSONObject(it) }
            val indices = incoming.map { it.optInt("index") }.toSet(); val ids = incoming.map { it.optString("id") }.toSet()
            rows.keys.toList().filter { rows.getValue(it).optInt("index") >= count || (rows.getValue(it).optInt("index") in indices && it !in ids) }.forEach { rows.remove(it); bodies.remove(it) }
            for (i in 0 until entries.length()) {
                val row = entries.getJSONObject(i); val id = row.optString("id"); val old = rows[id]
                val body = bodies.getOrPut(id) { Body() }
                if (row.optString("kind") in setOf("text", "plan")) {
                    if (!body.loaded || old?.optString("bodyVersion") != row.optString("bodyVersion")) {
                        body.request++; body.loading = false; body.loaded = true; body.text = row.optString("text")
                        body.nextOffset = if (row.optBoolean("hasMore")) row.optInt("nextOffset") else -1; body.error = ""
                    }
                } else if (old != null && old.optString("bodyVersion") != row.optString("bodyVersion") && !(old.optString("status") == "running" && row.optString("status") == "running")) {
                    body.request++; body.loading = false; body.loaded = false; body.text = ""; body.nextOffset = 0; body.error = ""
                }
                if (old?.optString("bodyVersion") == row.optString("bodyVersion")) for (key in listOf("title", "cwd", "description")) {
                    if (old.optString(key).length > row.optString(key).length) row.put(key, old.get(key))
                }
                rows[id] = row
            }
        }
        fun ordered() = rows.values.sortedBy { it.optInt("index") }
    }
    private val observer: () -> Unit = { render(); post { ensureOpened() } }
    init { orientation = VERTICAL; render() }
    override fun onAttachedToWindow() { super.onAttachedToWindow(); state.listen(observer); observer() }
    override fun onDetachedFromWindow() { state.unlisten(observer); super.onDetachedFromWindow() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun column() = LinearLayout(context).apply { orientation = VERTICAL }
    private fun label(text: CharSequence, size: Float = 13f, color: Int = Palette.muted) = Ui.label(context, text.toString(), size, color).apply { this.text = text }
    private fun action(text: String, run: () -> Unit): View = label(text, 13f, Palette.green).apply {
        minimumHeight = dp(48); gravity = Gravity.CENTER_VERTICAL; isFocusable = true; setOnClickListener { run() }
    }
    private fun ensureOpened() {
        if (!isAttachedToWindow || !canLoad()) return
        for (row in visibleRows()) {
            val body = state.bodies[row.optString("id")] ?: continue
            if (body.expanded && !body.loaded && !body.loading && body.error.isEmpty()) loadOutput(row, body)
        }
    }
    private fun entry(row: JSONObject) = ReplyPartGrouping.Entry(row.optString("id"), row.optInt("index"), row.optString("kind"), row.optString("title"), row.optString("toolName"), row.optString("groupType"), row.optString("status"))
    /** A semantic operation shares only its immediately adjacent entries. */
    private fun runs(): List<List<JSONObject>> {
        val rows = state.ordered()
        return ReplyPartGrouping.runs(rows.map(::entry)).map { run -> run.map { rows[it] } }
    }
    private fun groupOpen(run: List<JSONObject>) = ReplyPartGrouping.expanded(run.map(::entry), state.groups,
        run.filter { state.bodies[it.optString("id")]?.expanded == true }.map { it.optString("id") }.toSet())
    private fun visibleRows() = runs().flatMap { if (it.size > 1 && !groupOpen(it)) emptyList() else it }
    /** Called by the conversation's upward scroll/pull, before fetching an earlier whole turn. */
    fun hasEarlier() = (state.ordered().firstOrNull()?.optInt("index") ?: 0) > 0
    /** A streamed update keeps this view and its expanded bodies/groups in place. */
    fun accept(sequence: JSONArray, count: Int) { state.accept(sequence, count); state.changed() }
    fun loadEarlier(): Boolean {
        val first = state.ordered().firstOrNull()?.optInt("index") ?: return false
        if (first <= 0) return false
        if (!state.loading && canLoad()) loadSequence(maxOf(0, first - 8), first)
        return true
    }
    private fun render() {
        removeAllViews()
        var previous = -1
        for (run in runs()) {
            val row = run.first()
            val index = row.optInt("index")
            if (index > previous + 1) {
                val start = previous + 1; val end = index
                addView(action(if (start == 0) context.getString(R.string.earlier_content) else resources.getQuantityString(R.plurals.expand_middle_segments, end - start, end - start)) { loadSequence(maxOf(start, end - 8), end) }, LayoutParams(-1, -2))
            }
            if (run.size > 1) {
                val entries = run.map(::entry); val expanded = groupOpen(run)
                val title = ReplyPartLabels.title(context, entries)
                val mark = ReplyPartLabels.statusLabels(context, entries).joinToString("") { " · ${it.first}" }
                addView(action("${if (expanded) "▾" else "▸"} $title$mark") {
                    ReplyPartGrouping.remember(entries, state.groups, !expanded)
                    // Older caches could remember an open child inside an explicitly closed group.
                    run.forEach { state.bodies[it.optString("id")]?.expanded = false }
                    state.changed()
                }, LayoutParams(-1, -2))
                if (expanded) run.forEach { addView(step(it), LayoutParams(-1, -2)) }
                else {
                    val previews = JSONArray()
                    run.forEach { item -> item.optJSONArray("images")?.let { pictures ->
                        for (i in 0 until pictures.length()) previews.put(pictures.getJSONObject(i))
                    } }
                    if (previews.length() > 0) addView(images(previews), LayoutParams(-1, -2).apply { topMargin = dp(8); bottomMargin = dp(8) })
                }
            } else {
                val prose = row.optString("kind") in setOf("text", "plan")
                addView(if (prose) paragraph(row) else step(row), LayoutParams(-1, -2).apply { topMargin = dp(if (prose) 8 else 4); bottomMargin = dp(if (prose) 8 else 2) })
            }
            previous = run.last().optInt("index")
        }
        if (previous + 1 < state.count) addView(action(context.getString(R.string.continue_content)) { loadSequence(previous + 1, null) }, LayoutParams(-1, -2))
        if (state.loading) addView(label(context.getString(R.string.content_loading)))
        else if (state.error.isNotEmpty()) addView(action(context.getString(R.string.retry_error, state.error)) { loadSequence(state.retryOffset, state.retryBefore) })
    }
    private fun paragraph(row: JSONObject): View = column().apply {
        val body = state.bodies.getValue(row.optString("id"))
        addView(ChatMarkdownView(context, openMarkdown, anyFile = true).apply { render(body.text) }, LayoutParams(-1, -2))
        row.optJSONArray("images")?.takeIf { it.length() > 0 }?.let { addView(images(it), LayoutParams(-1, -2)) }
        addBodyFooter(row, body)
    }
    private fun LinearLayout.addBodyFooter(row: JSONObject, body: Body) {
        if (body.loading) addView(label(context.getString(R.string.content_loading)))
        else if (body.error.isNotEmpty()) addView(action(context.getString(R.string.retry_error, body.error)) { loadOutput(row, body) })
        else if (body.loaded && body.nextOffset >= 0) addView(action(if (row.optString("kind") in setOf("text", "plan")) context.getString(R.string.continue_reading) else context.getString(R.string.continue_output)) { loadOutput(row, body) })
    }
    private fun step(row: JSONObject): View {
        val id = row.optString("id"); val kind = row.optString("kind"); val body = state.bodies.getValue(id)
        val title = row.optString("title").ifBlank { when (kind) { "thinking" -> context.getString(R.string.thinking); "file" -> context.getString(R.string.file_changes); else -> context.getString(R.string.tool_call) } }
        val status = row.optString("status")
        val mark = when (status) { "running" -> context.getString(R.string.running); "failed" -> context.getString(R.string.failed); "declined" -> context.getString(R.string.not_run); "completed" -> "✓"; else -> "" }
        return column().apply {
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL; minimumHeight = dp(48); isFocusable = true
                contentDescription = if (mark.isNotEmpty()) context.getString(R.string.step_description, title, mark, context.getString(if (body.expanded) R.string.collapse else R.string.expand_content)) else context.getString(R.string.step_description_no_status, title, context.getString(if (body.expanded) R.string.collapse else R.string.expand_content))
                addView(label(if (kind == "command") "$" else if (kind == "thinking") "✻" else "›", 12f), LayoutParams(dp(22), -2))
                addView(label(title, 13f, Palette.text).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END; if (kind == "command") typeface = Typeface.MONOSPACE }, LayoutParams(0, -2, 1f))
                if (mark.isNotEmpty()) addView(label(mark, 11f, when (status) { "running" -> Palette.amber; "failed" -> Palette.red; else -> Palette.faint }), LayoutParams(-2, -2).apply { marginStart = dp(8) })
                addView(label(if (body.expanded) "▾" else "▸"), LayoutParams(dp(28), -2).apply { marginStart = dp(8) })
                setOnClickListener {
                    body.expanded = !body.expanded
                    if (body.expanded && status == "running" && !body.loading) { body.request++; body.loaded = false; body.text = ""; body.nextOffset = 0 }
                    body.error = if (body.expanded && !body.loaded && !canLoad()) context.getString(R.string.connect_to_read) else ""
                    state.changed()
                }
            }, LayoutParams(-1, -2))
            if (body.expanded) addView(column().apply {
                setPadding(dp(22), 0, dp(8), dp(8))
                if (kind == "file" && openMarkdown != null) {
                    val files = row.optJSONArray("files") ?: JSONArray()
                    for (index in 0 until files.length()) {
                        val path = files.getJSONObject(index).optString("path")
                        MarkdownFileLinks.parseTarget(path, anyFile = true)?.let { link ->
                            addView(Ui.button(context, context.getString(R.string.view_reference, link.label), Ui.Button.TEXT) { openMarkdown.invoke(link) }, LayoutParams(-1, -2))
                        }
                    }
                }
                if (kind == "command") addView(label(title, 12f, Palette.text).apply { typeface = Typeface.MONOSPACE }, LayoutParams(-1, -2).apply { bottomMargin = dp(6) })
                row.optString("cwd").takeIf { it.isNotEmpty() }?.let { addView(label(it, 11f, Palette.faint), LayoutParams(-1, -2).apply { bottomMargin = dp(6) }) }
                row.optString("description").takeIf { it.isNotEmpty() }?.let { addView(label(it, 12f, Palette.muted)) }
                if (body.loaded) {
                    if (kind == "thinking") addView(ChatMarkdownView(context, openMarkdown, anyFile = true).apply { render(body.text) }, LayoutParams(-1, -2))
                    else if (body.text.isNotEmpty() || (row.optJSONArray("images")?.length() ?: 0) == 0) addView(label(ReplyTextStyle.styled(kind, body.text.ifEmpty { if (status == "running") context.getString(R.string.awaiting_output) else context.getString(R.string.no_output) }), 12f, Palette.text).apply { typeface = Typeface.MONOSPACE }, LayoutParams(-1, -2))
                }
                addBodyFooter(row, body)
            }, LayoutParams(-1, -2))
            // A visible image is the result, while command output and other details remain on demand.
            row.optJSONArray("images")?.takeIf { it.length() > 0 }?.let {
                addView(images(it), LayoutParams(-1, -2).apply { topMargin = dp(8); bottomMargin = dp(8) })
            }
        }
    }
    private fun loadSequence(offset: Int, before: Int?) {
        if (state.loading || !canLoad()) return
        var ancestor = parent
        while (ancestor != null && ancestor !is android.widget.ScrollView) ancestor = ancestor.parent
        val scrolling = ancestor as? android.widget.ScrollView
        val epoch = state.epoch; state.loading = true; state.error = ""; state.retryOffset = offset; state.retryBefore = before; state.changed()
        headers(offset, before) { result ->
            if (epoch != state.epoch) return@headers
            // Capture at receipt time: the user can keep scrolling while the request is in flight.
            val anchor = if (before != null && result.optBoolean("ok")) scrolling?.scrollY?.let { it to height } else null
            state.loading = false
            if (result.optBoolean("ok")) state.accept(result.optJSONArray("parts") ?: JSONArray(), result.optInt("partCount", state.count))
            else state.error = result.optString("error", context.getString(R.string.content_read_failed))
            state.changed()
            if (anchor != null && isAttachedToWindow && scrolling != null) {
                val observer = scrolling.viewTreeObserver
                observer.addOnPreDrawListener(object : android.view.ViewTreeObserver.OnPreDrawListener {
                    override fun onPreDraw(): Boolean {
                        if (observer.isAlive) observer.removeOnPreDrawListener(this)
                        if (epoch == state.epoch && isAttachedToWindow)
                            scrolling.scrollTo(0, (anchor.first + height - anchor.second).coerceAtLeast(0))
                        return true
                    }
                })
            }
        }
    }
    private fun loadOutput(row: JSONObject, body: Body) {
        if (body.loading || !canLoad() || (body.loaded && body.nextOffset < 0)) return
        val epoch = state.epoch; val request = ++body.request; val offset = if (body.loaded) body.nextOffset else 0
        body.loading = true; body.error = ""; state.changed()
        output(row.optString("id"), offset) { result ->
            if (epoch != state.epoch || request != body.request) return@output
            body.loading = false
            if (result.optBoolean("ok")) {
                body.text = (if (offset == 0) "" else body.text) + result.optString("text"); body.loaded = true
                result.optJSONObject("part")?.let { detail -> val current = state.rows[row.optString("id")]!!; detail.keys().forEach { key -> current.put(key, detail.get(key)) } }
                val next = result.optInt("nextOffset", -1); body.nextOffset = if (next > offset) next else -1
            } else body.error = result.optString("error", context.getString(R.string.content_read_failed))
            state.changed()
        }
    }
}
