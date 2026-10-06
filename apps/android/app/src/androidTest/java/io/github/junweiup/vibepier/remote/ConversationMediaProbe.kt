package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.FullscreenImageDialog
import io.github.junweiup.vibepier.remote.core.ui.ZoomableImagePreview
import io.github.junweiup.vibepier.remote.features.sessions.ConversationImage
import io.github.junweiup.vibepier.remote.features.sessions.ConversationMedia
import org.json.JSONArray
import org.json.JSONObject

/** Real image dialog with synthetic pinned loopback TLS; no Mac, phone pairing or external network. */
internal object ConversationMediaProbe {
    fun run(test: Instrumentation, activity: MainActivity) {
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
        }
        fun await(condition: () -> Boolean) {
            val end = SystemClock.elapsedRealtime() + 5_000
            while (SystemClock.elapsedRealtime() < end) {
                var done = false
                main { done = condition() }
                if (done) return
                SystemClock.sleep(20)
            }
            error("Image dialog did not settle")
        }
        val fixture = BinaryLoopbackFixture(BinaryLoopbackFixture.jpeg(test.context.assets.open("direction-1.png").use { it.readBytes() }))
        val success = fixture.response()
        var bodyVersion = "initial"
        val replies = mutableListOf<(JSONObject) -> Unit>()
        lateinit var media: ConversationMedia
        lateinit var tile: ConversationImage
        lateinit var popup: AlertDialog
        var mediaReady = false
        var popupReady = false
        try {
            main {
                media = ConversationMedia(activity,
                    scope = { ConversationMedia.Scope("codex", "synthetic", 1, "synthetic-phone") },
                    active = { true }, version = { bodyVersion },
                    request = { op, params, callback -> if (op == "fileCancel") callback(JSONObject().put("ok", true)) else if (params.optString("size") == "thumb") callback(success) else replies.add(callback) },
                    imageViewer = { title -> FullscreenImageDialog(activity, title).also { popup = it.dialog; popupReady = true } }, readTimeoutMs = 1_000, binaryHost = { fixture.host })
                mediaReady = true
                val strip = media.strip(JSONArray().put(JSONObject().put("id", "photo#0")))
                tile = views(strip).filterIsInstance<ConversationImage>().single()
                activity.setContentView(strip)
            }
            await { tile.bitmap != null }
            main {
                bodyVersion = "updated" // Timeline still shows its old thumbnail after a revision.
                tile.performClick()
                check(replies.size == 1)
                check(views(popup.window!!.decorView).filterIsInstance<ZoomableImagePreview>().isNotEmpty()) { "Large dialog must immediately show its cached thumbnail" }
                media.cancelReads()
                check(views(popup.window!!.decorView).filterIsInstance<CanvasLabel>().any { it.isShown && it.text == activity.getString(R.string.image_large_failed) }) { "Cancelled read left the dialog loading forever" }
                views(popup.window!!.decorView).first { it.contentDescription == activity.getString(R.string.reload) }.performClick()
                check(replies.size == 2)
                replies[0](success) // A late cancelled answer must not consume the new waiter's callback.
                check(views(popup.window!!.decorView).filterIsInstance<CanvasLabel>().any { it.isShown && it.text == activity.getString(R.string.image_large_loading) })
                replies[1](success)
            }
            await { views(popup.window!!.decorView).filterIsInstance<ZoomableImagePreview>().isNotEmpty() && views(popup.window!!.decorView).filterIsInstance<CanvasLabel>().none { it.isShown && it.text == activity.getString(R.string.image_large_loading) } }
            main {
                popup.dismiss()
                tile.performClick() // Cache hits can finish synchronously.
                check(replies.size == 2)
                check(views(popup.window!!.decorView).filterIsInstance<CanvasLabel>().none { it.isShown && it.text == activity.getString(R.string.image_large_loading) })
                popup.dismiss()
                val strip = media.strip(JSONArray().put(JSONObject().put("id", "timeout#0")))
                tile = views(strip).filterIsInstance<ConversationImage>().single()
                activity.setContentView(strip)
            }
            await { tile.bitmap != null }
            main { tile.performClick() }
            await { views(popup.window!!.decorView).filterIsInstance<CanvasLabel>().any { it.isShown && it.text == activity.getString(R.string.image_large_failed) } }
        } finally {
            main { if (popupReady) popup.dismiss(); if (mediaReady) media.clear() }
            fixture.close()
        }
    }
}
