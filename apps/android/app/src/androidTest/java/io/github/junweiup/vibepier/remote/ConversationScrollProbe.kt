package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Intent
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import io.github.junweiup.vibepier.remote.features.sessions.ConversationTimeline
import io.github.junweiup.vibepier.remote.features.sessions.InlineReplyProcess
import org.json.JSONArray
import org.json.JSONObject

/** Real Android layout/draw with synthetic rows; never connects to a provider. */
object ConversationScrollProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "readme")) as MainActivity
        lateinit var scroll: ScrollView
        lateinit var content: LinearLayout
        lateinit var timeline: ConversationTimeline
        val views = mutableMapOf<String, TextView>()
        var restored = 0
        var unwantedLoads = 0
        var restoredY = 0
        fun main(action: () -> Unit) {
            val failure = java.util.concurrent.atomic.AtomicReference<Throwable>()
            test.runOnMainSync { try { action() } catch (error: Throwable) { failure.set(error) } }
            failure.get()?.let { throw it }
        }
        fun settle() { test.waitForIdleSync(); Thread.sleep(120); test.waitForIdleSync() }
        fun rows(ids: List<String>, older: Boolean) = buildList {
            if (older) add(ConversationTimeline.Row("older", "", { TextView(activity).apply {
                text = "Load earlier messages"; layoutParams = LinearLayout.LayoutParams(-1, 64)
            } }))
            ids.forEach { id -> add(ConversationTimeline.Row("message:$id", id, {
                TextView(activity).apply {
                    text = "$id " + "Synthetic wrapped message content. ".repeat(12)
                    setPadding(10, 12, 10, 12)
                    layoutParams = LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = 17 }
                    views[id] = this
                }
            })) }
        }
        fun preserve() = timeline.preservePosition(scroll, false, null, { true }, { restored++ })
        fun screenTop(id: String) = views.getValue(id).top - scroll.scrollY
        try {
            main {
                content = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
                timeline = ConversationTimeline(content)
                scroll = ScrollView(activity).apply { isFillViewport = true; addView(content) }
                scroll.setOnScrollChangeListener { _, _, y, _, oldY ->
                    if (!timeline.restoringPosition && y < oldY && y < 320) unwantedLoads++
                }
                activity.setContentView(scroll)
                timeline.reconcile(rows((10..20).map(Int::toString), true))
            }
            settle()
            var expected = 0
            main {
                scroll.scrollTo(0, 0)
                expected = screenTop("10")
                check(timeline.anchor(0)?.key == "message:10") { "Loading header must not be the anchor" }
                preserve()
                timeline.reconcile(rows((5..20).map(Int::toString), true))
            }
            settle()
            main {
                check(screenTop("10") == expected) { "Prepend jumped: ${screenTop("10")} expected $expected" }
                check(restored == 1)
                // User moves while a history request is in flight: capture the current viewport at receipt.
                scroll.scrollTo(0, views.getValue("7").top + 39)
                expected = screenTop("7")
                preserve()
                timeline.reconcile(rows((1..20).map(Int::toString), false))
                // A second snapshot arrives before layout; retain the original measured anchor.
                preserve()
                timeline.reconcile(rows((0..21).map(Int::toString), false))
            }
            settle()
            main {
                check(screenTop("7") == expected) { "Header removal / coalesced prepend jumped" }
                check(restored == 2 && !timeline.restoringPosition)
                restoredY = scroll.scrollY
                timeline.preservePosition(scroll, false, restoredY, { true }, { restored++ })
                timeline.reconcile(rows((0..22).map(Int::toString), false))
            }
            settle()
            main { check(restored == 3 && scroll.scrollY == restoredY); check(unwantedLoads == 0) { "Restore triggered another history load" } }
            lateinit var process: InlineReplyProcess
            var reply: ((JSONObject) -> Unit)? = null
            var receiptY = 0
            var receiptHeight = 0
            fun parts(start: Int, end: Int) = JSONArray().apply {
                for (i in start..end) put(JSONObject().put("id", "part:$i").put("index", i)
                    .put("kind", "text").put("bodyLoaded", true).put("bodyVersion", "1")
                    .put("text", "Paragraph $i. " + "Synthetic reply content. ".repeat(20)))
            }
            main {
                val state = InlineReplyProcess.State().apply { accept(parts(8, 19), 20) }
                process = InlineReplyProcess(activity, state, { true },
                    { _, _, callback -> reply = callback }, { _, _, _ -> error("Unexpected output read") },
                    { android.view.View(activity) })
                content.removeAllViews(); content.addView(process)
            }
            settle()
            main { scroll.scrollTo(0, 150); check(process.loadEarlier()); check(reply != null) }
            settle()
            main {
                scroll.scrollTo(0, 300) // Continue scrolling while the history read is pending.
                receiptY = scroll.scrollY; receiptHeight = process.height
                reply!!.invoke(JSONObject().put("ok", true).put("parts", parts(0, 7)).put("partCount", 20))
            }
            settle()
            main {
                check(scroll.scrollY == receiptY + process.height - receiptHeight) {
                    "Earlier reply parts used stale request position or unmeasured height"
                }
            }
            return "PASS: wrapped message anchor unchanged at top and mid-row; pagination header excluded/removed; consecutive updates before layout coalesced; restore before draw; no recursive history load; delayed earlier reply parts preserve receipt-time viewport\n"
        } finally { main { activity.finish() } }
    }
}
