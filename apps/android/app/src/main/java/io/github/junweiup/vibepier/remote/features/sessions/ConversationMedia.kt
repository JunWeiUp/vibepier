package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.R
import android.app.AlertDialog
import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.View.GONE
import android.view.View.VISIBLE
import android.widget.LinearLayout
import android.widget.ScrollView
import io.github.junweiup.vibepier.remote.core.ui.Ui
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
    private val dialog: (String, View, LinearLayout, Boolean) -> AlertDialog,
) {
    data class Scope(val provider: String, val thread: String, val generation: Int)
    private val ui = Handler(Looper.getMainLooper())
    private data class CachedImage(val bitmap: Bitmap, val at: Long = android.os.SystemClock.elapsedRealtime())
    private val imageCache = object : LinkedHashMap<String, CachedImage>(16, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CachedImage>?) = size > 24
    }
    private val imageWaiters = mutableMapOf<String, MutableList<(Bitmap?) -> Unit>>()
    private var waitEpoch = 0
    fun cancelReads() { waitEpoch++; imageWaiters.clear() }
    fun clear() { cancelReads(); imageCache.clear() }
    private fun isCurrent(token: Scope, epoch: Int) = active() && token == scope() && epoch == waitEpoch
    private fun dp(value: Int) = Ui.dp(context, value)
    private fun row() = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
    private fun column() = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private fun label(value: String, size: Float, color: Int) = Ui.label(context, value, size, color)
    private fun button(value: String, action: () -> Unit) = Ui.button(context, value, Ui.Button.TONAL, action)
    /** A message's or step's images: one large tile, or a row of square ones that scrolls sideways; tap to view larger. */
    fun strip(images: JSONArray): View {
        val single = images.length() == 1
        val tiles = row()
        for (i in 0 until images.length()) {
            val id = images.getJSONObject(i).optString("id")
            val tile = ConversationImage(context, if (single) dp(240) else dp(112), if (single) dp(180) else dp(112)).apply {
                isFocusable = true; contentDescription = context.getString(R.string.image_open_description, i + 1); setOnClickListener { showImage(id) }
            }
            tiles.addView(tile, LinearLayout.LayoutParams(-2, -2).apply { if (i > 0) marginStart = dp(8) })
            fetchImage(id, "thumb") { bitmap -> if (bitmap == null) tile.placeholder = context.getString(R.string.image_unavailable) else tile.bitmap = bitmap }
        }
        if (single) return tiles
        return android.widget.HorizontalScrollView(context).apply { isHorizontalScrollBarEnabled = false; addView(tiles) }
    }
    /** Asks the Mac for an image once, shares the answer with every view waiting for it and keeps thumbnails cached. */
    private fun imageKey(id: String, size: String) = "${scope().provider}:${scope().thread}:$size:$id:${version(id)}"
    private fun cachedImage(key: String, fresh: Boolean = true): android.graphics.Bitmap? = imageCache[key]?.takeIf { !fresh || android.os.SystemClock.elapsedRealtime() - it.at < 10 * 60_000 }?.bitmap
    private fun fetchImage(id: String, size: String, done: (android.graphics.Bitmap?) -> Unit) {
        val key = imageKey(id, size)
        cachedImage(key)?.let { done(it); return }
        if (!active()) { done(null); return }
        imageWaiters[key]?.let { it.add(done); return }
        imageWaiters[key] = mutableListOf(done); val token = scope(); val epoch = waitEpoch
        request("image", JSONObject().put("threadId", token.thread).put("imageId", id).put("size", size).put("cacheVersion", version(id))) { result ->
            if (!isCurrent(token, epoch)) return@request
            val encoded = result.optString("image")
            imageDecoder.execute {
                val bytes = try { android.util.Base64.decode(encoded, android.util.Base64.DEFAULT) } catch (_: Exception) { null }
                val bitmap = bytes?.takeIf { it.isNotEmpty() }?.let { android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size) }
                ui.post {
                    if (!isCurrent(token, epoch)) return@post
                    if (bitmap != null) {
                        imageCache[key] = CachedImage(bitmap)
                        while (imageCache.values.sumOf { it.bitmap.byteCount.toLong() } > 8 * 1024 * 1024 && imageCache.isNotEmpty()) imageCache.remove(imageCache.keys.first())
                    }
                    imageWaiters.remove(key)?.forEach { it(bitmap) }
                }
            }
        }
    }
    private fun showImage(id: String) {
        val body = column()
        val footer = row(); val dialog = dialog(context.getString(R.string.image_title), ScrollView(context).apply { addView(body) }, footer, true)
        footer.addView(button(context.getString(R.string.close)) { dialog.dismiss() }, LinearLayout.LayoutParams(-1, -2))
        val status = label(context.getString(R.string.image_large_loading), 13f, Palette.muted)
        cachedImage(imageKey(id, "thumb"), fresh = false)?.let { body.addView(AttachmentPreview(context, it, maximumHeightDp = null).apply { contentDescription = context.getString(R.string.image_title) }) }
        body.addView(status, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
        val retry = button(context.getString(R.string.reload)) {}.apply { visibility = GONE }
        footer.addView(retry, 0, LinearLayout.LayoutParams(0, -2, 1f))
        footer.getChildAt(1).layoutParams = LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = dp(8) }
        fun load() {
            retry.visibility = GONE; status.text = context.getString(R.string.image_large_loading)
            fetchImage(id, "large") { bitmap ->
                if (!dialog.isShowing) return@fetchImage
                if (bitmap == null) { status.text = context.getString(R.string.image_large_failed); retry.visibility = VISIBLE; return@fetchImage }
                body.removeAllViews(); body.addView(AttachmentPreview(context, bitmap, maximumHeightDp = null).apply { contentDescription = context.getString(R.string.image_title) })
            }
        }
        retry.setOnClickListener { load() }; load()
    }
    companion object { private val imageDecoder = java.util.concurrent.Executors.newSingleThreadExecutor() }
}
