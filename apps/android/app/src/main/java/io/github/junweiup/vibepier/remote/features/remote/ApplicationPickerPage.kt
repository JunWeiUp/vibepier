package io.github.junweiup.vibepier.remote.features.remote

import android.app.AlertDialog
import android.content.Context
import android.graphics.Typeface
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.text.TextUtils
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.protectControls
import org.json.JSONObject

/** Chooses installed Mac applications for the shared dock; selecting never launches an app. */
internal class ApplicationPickerPage(
    private val context: Context,
    private val request: (String, JSONObject, (JSONObject) -> Unit) -> Unit,
    initialSlot: Int? = null,
    private val source: () -> String = { "" },
    private val onDismiss: () -> Unit = {}
) {
    private val body = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val controls = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val status = Ui.label(context, "", Ui.CAPTION, Palette.muted)
    private val search = EditText(context).apply {
        hint = context.getString(R.string.app_picker_search)
        setSingleLine(true)
        setTextColor(Palette.text); setHintTextColor(Palette.muted)
        textSize = Ui.BODY
        setPadding(dp(16), dp(12), dp(16), dp(12))
        background = Ui.roundRect(context, Palette.surface1, 12)
        minimumHeight = dp(48)
        imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE
        inputType = android.text.InputType.TYPE_CLASS_TEXT
    }
    private var expectedSource = source()
    private var snapshot: JSONObject? = null
    private var slot = initialSlot
    private var busy = false
    private var closed = false
    private var generation = 0
    val dialog: AlertDialog
    private fun dp(value: Int) = Ui.dp(context, value)
    private fun button(title: String, action: () -> Unit) = Ui.button(context, title, Ui.Button.TEXT, action = action).apply {
        isEnabled = !busy
    }
    init {
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(16))
            setBackgroundColor(Palette.background)
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(Ui.label(context, context.getString(R.string.app_picker_title), 22f).apply { typeface = Typeface.DEFAULT_BOLD }, LinearLayout.LayoutParams(0, -2, 1f))
                addView(button(context.getString(R.string.app_picker_close)) { dismiss() })
            })
            addView(Ui.label(context, context.getString(R.string.app_picker_scope), Ui.CAPTION, Palette.muted))
            addView(status, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
            addView(controls, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
            addView(search, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12); bottomMargin = dp(12) })
            addView(ScrollView(context).apply { isFillViewport = true; addView(body) }, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).setView(root).create().apply {
            setOnDismissListener { closed = true; generation++; onDismiss() }
        }
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { render() }
            override fun afterTextChanged(s: Editable?) {}
        })
    }
    fun show() {
        dialog.show()
        dialog.window?.apply {
            protectControls()
            setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Palette.background))
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }
        load()
    }
    fun dismiss() = dialog.dismiss()
    private fun load() {
        if (busy || closed) return
        expectedSource = source()
        busy = true; status.text = context.getString(R.string.app_picker_loading); render()
        val token = ++generation
        request("applications", JSONObject()) { reply ->
            if (closed || token != generation || sourceChanged()) return@request
            busy = false
            if (reply.optBoolean("ok")) {
                snapshot = reply
                status.text = ""
            } else status.text = reply.optString("error", context.getString(R.string.app_picker_failed))
            render()
        }
    }
    private fun appRow(name: String, detail: String, badge: String, selected: Boolean = false, description: String = "$name\n$detail", action: () -> Unit): LinearLayout =
        LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(72)
            setPadding(dp(14), dp(12), dp(14), dp(12))
            if (selected) background = Ui.currentRowBackground(context)
            addView(Ui.label(context, badge, Ui.HEADLINE, Palette.accent).apply {
                gravity = Gravity.CENTER
                typeface = Ui.medium
                background = Ui.roundRect(context, Palette.surface3, 10)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(dp(40), dp(40)).apply { marginEnd = dp(12) })
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                addView(Ui.label(context, name, Ui.BODY).apply { typeface = Ui.medium })
                if (detail.isNotBlank()) addView(Ui.label(context, detail, Ui.CAPTION, Palette.muted).apply {
                    maxLines = 1; ellipsize = TextUtils.TruncateAt.END
                    setPadding(0, dp(3), 0, 0)
                })
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(Ui.label(context, if (selected) "✓" else "›", Ui.TITLE, if (selected) Palette.accent else Palette.muted).apply {
                gravity = Gravity.CENTER
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(dp(28), dp(40)))
            contentDescription = description
            isFocusable = true; isEnabled = !busy
            alpha = if (busy) .55f else 1f
            setOnClickListener { action() }
        }

    private fun render() {
        body.removeAllViews()
        controls.removeAllViews()
        status.visibility = if (status.text.isBlank()) View.GONE else View.VISIBLE
        search.visibility = if (slot == null) android.view.View.GONE else android.view.View.VISIBLE
        search.isEnabled = !busy
        val data = snapshot
        if (data == null) {
            body.addView(button(context.getString(R.string.app_picker_refresh)) { load() })
            return
        }
        val target = slot
        if (target == null) {
            controls.addView(button(context.getString(R.string.app_picker_refresh)) { load() })
            val group = Ui.listGroup(context)
            body.addView(group)
            val slots = data.optJSONArray("shortcuts")
            for (i in 0 until (slots?.length() ?: 0)) {
                val item = slots!!.getJSONObject(i)
                val index = item.getInt("slot")
                val name = item.optString("name").ifBlank { context.getString(R.string.not_configured) }
                Ui.addGroupRow(group, appRow(name, item.optString("bundleID"), (index + 1).toString(),
                    description = context.getString(R.string.app_picker_slot, index + 1, name)) {
                    slot = index; search.setText(""); status.text = ""; render()
                })
            }
            if ((slots?.length() ?: 0) < 64) body.addView(button(context.getString(R.string.app_picker_add)) {
                slot = slots?.length() ?: 0; search.setText(""); render()
            })
            return
        }
        controls.addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            addView(button(context.getString(R.string.app_picker_back)) { slot = null; search.setText(""); render() }, LinearLayout.LayoutParams(0, -2, 1f))
            if (target < (data.optJSONArray("shortcuts")?.length() ?: 0)) {
                addView(button(context.getString(R.string.app_picker_clear)) { save("") })
            }
        })
        controls.addView(Ui.label(context, context.getString(R.string.app_picker_choose_slot, target + 1), Ui.HEADLINE).apply {
            typeface = Ui.medium
            setPadding(0, dp(8), 0, 0)
        })
        val currentID = data.optJSONArray("shortcuts")?.optJSONObject(target)?.optString("bundleID").orEmpty()
        val group = Ui.listGroup(context)
        body.addView(group)
        val apps = data.optJSONArray("applications")
        val query = search.text.toString().trim()
        var count = 0
        for (i in 0 until (apps?.length() ?: 0)) {
            val item = apps!!.getJSONObject(i)
            val name = item.getString("name"); val id = item.getString("bundleID")
            if (!name.contains(query, true) && !id.contains(query, true)) continue
            count++
            Ui.addGroupRow(group, appRow(name, id, name.take(1).uppercase(), id == currentID) { save(id) })
        }
        if (count == 0) body.addView(Ui.label(context, context.getString(R.string.app_picker_empty), Ui.CAPTION, Palette.muted))
    }
    private fun sourceChanged(): Boolean {
        if (source() == expectedSource) return false
        generation++; busy = false; snapshot = null
        status.text = context.getString(R.string.app_picker_source_changed); render()
        return true
    }
    private fun save(bundleID: String) {
        if (busy || closed || sourceChanged()) return
        val data = snapshot ?: return
        val target = slot ?: return
        busy = true; status.text = context.getString(R.string.app_picker_saving); render()
        val token = ++generation
        request("applicationShortcutSet", JSONObject().put("index", target).put("bundleID", bundleID).put("revision", data.getString("revision"))) { reply ->
            if (closed || token != generation || sourceChanged()) return@request
            busy = false
            if (reply.optBoolean("ok")) {
                snapshot = reply; slot = null; search.setText("")
                status.text = context.getString(R.string.app_picker_saved)
            } else {
                snapshot = null
                status.text = reply.optString("error", context.getString(R.string.app_picker_failed))
            }
            render()
        }
    }
}
