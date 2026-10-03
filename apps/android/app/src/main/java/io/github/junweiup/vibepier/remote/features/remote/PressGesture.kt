package io.github.junweiup.vibepier.remote.features.remote

/** Own one pointer; once cancelled, a gesture can never restart without a new down. */
class PressGesture {
    var pointer: Int = -1; private set
    fun begin(id: Int, inside: Boolean): Boolean {
        if (!inside || pointer != -1) return false
        pointer = id
        return true
    }
    fun end(id: Int): Boolean {
        if (pointer != id) return false
        pointer = -1
        return true
    }
    fun cancel(): Boolean { val active = pointer != -1; pointer = -1; return active }
}
