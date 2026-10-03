package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.protectControls
import io.github.junweiup.vibepier.remote.features.remote.AppShortcutView
import io.github.junweiup.vibepier.remote.features.remote.Pad
import io.github.junweiup.vibepier.remote.features.remote.Palette
import io.github.junweiup.vibepier.remote.features.remote.TalkPad

import android.app.Dialog
import android.app.Instrumentation
import android.os.SystemClock
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.EditText

/** Uses isolated views: never connects to a Mac or sends shortcuts. */
object ControlViewProbe {
    fun run(test: Instrumentation): String {
        lateinit var voice: TalkPad
        var presses = 0
        var releases = 0
        var down = 0L
        fun touch(action: Int) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 400f, 390f, 0)
            check(voice.dispatchTouchEvent(event))
            event.recycle()
        }
        test.runOnMainSync {
            val context = test.targetContext
            val callback = object : ActionMode.Callback {
                override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean = error("Unexpected selection menu")
                override fun onPrepareActionMode(mode: ActionMode, menu: Menu) = false
                override fun onActionItemClicked(mode: ActionMode, item: MenuItem) = false
                override fun onDestroyActionMode(mode: ActionMode) {}
            }
            voice = TalkPad(context).apply {
                layout(0, 0, 800, 800)
                onPress = { presses++ }
                onRelease = { releases++ }
            }
            for (view in listOf(voice, Pad(context, R.drawable.ic_backspace, "删除", Palette.muted),
                CanvasLabel(context).apply { text = "按住说话" }, AppShortcutView(context))) {
                check(!view.showContextMenu())
                check(!view.showContextMenu(1f, 1f))
                check(view.startActionMode(callback) == null)
                check(view.startActionMode(callback, ActionMode.TYPE_FLOATING) == null)
                check(!view.isLongClickable)
            }
            val dialog = Dialog(context)
            dialog.window!!.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            dialog.window!!.protectControls()
            check(dialog.window!!.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE == 0)
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                check(dialog.window!!.decorView.importantForContentCapture == View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS)
            }
            val field = EditText(context).apply { setText("cmd+ctrl") }
            check(field.onCheckIsTextEditor())
            field.selectAll()
            check(field.selectionStart == 0 && field.selectionEnd == field.length())
            down = SystemClock.uptimeMillis()
            touch(MotionEvent.ACTION_DOWN)
            check(presses == 1 && releases == 0)
        }
        SystemClock.sleep(1200) // Exceed native long-press timeout without blocking the UI thread.
        test.runOnMainSync {
            check(presses == 1 && releases == 0)
            touch(MotionEvent.ACTION_UP)
            check(presses == 1 && releases == 1)
            voice.performClick() // TalkBack click-to-start / click-to-stop remains usable.
            voice.performClick()
            check(presses == 2 && releases == 2)
            down = SystemClock.uptimeMillis()
            touch(MotionEvent.ACTION_DOWN)
            touch(MotionEvent.ACTION_CANCEL)
            check(presses == 3 && releases == 3)
        }
        return "PASS: context/action menus blocked, screenshots allowed, editable selection, 1.2s voice hold/release, accessibility toggle, cancel\n"
    }
}
