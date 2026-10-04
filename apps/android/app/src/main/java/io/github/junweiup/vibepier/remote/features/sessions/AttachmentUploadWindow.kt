package io.github.junweiup.vibepier.remote.features.sessions

/** Reservations include chunks being encoded as well as requests awaiting acknowledgement. */
internal class AttachmentUploadWindow(val size: Int, val chunkBytes: Int, val capacity: Int) {
    private var next = 0
    private val pending = mutableSetOf<Int>()
    var acknowledgedBytes = 0; private set
    val complete get() = acknowledgedBytes == size && pending.isEmpty()
    init { require(size in 1..10 * 1024 * 1024 && chunkBytes in 1..128 * 1024 && capacity in 1..3) }
    fun reserve(): Int? {
        if (pending.size >= capacity || next >= size) return null
        val offset = next
        next += length(offset)
        check(pending.add(offset))
        return offset
    }
    fun length(offset: Int) = minOf(chunkBytes, size - offset)
    fun acknowledge(offset: Int, end: Int) {
        require(offset in pending && end == offset + length(offset))
        pending.remove(offset)
        acknowledgedBytes += length(offset)
    }
}
