package io.github.junweiup.vibepier.remote.core.session

import org.json.JSONObject

/** Removed transfer dialects must not escape through the generic RPC sender. */
internal object SessionTransferPolicy {
    fun accepts(op: String, fields: JSONObject): Boolean =
        op !in setOf("apkChunk", "attachmentChunk", "newAttachmentChunk") &&
            listOf("downloadVersion", "downloadToken", "uploadVersion", "uploadFragmentChars").none(fields::has)
}
