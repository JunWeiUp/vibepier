package io.github.junweiup.vibepier.remote.core.ui

import android.app.AlertDialog
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.FrameLayout
import android.widget.LinearLayout
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.features.remote.Palette

/** Image-only fullscreen host. Loading and retry never replace the close control or reset its viewport. */
internal class FullscreenImageDialog(private val context: Context, private val title: String) {
    val dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).create()
    val isShowing get() = dialog.isShowing
    private val imageArea = FrameLayout(context)
    internal var preview: ZoomableImagePreview? = null; private set
    var retry: () -> Unit = {}
    private val status = Ui.label(context, "", Ui.CAPTION, Palette.muted).apply { gravity = Gravity.CENTER_VERTICAL }
    private val reload = Ui.button(context, context.getString(R.string.reload), Ui.Button.TONAL) { retry() }
    private val feedback = LinearLayout(context).apply {
        gravity = Gravity.CENTER_VERTICAL; setPadding(Ui.dp(context, 16), Ui.dp(context, 8), Ui.dp(context, 12), Ui.dp(context, 8))
        addView(status, LinearLayout.LayoutParams(0, -2, 1f))
        addView(reload, LinearLayout.LayoutParams(-2, -2).apply { marginStart = Ui.dp(context, 8) })
    }
    private val root = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL; setBackgroundColor(Palette.background)
        addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL; setPadding(Ui.dp(context, 16), Ui.dp(context, 4), Ui.dp(context, 4), Ui.dp(context, 4))
            addView(Ui.label(context, title, Ui.LABEL).apply {
                typeface = Typeface.DEFAULT_BOLD; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
                contentDescription = title
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(IconControl(context, IconControl.Icon.CLOSE, context.getString(R.string.close), Palette.text) { dismiss() }, LinearLayout.LayoutParams(Ui.dp(context, 48), Ui.dp(context, 48)))
        }, LinearLayout.LayoutParams(-1, -2))
        addView(imageArea, LinearLayout.LayoutParams(-1, 0, 1f))
        addView(feedback, LinearLayout.LayoutParams(-1, -2))
        setOnApplyWindowInsetsListener { view, insets ->
            val safe = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            view.setPadding(safe.left, safe.top, safe.right, safe.bottom); insets
        }
    }
    fun show() {
        dialog.window?.protectControls(); dialog.show()
        dialog.setContentView(root, ViewGroup.LayoutParams(-1, -1))
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(Palette.background)); setDecorFitsSystemWindows(false)
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }
        root.requestApplyInsets()
    }
    fun loading() {
        status.text = context.getString(R.string.image_large_loading); reload.visibility = View.GONE; feedback.visibility = View.VISIBLE
    }
    fun failed(message: String = context.getString(R.string.image_large_failed)) {
        status.text = message; reload.visibility = View.VISIBLE; feedback.visibility = View.VISIBLE
    }
    fun display(bitmap: Bitmap) {
        val current = preview
        if (current == null) {
            preview = ZoomableImagePreview(context, bitmap).apply {
                contentDescription = context.getString(R.string.image_named_zoom_description, title)
            }.also { imageArea.addView(it, FrameLayout.LayoutParams(-1, -1)) }
        } else current.setBitmap(bitmap, reset = false)
        feedback.visibility = View.GONE
    }
    fun dismiss() { dialog.dismiss() }
}
