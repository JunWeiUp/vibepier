package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft

import io.github.junweiup.vibepier.remote.core.files.BinaryFileClient
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors

/** System-selected content is copied to this app's private storage, transferred through the authenticated raw HTTPS file channel. */
internal object CodexFileUpload {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    fun prepare(context: Context, uri: Uri, done: (File?, String, String, String?) -> Unit) {
        worker.execute {
            var target: File? = null
            try {
                var name = context.getString(R.string.attachment_name); context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
                    if (it.moveToFirst()) { name = it.getString(0) ?: name; if (!it.isNull(1) && it.getLong(1) > 10 * 1024 * 1024) error(context.getString(R.string.attachment_too_large)) }
                }
                val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
                val directory = File(context.filesDir, "codex-drafts").apply { mkdirs() }
                target = File(directory, UUID.randomUUID().toString())
                context.contentResolver.openInputStream(uri)?.use { input -> target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024); var size = 0
                    while (true) { val count = input.read(buffer); if (count < 0) break; size += count; if (size > 10 * 1024 * 1024) error(context.getString(R.string.attachment_too_large)); output.write(buffer, 0, count) }
                } } ?: error(context.getString(R.string.attachment_unreadable_selection))
                if (target.length() == 0L) error(context.getString(R.string.attachment_empty))
                if (mime.startsWith("image/") && mime !in listOf("image/jpeg", "image/png", "image/webp", "image/gif")) {
                    val dimensions = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeFile(target.path, dimensions)
                    var sample = 1; while (maxOf(dimensions.outWidth, dimensions.outHeight) / sample > 2048) sample *= 2
                    val image = BitmapFactory.decodeFile(target.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: error(context.getString(R.string.image_unreadable))
                    val normalized = File(directory, UUID.randomUUID().toString() + ".jpg")
                    try { normalized.outputStream().use { image.compress(Bitmap.CompressFormat.JPEG, 88, it) } } finally { image.recycle() }
                    target.delete(); target = normalized
                    val safeName = name.substringBeforeLast('.', name) + ".jpg"
                    val file = target; main.post { done(file, safeName, "image/jpeg", null) }
                } else { val file = target; main.post { done(file, name, mime, null) } }
            } catch (error: Exception) { target?.delete(); main.post { done(null, "", "", error.message ?: context.getString(R.string.attachment_unreadable)) } }
        }
    }
    fun upload(resources: android.content.res.Resources, client: SessionClient, thread: String, file: File, name: String, mime: String, progress: (JSONObject) -> Unit, cancelled: () -> Boolean = { false }, creation: SessionCreationDraft? = null, done: (JSONObject) -> Unit) {
        val id = UUID.randomUUID().toString(); val version = client.viewVersion; val provider = creation?.provider ?: client.provider
        val authorization = client.authorizationIdentity
        worker.execute {
            val size: Int; val hash: String
            try {
                val length = file.length(); check(length in 1..10L * 1024 * 1024)
                size = length.toInt()
                val digest = MessageDigest.getInstance("SHA-256")
                file.inputStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
                }
                hash = digest.digest().joinToString("") { "%02x".format(it) }
            } catch (_: Exception) { main.post { done(JSONObject().put("ok", false).put("error", resources.getString(R.string.attachment_expired))) }; return@execute }
            main.post {
                fun fields() = (if (creation == null) JSONObject().put("threadId", thread).put("viewVersion", version)
                    else JSONObject().put("draftId", creation.id).put("cwd", creation.cwd))
                    .put("attachmentId", id).put("provider", provider)
                fun operation(name: String) = if (creation == null) name else "new" + name.replaceFirstChar { it.uppercase() }
                var finished = false
                var binaryTransfer: BinaryFileClient? = null
                var binaryTicket: String? = null
                var lastProgress = -1
                var lastProgressAt = 0L
                fun stopped() = cancelled() || client.authorizationIdentity != authorization || client.provider != provider ||
                    (creation == null && client.viewVersion != version)
                fun finish(result: JSONObject) {
                    if (finished) return
                    finished = true
                    binaryTransfer?.cancel()
                    if (binaryTicket != null && client.online && client.authorizationIdentity == authorization)
                        client.request("fileCancel", JSONObject().put("ticket", binaryTicket)) {}
                    client.cancelAttachmentRequests(id)
                    done(JSONObject(result.toString()).put("cachePath", file.path).put("name", name).put("mime", mime).put("attachmentId", id))
                }
                fun stop() = finish(JSONObject().put("ok", false).put("error", resources.getString(R.string.attachment_upload_cancelled)))
                fun watchCancellation() {
                    if (finished) return
                    if (stopped()) stop() else main.postDelayed({ watchCancellation() }, 150)
                }
                if (stopped()) { stop(); return@post }
                watchCancellation()
                val start = fields().put("name", name).put("mime", mime).put("size", size)
                start.put("binaryVersion", 1)
                client.request(operation("attachmentStart"), start) { response ->
                    if (finished) return@request
                    if (stopped()) { stop(); return@request }
                    if (!response.optBoolean("ok")) { finish(response); return@request }
                    val binary = response.optJSONObject("binary")
                    if (binary != null) {
                        progress(fields().put("name", name).put("progress", 0))
                        val transfer = BinaryFileClient { !finished && !stopped() }; binaryTransfer = transfer; binaryTicket = binary.getString("id")
                        val host = client.binaryHost
                        worker.execute {
                            val result = runCatching {
                                transfer.upload(binary, host, file) { bytes ->
                                    val percent = minOf(95, (bytes * 100 / size).toInt())
                                    main.post {
                                        val now = android.os.SystemClock.elapsedRealtime()
                                        if (!finished && !stopped() && percent != lastProgress && now - lastProgressAt >= 150) {
                                            lastProgress = percent; lastProgressAt = now
                                            progress(fields().put("name", name).put("progress", percent))
                                        }
                                    }
                                }
                            }
                            main.post binaryDone@{
                                if (finished) return@binaryDone
                                if (stopped()) { stop(); return@binaryDone }
                                if (result.isFailure) { finish(JSONObject().put("ok", false).put("error", resources.getString(R.string.file_transfer_interrupted))); return@binaryDone }
                                client.request(operation("attachmentComplete"), fields().put("sha256", hash).put("binaryTicket", binary.getString("id"))) { done ->
                                    if (finished) return@request
                                    if (done.optBoolean("ok")) progress(fields().put("name", name).put("progress", 100))
                                    finish(done)
                                }
                            }
                        }
                        return@request
                    }
                    finish(JSONObject().put("ok", false).put("error", resources.getString(R.string.file_binary_required)))
                }
            }
        }
    }
}
