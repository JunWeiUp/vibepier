package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.VideoView
import io.github.junweiup.vibepier.remote.core.files.BinaryFileClient
import io.github.junweiup.vibepier.remote.core.files.BinaryMediaClient
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.files.ProjectFileHost
import io.github.junweiup.vibepier.remote.features.files.ProjectFileViewer
import io.github.junweiup.vibepier.remote.core.ui.ZoomableImagePreview
import io.github.junweiup.vibepier.remote.core.ui.FullscreenImageDialog
import io.github.junweiup.vibepier.remote.features.sessions.ConversationImage
import io.github.junweiup.vibepier.remote.features.sessions.ConversationMedia
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Real pinned HTTPS bodies and native media views; synthetic snapshots only. */
internal object BinaryMediaProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val profiles = JSONObject(File("/data/local/tmp/vibepier-media-probe.json").readText())
        val host = profiles.optString("host", "10.0.2.2")
        fun result(name: String) = JSONObject().put("ok", true).put("binary", profiles.getJSONObject(name))
        val start = SystemClock.elapsedRealtime()
        val bitmap = BinaryMediaClient.image(result("image"), host, BinaryFileClient { true }) ?: error("Binary image did not decode")
        check(bitmap.width == 1280 && bitmap.height == 720); bitmap.recycle()
        val badHash = result("badHash")
        badHash.getJSONObject("binary").put("sha256", "00".repeat(32))
        check(runCatching { BinaryMediaClient.image(badHash, host, BinaryFileClient { true }) }.isFailure)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval")) as MainActivity
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
        }
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun await(condition: () -> Boolean) {
            val until = SystemClock.elapsedRealtime() + 15_000
            while (SystemClock.elapsedRealtime() < until) {
                var ready = false; main { ready = condition() }
                if (ready) return
                SystemClock.sleep(20)
            }
            error("Binary media view did not settle")
        }
        var media: ConversationMedia? = null
        var dialog: AlertDialog? = null
        var viewer: ProjectFileViewer? = null
        val file = File(test.targetContext.cacheDir, "binary-video-fixture.mp4")
        try {
            BinaryMediaClient.video(result("video"), host, BinaryFileClient { true }, file) { _, _ -> }
            check(file.length() == profiles.getJSONObject("video").getLong("size")); file.delete()
            var imageRequests = 0
            lateinit var tile: ConversationImage
            main {
                media = ConversationMedia(activity,
                    scope = { ConversationMedia.Scope("codex", "fixture", 1, "synthetic") }, active = { true }, version = { "fixture" },
                    request = { op, args, done ->
                        if (op == "fileCancel") done(JSONObject().put("ok", true))
                        else { check(op == "image"); imageRequests++; done(result(if (args.optString("size") == "large") "large" else "thumb")) }
                    }, imageViewer = { title -> FullscreenImageDialog(activity, title).also { dialog = it.dialog } }, binaryHost = { host })
                val strip = media!!.strip(JSONArray().put(JSONObject().put("id", "fixture#0")))
                tile = views(strip).filterIsInstance<ConversationImage>().single()
                activity.setContentView(strip)
            }
            await { tile.bitmap != null }
            main { tile.performClick() }
            await { dialog != null && views(dialog!!.window!!.decorView).filterIsInstance<ZoomableImagePreview>().isNotEmpty() &&
                views(dialog!!.window!!.decorView).filterIsInstance<CanvasLabel>().none { it.isShown && it.text == activity.getString(R.string.image_large_loading) } }
            main {
                check(imageRequests == 2)
                dialog!!.dismiss(); tile.performClick()
                check(imageRequests == 2) { "Reopening cached large image fetched another body" }
                dialog!!.dismiss()
            }
            var videoRequests = 0
            main {
                val fileHost = ProjectFileHost(activity, "fixture", "codex", { op, _, done ->
                    if (op == "fileCancel") done(JSONObject().put("ok", true))
                    else { check(op == "readVideoFile"); videoRequests++; done(result("viewerVideo")) }
                }, { true }, { false }, { _, _ -> }, { false }, {}, binaryHost = { host })
                viewer = ProjectFileViewer(fileHost, "fixture.mp4"); viewer!!.show()
            }
            lateinit var video: VideoView
            await {
                val field = viewer!!.javaClass.getDeclaredField("videoPreview").apply { isAccessible = true }
                val preview = field.get(viewer) ?: return@await false
                video = preview.javaClass.getDeclaredField("video").apply { isAccessible = true }.get(preview) as VideoView
                video.duration > 0
            }
            main { check(videoRequests == 1); video.start() }
            await { video.currentPosition > 0 }
            main { video.pause(); video.seekTo(video.duration / 2) }
            await { video.currentPosition > video.duration / 3 }
            return "PASS: raw pinned HTTPS image/video, full SHA256 mismatch refusal, real thumbnail/large dialog/cache hit, single-request video prepare/play/pause/seek; elapsedMs=${SystemClock.elapsedRealtime() - start}\n"
        } finally {
            main { viewer?.dismiss(); dialog?.dismiss(); media?.clear(); activity.finish() }
            file.delete()
        }
    }
}
