package io.github.junweiup.vibepier.remote.core.transport

/** Bounded, order-independent assembly; incomplete icons are never decoded. */
class IconChunks(val count: Int) {
    init { require(count in 1..128) }
    private val parts = arrayOfNulls<String>(count)
    fun append(index: Int, text: String): String? {
        if (index !in parts.indices || text.length > 1200) return null
        parts[index] = text
        return if (parts.all { it != null }) parts.joinToString("") { it!! } else null
    }
}
