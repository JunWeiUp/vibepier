package io.github.junweiup.vibepier.remote.core.ui

import android.app.AlertDialog
import android.view.View
import android.view.Window
import android.view.WindowManager

/** Apply before show(), including separate dialog windows. */
internal fun Window.protectControls() {
    // Screenshots/recordings are user-controlled; selection prevention lives in ControlView.
    clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    decorView.importantForContentCapture = View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
}

internal fun AlertDialog.Builder.showProtected(): AlertDialog = create().apply {
    window?.protectControls()
    show()
}
