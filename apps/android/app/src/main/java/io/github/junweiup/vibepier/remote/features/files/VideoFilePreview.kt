package io.github.junweiup.vibepier.remote.features.files

import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.VideoView
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.files.BinaryFileClient
import io.github.junweiup.vibepier.remote.core.files.BinaryMediaClient
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
    private var ready = false
    private var binaryTransfer: BinaryFileClient? = null
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
        val fields = JSONObject().put("path", path).put("offset", 0).put("binaryVersion", 1)
        host.call("readVideoFile", fields) { result ->
            if (!current()) { release(); return@call }
            if (!result.optBoolean("ok")) {
                status.text = result.optString("error", context.getString(R.string.video_download_failed)); return@call
            }
            if (result.has("binary")) {
                val address = host.binaryHost()
                val transfer = BinaryFileClient { current() }.also { binaryTransfer = it }
                io.execute {
                    val downloaded = runCatching {
                        BinaryMediaClient.video(result, address, transfer, file) { received, size ->
                            ui.post { if (current()) status.text = context.getString(R.string.video_progress, (received * 100 / size).toInt()) }
                        }
                    }
                    ui.post {
                        result.optJSONObject("binary")?.optString("id")?.takeIf { it.isNotEmpty() }?.let { host.call("fileCancel", JSONObject().put("ticket", it)) {} }
                        if (!current()) { release(); return@post }
                        if (downloaded.isFailure) {
                            file.delete(); status.text = context.getString(R.string.video_download_failed)
                        } else {
                            ready = true; video.setVideoURI(android.net.Uri.fromFile(file))
                        }
                    }
                }
                return@call
            }
            status.text = context.getString(R.string.video_download_failed)
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
        closed = true; binaryTransfer?.cancel(); controller.hide(); video.stopPlayback()
        io.execute { file.delete() }
    }
    companion object {
        private val io = Executors.newSingleThreadExecutor()
    }
}
