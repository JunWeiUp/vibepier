package io.github.junweiup.vibepier.remote.features.remote

import android.app.AlertDialog
import android.content.Context
import android.graphics.Typeface
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.ViewGroup
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
    private val status = Ui.label(context, "", Ui.CAPTION, Palette.muted)
    private val search = EditText(context).apply {
        hint = context.getString(R.string.app_picker_search)
        setSingleLine(true)
        setTextColor(Palette.text); setHintTextColor(Palette.muted)
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
    private fun button(title: String, action: () -> Unit) = Ui.button(context, title, action = action).apply {
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
            addView(status)
            addView(search, LinearLayout.LayoutParams(-1, -2))
            addView(ScrollView(context).apply { addView(body) }, LinearLayout.LayoutParams(-1, 0, 1f))
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
    private fun render() {
        body.removeAllViews()
        search.visibility = if (slot == null) android.view.View.GONE else android.view.View.VISIBLE
        search.isEnabled = !busy
        val data = snapshot
        if (data == null) {
            body.addView(button(context.getString(R.string.app_picker_refresh)) { load() })
            return
        }
        val target = slot
        if (target == null) {
            body.addView(button(context.getString(R.string.app_picker_refresh)) { load() })
            val slots = data.optJSONArray("shortcuts")
            for (i in 0 until (slots?.length() ?: 0)) {
                val item = slots!!.getJSONObject(i)
                val index = item.getInt("slot")
                body.addView(button(context.getString(R.string.app_picker_slot, index + 1, item.optString("name").ifBlank { context.getString(R.string.not_configured) })) {
                    slot = index; search.setText(""); status.text = ""; render()
                })
            }
            if ((slots?.length() ?: 0) < 64) body.addView(button(context.getString(R.string.app_picker_add)) {
                slot = slots?.length() ?: 0; search.setText(""); render()
            })
            return
        }
        body.addView(button(context.getString(R.string.app_picker_back)) { slot = null; search.setText(""); render() })
        body.addView(Ui.label(context, context.getString(R.string.app_picker_choose_slot, target + 1), Ui.BODY))
        if (target < (data.optJSONArray("shortcuts")?.length() ?: 0)) {
            body.addView(button(context.getString(R.string.app_picker_clear)) { save("") })
        }
        val apps = data.optJSONArray("applications")
        val query = search.text.toString().trim()
        var count = 0
        for (i in 0 until (apps?.length() ?: 0)) {
            val item = apps!!.getJSONObject(i)
            val name = item.getString("name"); val id = item.getString("bundleID")
            if (!name.contains(query, true) && !id.contains(query, true)) continue
            count++
            body.addView(button("$name\n$id") { save(id) })
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
