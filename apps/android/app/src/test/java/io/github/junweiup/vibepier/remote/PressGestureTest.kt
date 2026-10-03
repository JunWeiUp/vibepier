package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.remote.PressGesture
import org.junit.Assert.*
import org.junit.Test
class PressGestureTest {
    @Test fun outsideNeverBegins() { val g = PressGesture(); assertFalse(g.begin(0, false)); assertFalse(g.end(0)) }
    @Test fun secondaryPointerCannotReleasePrimary() {
        val g = PressGesture(); assertTrue(g.begin(4, true)); assertFalse(g.begin(7, true))
        assertFalse(g.end(7)); assertEquals(4, g.pointer); assertTrue(g.end(4)); assertFalse(g.end(4))
    }
    @Test fun cancelledGestureCannotFireOnLaterUp() {
        val g = PressGesture(); g.begin(2, true); assertTrue(g.cancel()); assertFalse(g.end(2))
        assertTrue(g.begin(3, true)); assertTrue(g.end(3))
    }
}
