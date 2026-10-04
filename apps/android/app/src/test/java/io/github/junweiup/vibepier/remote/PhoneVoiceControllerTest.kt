package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.voice.PhoneVoiceController
import org.junit.Assert.*
import org.junit.Test

class PhoneVoiceControllerTest {
    private class Clock : PhoneVoiceController.Scheduler {
        var now = 0L
        val pending = mutableMapOf<Runnable, Long>()
        override fun post(task: Runnable, delayMs: Long) { pending[task] = now + delayMs }
        override fun cancel(task: Runnable) { pending.remove(task) }
        fun advance(duration: Long) {
            val end = now + duration
            while (true) {
                val entry = pending.minByOrNull { it.value }?.takeIf { it.value <= end } ?: break
                pending.remove(entry.key); now = entry.value; entry.key.run()
            }
            now = end
        }
    }
    private class Harness {
        val clock = Clock()
        val events = mutableListOf<String>()
        val failures = mutableListOf<String>()
        val states = mutableListOf<PhoneVoiceController.State>()
        var frame: ((ByteArray) -> Unit)? = null
        var failure: ((String) -> Unit)? = null
        var number = 0
        val voice = PhoneVoiceController(object : PhoneVoiceController.Transport {
            override fun begin(session: String, keys: String, app: String, rate: Int) { events += "begin:$session:$keys:$app:$rate" }
            override fun end(session: String) { events += "end:$session" }
            override fun frame(session: String, sequence: Int, bytes: ByteArray) { events += "frame:$session:$sequence" }
        }, object : PhoneVoiceController.Capture {
            override fun start(rate: Int, packetMs: Int, frame: (ByteArray) -> Unit, failure: (String) -> Unit) {
                events += "record:$rate:$packetMs"; this@Harness.frame = frame; this@Harness.failure = failure
            }
            override fun stop() { events += "stop" }
        }, clock, states::add, failures::add, "synthetic timeout", { "session-${++number}" })
        fun begin(bluetooth: Boolean = false) = voice.begin("rcmd", "test.editor", bluetooth)
        fun ready(id: String = "session-1", packetMs: Int = 20) = voice.receive(id, true, packetMs, "")
    }

    @Test fun earlyReleaseCancelsRetriesAndRejectsLateReady() {
        val h = Harness(); h.begin(); h.voice.stop(); h.ready(); h.clock.advance(5000)
        assertEquals(1, h.events.count { it.startsWith("begin:") })
        assertEquals(1, h.events.count { it == "end:session-1" })
        assertFalse(h.events.any { it.startsWith("record:") })
        assertTrue(h.failures.isEmpty()); assertFalse(h.voice.active)
    }
    @Test fun retriesStopAtDeadlineAndReleaseRemoteLease() {
        val h = Harness(); h.begin(true); h.clock.advance(5000)
        assertEquals(7, h.events.count { it == "begin:session-1:rcmd:test.editor:8000" })
        assertEquals(listOf("synthetic timeout"), h.failures); assertFalse(h.voice.active)
        assertEquals("end:session-1", h.events.last())
        assertTrue(h.clock.pending.isEmpty())
    }
    @Test fun readyStartsCaptureOnceAndUsesNegotiatedPacketSize() {
        val h = Harness(); h.begin(true); h.ready(packetMs = 60); h.ready(packetMs = 60)
        h.frame!!(byteArrayOf(1)); h.frame!!(byteArrayOf(2)); h.clock.advance(5000)
        assertEquals(1, h.events.count { it == "record:8000:60" })
        assertEquals(listOf("frame:session-1:0", "frame:session-1:1"), h.events.filter { it.startsWith("frame:") })
        assertTrue(h.voice.active); assertTrue(h.failures.isEmpty())
        h.voice.stop(); val size = h.events.size; h.frame!!(byteArrayOf(3))
        assertEquals(size, h.events.size)
        assertEquals(listOf("stop", "end:session-1"), h.events.takeLast(2))
    }
    @Test fun staleCaptureFailureCannotStopANewerGesture() {
        val h = Harness(); h.begin(); h.ready()
        val oldError = h.failure!!; val oldFrame = h.frame!!
        h.begin(); h.ready("session-2", 999)
        oldError("old recorder failed"); oldFrame(byteArrayOf(9)); h.clock.advance(0)
        assertTrue(h.voice.active); assertTrue(h.failures.isEmpty())
        assertEquals(2, h.events.count { it == "record:16000:20" })
        assertFalse(h.events.any { it.startsWith("frame:session-1") })
        h.frame!!(byteArrayOf(1)); assertEquals("frame:session-2:0", h.events.last())
    }
    @Test fun remoteRejectionStopsCaptureAndSurfacesError() {
        val h = Harness(); h.begin(); h.ready()
        h.voice.receive("session-1", false, 20, "synthetic rejection")
        assertFalse(h.voice.active); assertEquals(listOf("synthetic rejection"), h.failures)
        assertEquals(listOf("stop", "end:session-1"), h.events.takeLast(2))
    }
    @Test fun lateRejectionFromPriorSessionIsIgnored() {
        val h = Harness(); h.begin(); h.begin(); h.voice.receive("session-1", false, 20, "old rejection")
        assertTrue(h.voice.active); assertTrue(h.failures.isEmpty())
        h.ready("session-2"); assertEquals(PhoneVoiceController.State.RECORDING, h.states.last())
    }
    @Test fun audioPathLossEndsRecordingAndRejectsLateFrames() {
        val h = Harness(); h.begin(); h.ready()
        val oldFrame = h.frame!!
        h.voice.transportChanged(false, "synthetic path lost")
        oldFrame(byteArrayOf(4)); h.clock.advance(5000)
        assertFalse(h.voice.active)
        assertEquals(listOf("synthetic path lost"), h.failures)
        assertEquals(listOf("stop", "end:session-1"), h.events.takeLast(2))
        h.voice.transportChanged(true, "")
        assertFalse(h.voice.active)
    }
    @Test fun audioPathLossDuringNegotiationCancelsRetryAndIgnoresReady() {
        val h = Harness(); h.begin()
        h.voice.transportChanged(false, "synthetic path lost"); h.ready(); h.clock.advance(5000)
        assertEquals(1, h.events.count { it.startsWith("begin:") })
        assertFalse(h.events.any { it.startsWith("record:") })
        assertTrue(h.clock.pending.isEmpty())
        assertEquals(listOf("synthetic path lost"), h.failures)
    }
}
