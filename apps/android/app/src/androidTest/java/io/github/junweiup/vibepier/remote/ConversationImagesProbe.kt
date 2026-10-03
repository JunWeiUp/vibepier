package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.features.sessions.AttachmentPreview
import io.github.junweiup.vibepier.remote.features.sessions.ConversationImage
import io.github.junweiup.vibepier.remote.features.sessions.InlineReplyProcess

import android.app.Instrumentation
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import org.json.JSONArray
import org.json.JSONObject

/** The three existing design pictures, with native headers and collapsed outputs. No desktop calls. */
internal object ConversationImagesProbe {
    fun run(test: Instrumentation): String {
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval"))
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun main(run: () -> Unit) { test.runOnMainSync { run() }; test.waitForIdleSync() }
        val bitmaps = (1..3).map { test.context.assets.open("direction-$it.png").use(BitmapFactory::decodeStream) ?: error("Missing design image $it") }
        val reads = mutableListOf<String>()
        val rendered = mutableListOf<String>()
        val state = InlineReplyProcess.State()
        lateinit var process: InlineReplyProcess
        fun group() = views(process).first { it.contentDescription?.toString()?.contains(activity.getString(R.string.group_action_count, activity.getString(R.string.group_image_generation), 3)) == true }
        fun tiles() = views(process).filterIsInstance<ConversationImage>()
        val imageIDs = (1..3).map { "generation-$it#0" }
        try {
            main {
                val rows = JSONArray().put(JSONObject().put("id", "before").put("kind", "text").put("index", 0).put("text", "下面是三个设计方案").put("bodyVersion", "before"))
                for (i in 1..3) rows.put(JSONObject().put("id", "generation-$i").put("kind", "tool").put("title", "生成图片").put("groupType", "image-generation")
                    .put("index", i).put("status", "completed").put("bodyDeferred", true).put("bodyVersion", "gen-$i")
                    .put("images", JSONArray().put(JSONObject().put("id", "generation-$i#0"))))
                rows.put(JSONObject().put("id", "after").put("kind", "text").put("index", 4).put("text", "选择其中一个方案").put("bodyVersion", "after"))
                state.accept(rows, 5)
                process = InlineReplyProcess(activity, state, { true }, { _, _, _ -> error("No header read needed") }, { id, _, done ->
                    reads.add(id); done(JSONObject().put("ok", true).put("text", "生成完成").put("nextOffset", -1))
                }, { pictures ->
                    LinearLayout(activity).apply {
                        for (i in 0 until pictures.length()) {
                            val id = pictures.getJSONObject(i).getString("id"); rendered.add(id)
                            val index = imageIDs.indexOf(id); check(index >= 0)
                            addView(ConversationImage(activity, Ui.dp(activity, 92), Ui.dp(activity, 128)).apply {
                                bitmap = bitmaps[index]; contentDescription = "方案 ${index + 1} 缩略图"
                            })
                        }
                    }
                })
                activity.setContentView(android.widget.ScrollView(activity).apply { setPadding(Ui.dp(activity, 16), Ui.dp(activity, 40), Ui.dp(activity, 16), Ui.dp(activity, 16)); addView(process) })
            }
            SystemClock.sleep(200); test.waitForIdleSync()
            test.uiAutomation.takeScreenshot().also { bitmap ->
                java.io.File(activity.externalCacheDir!!, "conversation-folded-design-images.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
            main {
                check(group().contentDescription.toString().startsWith("▸"))
                check(tiles().size == 3 && tiles().all { it.bitmap != null && it.isShown })
                check(rendered.toSet() == imageIDs.toSet() && reads.isEmpty())
                check(imageIDs.indices.all { !state.bodies.getValue("generation-${it + 1}").loaded })
                // The surrounding prose keeps its original order without expanding the tools.
                check((process.getChildAt(0) as ViewGroup).let { views(it).filterIsInstance<CanvasLabel>().any { label -> label.text.toString() == "下面是三个设计方案" } })
                group().performClick()
            }
            main {
                check(tiles().size == 3 && reads.isEmpty())
                views(process).first { it.contentDescription?.toString()?.startsWith(activity.getString(R.string.step_description, "生成图片", "✓", activity.getString(R.string.expand_content))) == true }.performClick()
            }
            main {
                check(reads == listOf("generation-1"))
                check(tiles().size == 3)
                group().performClick()
                check(tiles().size == 3 && state.bodies.getValue("generation-1").loaded)
                // A lone tool result must expose its image too, even with an unread body.
                state.accept(JSONArray().put(JSONObject().put("id", "single").put("kind", "tool").put("title", "另一张图片").put("index", 5)
                    .put("bodyDeferred", true).put("bodyVersion", "single").put("images", JSONArray().put(JSONObject().put("id", imageIDs[0])))), 6)
                state.changed()
                check(tiles().size == 4 && !state.bodies.getValue("single").loaded && reads.size == 1)
                val restored = InlineReplyProcess.State().apply { restore(state.snapshot()) }
                check(restored.rows.getValue("single").getJSONArray("images").getJSONObject(0).getString("id") == imageIDs[0])
                val full = AttachmentPreview(activity, bitmaps[0], maximumHeightDp = null)
                val width = Ui.dp(activity, 280)
                full.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
                check(full.measuredHeight > Ui.dp(activity, 360)) { "A portrait must be scrollable at full width" }
                activity.setContentView(android.widget.ScrollView(activity).apply {
                    addView(LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL
                        addView(Ui.label(activity, "三张图片 · 工具内容仍折叠"))
                        imageIDs.forEachIndexed { index, _ -> addView(AttachmentPreview(activity, bitmaps[index], maximumHeightDp = null)) }
                    })
                })
            }
            SystemClock.sleep(200); test.waitForIdleSync()
            test.uiAutomation.takeScreenshot().also { bitmap ->
                java.io.File(activity.externalCacheDir!!, "conversation-design-images.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
            return "PASS: all three native design previews visible with group folded, output bodies remain lazy, expanding/collapsing does not duplicate images, individual tool preview, cached header restore, long image full-width scrolling\n"
        } finally {
            main { activity.finish() }
            bitmaps.forEach { it.recycle() }
        }
    }
}
