package io.github.junweiup.vibepier.remote.features.usage

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.IconControl
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.protectControls
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.app.AlertDialog
import android.app.DatePickerDialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.time.LocalDate
import java.util.Locale
import java.util.TimeZone

/** Native source-wide reader; no foreground application is launched by viewing statistics. */
internal class AppUsagePage(
    private val context: Context,
    private val request: (String, JSONObject, (JSONObject) -> Unit) -> Unit,
    private val online: () -> Boolean,
    private val paired: () -> Boolean,
    private val source: () -> String,
    private val authorize: () -> Unit,
    private val onDismiss: () -> Unit = {}
) {
    private val main = Handler(Looper.getMainLooper())
    private val compactType get() = context.resources.configuration.screenWidthDp <= 360 && context.resources.configuration.fontScale > 1.2f
    private val cache = AppUsageCache(context)
    private var expectedSource = source()
    private var selectedDate = ""
    private var defaultDate = true
    private var snapshot: AppUsageSnapshot? = null
    private var metadata: AppUsageSnapshot? = null
    private var generation = 0
    private var loading = false
    private var closed = false
    private var foreground = true
    private var wasOnline = online()
    private var expanded = false
    private var error = ""
    private var selected = ""
    private var order = emptyList<String>()
    private var strip: AppUsageStrip? = null
    private var preview: CanvasLabel? = null
    private val rows = mutableMapOf<String, View>()
    private val auxiliaries = mutableSetOf<AlertDialog>()
    private val body = column()
    private val scroll = ScrollView(context).apply { isFillViewport = false; addView(body) }
    val dialog: AlertDialog
    private val refresh = Runnable { if (!closed && foreground && dialog.isShowing) load(false) }

    init {
        val root = column().apply { setBackgroundColor(Palette.background) }
        root.addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(8), dp(8), 0)
            addView(IconControl(context, IconControl.Icon.BACK, context.getString(R.string.usage_back), Palette.text) { dismiss() }, LinearLayout.LayoutParams(dp(48), dp(48)))
            addView(Ui.label(context, context.getString(R.string.usage_title), 22f).apply { typeface = Typeface.DEFAULT_BOLD }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(Ui.button(context, "ⓘ", Ui.Button.TEXT) { explain() }.apply { contentDescription = context.getString(R.string.usage_manage_description) }, LinearLayout.LayoutParams(dp(48), dp(48)))
        }, LinearLayout.LayoutParams(-1, -2))
        root.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
        body.setPadding(dp(16), dp(6), dp(16), dp(24))
        dialog = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).setView(root).create().apply {
            setOnDismissListener {
                closed = true; generation++; main.removeCallbacks(refresh)
                auxiliaries.toList().forEach { it.dismiss() }; auxiliaries.clear(); onDismiss()
            }
        }
    }

    fun show() {
        dialog.show(); dialog.window?.apply {
            protectControls(); setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Palette.background))
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }
        load(true)
    }
    fun dismiss() = dialog.dismiss()
    fun suspend() { foreground = false; generation++; loading = false; main.removeCallbacks(refresh); auxiliaries.toList().forEach { it.dismiss() }; render() }
    fun resume() { foreground = true; if (!closed) load(false) }
    fun connectionChanged() {
        if (closed) return
        val currentSource = source()
        var sourceChanged = false
        if (currentSource.isNotBlank() && expectedSource.isNotBlank() && currentSource != expectedSource) {
            sourceChanged = true
            generation++; loading = false; expectedSource = currentSource; snapshot = null; metadata = null; selectedDate = ""; defaultDate = true; order = emptyList(); selected = ""
            error = context.getString(R.string.usage_source_changed); auxiliaries.toList().forEach { it.dismiss() }
        }
        val changed = wasOnline != online()
        wasOnline = online()
        if (!online() && changed) { generation++; loading = false; main.removeCallbacks(refresh); render() }
        else if (foreground && !loading && (changed || sourceChanged)) load(false)
    }

    private fun load(resetOrder: Boolean) {
        if (closed || !foreground) return
        if (selectedDate.isBlank() && snapshot == null) cache.latest(expectedSource)?.let {
            metadata = try { AppUsageSnapshot.parse(it) } catch (_: Exception) { null }
            metadata?.let { value ->
                selectedDate = value.today
                snapshot = cache.read(expectedSource, value.today)?.let { record -> try { AppUsageSnapshot.parse(record) } catch (_: Exception) { null } }
                order = snapshot?.apps?.map { app -> app.id } ?: emptyList()
            }
        }
        if (selectedDate.isNotBlank() && snapshot == null) {
            cache.read(expectedSource, selectedDate)?.let { snapshot = try { AppUsageSnapshot.parse(it) } catch (_: Exception) { null } }
        }
        if (!online() || !paired()) { loading = false; render(); return }
        loading = true; error = ""; render()
        val token = ++generation
        val fields = fields()
        request("appUsage", fields) { reply ->
            if (closed || !foreground || token != generation) return@request
            accept(reply, resetOrder)
        }
    }

    private fun fields() = JSONObject().put("provider", "codex").apply {
        if (selectedDate.isNotBlank() && !defaultDate) put("date", selectedDate)
        if (expectedSource.isNotBlank()) put("sourceID", expectedSource)
    }

    private fun accept(reply: JSONObject, resetOrder: Boolean) {
        loading = false
        if (!reply.optBoolean("ok")) error = reply.optString("error", context.getString(R.string.usage_read_failed))
        else {
            val value = runCatching { AppUsageSnapshot.parse(reply) }.getOrNull()
            when {
                value == null -> error = context.getString(R.string.usage_incomplete)
                expectedSource.isNotBlank() && value.source != expectedSource -> error = context.getString(R.string.usage_source_mismatch)
                !defaultDate && selectedDate.isNotBlank() && value.date != selectedDate -> error = context.getString(R.string.usage_date_mismatch)
                else -> {
                    snapshot = value; metadata = value; expectedSource = value.source; selectedDate = value.date; defaultDate = false
                    order = if (resetOrder || order.isEmpty()) value.apps.map { it.id } else order.filter { id -> value.apps.any { it.id == id } } + value.apps.map { it.id }.filter { it !in order }
                    try { cache.remember(reply) } catch (_: Exception) { error = context.getString(R.string.usage_cache_failed) }
                }
            }
        }
        render()
        main.removeCallbacks(refresh)
        val value = snapshot
        if (foreground && online() && value?.enabled == true && selectedDate == value.today) main.postDelayed(refresh, 60_000)
    }

    private fun changeDate(date: String) {
        generation++; main.removeCallbacks(refresh); selectedDate = date; defaultDate = false; expanded = false; selected = ""; order = emptyList()
        snapshot = cache.read(expectedSource, date)?.let { try { AppUsageSnapshot.parse(it) } catch (_: Exception) { null } }
        error = ""; scroll.scrollTo(0, 0); load(true)
    }

    private fun render() {
        val oldScroll = scroll.scrollY
        body.removeAllViews(); rows.clear(); strip = null
        val value = snapshot
        val dates = metadata
        val dateRow = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            addView(Ui.button(context, "‹", Ui.Button.TONAL) {
                if (selectedDate.isNotBlank()) changeDate(LocalDate.parse(selectedDate).minusDays(1).toString())
            }.apply { contentDescription = context.getString(R.string.usage_previous_day); isEnabled = selectedDate.isNotBlank() && !loading && dates != null && LocalDate.parse(selectedDate) > LocalDate.parse(dates.today).minusDays(89) }, LinearLayout.LayoutParams(dp(48), dp(48)))
            addView(Ui.button(context, if (selectedDate.isBlank() || (online() && selectedDate == dates?.today)) context.getString(R.string.usage_today) else "$selectedDate ▾", Ui.Button.TEXT) { chooseDate() }.apply {
                isEnabled = dates != null && !loading
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(Ui.button(context, "›", Ui.Button.TONAL) {
                if (selectedDate.isNotBlank()) changeDate(LocalDate.parse(selectedDate).plusDays(1).toString())
            }.apply { contentDescription = context.getString(R.string.usage_next_day); isEnabled = dates != null && selectedDate < dates.today && !loading }, LinearLayout.LayoutParams(dp(48), dp(48)))
        }
        body.addView(dateRow)
        body.addView(Ui.label(context, dates?.let { "${it.sourceName} · ${it.timeZone}" } ?: context.getString(R.string.usage_foreground_usage), Ui.CAPTION, Palette.muted).apply { gravity = Gravity.CENTER }, params(10))
        if (dates != null && selectedDate != dates.today) body.addView(Ui.button(context, context.getString(R.string.usage_back_today), Ui.Button.TEXT) { changeDate(dates.today) }, params(4))
        if (value != null) body.addView(Ui.label(context,
            when { !online() -> context.getString(R.string.usage_offline_as_of, time(value.syncedAt, value.timeZone, true))
                !foreground -> context.getString(R.string.usage_as_of, time(value.syncedAt, value.timeZone, true))
                loading -> context.getString(R.string.usage_syncing)
                !value.enabled -> context.getString(R.string.usage_paused_sync, time(value.syncedAt, value.timeZone))
                else -> context.getString(R.string.usage_synced, time(value.syncedAt, value.timeZone)) }, Ui.CAPTION, Palette.faint).apply { gravity = Gravity.CENTER }, params(5))
        if (error.isNotBlank()) body.addView(Ui.label(context, error, Ui.LABEL, Palette.red), params(14))
        if (!paired()) {
            card(context.getString(R.string.usage_authorize_title), context.getString(R.string.usage_authorize_explanation))
            body.addView(Ui.button(context, context.getString(R.string.usage_authorize)) { authorize(); error = context.getString(R.string.usage_authorize_pending); render() }, params(12))
        } else if (value == null) {
            card(if (loading) context.getString(R.string.usage_loading) else context.getString(R.string.usage_connect_day), if (loading) context.getString(R.string.usage_local_records) else context.getString(R.string.usage_no_synced_day))
        } else {
            // The total is the headline: a large number, then one bar showing how it splits between applications.
            body.addView(Ui.label(context, if (selectedDate == value.today) context.getString(R.string.usage_today_total) else context.getString(R.string.usage_day_total), Ui.LABEL, Palette.muted), params(18))
            body.addView(Ui.label(context, AppUsageLabels.duration(context, value.total), if (compactType) 32f else 40f, Palette.text).apply {
                typeface = Typeface.DEFAULT_BOLD; letterSpacing = -.01f
            }, params(2))
            body.addView(Ui.label(context, context.getString(R.string.usage_day_share_apps, AppUsageMath.percent(value.total, value.daySeconds), value.apps.size) +
                (if (compactType) "\n" else " · ") + context.getString(R.string.usage_coverage, AppUsageLabels.duration(context, value.coverage)), Ui.CAPTION, Palette.faint), params(4))
            if (value.apps.isNotEmpty() && value.total > 0) body.addView(ShareBar(context, value.apps.sortedByDescending { it.seconds }.let { apps ->
                apps.take(4).map { it.seconds to color(it.color) } + listOfNotNull(apps.drop(4).sumOf { it.seconds }.takeIf { it > 0 }?.let { it to Palette.surface4 })
            }), LinearLayout.LayoutParams(-1, dp(10)).apply { topMargin = dp(14) })
            if (!value.enabled) {
                body.addView(Ui.label(context, context.getString(R.string.usage_starts_now), Ui.CAPTION, Palette.muted), params(12))
                body.addView(Ui.button(context, context.getString(R.string.usage_enable), Ui.Button.PRIMARY) { setEnabled(true) }.apply { isEnabled = online() && !loading }, params(8))
            }
            if (value.apps.isEmpty()) body.addView(Ui.label(context, if (selectedDate == value.today) context.getString(R.string.usage_empty_today) else context.getString(R.string.usage_empty_day), Ui.BODY, Palette.muted), params(24))
            else {
                val group = Ui.listGroup(context)
                val apps = value.apps.sortedBy { order.indexOf(it.id).takeIf { n -> n >= 0 } ?: Int.MAX_VALUE }
                (if (expanded) apps else apps.take(6)).forEach { app ->
                    val row = applicationRow(app, value)
                    rows[app.id] = row; Ui.addGroupRow(group, row)
                }
                body.addView(group, params(14))
                if (apps.size > 6) body.addView(Ui.button(context, if (expanded) context.getString(R.string.usage_collapse_apps) else context.getString(R.string.usage_show_apps, apps.size), Ui.Button.TEXT) { expanded = !expanded; render() }, params(4))
            }
            distribution(value)
        }
        body.addView(Ui.button(context, if (loading) context.getString(R.string.usage_syncing) else context.getString(R.string.usage_resync), Ui.Button.TEXT) { load(false) }.apply { isEnabled = online() && !loading }, params(10))
        body.post { if (!closed) scroll.scrollTo(0, oldScroll) }
    }

    private fun applicationRow(app: AppUsageApplication, value: AppUsageSnapshot): View = LinearLayout(context).apply {
        gravity = Gravity.CENTER_VERTICAL; minimumHeight = dp(64); setPadding(dp(14), dp(10), dp(14), dp(10))
        isFocusable = true
        contentDescription = context.getString(R.string.usage_app_description, app.name, AppUsageLabels.duration(context, app.seconds), AppUsageMath.percent(app.seconds, value.total))
        if (selected == app.id) background = Ui.roundRect(context, Palette.accentContainer, 0)
        val bitmap = try { if (app.icon.isBlank()) null else Base64.decode(app.icon, Base64.DEFAULT).let { BitmapFactory.decodeByteArray(it, 0, it.size) } } catch (_: Exception) { null }
        if (bitmap != null) addView(ImageView(context).apply { setImageBitmap(bitmap); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }, LinearLayout.LayoutParams(dp(34), dp(34)).apply { marginEnd = dp(12) })
        else addView(Ui.label(context, app.name.take(1), Ui.BODY, Palette.background).apply { gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD; background = Ui.roundRect(context, color(app.color), 9) }, LinearLayout.LayoutParams(dp(34), dp(34)).apply { marginEnd = dp(12) })
        val current = selectedDate == value.today && app.id == value.current && online() && this@AppUsagePage.foreground && value.enabled
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL
                orientation = if (compactType) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
                addView(Ui.label(context, app.name + if (current) context.getString(R.string.usage_current_suffix) else "", if (compactType) Ui.LABEL else Ui.BODY).apply {
                    maxLines = 1; typeface = Ui.medium; ellipsize = android.text.TextUtils.TruncateAt.END
                }, if (compactType) LinearLayout.LayoutParams(-1, -2) else LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(8) })
                addView(Ui.label(context, "${AppUsageLabels.duration(context, app.seconds)} · ${AppUsageMath.percent(app.seconds, value.total)}", Ui.CAPTION, Palette.muted),
                    LinearLayout.LayoutParams(-2, -2).apply { if (compactType) topMargin = dp(2) })
            })
            addView(ShareBar(context, listOf(app.seconds to color(app.color)), total = value.total, track = Palette.surface2),
                LinearLayout.LayoutParams(-1, dp(5)).apply { topMargin = dp(8) })
        }, LinearLayout.LayoutParams(0, -2, 1f))
        setOnClickListener { selected = app.id; highlightSelected(); showDetail(app.id) }
    }

    /** Proportions on one rounded track; with `total`, the parts fill only their share of it. */
    private class ShareBar(context: Context, private val parts: List<Pair<Double, Int>>, private val total: Double = parts.sumOf { it.first },
                           private val track: Int? = null) : View(context) {
        private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        private val gap = resources.displayMetrics.density * 2
        private val clip = android.graphics.Path()
        init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }
        override fun onDraw(canvas: android.graphics.Canvas) {
            val radius = height / 2f
            clip.reset(); clip.addRoundRect(0f, 0f, width.toFloat(), height.toFloat(), radius, radius, android.graphics.Path.Direction.CW)
            canvas.save(); canvas.clipPath(clip)
            track?.let { paint.color = it; canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint) }
            if (total > 0) {
                var x = 0f
                parts.forEachIndexed { index, (seconds, color) ->
                    val w = (seconds / total * width).toFloat()
                    paint.color = color
                    canvas.drawRect(x, 0f, (x + w - if (index < parts.lastIndex) gap else 0f).coerceAtLeast(x), height.toFloat(), paint)
                    x += w
                }
            }
            canvas.restore()
        }
    }

    private fun distribution(value: AppUsageSnapshot) {
        val categories = value.segments(order).filter { it.kind != "app" }
        body.addView(column().apply {
            background = Ui.roundRect(context, Palette.surface1, 18); setPadding(dp(16), dp(16), dp(16), dp(12))
            addView(Ui.label(context, context.getString(R.string.usage_timeline_title), Ui.HEADLINE).apply { typeface = Ui.medium })
            if (value.timeline == null) {
                addView(Ui.label(context, context.getString(R.string.usage_timeline_missing), Ui.CAPTION, Palette.muted), params(12))
                return@apply
            }
            preview = Ui.label(context, context.getString(R.string.usage_timeline_hint), Ui.CAPTION, Palette.muted)
            addView(preview, params(12))
            fun part(range: AppUsageTimeRange): AppUsageSegment = if (range.kind == "app") value.apps.first { it.id == range.id }.let {
                AppUsageSegment(it.id, it.name, range.seconds, it.color)
            } else categories.first { it.kind == range.kind }.copy(seconds = range.seconds)
            strip = AppUsageStrip(context, value, { range ->
                preview?.text = "${AppUsageLabels.name(context, part(range))} · ${value.timeRange(range)} · ${AppUsageLabels.duration(context, range.seconds)}"
            }, { range ->
                val segment = part(range)
                selected = segment.id; highlightSelected()
                if (range.kind == "app") showDetail(range.id)
                else showCategory(segment, value.timeRange(range))
            }).also { it.highlight(selected) }
            addView(strip, LinearLayout.LayoutParams(-1, dp(84)).apply { topMargin = dp(14) })
            addView(Ui.label(context, context.getString(R.string.usage_timeline_order), Ui.CAPTION, Palette.faint).apply { gravity = Gravity.CENTER }, params(8))
            if (value.daySeconds != 86400.0) addView(Ui.label(context, context.getString(R.string.usage_dst_explanation, AppUsageLabels.duration(context, value.daySeconds)), Ui.CAPTION, Palette.muted), params(8))
            categories.forEach { part -> addView(Ui.button(context, "${if (part.kind == "unrecorded") "▨" else if (part.kind == "future") "▢" else "■"} ${AppUsageLabels.name(context, part)} · ${AppUsageLabels.duration(context, part.seconds)}", Ui.Button.TEXT) { showCategory(part) }) }
        }, params(16))
    }

    private fun showDetail(id: String) {
        val value = snapshot ?: return
        val app = value.apps.firstOrNull { it.id == id } ?: return
        val content = column().apply {
            addView(Ui.label(context, "${value.date} · ${AppUsageLabels.duration(context, app.seconds)}", Ui.HEADLINE, Palette.accent))
            addView(Ui.label(context, context.getString(R.string.usage_app_shares, AppUsageMath.percent(app.seconds, value.total), AppUsageMath.percent(app.seconds, value.daySeconds))), params(12))
            val intervals = value.timeline?.filter { it.kind == "app" && it.id == id }?.map { Triple(it.id, it.start, it.end) } ?: value.intervals.filter { it.first == id }
            if (intervals.isNotEmpty()) {
                addView(Ui.overline(context, context.getString(R.string.usage_recent_intervals)), params(20))
                intervals.takeLast(20).forEach { (_, start, end) -> addView(Ui.label(context, "${value.timeRange(AppUsageTimeRange(id, start, end, "app"))} · ${AppUsageLabels.duration(context, (end - start) / 1000.0)}", Ui.CAPTION, Palette.muted), params(8)) }
            }
        }
        detail(app.name, content) { highlightSelected() }
    }
    private fun showCategory(part: AppUsageSegment, timeRange: String? = null) {
        selected = part.id; highlightSelected()
        val explanation = when (part.kind) {
            "rest" -> context.getString(R.string.usage_rest_explanation)
            "unrecorded" -> context.getString(R.string.usage_unrecorded_explanation)
            else -> if (!online()) context.getString(R.string.usage_remaining_offline) else context.getString(R.string.usage_future_explanation)
        }
        detail(AppUsageLabels.name(context, part), column().apply { if (timeRange != null) addView(Ui.label(context, timeRange, Ui.HEADLINE, Palette.accent), params(8)); addView(Ui.label(context, AppUsageLabels.duration(context, part.seconds), 24f, Palette.accent)); addView(Ui.label(context, explanation, Ui.BODY, Palette.muted), params(12)) })
    }
    private fun explain() {
        val value = snapshot
        val content = column().apply {
            addView(Ui.label(context, context.getString(R.string.usage_explanation), Ui.BODY, Palette.muted))
            addView(Ui.label(context, context.getString(R.string.usage_source_details, value?.sourceName ?: context.getString(R.string.usage_not_synced), value?.timeZone ?: context.getString(R.string.usage_mac_timezone)), Ui.CAPTION, Palette.faint), params(16))
            if (value != null) addView(Ui.button(context, if (value.enabled) context.getString(R.string.usage_pause) else context.getString(R.string.usage_enable)) { auxiliaries.toList().forEach { it.dismiss() }; setEnabled(!value.enabled) }.apply { isEnabled = online() && !loading }, params(16))
        }
        detail(context.getString(R.string.usage_about), content)
    }
    private fun setEnabled(enabled: Boolean) {
        if (!online() || loading) return
        loading = true; error = ""; render()
        val token = ++generation
        val controls = context.getSharedPreferences("application-usage-controls", Context.MODE_PRIVATE)
        val sequence = maxOf(System.currentTimeMillis(), controls.getLong("mutationSequence", 0) + 1)
        if (!controls.edit().putLong("mutationSequence", sequence).commit()) { loading = false; error = context.getString(R.string.usage_mutation_save_failed); render(); return }
        request("appUsageSet", fields().put("enabled", enabled).put("mutationSequence", sequence)) { reply ->
            if (closed || !foreground || token != generation) return@request
            accept(reply, false)
        }
    }
    private fun chooseDate() {
        val value = metadata ?: return
        val chosen = LocalDate.parse(selectedDate.ifBlank { value.today })
        val pickerSource = expectedSource
        DatePickerDialog(context, { _, year, month, day ->
            if (closed || !foreground || expectedSource != pickerSource) return@DatePickerDialog
            val date = LocalDate.of(year, month + 1, day)
            if (date <= LocalDate.parse(value.today) && date >= LocalDate.parse(value.today).minusDays(89)) changeDate(date.toString())
        }, chosen.year, chosen.monthValue - 1, chosen.dayOfMonth).apply {
            val formatter = SimpleDateFormat("yyyy-MM-dd", Locale.US)
            datePicker.maxDate = formatter.parse(value.today)!!.time
            datePicker.minDate = formatter.parse(LocalDate.parse(value.today).minusDays(89).toString())!!.time
            auxiliaries.add(this)
            setOnDismissListener { auxiliaries.remove(this) }
            show(); window?.protectControls()
        }
    }
    private fun detail(title: String, content: LinearLayout, dismissed: () -> Unit = {}) {
        content.setPadding(dp(20), dp(12), dp(20), dp(20))
        val popup = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog).setTitle(title)
            .setView(ScrollView(context).apply { addView(content) }).setNegativeButton(context.getString(R.string.usage_done), null).create()
        auxiliaries.add(popup)
        popup.setOnDismissListener { auxiliaries.remove(popup); dismissed() }
        popup.show(); popup.window?.protectControls()
    }
    private fun card(title: String, subtitle: String) {
        body.addView(column().apply {
            background = Ui.roundRect(context, Palette.surface1, 18); setPadding(dp(20), dp(20), dp(20), dp(20))
            addView(Ui.label(context, title, 20f).apply { typeface = Ui.medium }); addView(Ui.label(context, subtitle, Ui.BODY, Palette.muted), params(12))
        }, params(20))
    }
    private fun time(milliseconds: Long, zone: String, date: Boolean = false) = SimpleDateFormat(if (date) "MM-dd HH:mm" else "HH:mm", Locale.CHINA).apply { timeZone = TimeZone.getTimeZone(zone) }.format(java.util.Date(milliseconds))
    private fun color(value: String) = try { Color.parseColor(value) } catch (_: Exception) { Palette.accent }
    private fun highlightSelected() {
        rows.forEach { (id, row) -> row.background = if (id == selected) Ui.roundRect(context, Palette.accentContainer, 0) else null }
        strip?.highlight(selected)
    }
    private fun column() = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private fun params(top: Int = 0) = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }
    private fun dp(value: Int) = Ui.dp(context, value)
}
