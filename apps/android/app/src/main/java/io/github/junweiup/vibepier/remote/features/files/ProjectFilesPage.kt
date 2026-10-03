package io.github.junweiup.vibepier.remote.features.files

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.IconControl
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.protectControls
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.app.AlertDialog
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import org.json.JSONArray
import org.json.JSONObject

/**
 * The open session's workspace as a tree: folders expand in place, the breadcrumb climbs back, and the tabs switch to
 * the files this turn changed or the ones opened recently. Typing searches file names across the project.
 */
internal class ProjectFilesPage(
    private val host: ProjectFileHost, private var changes: JSONObject?, initialMode: String = "all",
    private val onChanges: (JSONObject) -> Unit = {}, private val onClose: () -> Unit = {},
) {
    private val context = host.context
    private val ui = Handler(Looper.getMainLooper())
    private fun dp(value: Int) = host.dp(value)
    private var mode = initialMode
    private var base = ""
    private var query = ""
    private var searchWork: Runnable? = null
    private var searchResults: JSONObject? = null
    private var searching = false
    private val folders = mutableMapOf<String, JSONObject>()
    private val loadingFolders = mutableSetOf<String>()
    private val expanded = mutableSetOf<String>()
    private var error = ""
    private var closed = false
    private var viewer: ProjectFileViewer? = null
    private val title = Ui.label(context, context.getString(R.string.files_project_files), 20f).apply { typeface = Typeface.DEFAULT_BOLD; maxLines = 1; ellipsize = TextUtils.TruncateAt.END }
    private val subtitle = Ui.label(context, "", Ui.CAPTION, Palette.muted).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.START }
    private val tabs = LinearLayout(context)
    private val crumb = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
    private val list = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val scroll = ScrollView(context).apply { addView(list); clipToPadding = false; setPadding(0, 0, 0, Ui.dp(context, 24)) }
    private val footer = Ui.label(context, "", Ui.CAPTION, Palette.faint).apply { gravity = Gravity.CENTER }
    private val field = EditText(context).apply {
        hint = context.getString(R.string.files_search_file_names_across_the_project); textSize = Ui.BODY; setTextColor(Palette.text); setHintTextColor(Palette.faint)
        setSingleLine(); inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS; background = null
        setPadding(dp(4), 0, dp(12), 0); gravity = Gravity.CENTER_VERTICAL
    }
    private val root: LinearLayout
    val dialog: AlertDialog

    init {
        root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; setBackgroundColor(Palette.background)
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL; setPadding(dp(4), dp(8), dp(10), dp(2))
                addView(IconControl(context, IconControl.Icon.BACK, context.getString(R.string.files_back_to_session), Palette.text) { dismiss() }, LinearLayout.LayoutParams(dp(44), dp(48)))
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(title); addView(subtitle, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(1) })
                }, LinearLayout.LayoutParams(0, -2, 1f))
                addView(IconControl(context, IconControl.Icon.REFRESH, context.getString(R.string.files_refresh)) { refresh() }.apply { background = Ui.roundRect(context, Palette.surface1, 12) },
                    LinearLayout.LayoutParams(dp(44), dp(44)))
            })
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL; background = Ui.roundRect(context, Palette.surface1, 12)
                addView(IconControl(context, IconControl.Icon.SEARCH, context.getString(R.string.files_search), Palette.faint) { field.requestFocus() }.apply {
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO; minimumHeight = 0; minimumWidth = 0
                }, LinearLayout.LayoutParams(dp(40), dp(44)))
                addView(field, LinearLayout.LayoutParams(0, dp(44), 1f))
            }, LinearLayout.LayoutParams(-1, dp(44)).apply { setMargins(dp(14), dp(8), dp(14), 0) })
            addView(tabs, LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(12), dp(4), dp(12), 0) })
            addView(crumb, LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(16), 0, dp(12), 0) })
            addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f).apply { setMargins(dp(8), 0, dp(8), 0) })
            addView(footer, LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(16), dp(4), dp(16), dp(14)) })
        }
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                query = s?.toString()?.trim() ?: ""
                searchWork?.let(ui::removeCallbacks)
                if (query.isEmpty()) { searchResults = null; searching = false; render(); return }
                searchWork = Runnable { search() }.also { ui.postDelayed(it, 300) }
            }
        })
        dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).create().apply {
            setOnDismissListener { if (!closed) { closed = true; searchWork?.let(ui::removeCallbacks); viewer?.dismiss(); onClose() } }
        }
    }

    fun show() {
        dialog.window?.protectControls(); dialog.show()
        // Set after show: an AlertDialog view wraps its height, while content set now fills the window.
        dialog.setContentView(root, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        dialog.window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(Palette.background))
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN)
        }
        render(); load(""); loadChanges()
    }
    fun dismiss() { if (!closed) dialog.dismiss() }
    private fun say(text: String) { footer.text = text }

    private fun refresh() { folders.clear(); loadingFolders.clear(); error = ""; load(base); expanded.forEach(::load); loadChanges(); if (query.isNotEmpty()) search() }

    private fun load(folder: String) {
        if (folder in loadingFolders || closed) return
        loadingFolders.add(folder); render()
        host.call("browseFiles", JSONObject().put("folder", folder)) { result ->
            loadingFolders.remove(folder)
            if (closed) return@call
            if (!result.optBoolean("ok")) { if (folder == base) error = result.optString("error", context.getString(R.string.files_could_not_read_directory)) ; expanded.remove(folder); render(); return@call }
            error = ""
            folders[result.optString("folder", folder)] = result
            if (result.has("rootPath")) host.rootPath = result.optString("rootPath")
            header(result)
            render()
        }
    }

    private fun loadChanges() {
        host.call("fileChanges", JSONObject()) { result ->
            if (closed || !result.optBoolean("ok")) return@call
            changes = result; onChanges(result); header(result); render()
        }
    }

    private fun search() {
        val wanted = query; searching = true; render()
        host.call("searchFiles", JSONObject().put("query", wanted)) { result ->
            if (closed || wanted != query) return@call
            searching = false
            searchResults = if (result.optBoolean("ok")) result else JSONObject().put("error", result.optString("error", context.getString(R.string.files_search_failed)))
            render()
        }
    }

    private fun header(result: JSONObject) {
        result.optString("root").takeIf { it.isNotEmpty() }?.let { title.text = it }
        val branch = result.optString("branch")
        val path = result.optString("rootPath").replace(Regex("^" + "/Users" + "/[^/]+"), "~")
        if (path.isNotEmpty() || branch.isNotEmpty()) subtitle.text = listOf(branch, path).filter(String::isNotEmpty).joinToString(" · ")
    }

    private fun render() {
        if (closed) return
        val changed = changes?.optJSONArray("files")?.length() ?: 0
        tabs.removeAllViews()
        tabs.addView(Ui.segmented(context, listOf("all" to context.getString(R.string.files_all), "changes" to if (changed > 0) context.getString(R.string.files_turn_changes_1 ,changed) else context.getString(R.string.files_turn_changes), "recent" to context.getString(R.string.files_recent)),
            mode, context.getString(R.string.files_files), Ui.LABEL, 40) { mode = it; render() }, LinearLayout.LayoutParams(-1, -2))
        tabs.visibility = if (query.isEmpty()) View.VISIBLE else View.GONE
        renderCrumb()
        list.removeAllViews()
        when {
            query.isNotEmpty() -> renderSearch()
            mode == "changes" -> renderChanges()
            mode == "recent" -> renderRecent()
            else -> renderTree()
        }
    }

    private fun renderCrumb() {
        crumb.removeAllViews()
        if (query.isNotEmpty() || mode != "all") { crumb.visibility = View.GONE; return }
        crumb.visibility = View.VISIBLE
        val parts = listOf("" to title.text.toString()) + base.split('/').filter(String::isNotEmpty).runningFold("") { path, part -> if (path.isEmpty()) part else "$path/$part" }.drop(1).map { it to it.substringAfterLast('/') }
        val row = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
        parts.forEachIndexed { index, (path, label) ->
            if (index > 0) row.addView(Ui.label(context, "›", Ui.LABEL, Palette.faint), LinearLayout.LayoutParams(-2, -2).apply { setMargins(dp(4), 0, dp(4), 0) })
            val last = index == parts.lastIndex
            row.addView(Ui.label(context, label, Ui.LABEL, if (last) Palette.text else Palette.muted).apply {
                typeface = if (last) Typeface.DEFAULT_BOLD else Typeface.DEFAULT; maxLines = 1; minimumHeight = dp(40); gravity = Gravity.CENTER_VERTICAL
                if (!last) { isFocusable = true; contentDescription = context.getString(R.string.files_back_to_1 ,label); setOnClickListener { base = path; render(); if (path !in folders) load(path) } }
            })
        }
        crumb.addView(android.widget.HorizontalScrollView(context).apply { isHorizontalScrollBarEnabled = false; addView(row) }, LinearLayout.LayoutParams(-1, -2))
    }

    private fun renderTree() {
        val listing = folders[base]
        when {
            error.isNotEmpty() && listing == null -> card(context.getString(R.string.files_could_not_read_directory), error, retry = true)
            listing == null -> card(context.getString(R.string.files_loading_directory), "")
            else -> {
                addEntries(base, 0)
                val count = listing.optJSONArray("entries")?.length() ?: 0
                say(context.resources.getQuantityString(R.plurals.files_read_only_dotfiles_hidden_1_entries, count, count) + if (listing.optBoolean("truncated")) context.getString(R.string.files_showing_the_first_200_entries) else "")
            }
        }
    }

    private fun addEntries(folder: String, depth: Int) {
        val entries = folders[folder]?.optJSONArray("entries") ?: JSONArray()
        if (entries.length() == 0 && depth > 0) list.addView(Ui.label(context, context.getString(R.string.files_empty_folder), Ui.CAPTION, Palette.faint).apply { setPadding(dp(18 + depth * 18), dp(8), 0, dp(8)) })
        for (index in 0 until entries.length()) {
            val entry = entries.getJSONObject(index)
            val path = entry.optString("path"); val directory = entry.optBoolean("directory")
            list.addView(row(entry, depth))
            if (directory && path in expanded) {
                if (path in folders) addEntries(path, depth + 1)
                else list.addView(Ui.label(context, context.getString(R.string.files_loading), Ui.CAPTION, Palette.faint).apply { setPadding(dp(18 + (depth + 1) * 18), dp(8), 0, dp(8)) })
            }
        }
    }

    /** One tree, search, change or recent row; `depth` indents tree rows only. */
    private fun row(entry: JSONObject, depth: Int, detail: String = "", diffCounts: Pair<Int, Int>? = null): View {
        val path = entry.optString("path"); val name = entry.optString("name").ifEmpty { path.substringAfterLast('/') }
        val directory = entry.optBoolean("directory"); val status = entry.optString("status")
        val open = directory && path in expanded
        val unreadable = !directory && entry.has("size") && entry.optLong("size") > 2 * 1024 * 1024
        return LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL; minimumHeight = dp(if (detail.isEmpty()) 44 else 54)
            setPadding(dp(6 + maxOf(depth, 0) * 18), 0, dp(8), 0); isFocusable = true
            background = context.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).let { val d = it.getDrawable(0); it.recycle(); d }
            contentDescription = (if (directory) context.getString(R.string.files_folder) else context.getString(R.string.files_file)) + name + when (status) { "M" -> context.getString(R.string.files_modified_82); "A" -> context.getString(R.string.files_added_83); "D" -> context.getString(R.string.files_deleted_84); else -> "" } +
                if (directory) (if (open) context.getString(R.string.files_expanded) else context.getString(R.string.files_tap_to_expand)) else context.getString(R.string.files_tap_to_open_hold_for_more_actions)
            if (depth >= 0 && detail.isEmpty()) addView(Ui.label(context, if (directory) (if (open) "▾" else "▸") else "", Ui.CAPTION, Palette.faint).apply {
                gravity = Gravity.CENTER; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(dp(14), -2))
            addView(FileBadge(context, if (directory) null else name, muted = unreadable), LinearLayout.LayoutParams(dp(20), dp(20)).apply { setMargins(dp(4), 0, dp(10), 0) })
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                addView(Ui.label(context, name, Ui.BODY, if (unreadable) Palette.faint else Palette.text).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.MIDDLE })
                if (detail.isNotEmpty()) addView(Ui.label(context, detail, Ui.OVERLINE, Palette.faint).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.START })
            }, LinearLayout.LayoutParams(0, -2, 1f))
            if (directory && entry.optBoolean("changed")) addView(View(context).apply { background = Ui.roundRect(context, Palette.amber, 3) },
                LinearLayout.LayoutParams(dp(6), dp(6)).apply { marginEnd = dp(8) })
            diffCounts?.let { (plus, minus) ->
                addView(Ui.label(context, "+$plus", Ui.CAPTION, Palette.accent).apply { typeface = Typeface.MONOSPACE }, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(4) })
                if (minus > 0) addView(Ui.label(context, "−$minus", Ui.CAPTION, Palette.red).apply { typeface = Typeface.MONOSPACE }, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(4) })
                addView(View(context), LinearLayout.LayoutParams(dp(4), 1))
            }
            if (status.isNotEmpty()) addView(Ui.label(context, status, Ui.CAPTION, if (status == "A") Palette.accent else if (status == "D") Palette.red else Palette.amber).apply {
                typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD); gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(dp(18), -2).apply { marginEnd = dp(6) })
            if (!directory && entry.has("size")) addView(Ui.label(context, if (unreadable) context.getString(R.string.files_too_large) else ProjectFiles.size(entry.optLong("size")), Ui.OVERLINE, Palette.faint).apply {
                typeface = Typeface.MONOSPACE
            })
            setOnClickListener {
                if (directory) {
                    if (open) expanded.remove(path) else { expanded.add(path); if (path !in folders) load(path) }
                    render()
                } else openFile(path, status, diffCounts != null)
            }
            setOnLongClickListener {
                if (directory) folderActions(path) else host.actions(path, false, null, ::say) { dismiss() }
                true
            }
        }
    }

    private fun folderActions(path: String) {
        lateinit var dialog: AlertDialog
        val box = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(14), 0, dp(18)) }
        fun item(text: String, action: () -> Unit) = box.addView(Ui.label(context, text, Ui.BODY).apply {
            minimumHeight = dp(52); gravity = Gravity.CENTER_VERTICAL; setPadding(dp(20), 0, dp(20), 0); isFocusable = true
            setOnClickListener { dialog.dismiss(); action() }
        }, LinearLayout.LayoutParams(-1, -2))
        box.addView(Ui.label(context, path.substringAfterLast('/'), Ui.BODY).apply { typeface = Typeface.DEFAULT_BOLD; setPadding(dp(20), 0, dp(20), dp(8)) })
        item(context.getString(R.string.files_open_this_folder)) { base = path; expanded.remove(path); render(); if (path !in folders) load(path) }
        item(context.getString(R.string.files_quote_in_reply)) { host.quote(path, null); dismiss() }
        item(context.getString(R.string.files_show_in_finder)) { host.openOnMac(path, true, ::say) }
        dialog = host.sheet(box)
    }

    private fun renderChanges() {
        val files = changes?.optJSONArray("files")
        if (files == null) { card(context.getString(R.string.files_loading_turn_changes), ""); say(""); return }
        if (files.length() == 0) {
            card(context.getString(R.string.files_no_file_changes_in_this_turn), context.getString(R.string.files_the_latest_reply_did_not_change_files_in_this_project) + (changes?.optInt("gitChanged")?.takeIf { it > 0 }?.let { context.resources.getQuantityString(R.plurals.files_nthe_workspace_has_1_uncommitted_changes_see_marked_files_under_all, it, it) } ?: ""))
            say(""); return
        }
        for (index in 0 until files.length()) {
            val file = files.getJSONObject(index); val path = file.optString("path")
            list.addView(row(JSONObject().put("path", path).put("name", path.substringAfterLast('/')).put("status", file.optString("status").ifEmpty { if (file.optString("kind") == "add") "A" else "M" }),
                -1, path.substringBeforeLast('/', context.getString(R.string.files_project_root)), file.optInt("added") to file.optInt("removed")))
        }
        say(context.getString(R.string.files_files_changed_by_the_latest_reply_tap_to_view_diff))
    }

    private fun renderRecent() {
        val recent = host.recent()
        if (recent.isEmpty()) { card(context.getString(R.string.files_no_recent_files), context.getString(R.string.files_files_opened_from_all_or_search_appear_here)); say(""); return }
        recent.forEach { path -> list.addView(row(JSONObject().put("path", path).put("name", path.substringAfterLast('/')), -1, path.substringBeforeLast('/', context.getString(R.string.files_project_root)))) }
        say(context.getString(R.string.files_stored_only_on_this_phone_up_to_20_files))
    }

    private fun renderSearch() {
        val result = searchResults
        when {
            result == null || searching && result.optString("query") != query -> card(context.getString(R.string.files_searching), "")
            result.has("error") -> card(context.getString(R.string.files_search_failed), result.optString("error"))
            else -> {
                val rows = result.optJSONArray("results") ?: JSONArray()
                if (rows.length() == 0) card(context.getString(R.string.files_no_matches), context.getString(R.string.files_no_file_names_contain_1 ,query))
                for (index in 0 until rows.length()) {
                    val file = rows.getJSONObject(index); val path = file.optString("path")
                    list.addView(row(file, -1, path.substringBeforeLast('/', context.getString(R.string.files_project_root))))
                }
                say(context.resources.getQuantityString(R.plurals.files_1_results, rows.length(), rows.length()) + if (result.optBoolean("truncated")) context.getString(R.string.files_showing_the_first_100_narrow_your_search) else "")
                return
            }
        }
        say("")
    }

    private fun card(heading: String, detail: String, retry: Boolean = false) {
        list.addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(14), dp(16), dp(14)); background = Ui.roundRect(context, Palette.surface1, 14)
            addView(Ui.label(context, heading, Ui.BODY).apply { typeface = Typeface.DEFAULT_BOLD })
            if (detail.isNotEmpty()) addView(Ui.label(context, detail, Ui.LABEL, Palette.muted), LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4) })
            if (retry) addView(Ui.button(context, context.getString(R.string.files_retry), Ui.Button.TEXT) { error = ""; load(base) }.apply { gravity = Gravity.START or Gravity.CENTER_VERTICAL })
        }, LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(6), dp(10), dp(6), 0) })
    }

    fun openFile(path: String, status: String = "", diff: Boolean = false, line: Int? = null) {
        if (viewer != null || closed) return
        viewer = ProjectFileViewer(host, path, line, status, preferDiff = diff) { viewer = null; if (mode == "recent") render() }.also { it.show() }
    }
}
