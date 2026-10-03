package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel

/** Exercises production menu controls with review-only responses; never locks a real Mac. */
object ScreenControlsProbe {
    fun run(test: Instrumentation): String {
        fun field(value: Any, name: String) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
        }
        for (fixture in listOf("approval", "offline")) {
            val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", fixture))
            try {
                test.waitForIdleSync()
                lateinit var panel: ConversationPanel
                main { panel = (activity as MainActivity).sessionNavigation.panel as ConversationPanel }
                for ((action, expected) in listOf(activity.getString(R.string.session_lock) to activity.getString(R.string.session_mac_locked), activity.getString(R.string.session_unlock) to activity.getString(R.string.session_mac_unlocked))) {
                    lateinit var dialog: AlertDialog
                    main {
                        panel.javaClass.getDeclaredMethod("showDrawerMenu").apply { isAccessible = true }.invoke(panel)
                        @Suppress("UNCHECKED_CAST") val dialogs = field(panel, "auxiliaryDialogs") as Set<AlertDialog>
                        dialog = dialogs.last { it.isShowing }
                    }
                    test.waitForIdleSync()
                    if (fixture == "approval" && action == activity.getString(R.string.session_lock)) {
                        // Idle callbacks can precede the window's first composed animation frame.
                        SystemClock.sleep(350)
                        test.waitForIdleSync()
                        test.uiAutomation.takeScreenshot()?.let { bitmap ->
                            try {
                                java.io.File(activity.externalCacheDir, "screen-controls-menu.png").outputStream().use {
                                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                                }
                            } finally { bitmap.recycle() }
                        }
                    }
                    main {
                        val children = views(dialog.window!!.decorView)
                        for (name in listOf(activity.getString(R.string.session_lock), activity.getString(R.string.session_unlock))) {
                            val button = children.single { it.contentDescription == name && it.isClickable }
                            val visible = android.graphics.Rect()
                            check(button.isShown && button.getGlobalVisibleRect(visible) && visible.height() == button.height) { "Screen action must be fully visible: $name" }
                        }
                        children.first { it.contentDescription == action }.performClick()
                    }
                    SystemClock.sleep(180); test.waitForIdleSync()
                    main {
                        val notice = (field(panel, "info") as CanvasLabel).text.toString()
                        check(notice == if (fixture == "offline") activity.getString(R.string.session_connect_to_the_mac_first) else expected) { notice }
                        check(field(panel, "screenActionPending") == false)
                    }
                }
            } finally { main { activity.finish() } }
        }
        return "PASS: session menu has lock/unlock, both clicks show confirmed states, offline commands are blocked; no real desktop actions\n"
    }
}
