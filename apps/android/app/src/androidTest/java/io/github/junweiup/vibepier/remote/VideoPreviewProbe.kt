package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.widget.VideoView
import io.github.junweiup.vibepier.remote.features.files.ProjectFileHost
import io.github.junweiup.vibepier.remote.features.files.ProjectFileViewer
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Emulator-only H.264/AAC fixture; no real provider, network or phone data. */
object VideoPreviewProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW)
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "files")) as MainActivity
        fun main(block: () -> Unit) {
            var error: Throwable? = null
            test.runOnMainSync { try { block() } catch (e: Throwable) { error = e } }
            error?.let { throw it }
        }
        fun field(value: Any, name: String) = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
        fun waitFor(condition: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 10_000
            while (!condition()) { check(SystemClock.elapsedRealtime() < deadline) { "Video preview timed out" }; SystemClock.sleep(50) }
        }
        val bytes = test.context.assets.open("video-preview.mp4").use { it.readBytes() }
        val handler = Handler(Looper.getMainLooper())
        var viewer: ProjectFileViewer? = null
        try {
            for (provider in listOf("claude", "codex")) {
                var reads = 0
                main {
                    val host = ProjectFileHost(activity, "fixture", provider, { op, args, done ->
                        check(op == "readVideoFile"); reads++
                        val offset = args.getInt("offset")
                        if (offset > 0) check(args.getString("version") == "fixture-video")
                        val next = minOf(offset + 16_384, bytes.size)
                        handler.post { done(JSONObject().put("ok", true).put("path", "demo.mp4").put("mime", "video/mp4")
                            .put("size", bytes.size).put("offset", offset).put("version", "fixture-video")
                            .put("nextOffset", if (next == bytes.size) -1 else next)
                            .put("video", android.util.Base64.encodeToString(bytes.copyOfRange(offset, next), android.util.Base64.NO_WRAP))) }
                    }, { true }, { false }, { _, _ -> }, { false }, {}, allowLegacyMedia = true)
                    viewer = ProjectFileViewer(host, "demo.mp4"); viewer!!.show()
                }
                var player: VideoView? = null
                var temporary: File? = null
                waitFor {
                    var prepared = false
                    main {
                        val preview = field(viewer!!, "videoPreview")!!
                        player = field(preview, "video") as VideoView
                        temporary = field(preview, "file") as File
                        prepared = player!!.duration > 0
                    }
                    prepared
                }
                check(reads > 1)
                check(MessageDigest.isEqual(MessageDigest.getInstance("SHA-256").digest(bytes),
                    MessageDigest.getInstance("SHA-256").digest(temporary!!.readBytes())))
                main { check(!player!!.isPlaying); check(player!!.duration in 3900..4200); player!!.start() }
                waitFor { var progressed = false; main { progressed = player!!.isPlaying && player!!.currentPosition > 100 }; progressed }
                main { player!!.pause(); player!!.seekTo(2000) }
                SystemClock.sleep(500) // Wait for the asynchronous seek, not VideoView’s queued target position.
                waitFor { var sought = false; main { sought = !player!!.isPlaying && player!!.currentPosition >= 1500 }; sought }
                test.uiAutomation.takeScreenshot()?.let { bitmap ->
                    File(activity.getExternalFilesDir(null), "video-preview-$provider.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
                }
                main { viewer!!.dismiss(); check(field(viewer!!, "videoPreview") == null) }
                waitFor { !temporary!!.exists() }
            }
            return "PASS: Claude/Codex MP4 multi-chunk download, exact digest, H.264/AAC prepare, manual play/pause/seek and private file cleanup."
        } finally { main { viewer?.dismiss(); activity.finish() } }
    }
}
