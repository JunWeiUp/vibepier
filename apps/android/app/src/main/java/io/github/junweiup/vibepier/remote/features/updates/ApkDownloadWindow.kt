package io.github.junweiup.vibepier.remote.features.updates

/** Main-thread owned. Reservations include replies being buffered or written, not just network reads. */
class ApkDownloadWindow(val size: Long, start: Long, val chunkBytes: Int, val capacity: Int) {
    var durableOffset = start; private set
    private var nextOffset = start
    private val slots = linkedMapOf<Long, ByteArray?>()
    val complete get() = durableOffset == size
    val occupied get() = slots.size
    init {
        require(size in 1..512L * 1024 * 1024 && start in 0..size)
        require(chunkBytes in 1..128 * 1024 && capacity in 1..4)
    }
    fun reserve(): Long? {
        if (slots.size == capacity || nextOffset == size) return null
        val offset = nextOffset
        nextOffset += minOf(chunkBytes.toLong(), size - offset)
        slots[offset] = null
        return offset
    }
    fun accept(offset: Long, bytes: ByteArray) {
        require(slots.containsKey(offset) && slots[offset] == null)
        require(bytes.size.toLong() == minOf(chunkBytes.toLong(), size - offset))
        slots[offset] = bytes
    }
    fun ready(): ByteArray? = slots[durableOffset]
    fun committed(offset: Long, bytes: ByteArray) {
        check(offset == durableOffset && slots[offset] === bytes)
        slots.remove(offset)
        durableOffset += bytes.size
    }
}
