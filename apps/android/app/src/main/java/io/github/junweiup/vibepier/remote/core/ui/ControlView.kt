package io.github.junweiup.vibepier.remote.core.ui

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.drawable.StateListDrawable
import android.view.PointerIcon
import io.github.junweiup.vibepier.remote.features.remote.Palette
import android.view.ActionMode
import android.view.View
import android.view.ViewStructure

/** Display controls have touch gestures, but no text selection or context actions. */
open class ControlView(context: Context) : View(context) {
    private var interactionInstalled = false
    protected open val usesSharedInteraction = true

    // Foreground survives background changes (selected chips, live session status, etc.).
    // Use View's own state dispatch; never intercept clicks or held-key gestures.
    override fun drawableStateChanged() {
        super.drawableStateChanged()
        if (usesSharedInteraction && !interactionInstalled && (isClickable || isLongClickable)) {
            interactionInstalled = true
            fun layer(color: Int, outlined: Boolean = false) = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = 12f * resources.displayMetrics.density
                setColor(color)
                if (outlined) setStroke((2f * resources.displayMetrics.density).toInt(), Palette.accent)
            }
            val states = StateListDrawable().apply {
                addState(intArrayOf(-android.R.attr.state_enabled), layer(Color.TRANSPARENT))
                addState(intArrayOf(android.R.attr.state_focused), layer(0x1872D4B9, true))
                addState(intArrayOf(android.R.attr.state_hovered), layer(0x2072D4B9))
                addState(intArrayOf(), layer(Color.TRANSPARENT))
            }
            foreground = RippleDrawable(ColorStateList.valueOf(0x3872D4B9), states, layer(Color.WHITE))
            pointerIcon = PointerIcon.getSystemIcon(context, PointerIcon.TYPE_HAND)
        }
        invalidate()
    }

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
