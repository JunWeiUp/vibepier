package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.sessions.InlineReplyProcess

import android.app.Activity
import android.app.Instrumentation
import android.view.View
import android.view.ViewGroup
import org.json.JSONArray
import org.json.JSONObject

/** Group taxonomy and explicit lazy reads, exercised only with synthetic headers in the review build. */
internal object SemanticGroupingProbe {
    private fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
    private fun row(index: Int, kind: String, title: String, type: String = "", tool: String = "", status: String = "completed") = JSONObject()
        .put("id", "semantic-$index").put("index", index).put("kind", kind).put("title", title).put("groupType", type).put("toolName", tool)
        .put("status", status).put("text", if (kind in setOf("text", "plan")) "原位置的 $kind 正文" else "预览-$index")
        .put("bodyDeferred", kind !in setOf("text", "plan")).put("bodyVersion", "semantic-version-$index")
    private fun group(root: View, title: String) = views(root).first { it.contentDescription?.toString()?.contains(title) == true }
    private fun child(root: View, title: String) = views(root).first { it.contentDescription?.toString()?.startsWith(root.context.getString(R.string.step_description_no_status, title, "")) == true }

    fun run(test: Instrumentation, activity: Activity) {
        fun actionTitle(resource: Int) = activity.getString(R.string.group_action_count, activity.getString(resource), 2)
        val readTitle = actionTitle(R.string.group_file_read)
        val imagesTitle = actionTitle(R.string.group_image_view)
        val thinkingTitle = activity.resources.getQuantityString(R.plurals.group_thoughts, 2, 2)
        val noticeTitle = activity.resources.getQuantityString(R.plurals.group_notices, 2, 2)
        val state = InlineReplyProcess.State(); val reads = mutableListOf<String>(); val imageReads = mutableListOf<String>()
        lateinit var process: InlineReplyProcess
        val entries = JSONArray()
            .put(row(0, "tool", "读取 A", "file-read", "Read", "running")).put(row(1, "tool", "读取 B", "file-read", "Read", "failed"))
            .put(row(2, "text", "文字"))
            .put(row(3, "tool", "搜索 TODO", "file-search", "Grep")).put(row(4, "tool", "查找 *.kt", "file-search", "Glob"))
            .put(row(5, "tool", "搜索网页 A", "web-search", "WebSearch")).put(row(6, "tool", "搜索网页 B", "web-search", "WebSearch"))
            .put(row(7, "tool", "访问 A", "web-fetch", "WebFetch")).put(row(8, "tool", "访问 B", "web-fetch", "WebFetch"))
            .put(row(9, "tool", "子任务 · A", "agent", "Task")).put(row(10, "tool", "子任务 · B", "agent", "Agent"))
            .put(row(11, "tool", "图片 A", "image-view", "imageView")).put(row(12, "tool", "图片 B", "image-view", "imageView").put("images", JSONArray().put(JSONObject().put("id", "semantic-image"))))
            .put(row(13, "tool", "生成 A", "image-generation", "imageGeneration")).put(row(14, "tool", "生成 B", "image-generation", "imageGeneration"))
            .put(row(15, "thinking", "分析 A", "thinking")).put(row(16, "thinking", "分析 B", "thinking"))
            .put(row(17, "notice", "压缩 A", "notice:compaction")).put(row(18, "notice", "压缩 B", "notice:compaction"))
            .put(row(19, "notice", "压缩失败", "notice:compaction", status = "failed")).put(row(20, "notice", "压缩未执行", "notice:compaction", status = "declined"))
            .put(row(21, "notice", "模型 A", "notice:model_change")).put(row(22, "notice", "模型 B", "notice:model_change"))
            .put(row(23, "plan", "计划"))
            .put(row(24, "tool", "请求审批 A", "approval", "Read")).put(row(25, "tool", "请求审批 B", "approval", "Read"))
            .put(row(26, "tool", "更新计划 A", "plan", "TodoWrite")).put(row(27, "tool", "更新计划 B", "plan", "TodoWrite"))
            .put(row(28, "tool", "操作参数 A", "tool:server.method", "server · method")).put(row(29, "tool", "操作参数 B", "tool:server.method", "server · method"))
            .put(row(30, "tool", "另一个参数 A", "tool:other.method", "other · method")).put(row(31, "tool", "另一个参数 B", "tool:other.method", "other · method"))
            .put(row(32, "tool", "缺页前读取", "file-read", "Read")).put(row(34, "tool", "缺页后读取", "file-read", "Read"))
            .put(row(35, "tool", "附件 A.pdf", "attachment")).put(row(36, "tool", "附件 B.pdf", "attachment"))
        test.runOnMainSync {
            state.accept(entries, 37)
            process = InlineReplyProcess(activity, state, { true }, { _, _, _ -> error("Group opening must not fetch headers") },
                { id, _, done -> reads.add(id); done(JSONObject().put("ok", true).put("text", "完整-$id").put("nextOffset", -1)) },
                { images -> imageReads.add(images.getJSONObject(0).getString("id")); View(activity) })
            activity.setContentView(process)
        }
        test.waitForIdleSync()
        test.runOnMainSync {
            check(reads.isEmpty() && imageReads.toSet() == setOf("semantic-image"))
            val titles = listOf(R.string.group_file_read, R.string.group_file_search, R.string.group_web_search,
                R.string.group_web_fetch, R.string.group_agent, R.string.group_image_view,
                R.string.group_image_generation, R.string.group_attachment).map(::actionTitle) +
                listOf(thinkingTitle, noticeTitle) + listOf("server · method", "other · method").map {
                    activity.resources.getQuantityString(R.plurals.group_named_calls, 2, it, 2)
                }
            titles.forEach { check(group(process, it).contentDescription.toString().startsWith("▸")) }
            val readGroup = group(process, readTitle).contentDescription.toString()
            check(activity.getString(R.string.running) in readGroup && activity.resources.getQuantityString(R.plurals.group_failed, 1, 1) in readGroup)
            check(views(process).count { it.contentDescription?.toString()?.contains(noticeTitle) == true } == 2)
            for (title in listOf("压缩失败", "压缩未执行", "请求审批 A", "请求审批 B", "更新计划 A", "更新计划 B", "缺页前读取", "缺页后读取")) child(process, title)
            // Include the exact old durable-cache combination: closed group with open, unfetched child.
            state.bodies.getValue("semantic-0").expanded = true
            state.groups["tool:semantic-0"] = false; state.groups["tool:semantic-1"] = false
            val oldCache = state.snapshot(); state.rows.clear(); state.bodies.clear(); state.groups.clear(); state.restore(oldCache); state.changed()
            group(process, readTitle).performClick()
        }
        test.waitForIdleSync()
        test.runOnMainSync {
            check(reads.isEmpty() && imageReads.toSet() == setOf("semantic-image") && !state.bodies.getValue("semantic-0").expanded)
            child(process, "读取 A").performClick()
        }
        test.waitForIdleSync()
        test.runOnMainSync {
            check(reads == listOf("semantic-0"))
            group(process, readTitle).performClick()
            check(!state.bodies.getValue("semantic-0").expanded && state.bodies.getValue("semantic-0").text == "完整-semantic-0")
            state.accept(JSONArray().put(row(0, "tool", "读取 A", "file-read", "Read").put("bodyVersion", "finished")), state.count); state.changed()
            group(process, readTitle).performClick()
            group(process, imagesTitle).performClick()
            group(process, thinkingTitle).performClick()
            group(process, noticeTitle).performClick()
        }
        test.waitForIdleSync()
        test.runOnMainSync {
            check(reads == listOf("semantic-0") && imageReads.toSet() == setOf("semantic-image"))
            child(process, "图片 B").performClick()
        }
        test.waitForIdleSync()
        test.runOnMainSync {
            check(reads == listOf("semantic-0", "semantic-12") && imageReads.toSet() == setOf("semantic-image"))
            group(process, imagesTitle).performClick()
            state.accept(JSONArray().put(row(12, "tool", "图片 B", "image-view", "imageView").put("bodyVersion", "new-image")
                .put("images", JSONArray().put(JSONObject().put("id", "semantic-image-new")))), state.count); state.changed()
            group(process, imagesTitle).performClick()
        }
        test.waitForIdleSync()
        test.runOnMainSync {
            check(reads == listOf("semantic-0", "semantic-12") && imageReads.toSet() == setOf("semantic-image", "semantic-image-new"))
            check(!state.bodies.getValue("semantic-12").expanded)
            child(process, "压缩失败").performClick()
        }
        test.waitForIdleSync()
        test.runOnMainSync { check(reads == listOf("semantic-0", "semantic-12", "semantic-19")) }
    }
}
