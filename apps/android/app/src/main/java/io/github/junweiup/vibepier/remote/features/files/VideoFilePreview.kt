package io.github.junweiup.vibepier.remote.features.files

import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.VideoView
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.features.remote.Palette
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** Download to a private temporary file before playback; never expose capabilities to a media URL. */
@android.annotation.SuppressLint("ViewConstructor") // Constructed with the authorized session host.
internal class VideoFilePreview(private val host: ProjectFileHost, private val path: String) : FrameLayout(host.context) {
    private val ui = android.os.Handler(android.os.Looper.getMainLooper())
    private val file = File(host.context.cacheDir, "video-${java.util.UUID.randomUUID()}.mp4")
    @Volatile private var closed = false
    private var offset = 0
    private var version = ""
    private var total = 0
    private var ready = false
    private val video = VideoView(context)
    private val status = Ui.label(context, context.getString(R.string.video_loading), Ui.BODY, Palette.muted).apply {
        gravity = Gravity.CENTER; setPadding(host.dp(16), host.dp(16), host.dp(16), host.dp(16))
    }
    private val controller = MediaController(context)
    init {
        setBackgroundColor(android.graphics.Color.BLACK)
        addView(video, LayoutParams(-1, -1, Gravity.CENTER))
        addView(status, LayoutParams(-1, -1))
        video.contentDescription = path.substringAfterLast('/')
        controller.setAnchorView(video)
        video.setMediaController(controller)
        video.setOnPreparedListener {
            if (current()) { status.visibility = View.GONE; controller.show(0) }
            else release()
        }
        video.setOnErrorListener { _, _, _ ->
            status.text = context.getString(R.string.video_playback_failed); status.visibility = View.VISIBLE
            true
        }
        load()
    }
    private fun current() = !closed && host.isCurrent()
    private fun load() {
        if (!current()) { release(); return }
        val expected = offset
        val fields = JSONObject().put("path", path).put("offset", expected)
        if (version.isNotEmpty()) fields.put("version", version)
        host.call("readVideoFile", fields) { result ->
            if (!current()) { release(); return@call }
            if (!result.optBoolean("ok")) {
                status.text = result.optString("error", context.getString(R.string.video_download_failed)); return@call
            }
            val revision = result.optString("version")
            val size = result.optInt("size")
            val next = result.optInt("nextOffset", -2)
            val encoded = result.optString("video")
            if (revision.isEmpty() || (version.isNotEmpty() && version != revision) || size !in 1..MAX_BYTES ||
                (total != 0 && total != size) || result.optInt("offset", -1) != expected ||
                result.optString("mime") != "video/mp4" || encoded.length > 180_000) {
                status.text = context.getString(R.string.video_download_failed); return@call
            }
            version = revision; total = size
            io.execute {
                val written = runCatching {
                    check(current())
                    val bytes = android.util.Base64.decode(encoded, android.util.Base64.DEFAULT)
                    check(bytes.isNotEmpty() && bytes.size <= 128 * 1024 && expected + bytes.size <= size)
                    check(next == if (expected + bytes.size == size) -1 else expected + bytes.size)
                    check(file.length() == expected.toLong())
                    java.io.FileOutputStream(file, true).use { it.write(bytes) }
                    check(file.length() == (expected + bytes.size).toLong())
                    bytes.size
                }
                ui.post {
                    if (!current()) { release(); return@post }
                    if (written.isFailure) { status.text = context.getString(R.string.video_download_failed); return@post }
                    offset = expected + written.getOrThrow()
                    if (next == -1) {
                        ready = true
                        video.setVideoURI(android.net.Uri.fromFile(file))
                    } else {
                        status.text = context.getString(R.string.video_progress, (offset.toLong() * 100 / total).toInt())
                        load()
                    }
                }
            }
        }
    }
    fun pause() { if (ready && video.isPlaying) video.pause(); controller.hide() }
    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility != View.VISIBLE && ready) pause()
    }
    override fun onDetachedFromWindow() { pause(); super.onDetachedFromWindow() }
    fun release() {
        if (closed) return
        closed = true; controller.hide(); video.stopPlayback()
        io.execute { file.delete() }
    }
    companion object {
        private const val MAX_BYTES = 128 * 1024 * 1024
        private val io = Executors.newSingleThreadExecutor()
    }
}
