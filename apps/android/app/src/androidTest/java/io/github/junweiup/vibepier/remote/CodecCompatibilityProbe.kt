package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.security.StrictUtf8
import org.json.JSONObject
import java.util.Base64

/** Synthetic boundary diagnostics; never prints user text, credentials or real packets. */
object CodecCompatibilityProbe {
    fun run(): String {
        check(BuildConfig.DESIGN_REVIEW)
        val diagnostics = mutableListOf<String>()
        var failures = 0
        fun compare(name: String, expected: String, read: () -> String) {
            val actual = runCatching(read)
            val value = actual.getOrNull()
            val exact = value == expected
            if (!exact) failures++
            diagnostics.add("$name exact=$exact expected=${expected.length} actual=${value?.length} error=${actual.exceptionOrNull()?.javaClass?.simpleName}")
        }
        for ((name, sample) in listOf("ascii" to "a+/=".repeat(50_000), "unicode" to "界".repeat(90_000))) {
            val bytes = sample.toByteArray(Charsets.UTF_8)
            val json = JSONObject().put("text", sample).toString()
            compare("$name utf8", sample) { StrictUtf8.decode(bytes) }
            compare("$name legacyDecoder", sample) { Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString() }
            compare("$name substring", sample) { ("prefix" + sample + "suffix").substring(6, 6 + sample.length) }
            compare("$name builder", sample) { StringBuilder().append(sample).toString() }
            compare("$name JSON serialize", "{\"text\":\"$sample\"}") { json.replace("\\/", "/") }
            compare("$name JSON roundtrip", sample) { JSONObject(json).getString("text") }
            compare("$name direct JSON parse", sample) { JSONObject("{\"text\":\"$sample\"}").getString("text") }
            compare("$name base64", sample) { String(Base64.getDecoder().decode(Base64.getEncoder().encodeToString(bytes)), Charsets.UTF_8) }
            compare("$name Android base64", sample) { String(android.util.Base64.decode(android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP), android.util.Base64.NO_WRAP), Charsets.UTF_8) }
            compare("$name 900-character assembly", sample) { sample.chunked(900).joinToString("") }
        }
        val detail = diagnostics.joinToString("\n")
        check(failures == 0) { "Synthetic codec failures=$failures\n$detail" }
        return "PASS: Android UTF-8, substring, builder, JSON, Base64 and fragment round trips\n$detail\n"
    }
}
