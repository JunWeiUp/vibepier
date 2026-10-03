package io.github.junweiup.vibepier.remote.features.sessions

import android.app.AlertDialog
import android.content.Context
import android.view.Gravity
import android.widget.LinearLayout
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.showProtected
import io.github.junweiup.vibepier.remote.features.remote.Palette
import org.json.JSONArray
import org.json.JSONObject

/** Configuration belongs to the first prompt, with no settings mutation until Start. */
@android.annotation.SuppressLint("ViewConstructor")
internal class NewSessionOptionsView(
    context: Context,
    initial: SessionCreationDraft,
    private val changed: (SessionCreationDraft) -> Unit,
    private val addAttachment: () -> Unit,
) : LinearLayout(context) {
    var draft = initial; private set
    private var options = JSONObject()
    private var models = JSONArray()
    private var modes = JSONArray()
    private var locked = false
    private val menus = mutableListOf<AlertDialog>()
    var loaded = false; private set
    val supportsAttachments get() = loaded && options.optJSONObject("capabilities")?.optBoolean("attachments") == true
    val ready: Boolean get() {
        if (!loaded) return false
        val model = rows(models).firstOrNull { it.optString("id") == draft.model } ?: return false
        val efforts = strings(model.optJSONArray("efforts"))
        val mode = rows(modes).firstOrNull { it.optString("id") == draft.mode } ?: return false
        return (efforts.isEmpty() || draft.effort in efforts) &&
            (!mode.optBoolean("requiresConfirmation") || draft.confirmFullAccess)
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun action(text: String, click: () -> Unit) = CanvasLabel(context).apply {
        this.text = text; textSize = Ui.LABEL; setTextColor(Palette.text)
        minimumHeight = dp(48); gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(12), dp(8), dp(12), dp(8)); background = Ui.roundRect(context, Palette.surfaceTop, 12)
        isFocusable = true; setOnClickListener { if (!locked && loaded) click() }
    }
    private val model = action(context.getString(R.string.choose_model), ::chooseModel)
    private val mode = action(context.getString(R.string.approval_mode), ::chooseMode)
    private val add = action(context.getString(R.string.session_add_attachment)) { if (supportsAttachments) addAttachment() }
    init {
        orientation = VERTICAL
        for (view in listOf(model, mode, add)) addView(view, LayoutParams(-1, -2).apply { topMargin = dp(8) })
        update()
    }
    fun applyOptions(value: JSONObject) {
        options = JSONObject(value.toString())
        models = options.optJSONArray("models") ?: JSONArray()
        modes = options.optJSONArray("permissionModes") ?: JSONArray()
        loaded = value.optBoolean("ok") && value.optInt("creationVersion") == 1
        val current = value.optJSONObject("composer") ?: JSONObject()
        if (draft.model.isEmpty()) {
            val preferred = rows(models).firstOrNull { it.optString("id") == current.optString("model") } ?: rows(models).firstOrNull()
            draft = draft.copy(model = preferred?.optString("id") ?: "", effort = current.optString("effort").ifBlank {
                preferred?.optString("defaultEffort")?.ifBlank { strings(preferred?.optJSONArray("efforts")).firstOrNull() ?: "" } ?: ""
            })
        }
        if (draft.mode.isEmpty()) {
            val preferred = rows(modes).firstOrNull { it.optString("id") == current.optString("mode") && !it.optBoolean("requiresConfirmation") }
                ?: rows(modes).firstOrNull { !it.optBoolean("requiresConfirmation") }
            draft = draft.copy(mode = preferred?.optString("id") ?: "", confirmFullAccess = false)
        }
        changed(draft); update()
    }
    fun setLocked(value: Boolean) { locked = value; update() }
    fun closeMenus() { menus.toList().forEach { it.dismiss() }; menus.clear() }
    private fun update() {
        val selectedModel = rows(models).firstOrNull { it.optString("id") == draft.model }
        val selectedMode = rows(modes).firstOrNull { it.optString("id") == draft.mode }
        model.text = selectedModel?.optString("name")?.ifBlank { draft.model }?.let {
            it + if (draft.effort.isEmpty()) "" else " · " + effortName(draft.effort)
        } ?: context.getString(R.string.choose_model)
        mode.text = selectedMode?.let(::modeName) ?: context.getString(R.string.approval_mode)
        for (view in listOf(model, mode)) { view.isEnabled = loaded && !locked; view.alpha = if (view.isEnabled) 1f else .45f }
        add.isEnabled = supportsAttachments && !locked; add.alpha = if (add.isEnabled) 1f else .45f
    }
    private fun chooseModel() {
        menu(context.getString(R.string.choose_model), rows(models).map { it.optString("name").ifBlank { it.optString("id") } }) { index ->
            val selected = rows(models)[index]; val efforts = strings(selected.optJSONArray("efforts"))
            fun select(effort: String) { draft = draft.copy(model = selected.getString("id"), effort = effort); changed(draft); update() }
            if (efforts.size <= 1) select(efforts.firstOrNull() ?: "")
            else menu(selected.optString("name"), efforts.map(::effortName)) { select(efforts[it]) }
        }
    }
    private fun chooseMode() {
        menu(context.getString(R.string.approval_mode), rows(modes).map(::modeName)) { index ->
            val selected = rows(modes)[index]
            fun select(confirmed: Boolean) { draft = draft.copy(mode = selected.getString("id"), confirmFullAccess = confirmed); changed(draft); update() }
            if (!selected.optBoolean("requiresConfirmation")) select(false)
            else {
                val message = selected.optString("confirmationText").ifBlank {
                    context.getString(if (draft.provider == "claude") R.string.session_claude_full_access_warning else R.string.session_codex_full_access_warning, draft.cwd)
                }
                val dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog)
                    .setTitle(context.getString(R.string.session_enable_full_access)).setMessage(message)
                    .setNegativeButton(R.string.cancel, null)
                    .setPositiveButton(R.string.session_confirm_change) { _, _ -> if (!locked) select(true) }.showProtected()
                menus.add(dialog)
            }
        }
    }
    private fun menu(title: String, labels: List<String>, select: (Int) -> Unit) {
        val dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).setTitle(title)
            .setItems(labels.toTypedArray()) { _, index -> if (!locked) select(index) }.setNegativeButton(R.string.cancel, null).showProtected()
        menus.removeAll { !it.isShowing }; menus.add(dialog)
    }
    private fun rows(values: JSONArray) = (0 until values.length()).mapNotNull { values.optJSONObject(it) }
    private fun strings(values: JSONArray?) = (0 until (values?.length() ?: 0)).map { values!!.getString(it) }
    private fun modeName(value: JSONObject): String {
        val id = value.optString("id")
        val resource = when (id) {
            "default" -> if (draft.provider == "claude") R.string.session_ask_confirm_before_changes else null
            "acceptEdits" -> R.string.session_accept_edits_accept_file_changes_automatically
            "plan" -> R.string.session_plan_analyze_without_edits
            "bypassPermissions" -> R.string.session_skip_approvals_do_not_ask_again
            "auto" -> if (draft.provider == "claude") R.string.session_auto_claude_code_evaluates_risk else R.string.session_default_permissions
            "guardian-approvals" -> R.string.session_approve_for_me_use_the_codex_approval_agent
            "full-access" -> R.string.session_full_access_no_sandbox_restrictions
            else -> null
        }
        return resource?.let(context::getString) ?: value.optString("name").ifBlank { id }
    }
    private fun effortName(id: String): String {
        rows(options.optJSONArray("efforts") ?: JSONArray()).firstOrNull { it.optString("id") == id }
            ?.optString("name")?.takeIf { it.isNotBlank() }?.let { return it }
        val resource = when (id) {
            "default" -> R.string.session_default; "low" -> R.string.session_low; "medium" -> R.string.session_medium
            "high" -> R.string.session_high; "xhigh" -> R.string.session_extra_high; "max" -> R.string.session_maximum
            "ultra" -> R.string.session_ultra; else -> return id
        }
        return context.getString(resource)
    }
}
