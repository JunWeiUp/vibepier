package io.github.junweiup.vibepier.remote.core.ui

import android.content.Context
import android.view.ActionMode
import android.view.View
import android.view.ViewStructure

/** Display controls have touch gestures, but no text selection or context actions. */
open class ControlView(context: Context) : View(context) {
    init {
        isLongClickable = false
        importantForContentCapture = IMPORTANT_FOR_CONTENT_CAPTURE_NO
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            setAccessibilityDataSensitive(ACCESSIBILITY_DATA_SENSITIVE_YES)
        }
    }

    final override fun showContextMenu() = false
    final override fun showContextMenu(x: Float, y: Float) = false
    final override fun startActionMode(callback: ActionMode.Callback): ActionMode? = null
    final override fun startActionMode(callback: ActionMode.Callback, type: Int): ActionMode? = null

    // Assist extraction is separate from TalkBack: keep normal accessibility labels.
    final override fun onProvideStructure(structure: ViewStructure) {
        super.onProvideStructure(structure)
        structure.setText(null)
        structure.setContentDescription(null)
        structure.setDataIsSensitive(true)
    }
}
