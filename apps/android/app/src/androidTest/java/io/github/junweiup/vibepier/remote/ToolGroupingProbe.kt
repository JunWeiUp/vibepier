package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.sessions.InlineReplyProcess

import android.app.Instrumentation
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import org.json.JSONArray
import org.json.JSONObject

/** Synthetic ordered headers: no Mac, model request, shortcut, or production preference is used. */
object ToolGroupingProbe {
    private fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
    private fun js(index: Int) = JSONObject().put("id", "tool-$index").put("index", index).put("kind", "tool")
        .put("title", "cua_repl · js").put("status", "completed").put("bodyDeferred", true).put("bodyVersion", "version-$index")
        .apply { if (index == 11) put("images", JSONArray().put(JSONObject().put("id", "shot-11"))) }
    private fun group(view: View, count: Int) = views(view).first { it.contentDescription?.toString()?.contains(view.resources.getQuantityString(R.plurals.group_named_calls, count, "cua_repl · js", count)) == true }
    private fun steps(view: View) = views(view).filter { it.contentDescription?.toString()?.startsWith(view.context.getString(R.string.step_description_no_status, "cua_repl · js", "")) == true }

    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval"))
        val state = InlineReplyProcess.State()
        val reads = mutableListOf<String>(); val imageReads = mutableListOf<String>(); val pages = mutableListOf<Pair<Int, Int?>>()
        lateinit var process: InlineReplyProcess
        try {
            test.runOnMainSync {
                val entries = JSONArray().put(js(10).put("status", "running")).put(js(11))
                    .put(JSONObject().put("id", "paragraph").put("index", 12).put("kind", "text").put("text", "原位置的文字").put("bodyVersion", "paragraph"))
                    .put(js(13)).put(JSONObject().put("id", "file").put("index", 14).put("kind", "file").put("title", "文件编辑"))
                    .put(js(15)).put(JSONObject().put("id", "command").put("index", 16).put("kind", "command").put("title", "命令"))
                    .put(js(17)).put(JSONObject().put("id", "other").put("index", 18).put("kind", "tool").put("title", "functions · exec"))
                    .put(js(19)).put(js(20))
                state.accept(entries, 21)
                process = InlineReplyProcess(activity, state, { true }, { offset, before, done ->
                    pages.add(offset to before)
                    val earlier = JSONArray((offset until (before ?: 21)).map(::js))
                    done(JSONObject().put("ok", true).put("parts", earlier).put("partCount", state.count))
                }, { id, _, done -> reads.add(id); done(JSONObject().put("ok", true).put("text", "输出-$id").put("nextOffset", -1)) }, { images ->
                    for (i in 0 until images.length()) imageReads.add(images.getJSONObject(i).getString("id"))
                    View(activity)
                })
                activity.setContentView(process)
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(reads.isEmpty() && imageReads.toSet() == setOf("shot-11"))
                check(views(process).count { it.contentDescription?.toString()?.contains(activity.resources.getQuantityString(R.plurals.group_named_calls, 2, "cua_repl · js", 2)) == true } == 2)
                check(steps(process).size == 3) // Only the singleton JS entries separated by prose/file/command/another tool are visible.
                group(process, 2).performClick()
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(reads.isEmpty() && imageReads.toSet() == setOf("shot-11"))
                check(steps(process).size == 5)
                steps(process).first().performClick()
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(reads == listOf("tool-10") && imageReads.toSet() == setOf("shot-11"))
                check(process.loadEarlier())
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(pages == listOf(2 to 10))
                check(group(process, 10).contentDescription.toString().startsWith("▾"))
                check(reads == listOf("tool-10") && imageReads.toSet() == setOf("shot-11"))
                val titles = steps(process); check(titles.size == 13)
                group(process, 10).performClick()
                check(!state.bodies.getValue("tool-10").expanded && state.bodies.getValue("tool-10").loaded)
                check(process.loadEarlier())
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(pages == listOf(2 to 10, 0 to 2))
                check(group(process, 12).contentDescription.toString().startsWith("▸"))
                check(reads == listOf("tool-10") && imageReads.toSet() == setOf("shot-11"))
                state.accept(JSONArray().put(js(21)), 22); state.changed()
                check(group(process, 12).contentDescription.toString().startsWith("▸"))
                check(group(process, 3).contentDescription.toString().startsWith("▸"))
                val restored = InlineReplyProcess.State().apply { restore(state.snapshot()) }
                check(restored.groups.values.none { it } && !restored.bodies.getValue("tool-10").expanded && restored.bodies.getValue("tool-10").text == "输出-tool-10")
                // A finished/body-version patch invalidates only the fetched body; the closed child stays closed.
                state.accept(JSONArray().put(js(10).put("bodyVersion", "finished-10")), state.count); state.changed()
                check(!state.bodies.getValue("tool-10").expanded && !state.bodies.getValue("tool-10").loaded)
                group(process, 12).performClick()
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(reads == listOf("tool-10") && imageReads.toSet() == setOf("shot-11")) // Reopening only lists closed headings despite the patch.
                steps(process)[11].performClick()
            }
            test.waitForIdleSync()
            test.runOnMainSync {
                check(reads == listOf("tool-10", "tool-11") && "shot-11" in imageReads)
                val openState = InlineReplyProcess.State().apply { restore(state.snapshot()) }
                check(openState.groups.getValue("tool:tool-0") && openState.bodies.getValue("tool-11").expanded)

            }
            SemanticGroupingProbe.run(test, activity)
            return "PASS: adjacent semantic processing groups default folded; MCP methods/prose/plans/approvals/failed notices/index gaps preserve boundaries; mixed running/failed statuses remain visible; image previews remain visible in folded groups; only a tapped child reads output; earlier pagination and durable cache preserve explicit choices; collapse clears child expansion without clearing fetched bodies; completion patches and group reopen cause no reads\n"
        } finally { test.runOnMainSync { activity.finish() } }
    }
}
