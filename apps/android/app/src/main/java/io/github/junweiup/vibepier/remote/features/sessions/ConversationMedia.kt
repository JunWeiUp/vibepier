package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.files.BinaryFileClient
import io.github.junweiup.vibepier.remote.core.files.BinaryMediaClient
import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.FullscreenImageDialog
import io.github.junweiup.vibepier.remote.features.remote.Palette
import org.json.JSONArray
import org.json.JSONObject

/** Bounded media cache and image presentation, scoped to one visible conversation generation. */
internal class ConversationMedia(
    private val context: Context,
    private val scope: () -> Scope,
    private val active: () -> Boolean,
    private val version: (String) -> String,
    private val request: (String, JSONObject, (JSONObject) -> Unit) -> Unit,
    private val imageViewer: (String) -> FullscreenImageDialog = { FullscreenImageDialog(context, it) },
    private val readTimeoutMs: Long = 30_000L,
    private val binaryHost: () -> String? = { null },
    private val allowLegacyImages: Boolean = false,
) {
    data class Scope(val provider: String, val thread: String, val generation: Int, val authorization: String = "")
    private val ui = Handler(Looper.getMainLooper())
    private data class CachedImage(val bitmap: Bitmap, val at: Long = android.os.SystemClock.elapsedRealtime())
    private val imageCache = object : LinkedHashMap<String, CachedImage>(16, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CachedImage>?) = size > 24
    }
    private class ImageRead(val callbacks: MutableList<(Bitmap?) -> Unit>) {
        var timeout: Runnable? = null
        var transfer: BinaryFileClient? = null
        var start: (() -> Unit)? = null
        var started = false
    }
    private val imageWaiters = mutableMapOf<String, ImageRead>()
    private val queuedReads = mutableListOf<ImageRead>()
    private var activeReads = 0
    private fun drainReads() {
        while (activeReads < 2 && queuedReads.isNotEmpty()) {
            val read = queuedReads.removeAt(0)
            read.started = true; activeReads++
            read.start?.invoke()
        }
    }
    private var waitEpoch = 0
    fun cancelReads() {
        waitEpoch++
        val cancelled = imageWaiters.values.toList()
        imageWaiters.clear(); queuedReads.clear(); activeReads = 0
        cancelled.forEach { read ->
            read.timeout?.let(ui::removeCallbacks)
            read.transfer?.cancel()
            read.callbacks.toList().forEach { it(null) }
        }
    }
    internal var previewDialog: FullscreenImageDialog? = null; private set
    fun clear() { previewDialog?.dismiss(); previewDialog = null; cancelReads(); imageCache.clear() }
    private fun isCurrent(token: Scope, epoch: Int) = active() && token == scope() && epoch == waitEpoch
    private fun dp(value: Int) = Ui.dp(context, value)
    private fun row() = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
    /** A message's or step's images: one large tile, or a row of square ones that scrolls sideways; tap to view larger. */
    fun strip(images: JSONArray): View {
        val renderedScope = scope()
        val single = images.length() == 1
        val tiles = row()
        for (i in 0 until images.length()) {
            val id = images.getJSONObject(i).optString("id")
            val tile = ConversationImage(context, if (single) dp(240) else dp(112), if (single) dp(180) else dp(112)).apply {
                isFocusable = true; contentDescription = context.getString(R.string.image_open_description, i + 1)
                setOnClickListener { if (active() && renderedScope == scope()) showImage(id, bitmap) }
            }
            tiles.addView(tile, LinearLayout.LayoutParams(-2, -2).apply { if (i > 0) marginStart = dp(8) })
            fetchImage(id, "thumb") { bitmap -> if (bitmap == null) tile.placeholder = context.getString(R.string.image_unavailable) else tile.bitmap = bitmap }
        }
        if (single) return tiles
        return android.widget.HorizontalScrollView(context).apply { isHorizontalScrollBarEnabled = false; addView(tiles) }
    }
    /** Asks the Mac for an image once, shares the answer with every view waiting for it and keeps thumbnails cached. */
    private fun imageKey(id: String, size: String) = "${scope().authorization}:${scope().provider}:${scope().thread}:$size:$id:${version(id)}"
    private fun cachedImage(key: String, fresh: Boolean = true): android.graphics.Bitmap? = imageCache[key]?.takeIf { !fresh || android.os.SystemClock.elapsedRealtime() - it.at < 10 * 60_000 }?.bitmap
    private fun fetchImage(id: String, size: String, done: (android.graphics.Bitmap?) -> Unit) {
        val key = imageKey(id, size)
        cachedImage(key)?.let { done(it); return }
        if (!active()) { done(null); return }
        imageWaiters[key]?.let { it.callbacks.add(done); return }
        if (imageWaiters.size >= 32) { done(null); return }
        val read = ImageRead(mutableListOf(done))
        imageWaiters[key] = read; val token = scope(); val epoch = waitEpoch
        fun finish(bitmap: Bitmap?) {
            if (imageWaiters[key] !== read) return
            imageWaiters.remove(key)
            queuedReads.remove(read)
            if (read.started) activeReads--
            read.timeout?.let(ui::removeCallbacks)
            read.transfer?.cancel()
            read.callbacks.toList().forEach { it(bitmap) }
            drainReads()
        }
        val hardDeadline = android.os.SystemClock.elapsedRealtime() + maxOf(readTimeoutMs, 120_000L)
        fun progress() {
            ui.post {
                if (imageWaiters[key] !== read) return@post
                read.timeout?.let {
                    ui.removeCallbacks(it)
                    ui.postDelayed(it, minOf(readTimeoutMs, (hardDeadline - android.os.SystemClock.elapsedRealtime()).coerceAtLeast(0)))
                }
            }
        }
        read.timeout = Runnable { finish(null) }.also { ui.postDelayed(it, readTimeoutMs) }
        read.start = { request("image", JSONObject().put("threadId", token.thread).put("imageId", id).put("size", size).put("cacheVersion", version(id)).put("binaryVersion", 1)) { result ->
            if (imageWaiters[key] !== read) return@request
            if (!isCurrent(token, epoch)) { finish(null); return@request }
            val host = binaryHost()
            val transfer = BinaryFileClient { isCurrent(token, epoch) }
            read.transfer = transfer
            imageDecoder.execute {
                val bitmap = runCatching {
                    if (result.has("binary")) BinaryMediaClient.image(result, host, transfer, ::progress)
                    else {
                        check(allowLegacyImages)
                        val bytes = android.util.Base64.decode(result.optString("image"), android.util.Base64.DEFAULT)
                        android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    }
                }.getOrNull()
                ui.post {
                    if (token.authorization == scope().authorization) result.optJSONObject("binary")?.optString("id")?.takeIf { it.isNotEmpty() }?.let { request("fileCancel", JSONObject().put("ticket", it)) {} }
                    if (imageWaiters[key] !== read) return@post
                    if (!isCurrent(token, epoch)) { finish(null); return@post }
                    if (bitmap != null) {
                        imageCache[key] = CachedImage(bitmap)
                        while (imageCache.values.sumOf { it.bitmap.byteCount.toLong() } > 16 * 1024 * 1024 && imageCache.isNotEmpty()) imageCache.remove(imageCache.keys.first())
                    }
                    finish(bitmap)
                }
            }
        } }
        val position = if (size == "large") 0 else queuedReads.size
        queuedReads.add(position, read)
        drainReads()
    }
    private fun showImage(id: String, thumbnail: Bitmap?) {
        previewDialog?.dismiss()
        val viewer = imageViewer(context.getString(R.string.image_title)).also { previewDialog = it }
        viewer.show()
        (thumbnail ?: cachedImage(imageKey(id, "thumb"), fresh = false))?.let(viewer::display)
        fun load() {
            viewer.loading()
            fetchImage(id, "large") { bitmap ->
                if (!viewer.isShowing) return@fetchImage
                if (bitmap == null) { viewer.failed(); return@fetchImage }
                viewer.display(bitmap)
            }
        }
        viewer.retry = ::load; load()
    }
    companion object { private val imageDecoder = java.util.concurrent.Executors.newFixedThreadPool(2) }
}
