package io.github.junweiup.vibepier.remote.core.files

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

/** Media bytes travel only through the binary HTTPS channel; RPC carries metadata. */
internal object BinaryMediaClient {
    private fun profile(result: JSONObject, mime: String, maximum: Long): JSONObject {
        check(result.optBoolean("ok"))
        val profile = result.getJSONObject("binary")
        check(profile.getString("kind") == "media" && profile.getString("mime") == mime &&
            profile.getLong("size") in 1..maximum && profile.getLong("offset") == 0L)
        val hash = profile.getString("sha256")
        check(hash.length == 64 && hash.all { it in '0'..'9' || it in 'a'..'f' })
        return profile
    }
    private fun verify(hash: MessageDigest, profile: JSONObject) {
        val expected = profile.getString("sha256").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        check(MessageDigest.isEqual(hash.digest(), expected))
    }
    fun image(result: JSONObject, host: String?, client: BinaryFileClient, progress: () -> Unit = {}): Bitmap? {
        val profile = profile(result, "image/jpeg", 8L * 1024 * 1024)
        val hash = MessageDigest.getInstance("SHA-256")
        val output = ByteArrayOutputStream(profile.getInt("size"))
        client.download(profile, host, profile.getLong("size"), 0, kind = "media", chunkBytes = 64 * 1024) { bytes -> hash.update(bytes); output.write(bytes); progress() }
        verify(hash, profile)
        val bytes = output.toByteArray()
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        check(bounds.outWidth in 1..2048 && bounds.outHeight in 1..2048)
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }
    fun video(result: JSONObject, host: String?, client: BinaryFileClient, file: File, progress: (Long, Long) -> Unit) {
        val profile = profile(result, "video/mp4", 128L * 1024 * 1024)
        val size = profile.getLong("size")
        val hash = MessageDigest.getInstance("SHA-256")
        FileOutputStream(file, false).use { output ->
            var received = 0L
            client.download(profile, host, size, 0, kind = "media") { bytes ->
                hash.update(bytes); output.write(bytes); received += bytes.size; progress(received, size)
            }
            check(received == size)
            output.fd.sync()
        }
        verify(hash, profile)
    }
}
