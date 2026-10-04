package io.github.junweiup.vibepier.remote.features.sessions

import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.view.ViewTreeObserver

/** Reconciles stable message/approval identities without detaching unchanged rows. */
internal class ConversationTimeline(private val container: LinearLayout) {
    class Row(val key: String, val signature: String, val create: () -> View,
              val update: (View) -> Boolean = { false })
    data class Anchor(val key: String, val offset: Int)
    private data class Entry(val signature: String, val view: View)
    private val entries = linkedMapOf<String, Entry>()

    fun anchor(y: Int): Anchor? = entries.entries.firstOrNull { it.key != "older" && it.value.view.bottom > y }
        ?.let { Anchor(it.key, y - it.value.view.top) }
    fun position(anchor: Anchor): Int? = entries[anchor.key]?.view?.let { it.top + anchor.offset }

    private data class PendingPosition(val anchor: Anchor?, val y: Int, val height: Int,
                                       val bottom: Boolean, val restored: Int?)
    private var pendingPosition: PendingPosition? = null
    val restoringPosition: Boolean get() = pendingPosition != null

    /** Keep the first snapshot across updates arriving before the same layout/draw. */
    fun preservePosition(scroll: ScrollView, bottom: Boolean, restored: Int?,
                         valid: () -> Boolean, onRestore: () -> Unit) {
        if (pendingPosition != null) return
        pendingPosition = PendingPosition(anchor(scroll.scrollY), scroll.scrollY, container.height, bottom, restored)
        val observer = scroll.viewTreeObserver
        val listener = object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (observer.isAlive) observer.removeOnPreDrawListener(this)
                val saved = pendingPosition ?: return true
                try {
                    if (valid()) {
                        val target = saved.restored ?: if (saved.bottom) container.height else
                            saved.anchor?.let(::position) ?: (saved.y + container.height - saved.height)
                        scroll.scrollTo(0, target.coerceAtLeast(0))
                        onRestore()
                    }
                } finally { pendingPosition = null }
                return true
            }
        }
        observer.addOnPreDrawListener(listener)
    }

    fun reconcile(rows: List<Row>) {
        val keys = rows.map { it.key }.toSet()
        entries.keys.filter { it !in keys }.toList().forEach { key ->
            entries.remove(key)?.view?.let(container::removeView)
        }
        val ordered = linkedMapOf<String, Entry>()
        rows.distinctBy { it.key }.forEachIndexed { index, row ->
            val old = entries[row.key]
            val view = when {
                old == null -> row.create()
                old.signature == row.signature -> old.view
                row.update(old.view) -> old.view
                else -> row.create().also { container.removeView(old.view) }
            }
            if (container.getChildAt(index) !== view) {
                (view.parent as? ViewGroup)?.removeView(view)
                container.addView(view, index)
            }
            ordered[row.key] = Entry(row.signature, view)
        }
        entries.clear(); entries.putAll(ordered)
    }
}
