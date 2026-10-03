package io.github.junweiup.vibepier.remote.core.transport

/** One complete, ordered list per Mac revision; partial updates keep the prior list visible. */
internal class ShortcutSnapshot<T> {
    var revision = ""; private set
    var count = 5; private set
    private val entries = mutableMapOf<Int, T>()
    val complete get() = revision.isNotEmpty() && entries.size == count
    fun contains(slot: Int) = slot in entries

    /** Returns true when a new snapshot replaces the pending assembly. Old Macs omit count and use five. */
    fun begin(value: String, total: Int = 5): Boolean {
        if (value.isBlank() || total <= 0) return false
        if (value == revision && total == count) return false
        revision = value; count = total; entries.clear()
        return true
    }

    fun append(value: String, slot: Int, total: Int = count, entry: T): List<T>? {
        if (value != revision || value.isBlank() || total != count || slot !in 0 until count || contains(slot)) return null
        entries[slot] = entry
        return if (complete) (0 until count).map { entries.getValue(it) } else null
    }

    fun clear() { revision = ""; count = 5; entries.clear() }

    companion object {
        fun validSlots(slots: List<Int>) = slots.sorted() == slots.indices.toList()
    }
}
