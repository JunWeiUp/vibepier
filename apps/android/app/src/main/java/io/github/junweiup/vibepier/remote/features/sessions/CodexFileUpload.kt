package io.github.junweiup.vibepier.remote.features.sessions

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.session.SessionCreationDraft

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors

/** System-selected content is copied to this app's private storage, then encrypted by SessionClient. */
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
        val id = UUID.randomUUID().toString(); val version = client.viewVersion; val provider = creation?.provider ?: client.provider; var bytes: ByteArray; var digest: String
        worker.execute {
            try { bytes = file.readBytes(); digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) } }
            catch (_: Exception) { main.post { done(JSONObject().put("ok", false).put("error", resources.getString(R.string.attachment_expired))) }; return@execute }
            val content = bytes; val hash = digest
            main.post {
                fun fields() = (if (creation == null) JSONObject().put("threadId", thread).put("viewVersion", version)
                    else JSONObject().put("draftId", creation.id).put("cwd", creation.cwd))
                    .put("attachmentId", id).put("provider", provider)
                fun operation(name: String) = if (creation == null) name else "new" + name.replaceFirstChar { it.uppercase() }
                fun finish(result: JSONObject) { done(JSONObject(result.toString()).put("cachePath", file.path).put("name", name).put("mime", mime).put("attachmentId", id)) }
                fun chunk(offset: Int) {
                    if (cancelled()) { finish(JSONObject().put("ok", false).put("error", resources.getString(R.string.attachment_upload_cancelled))); return }
                    if (offset >= content.size) { client.request(operation("attachmentComplete"), fields().put("sha256", hash), ::finish); return }
                    val end = minOf(content.size, offset + client.attachmentChunkBytes)
                    progress(fields().put("name", name).put("progress", (offset * 100L / content.size).toInt()))
                    client.request(operation("attachmentChunk"), fields().put("offset", offset).put("data", Base64.encodeToString(content.copyOfRange(offset, end), Base64.NO_WRAP))) { result ->
                        if (result.optBoolean("ok")) chunk(end) else finish(result)
                    }
                }
                client.request(operation("attachmentStart"), fields().put("name", name).put("mime", mime).put("size", content.size)) { result -> if (result.optBoolean("ok")) chunk(0) else finish(result) }
            }
        }
    }
}
