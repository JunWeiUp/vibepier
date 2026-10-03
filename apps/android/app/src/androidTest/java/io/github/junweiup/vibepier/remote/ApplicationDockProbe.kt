package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.transport.RemoteSender
import io.github.junweiup.vibepier.remote.features.remote.AppShortcutView
import io.github.junweiup.vibepier.remote.features.remote.DockApplications
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel

import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.widget.HorizontalScrollView
import android.widget.LinearLayout

/** Exercises the real dock layout with local click counters, so gestures never launch a Mac application. */
object ApplicationDockProbe {
    fun run(test: Instrumentation): String {
        RemoteConfigurationCacheProbe.run(test.targetContext)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "offline")) as MainActivity
        fun field(name: String) = activity.javaClass.getDeclaredField(name).apply { isAccessible = true }
        fun current(bundleID: String?, name: String = "") {
            field("application").set(activity, bundleID?.let { RemoteSender.Application(it, name) })
            activity.javaClass.getDeclaredMethod("refreshApplicationDock").apply { isAccessible = true }.invoke(activity)
        }
        fun populate(count: Int, selected: Int? = null) {
            field("appShortcuts").set(activity, (0 until count).map { RemoteSender.AppShortcut(it, "dock.app.$it", "Dock App $it", "", true) })
            current(selected?.let { "dock.app.$it" }, selected?.let { "Dock App $it" } ?: "")
        }
        @Suppress("UNCHECKED_CAST")
        fun entries() = field("dockEntries").get(activity) as List<RemoteSender.AppShortcut>
        lateinit var scroll: HorizontalScrollView
        lateinit var row: LinearLayout
        var clicks = 0
        var clickedSlot = -1
        var hideClicks = 0
        var savedTiles = emptyList<View>()
        var savedPositions = emptyList<Int>()
        var savedScroll = 0
        fun details(): String {
            val last = row.getChildAt(8)
            val location = IntArray(2)
            scroll.getLocationOnScreen(location)
            return "clicks=$clicks clickedSlot=$clickedSlot scrollX=${scroll.scrollX} viewport=${scroll.width}x${scroll.height}" +
                " viewportScreen=${location.toList()} rowWidth=${row.width} children=${row.childCount} windowFocus=${activity.hasWindowFocus()}" +
                (last?.let { " lastBounds=${it.left},${it.top},${it.right},${it.bottom} enabled=${it.isEnabled} clickable=${it.isClickable} shown=${it.isShown}" } ?: "")
        }
        fun checkFixedPositions() {
            check((1 until row.childCount).map { row.getChildAt(it) } == savedTiles) { "A foreground change must reuse the saved application tiles" }
            check(savedTiles.map { it.left } == savedPositions) { "Saved application positions must never follow the foreground" }
            check(scroll.scrollX == savedScroll) { "A foreground change must preserve the user's horizontal scroll: ${details()} expected=$savedScroll" }
        }
        fun pointer(action: Int, down: Long, x: Float, y: Float) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { test.sendPointerSync(event) } finally { event.recycle() }
        }
        fun settleScroll() {
            var previous = -1
            var stable = 0
            repeat(60) {
                SystemClock.sleep(32)
                var current = 0
                test.runOnMainSync { current = scroll.scrollX }
                stable = if (current == previous) stable + 1 else 0
                previous = current
                if (stable >= 4) return
            }
            test.runOnMainSync { error("The dock did not finish scrolling: ${details()}") }
        }
        try {
            test.waitForIdleSync()
            test.runOnMainSync {
                ((activity as MainActivity).sessionNavigation.panel as? ConversationPanel)?.close()
                scroll = field("applicationDockScroll").get(activity) as HorizontalScrollView
                row = field("applicationDockRow").get(activity) as LinearLayout
                populate(8, selected = 3)
            }
            test.waitForIdleSync()
            SystemClock.sleep(100) // Let the window draw after closing the fixture panel.
            var start = 0f
            var end = 0f
            var y = 0f
            test.runOnMainSync {
                check(activity.hasWindowFocus()) { "The dock window must accept injected touch events: ${details()}" }
                check(row.childCount == 9) { "The dock should expose eight saved applications and one permanent temporary position: ${details()}" }
                check(scroll.width > 0 && row.width > scroll.width) { "More than five applications should extend past the viewport: ${details()}" }
                check(scroll.canScrollHorizontally(1)) { "Eight applications must be reachable by horizontal scrolling: ${details()}" }
                check(DockApplications.isTemporaryPlaceholder(entries().first())) { "A saved current application must leave the temporary position empty" }
                check(!row.getChildAt(0).isEnabled && row.getChildAt(0).contentDescription.toString().equals(activity.getString(R.string.dock_placeholder_description))) { "The reserved position must explain its purpose without offering a false app action" }
                check(entries().drop(1).map { it.bundleID } == (0..7).map { "dock.app.$it" }) { "All configured applications must keep the saved order" }
                check(entries()[4].slot == 3) { "A configured current application must retain its original launch slot and position" }
                check(row.getChildAt(4).contentDescription.toString() == activity.getString(R.string.dock_hide_description, "Dock App 3")) { "The selected application's accessibility action must describe hiding from its fixed position" }
                check(row.getChildAt(8).contentDescription.toString().contains("Dock App 7"))
                savedTiles = (1 until row.childCount).map { row.getChildAt(it) }
                savedPositions = savedTiles.map { it.left }
                for (index in 0 until row.childCount) row.getChildAt(index).setOnClickListener {
                    val entry = entries()[index]
                    when (DockApplications.action(entry, field("application").get(activity) as? RemoteSender.Application)) {
                        "hide" -> hideClicks++
                        "activate" -> { clicks++; clickedSlot = entry.slot }
                    }
                }
                // Local callbacks verify the hit targets without sending hide or launch requests to a Mac.
                row.getChildAt(4).performClick()
                row.getChildAt(4).performClick()
                check(hideClicks == 2 && clicks == 0) { "Repeated taps on the selected entry must remain actionable" }
                scroll.scrollTo(0, 0)
                val location = IntArray(2)
                scroll.getLocationOnScreen(location)
                start = location[0] + scroll.width * 0.82f
                end = location[0] + scroll.width * 0.12f
                y = location[1] + scroll.height / 2f
            }
            val dragDown = SystemClock.uptimeMillis()
            pointer(MotionEvent.ACTION_DOWN, dragDown, start, y)
            for (step in 1..16) {
                SystemClock.sleep(16)
                pointer(MotionEvent.ACTION_MOVE, dragDown, start + (end - start) * step / 16, y)
            }
            // Release with a stationary finger, so the following tap never races a fling.
            SystemClock.sleep(100)
            pointer(MotionEvent.ACTION_MOVE, dragDown, end, y)
            SystemClock.sleep(60)
            pointer(MotionEvent.ACTION_UP, dragDown, end, y)
            test.waitForIdleSync()
            settleScroll()
            var tapX = 0f
            var tapY = 0f
            test.runOnMainSync {
                check(clicks == 0 && hideClicks == 2) { "A dock swipe must not switch or hide applications: ${details()}" }
                check(scroll.scrollX > scroll.width / 4) { "A horizontal drag should reveal the later applications: ${details()}" }
                scroll.scrollTo(row.width - scroll.width, 0)
            }
            test.waitForIdleSync()
            SystemClock.sleep(50)
            test.runOnMainSync {
                val last = row.getChildAt(8)
                val viewport = IntArray(2); scroll.getLocationOnScreen(viewport)
                val target = IntArray(2); last.getLocationOnScreen(target)
                tapX = target[0] + last.width / 2f
                tapY = target[1] + last.height / 2f
                check(last.isEnabled && last.isClickable && last.isShown) { "The eighth application must remain interactive: ${details()}" }
                check(tapX in viewport[0].toFloat()..(viewport[0] + scroll.width).toFloat()) { "The eighth application's target must be inside the viewport: tap=$tapX,$tapY ${details()}" }
            }
            val tapDown = SystemClock.uptimeMillis()
            pointer(MotionEvent.ACTION_DOWN, tapDown, tapX, tapY)
            SystemClock.sleep(80)
            pointer(MotionEvent.ACTION_UP, tapDown, tapX, tapY)
            test.waitForIdleSync()
            test.runOnMainSync {
                check(clicks == 1 && clickedSlot == 7 && hideClicks == 2) { "An intentional tap should click the eighth application exactly once: tap=$tapX,$tapY ${details()}" }
                savedScroll = scroll.scrollX
                current("dock.app.6", "Dock App 6")
            }
            test.waitForIdleSync()
            settleScroll()
            test.runOnMainSync {
                checkFixedPositions()
                check(entries().drop(1).map { it.bundleID } == (0..7).map { "dock.app.$it" }) { "A foreground change must only update selection" }
                check(entries()[7].slot == 6)
                check(row.getChildAt(7).contentDescription.toString() == activity.getString(R.string.dock_hide_description, "Dock App 6"))
                check(row.getChildAt(4).contentDescription.toString() == activity.getString(R.string.dock_switch_description, "Dock App 3"))
                current("dock.app.0", "Dock App 0")
            }
            test.waitForIdleSync()
            settleScroll()
            test.runOnMainSync {
                checkFixedPositions()
                check(row.getChildAt(1).contentDescription.toString() == activity.getString(R.string.dock_hide_description, "Dock App 0")) { "An off-screen saved current app must stay selected at its fixed position without scrolling there" }
                current("other.mac.app", "Other Mac App")
            }
            test.waitForIdleSync()
            settleScroll()
            test.runOnMainSync {
                checkFixedPositions()
                check(row.childCount == 9 && entries().size == 9) { "An unconfigured current application must fill the reserved position without adding a tile" }
                check(entries().first() == RemoteSender.AppShortcut(-1, "other.mac.app", "Other Mac App", "", true))
                check(entries().drop(1).map { it.slot } == (0..7).toList())
                check(row.getChildAt(0).contentDescription.toString() == activity.getString(R.string.dock_hide_description, "Other Mac App"))
                check(row.getChildAt(0).isEnabled)
                current("second.external.app", "Second External App")
            }
            test.waitForIdleSync()
            settleScroll()
            test.runOnMainSync {
                checkFixedPositions()
                check(entries().first().bundleID == "second.external.app")
                check(row.getChildAt(0).contentDescription.toString() == activity.getString(R.string.dock_hide_description, "Second External App"))
                current(null)
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                checkFixedPositions()
                check(row.childCount == 9 && entries().drop(1).map { it.slot } == (0..7).toList()) { "Disconnecting must clear the temporary position while keeping every saved tile in place" }
                check(DockApplications.isTemporaryPlaceholder(entries().first()) && !row.getChildAt(0).isEnabled)
                for (index in 0 until row.childCount) {
                    check(!row.getChildAt(index).contentDescription.toString().startsWith("隐藏 ")) { "An offline dock must never advertise a stale hide action" }
                }
                populate(5, selected = 2)
            }
            test.waitForIdleSync()
            settleScroll()
            test.runOnMainSync {
                check(row.childCount == 6 && entries().drop(1).map { it.slot } == (0..4).toList())
                check(row.width > scroll.width) { "Five saved applications plus the permanent position must remain horizontally reachable" }
                populate(4, selected = 2)
            }
            test.waitForIdleSync()
            settleScroll()
            test.runOnMainSync {
                check(row.childCount == 5)
                check(!scroll.canScrollHorizontally(-1) && !scroll.canScrollHorizontally(1)) { "Four saved applications and the permanent position should fit without horizontal overflow" }
                check(scroll.scrollX == 0) { "Shrinking the list should reset an obsolete scroll position" }
                populate(2, selected = 1)
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(row.childCount == 5 && entries().size == 3) { "A short dock must retain five touch-size positions including its permanent temporary position" }
                check(DockApplications.isTemporaryPlaceholder(entries().first()))
                check(entries().drop(1).map { it.bundleID } == listOf("dock.app.0", "dock.app.1"))
            }
            verifyPressedIdentity(test, activity, row)
        } finally {
            test.runOnMainSync { activity.finish() }
            test.waitForIdleSync()
        }
        return "PASS: eight-app cache and recovery, legacy sync, permanent temporary position, fixed saved order and tile coordinates, foreground selection without auto-scroll, unconfigured current replacement and offline clearing without moving tiles, local repeated selected taps, horizontal swipe without click, eighth-app tap, horizontal overflow and five-position fit, current-icon reordered/stale/late frames and LRU, changed press identity cancellation and accessibility recovery\n"
    }

    /** Attached isolated tile: native posted clicks run normally, with only a local listener. */
    private fun verifyPressedIdentity(test: Instrumentation, activity: MainActivity, row: LinearLayout) {
        lateinit var tile: AppShortcutView
        var clicks = 0
        var down = 0L
        val appA = RemoteSender.AppShortcut(0, "isolated.app.a", "Isolated App A", "", true)
        val appB = RemoteSender.AppShortcut(1, "isolated.app.b", "Isolated App B", "", true)
        fun touch(action: Int) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, tile.width / 2f, tile.height / 2f, 0)
            try { check(tile.dispatchTouchEvent(event)) } finally { event.recycle() }
        }
        test.runOnMainSync {
            tile = AppShortcutView(activity).apply { setOnClickListener { clicks++ } }
            row.addView(tile, LinearLayout.LayoutParams(160, 100))
        }
        test.waitForIdleSync()
        try {
            test.runOnMainSync {
                check(tile.isAttachedToWindow && tile.width > 0 && tile.height > 0)
                tile.update(appA, "other.current.app")
                down = SystemClock.uptimeMillis()
                touch(MotionEvent.ACTION_DOWN)
                tile.update(appB, "other.current.app")
                touch(MotionEvent.ACTION_UP)
            }
            test.waitForIdleSync() // Both View's posted performClick and the press-identity reset must finish.
            test.runOnMainSync {
                check(clicks == 0) { "A reordered application under a pressed finger must not be activated" }
                tile.performClick()
                check(clicks == 1) { "An accessibility click must work after a cancelled identity-changing tap" }
                clicks = 0
                tile.update(appA, "other.current.app")
                down = SystemClock.uptimeMillis()
                touch(MotionEvent.ACTION_DOWN)
                tile.update(appA, appA.bundleID)
                touch(MotionEvent.ACTION_UP)
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(clicks == 0) { "A foreground change must not turn an activation tap into a hide tap" }
                tile.update(appA, appA.bundleID)
                down = SystemClock.uptimeMillis()
                touch(MotionEvent.ACTION_DOWN)
                tile.update(appA, "other.current.app")
                touch(MotionEvent.ACTION_UP)
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(clicks == 0) { "A foreground change must not turn a hide tap into an activation tap" }
                tile.update(appA, "other.current.app")
                down = SystemClock.uptimeMillis()
                touch(MotionEvent.ACTION_DOWN)
                tile.update(appA.copy(name = "Refreshed App A"), "other.current.app")
                touch(MotionEvent.ACTION_UP)
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(clicks == 1) { "A name/icon refresh with the same action identity must preserve a normal tap" }
                down = SystemClock.uptimeMillis()
                touch(MotionEvent.ACTION_DOWN)
                tile.update(appB, appB.bundleID)
                touch(MotionEvent.ACTION_CANCEL)
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(clicks == 1) { "An explicit gesture cancellation must not click" }
                tile.performClick()
                check(clicks == 2) { "TalkBack performClick must remain available after an explicit cancellation" }
            }
        } finally {
            test.runOnMainSync { row.removeView(tile) }
            test.waitForIdleSync()
        }
    }
}
