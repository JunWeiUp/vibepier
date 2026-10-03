package io.github.junweiup.vibepier.remote.features.remote

import io.github.junweiup.vibepier.remote.core.ui.showProtected
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.IconControl
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.protectControls

import android.app.AlertDialog
import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.Editable
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.EditText
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Toast

/**
 * Every button's hotkey for one profile at a time: shared keys or one application's overrides. The page follows the
 * Mac's current application when it opens; a row's edit is captured with its profile, so switching apps meanwhile never
 * saves into another profile.
 */
internal class KeyConfigPage(
    private val context: Context,
    initialProfile: String?,
    private val profiles: () -> List<Profile>,
    private val profileName: (String?) -> String,
    private val resolve: (control: String, profile: String?) -> String,
    private val overridden: (control: String, profile: String?) -> Boolean,
    private val save: (control: String, keys: String?, profile: String?) -> Unit,
    private val onDismiss: () -> Unit = {},
) {
    data class Profile(val id: String?, val title: String, val summary: String)

    private class Control(val id: String, val title: String, val icon: Int)
    private val controls = listOf(
        Control("knob-left", context.getString(R.string.rotate_left), R.drawable.ic_rotate_left),
        Control("knob-right", context.getString(R.string.rotate_right), R.drawable.ic_rotate_right),
        Control("cancel", context.getString(R.string.cancel), R.drawable.ic_close),
        Control("confirm", context.getString(R.string.confirm), R.drawable.ic_check),
        Control("talk", context.getString(R.string.voice), R.drawable.ic_mic),
        Control("knob-press", context.getString(R.string.delete), R.drawable.ic_backspace),
    )
    private var profile = initialProfile
    private val body = column()
    private val auxiliaries = mutableSetOf<AlertDialog>()
    val dialog: AlertDialog

    init {
        val root = column().apply { setBackgroundColor(Palette.background) }
        root.addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(6), dp(8), dp(16), dp(4))
            addView(IconControl(context, IconControl.Icon.BACK, context.getString(R.string.back_to_remote), Palette.text) { dismiss() }, LinearLayout.LayoutParams(dp(48), dp(48)))
            addView(Ui.label(context, context.getString(R.string.key_configuration), 22f).apply { typeface = Typeface.DEFAULT_BOLD }, LinearLayout.LayoutParams(0, -2, 1f))
        }, LinearLayout.LayoutParams(-1, -2))
        root.addView(ScrollView(context).apply { addView(body) }, LinearLayout.LayoutParams(-1, 0, 1f))
        body.setPadding(dp(16), dp(4), dp(16), dp(24))
        dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).setView(root).create().apply {
            setOnDismissListener { auxiliaries.toList().forEach { it.dismiss() }; auxiliaries.clear(); onDismiss() }
        }
    }

    fun show() {
        render()
        dialog.window?.protectControls()
        dialog.show()
        dialog.window?.apply {
            setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Palette.background))
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }
    }

    fun dismiss() = dialog.dismiss()

    /** Bindings changed elsewhere (a Mac snapshot or another edit); redraw what this profile resolves to. */
    fun refresh() { if (dialog.isShowing) render() }

    private fun render() {
        body.removeAllViews()
        val current = profiles().firstOrNull { it.id == profile }
        body.addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            background = Ui.roundRect(context, Palette.surface1, 16)
            setPadding(dp(14), dp(10), dp(8), dp(10))
            minimumHeight = dp(64)
            isFocusable = true
            contentDescription = context.getString(R.string.profile_switch_description, profileName(profile))
            setOnClickListener { chooseProfile() }
            addView(Ui.label(context, if (profile == null) "⌘" else profileName(profile).take(1), Ui.LABEL, Palette.text).apply {
                gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD
                background = Ui.roundRect(context, Palette.surface4, 10)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(dp(36), dp(36)).apply { marginEnd = dp(12) })
            addView(column().apply {
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                addView(Ui.label(context, if (profile == null) context.getString(R.string.general_bindings) else context.getString(R.string.profile_custom, profileName(profile))).apply {
                    typeface = Ui.medium; maxLines = 1; ellipsize = TextUtils.TruncateAt.END
                })
                addView(Ui.label(context, current?.summary ?: context.getString(R.string.general_bindings_detail), Ui.CAPTION, Palette.muted).apply { maxLines = 2 },
                    LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(2) })
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(Ui.label(context, context.getString(R.string.profile_switch), Ui.LABEL, Palette.muted).apply {
                gravity = Gravity.CENTER; typeface = Ui.medium
                background = Ui.roundRect(context, Palette.surface3, 10)
                setPadding(dp(12), dp(8), dp(12), dp(8))
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            })
        }, LinearLayout.LayoutParams(-1, -2))
        body.addView(Ui.label(context, if (profile == null) context.getString(R.string.profile_general_effect) else context.getString(R.string.profile_inherited_effect),
            Ui.CAPTION, Palette.faint), LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(16); bottomMargin = dp(8); marginStart = dp(6) })
        val group = Ui.listGroup(context)
        controls.forEach { control -> Ui.addGroupRow(group, controlRow(control)) }
        body.addView(group, LinearLayout.LayoutParams(-1, -2))
        body.addView(Ui.label(context, context.getString(R.string.key_editor_detail), Ui.CAPTION, Palette.faint),
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12); marginStart = dp(6); marginEnd = dp(6) })
    }

    private fun controlRow(control: Control): View = LinearLayout(context).apply {
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(56)
        setPadding(dp(14), dp(8), dp(14), dp(8))
        isFocusable = true
        val keys = resolve(control.id, profile)
        val own = profile == null || overridden(control.id, profile)
        contentDescription = context.getString(if (own) R.string.key_edit_description else R.string.key_inherited_edit_description, control.title, KeyLabels.label(context, keys))
        setOnClickListener { edit(control) }
        addView(android.widget.ImageView(context).apply {
            setImageResource(control.icon); setColorFilter(Palette.muted)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginEnd = dp(14) })
        addView(Ui.label(context, control.title).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }, LinearLayout.LayoutParams(0, -2, 1f))
        if (!own) addView(Ui.label(context, context.getString(R.string.inherited_from_general), Ui.CAPTION, Palette.faint).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO },
            LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(8) })
        val tinted = profile != null && own
        addView(Ui.label(context, KeyLabels.label(context, keys), Ui.CAPTION, if (tinted) Palette.accent else Palette.muted).apply {
            typeface = Typeface.MONOSPACE; maxLines = 1; ellipsize = TextUtils.TruncateAt.END
            background = Ui.roundRect(context, if (tinted) Palette.accentContainer else Palette.surface3, 7)
            setPadding(dp(8), dp(3), dp(8), dp(3))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(-2, -2))
    }

    private fun chooseProfile() {
        val options = profiles()
        val adapter = object : android.widget.BaseAdapter() {
            override fun getCount() = options.size
            override fun getItem(position: Int) = options[position]
            override fun getItemId(position: Int) = position.toLong()
            override fun getView(position: Int, recycled: View?, parent: ViewGroup): View = column().apply {
                minimumHeight = dp(64); gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(24), dp(10), dp(24), dp(10))
                val item = options[position]
                addView(Ui.label(context, (if (item.id == profile) "✓ " else "") + item.title, 16f, if (item.id == profile) Palette.accent else Palette.text).apply {
                    typeface = Ui.medium; maxLines = 2
                })
                addView(Ui.label(context, item.summary, Ui.CAPTION, Palette.muted), LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(3) })
            }
        }
        AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog)
            .setTitle(context.getString(R.string.choose_profile))
            .setAdapter(adapter) { _, which -> profile = options[which].id; render() }
            .setNegativeButton(context.getString(R.string.cancel), null)
            .showProtected().also(::track)
    }

    /** The edit panel rises from the bottom; its profile is fixed when it opens. */
    private fun edit(control: Control) {
        val scope = profile
        val field = EditText(context).apply {
            hint = context.getString(R.string.key_input_hint)
            setText(resolve(control.id, scope))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            isSingleLine = true; textSize = Ui.BODY
            setTextColor(Palette.text); setHintTextColor(Palette.faint)
            typeface = Typeface.MONOSPACE
            background = Ui.roundRect(context, Palette.surface3, 13)
            setPadding(dp(14), dp(12), dp(14), dp(12))
            setSelection(text.length)
        }
        val error = Ui.label(context, "", Ui.CAPTION, Palette.red).apply { visibility = View.GONE }
        val modifierViews = mutableMapOf<String, CanvasLabel>()
        val presetViews = mutableMapOf<String, CanvasLabel>()
        fun paint() {
            val value = Keys.normalize(field.text.toString())
            modifierViews.forEach { (key, view) ->
                val on = Keys.hasModifier(field.text.toString(), key)
                view.background = Ui.roundRect(context, if (on) Palette.accentContainer else Palette.surface3, 13)
                view.setTextColor(if (on) Palette.accent else Palette.muted)
                view.stateDescription = if (on) context.getString(R.string.selected) else context.getString(R.string.not_selected)
            }
            presetViews.forEach { (key, view) ->
                val on = key == value
                view.background = Ui.roundRect(context, if (on) Palette.accentContainer else Palette.surface1, 10)
                view.setTextColor(if (on) Palette.accent else Palette.muted)
            }
        }
        fun set(value: String?) {
            if (value == null) Toast.makeText(context, context.getString(R.string.key_limit_error), Toast.LENGTH_SHORT).show()
            else { field.setText(value); field.setSelection(value.length) }
            paint()
        }
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { error.visibility = View.GONE; paint() }
            override fun afterTextChanged(s: Editable?) {}
        })
        val modifiers = GridLayout(context).apply { columnCount = if (resources.configuration.fontScale > 1.15f) 2 else 4 }
        Keys.modifiers.forEach { (key, name) ->
            val (symbol, word) = name.split(" ", limit = 2).let { it[0] to it.getOrElse(1) { "" } }
            modifiers.addView(CanvasLabel(context).apply {
                modifierViews[key] = this
                text = android.text.SpannableString("$symbol\n$word").apply {
                    setSpan(android.text.style.RelativeSizeSpan(1.5f), 0, symbol.length, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                textSize = Ui.CAPTION; gravity = Gravity.CENTER
                minimumHeight = dp(52); isFocusable = true
                contentDescription = word
                setOnClickListener { set(Keys.toggleModifier(field.text.toString(), key, !Keys.hasModifier(field.text.toString(), key))) }
            }, GridLayout.LayoutParams(GridLayout.spec(GridLayout.UNDEFINED), GridLayout.spec(GridLayout.UNDEFINED, 1f)).apply {
                width = 0; setMargins(dp(4), dp(4), dp(4), dp(4))
            })
        }
        val presetPaint = android.graphics.Paint().apply { textSize = Ui.LABEL * context.resources.displayMetrics.scaledDensity }
        val presetWidth = Keys.presets.maxOf { presetPaint.measureText(KeyLabels.label(context, it)) } + dp(22)
        val columns = (dp(context.resources.configuration.screenWidthDp - 36) / presetWidth).toInt().coerceIn(2, 4)
        val presets = GridLayout(context).apply { columnCount = columns }
        Keys.presets.forEach { key ->
            presets.addView(CanvasLabel(context).apply {
                presetViews[key] = this
                text = KeyLabels.label(context, key); textSize = Ui.LABEL; gravity = Gravity.CENTER; maxLines = 1
                minimumHeight = dp(48); isFocusable = true
                setOnClickListener { set(Keys.choosePreset(field.text.toString(), key)) }
            }, GridLayout.LayoutParams(GridLayout.spec(GridLayout.UNDEFINED), GridLayout.spec(GridLayout.UNDEFINED, 1f)).apply {
                width = 0; setMargins(dp(3), dp(3), dp(3), dp(3))
            })
        }
        paint()
        lateinit var sheet: AlertDialog
        val content = column().apply {
            setPadding(dp(18), dp(10), dp(18), dp(8))
            addView(View(context).apply { background = Ui.roundRect(context, Palette.surface4, 2) },
                LinearLayout.LayoutParams(dp(38), dp(4)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(12) })
            addView(LinearLayout(context).apply {
                gravity = Gravity.BOTTOM
                addView(Ui.label(context, context.getString(R.string.key_editor_title, control.title), 18f).apply { typeface = Typeface.DEFAULT_BOLD })
                addView(Ui.label(context, if (scope == null) context.getString(R.string.general_profile) else context.getString(R.string.profile_custom, profileName(scope)), Ui.CAPTION, Palette.muted).apply {
                    maxLines = 1; ellipsize = TextUtils.TruncateAt.END
                }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = dp(8) })
            })
            addView(field, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12) })
            addView(error, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
            addView(modifiers, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
            addView(Ui.label(context, context.getString(R.string.key_presets_default, KeyLabels.label(context, Keys.defaults.getValue(control.id))), Ui.CAPTION, Palette.faint),
                LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10); bottomMargin = dp(2); marginStart = dp(4) })
            addView(presets, LinearLayout.LayoutParams(-1, -2))
        }
        val actions = LinearLayout(context).apply {
            setPadding(dp(18), dp(10), dp(18), dp(18))
            addView(Ui.button(context, if (scope == null) context.getString(R.string.restore_default) else context.getString(R.string.restore_inherited)) {
                save(control.id, null, scope); sheet.dismiss()
            }, LinearLayout.LayoutParams(0, dp(48), 1f).apply { marginEnd = dp(10) })
            addView(Ui.button(context, context.getString(R.string.save), Ui.Button.PRIMARY) {
                val keys = Keys.normalize(field.text.toString())
                if (keys == null) { error.text = context.getString(R.string.key_parse_error); error.visibility = View.VISIBLE }
                else { save(control.id, keys, scope); sheet.dismiss() }
            }, LinearLayout.LayoutParams(0, dp(48), 1f))
        }
        sheet = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog)
            .setView(column().apply {
                // Let long presets scroll while both actions remain reachable at large font sizes.
                addView(ScrollView(context).apply { addView(content) }, LinearLayout.LayoutParams(-1, -2, 1f))
                addView(actions, LinearLayout.LayoutParams(-1, -2))
            })
            .create()
        sheet.window?.protectControls()
        sheet.show()
        sheet.window?.apply {
            setBackgroundDrawable(GradientDrawable().apply {
                setColor(Palette.surface2)
                val r = dp(26).toFloat()
                cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
            })
            setGravity(Gravity.BOTTOM)
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            attributes = attributes.apply { y = 0 }
        }
        track(sheet)
    }

    private fun track(dialog: AlertDialog) {
        auxiliaries.add(dialog)
        dialog.setOnDismissListener { auxiliaries.remove(dialog); render() }
    }

    private fun column() = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private fun dp(value: Int) = Ui.dp(context, value)
}
