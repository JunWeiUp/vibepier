package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.usage.AppUsageLabels
import io.github.junweiup.vibepier.remote.features.usage.AppUsagePage
import io.github.junweiup.vibepier.remote.features.usage.AppUsageStrip

import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import org.json.JSONArray
import org.json.JSONObject

/** Isolated native-page data: never modifies the real Mac or the real app's records. */
internal object AppUsageProbe {
    fun fixture(): JSONObject {
        val names = listOf("ChatGPT", "Claude", "ZCode", "Microsoft Edge", "飞书", "Finder", "很长的第七个应用名称用于确认字体布局")
        val minutes = listOf(140, 95, 70, 52, 35, 12, 1)
        val colors = listOf("#BBDDB2", "#DB9788", "#B6A2D7", "#8EBAD1", "#CFBE94", "#94A9B5", "#B5CFCA")
        val day = java.time.LocalDate.now(java.time.ZoneId.of("Asia/Shanghai")).toString()
        val start = java.time.LocalDate.parse(day).atStartOfDay(java.time.ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli()
        val timeline = JSONArray().put(JSONArray(listOf("", start, start + 385 * 60000L)))
        var cursor = start + (385 + 254) * 60000L
        // Two separate visits to ChatGPT, with Claude between them.
        val visits = listOf(0 to 70, 1 to 95, 0 to 70) + (2..6).map { it to minutes[it] }
        visits.forEach { (index, duration) ->
            val end = cursor + duration * 60000L
            timeline.put(JSONArray(listOf("app.$index", cursor, end))); cursor = end
        }
        return JSONObject().put("ok", true).put("sourceID", "usage-probe-mac").put("sourceName", "Mac · 验证数据")
            .put("timeZone", "Asia/Shanghai").put("date", day).put("today", day).put("syncedAt", cursor).put("dayStart", start).put("timelineVersion", 1).put("timeline", timeline)
            .put("enabled", true).put("daySeconds", 86400).put("restSeconds", 385 * 60).put("unrecordedSeconds", 254 * 60)
            .put("futureSeconds", 396 * 60).put("currentAppID", "app.0")
            .put("apps", JSONArray(names.mapIndexed { i, name -> JSONObject().put("id", "app.$i").put("name", name).put("seconds", minutes[i] * 60).put("color", colors[i]) }))
    }
    fun run(instrumentation: Instrumentation): String {
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val requests = mutableListOf<(JSONObject) -> Unit>()
        var online = true
        var page: AppUsagePage? = null
        fun views(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) } else emptyList()
        fun labels(): List<String> = views(page!!.dialog.window!!.decorView).mapNotNull { (it as? CanvasLabel)?.text?.toString() }
        instrumentation.runOnMainSync {
            io.github.junweiup.vibepier.remote.core.security.PrivatePreferences.open(instrumentation.targetContext, "application-usage-cache").edit().clear().commit()
            page = AppUsagePage(activity, { _, _, callback -> requests += callback }, { online }, { true }, { "usage-probe-mac" }, {})
            page!!.show()
            check(labels().any { it == activity.getString(R.string.usage_loading) })
            requests.removeAt(0)(fixture())
            check(labels().contains(AppUsageLabels.duration(activity, 405.0 * 60)))
            check(labels().any { it.contains("28.1%") })
            check(labels().any { it == activity.getString(R.string.usage_show_apps, 7) })
            val more = views(page!!.dialog.window!!.decorView).filterIsInstance<CanvasLabel>().first { it.text.toString() == activity.getString(R.string.usage_show_apps, 7) }
            more.performClick()
            check(labels().any { it.contains("很长的第七个") })
            val strip = views(page!!.dialog.window!!.decorView).filterIsInstance<AppUsageStrip>().single()
            check(strip.contentDescription.toString().contains("ChatGPT"))
            check(strip.contentDescription.toString().contains(activity.getString(R.string.usage_unrecorded)))
            check(strip.contentDescription.toString().contains("10:39–11:49"))
            check(strip.contentDescription.toString().contains("13:24–14:34"))
            check(!strip.contentDescription.toString().contains("累计排列"))
            strip.highlight("app.0")
            online = false; page!!.connectionChanged()
            check(labels().any { it.startsWith(activity.getString(R.string.usage_offline_as_of, "")) })
            page!!.dismiss()
            // An offline reopen restores only this source's immutable snapshot.
            page = AppUsagePage(activity, { _, _, _ -> error("离线不应发请求") }, { false }, { true }, { "usage-probe-mac" }, {})
            page!!.show()
            check(labels().contains(AppUsageLabels.duration(activity, 405.0 * 60)))
            check(labels().none { it.endsWith(activity.getString(R.string.usage_current_suffix)) })
            page!!.dismiss()
            page = AppUsagePage(activity, { _, _, _ -> }, { false }, { true }, { "other-mac" }, {})
            page!!.show()
            check(labels().none { it == AppUsageLabels.duration(activity, 405.0 * 60) })
            check(labels().any { it == activity.getString(R.string.usage_connect_day) })
            page!!.dismiss()
            val legacy = fixture().apply { remove("timelineVersion"); remove("timeline") }
            page = AppUsagePage(activity, { _, _, callback -> callback(legacy) }, { true }, { true }, { "usage-probe-mac" }, {})
            page!!.show()
            check(labels().contains(AppUsageLabels.duration(activity, 405.0 * 60)))
            check(labels().any { it == activity.getString(R.string.usage_timeline_missing) })
            check(views(page!!.dialog.window!!.decorView).none { it is AppUsageStrip })
            page!!.dismiss()
        }
        // Capture the actual measured native layout, including the distribution at the bottom.
        instrumentation.runOnMainSync {
            online = true
            page = AppUsagePage(activity, { _, _, callback -> callback(fixture()) }, { true }, { true }, { "usage-probe-mac" }, {})
            page!!.show()
        }
        instrumentation.waitForIdleSync()
        android.os.SystemClock.sleep(200)
        instrumentation.runOnMainSync {
            val name = views(page!!.dialog.window!!.decorView).filterIsInstance<CanvasLabel>().single {
                it.text.toString() == "ChatGPT" + activity.getString(R.string.usage_current_suffix)
            }
            val layout = name.javaClass.getDeclaredField("layout").apply { isAccessible = true }.get(name) as android.text.Layout
            check(layout.getEllipsisCount(0) == 0) { "A short app name must remain readable beside or above its duration" }
        }
        val screenshots = activity.externalCacheDir!!
        fun capture(name: String) {
            instrumentation.uiAutomation.takeScreenshot().also { bitmap ->
                java.io.File(screenshots, name).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
        }
        capture("app-usage-top.png")
        instrumentation.runOnMainSync {
            val root = page!!.dialog.window!!.decorView
            val scrolling = views(root).filterIsInstance<android.widget.ScrollView>().first { it.isShown && it.height > 0 }
            scrolling.scrollTo(0, scrolling.getChildAt(0).height)
        }
        instrumentation.waitForIdleSync(); android.os.SystemClock.sleep(300)
        instrumentation.runOnMainSync {
            val strip = views(page!!.dialog.window!!.decorView).filterIsInstance<AppUsageStrip>().single()
            // Touch the second ChatGPT visit at 13:59, rather than its first rank in the totals list.
            val x = strip.width * (13 * 60 + 59) / 1440f
            val stamp = android.os.SystemClock.uptimeMillis()
            android.view.MotionEvent.obtain(stamp, stamp, android.view.MotionEvent.ACTION_DOWN, x, 10f, 0).also { strip.dispatchTouchEvent(it); it.recycle() }
            check(labels().any { it.contains("ChatGPT · 13:24–14:34") })
            android.view.MotionEvent.obtain(stamp, stamp, android.view.MotionEvent.ACTION_CANCEL, x, 10f, 0).also { strip.dispatchTouchEvent(it); it.recycle() }
        }
        instrumentation.waitForIdleSync()
        capture("app-usage-bottom.png")
        instrumentation.runOnMainSync { page!!.dismiss() }
        instrumentation.runOnMainSync { activity.finish() }
        return "PASS: native app usage total 405 min, day share 28.1%, expansion, actual interval positions/repeat visits, chart accessibility descriptions, immutable offline snapshot and Mac-source isolation."
    }
}
