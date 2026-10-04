package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.text.Layout
import android.view.ContextThemeWrapper
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.ScrollView
import java.io.File
import java.util.Locale
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.remote.AppShortcutView
import io.github.junweiup.vibepier.remote.features.remote.DockApplications
import io.github.junweiup.vibepier.remote.features.remote.KeyConfigPage
import io.github.junweiup.vibepier.remote.features.remote.KeyLabels
import io.github.junweiup.vibepier.remote.features.remote.Keys
import io.github.junweiup.vibepier.remote.features.remote.Palette
import io.github.junweiup.vibepier.remote.features.remote.TalkPad
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import io.github.junweiup.vibepier.remote.features.settings.SettingsSheet

/** Real resource resolution and native controls, with local callbacks and synthetic profiles only. */
object ControlsLocalizationProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW && android.os.Build.MODEL.contains("sdk", true))
        fun main(block: () -> Unit) {
            var error: Throwable? = null
            test.runOnMainSync { try { block() } catch (failure: Throwable) { error = failure } }
            error?.let { throw it }
        }
        fun views(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) } else emptyList()
        fun field(value: Any, name: String) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
        fun snapshot(view: View, file: File) {
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            try {
                val canvas = Canvas(bitmap)
                canvas.drawColor(Palette.surface1)
                view.draw(canvas)
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
            finally { bitmap.recycle() }
        }
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "offline")) as MainActivity
        try {
            main { (activity.sessionNavigation.panel as? ConversationPanel)?.close() }
            val available = android.graphics.Rect()
            main { activity.window.decorView.getWindowVisibleDisplayFrame(available) }
            val density = activity.resources.displayMetrics.density
            val widths = listOf(320, 400).filter { (it * density).toInt() <= available.width() }
            check(widths.isNotEmpty()) { "The probe needs a viewport at least 320dp wide" }
            // Exercise 400dp only on a display that can contain it. Never force a dialog below system bars.
            val height = minOf((640 * density).toInt(), available.height())
            for (locale in listOf(Locale.ENGLISH, Locale.SIMPLIFIED_CHINESE)) for (width in widths) for (scale in listOf(1f, 1.5f)) {
                lateinit var page: KeyConfigPage
                lateinit var context: ContextThemeWrapper
                var saved: Pair<String, String?>? = null
                main {
                    context = ContextThemeWrapper(activity, R.style.Theme_VibePier_Dialog).apply {
                        applyOverrideConfiguration(Configuration(activity.resources.configuration).apply {
                            setLocale(locale); fontScale = scale; screenWidthDp = width
                        })
                    }
                    check(KeyLabels.label(context, "cmd+return") == if (locale == Locale.ENGLISH) "⌘ Return" else "⌘ 回车")
                    check(KeyLabels.label(context, "rcmd") == if (locale == Locale.ENGLISH) "Right ⌘" else "右⌘")
                    check(KeyLabels.label(context, "cmd++") == "⌘ +")
                    val voice = TalkPad(context).apply { binding = "rcmd" }
                    check(voice.label == if (locale == Locale.ENGLISH) "Hold to talk" else "按住说话")
                    voice.layout(0, 0, (width * context.resources.displayMetrics.density).toInt(), (360 * context.resources.displayMetrics.density).toInt())
                    voice.performClick()
                    try { snapshot(voice, File(activity.filesDir, "voice-$locale-$width-$scale.png")) }
                    finally { voice.releaseIfHeld() }
                    check(context.getString(R.string.custom_binding_suffix).startsWith(" · "))
                    check(context.getString(R.string.current_app_suffix).startsWith(" · "))
                    val dock = AppShortcutView(context)
                    dock.update(DockApplications.entries(emptyList(), null).first(), null)
                    check(dock.contentDescription == context.getString(R.string.dock_placeholder_description))
                    page = KeyConfigPage(context, null,
                        profiles = { listOf(KeyConfigPage.Profile(null, context.getString(R.string.general_bindings), "")) },
                        profileName = { context.getString(R.string.general_bindings) },
                        resolve = { key, _ -> Keys.defaults.getValue(key) }, overridden = { _, _ -> false },
                        title = { key, _ -> context.getString(when (key) {
                            "knob-left" -> R.string.rotate_left
                            "knob-right" -> R.string.rotate_right
                            "cancel" -> R.string.cancel
                            "confirm" -> R.string.confirm
                            "talk" -> R.string.voice
                            else -> R.string.delete
                        }) },
                        save = { key, value, scope, _ -> check(scope == null); saved = key to value })
                    page.show()
                    page.dialog.window!!.setLayout((width * context.resources.displayMetrics.density).toInt(), height)
                }
                try {
                    test.waitForIdleSync()
                    android.os.SystemClock.sleep(100)
                    main {
                        val root = page.dialog.window!!.decorView
                        check(views(root).filterIsInstance<CanvasLabel>().any { it.text.toString() == context.getString(R.string.key_configuration) })
                        if (locale == Locale.ENGLISH) check(views(root).filterIsInstance<CanvasLabel>().none { it.text.codePoints().anyMatch { point -> Character.UnicodeScript.of(point) == Character.UnicodeScript.HAN } })
                        val description = context.getString(R.string.key_edit_description, context.getString(R.string.rotate_left), KeyLabels.label(context, "wheel-up"))
                        check(views(root).first { it.contentDescription == description && it.isClickable }.performClick())
                        @Suppress("UNCHECKED_CAST") val dialogs = field(page, "auxiliaries") as Set<AlertDialog>
                        dialogs.last { it.isShowing }.window!!.setLayout((width * context.resources.displayMetrics.density).toInt(), height)
                    }
                    test.waitForIdleSync()
                    android.os.SystemClock.sleep(100)
                    main {
                        @Suppress("UNCHECKED_CAST") val dialogs = field(page, "auxiliaries") as Set<AlertDialog>
                        val editor = dialogs.last { it.isShowing }.window!!.decorView
                        check(editor.width == (width * context.resources.displayMetrics.density).toInt()) { "Editor width must match the simulated viewport" }
                        val children = views(editor)
                        val initialSave = children.filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == context.getString(R.string.save) }
                        val initialVisible = android.graphics.Rect()
                        check(initialSave.getGlobalVisibleRect(initialVisible) && initialVisible.height() == initialSave.height) { "Fixed Save action must be visible before scrolling: $locale $width $scale" }
                        val input = children.filterIsInstance<EditText>().single { it.text.toString() == "wheel-up" }
                        check(input.text.toString() == "wheel-up")
                        val space = children.filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == context.getString(R.string.key_space) }
                        val textLayout = field(space, "layout") as Layout
                        check(textLayout.getLineWidth(0) <= space.width - space.paddingLeft - space.paddingRight + 1) { "Preset clipped: $locale $width $scale" }
                        check(space.height >= (48 * context.resources.displayMetrics.density).toInt())
                        space.performClick()
                        children.first { it.contentDescription == "Control" && it.isClickable }.performClick()
                        check(input.text.toString() == "ctrl+space") { "Localized labels must not change wire keys" }
                        snapshot(editor, File(activity.filesDir, "controls-$locale-$width-$scale.png"))
                        children.filterIsInstance<ScrollView>().filter { it.isShown }.reversed().forEach { it.isSmoothScrollingEnabled = false; it.fullScroll(View.FOCUS_DOWN) }
                    }
                    test.waitForIdleSync()
                    android.os.SystemClock.sleep(100)
                    main {
                        @Suppress("UNCHECKED_CAST") val dialogs = field(page, "auxiliaries") as Set<AlertDialog>
                        val editor = dialogs.last { it.isShowing }.window!!.decorView
                        val children = views(editor)
                        val saveButton = children.filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == context.getString(R.string.save) }
                        snapshot(editor, File(activity.filesDir, "controls-bottom-$locale-$width-$scale.png"))
                        val visible = android.graphics.Rect()
                        check(saveButton.getGlobalVisibleRect(visible) && visible.height() == saveButton.height) { "Save must be reachable at $locale $width $scale: window=${editor.width}x${editor.height} visible=$visible buttonHeight=${saveButton.height} viewport=$available scrolls=${children.filterIsInstance<ScrollView>().map { "${it.width}x${it.height} y=${it.scrollY} child=${it.getChildAt(0)?.height}" }}" }
                        snapshot(editor, File(activity.filesDir, "controls-bottom-$locale-$width-$scale.png"))
                        children.filterIsInstance<CanvasLabel>().single { it.isClickable && it.text.toString() == context.getString(R.string.save) }.performClick()
                        check(saved == ("knob-left" to "ctrl+space"))
                    }
                } finally { main { page.dismiss() } }
                main {
                    val settings = SettingsSheet(context)
                    settings.show {}
                    try {
                        val dialog = field(settings, "dialog") as AlertDialog
                        check(views(dialog.window!!.decorView).filterIsInstance<CanvasLabel>().any { it.text.toString() == context.getString(R.string.settings_title) })
                    } finally { settings.dismiss() }
                }
            }
        } finally { main { activity.finish() } }
        return "PASS: EN/zh-CN native resources, 320/400dp and 1x/1.5x font key editor, localized presets/accessibility, stable ctrl+space wire binding, settings title; synthetic UI only\n"
    }
}
