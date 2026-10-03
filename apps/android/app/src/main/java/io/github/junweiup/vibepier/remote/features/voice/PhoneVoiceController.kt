package io.github.junweiup.vibepier.remote.features.voice

import java.util.UUID

/** Main-thread lifecycle owner. Audio callbacks cannot outlive the gesture/session that created them. */
internal class PhoneVoiceController(
    private val transport: Transport,
    private val capture: Capture,
    private val scheduler: Scheduler,
    private val stateChanged: (State) -> Unit,
    private val failed: (String) -> Unit,
    private val timeoutMessage: String,
    private val identity: () -> String = { UUID.randomUUID().toString().replace("-", "") },
) {
    enum class State { IDLE, CONNECTING, RECORDING }
    interface Transport {
        fun begin(session: String, keys: String, app: String, rate: Int)
        fun end(session: String)
        fun frame(session: String, sequence: Int, bytes: ByteArray)
    }
    interface Capture {
        fun start(rate: Int, packetMs: Int, frame: (ByteArray) -> Unit, failure: (String) -> Unit)
        fun stop()
    }
    interface Scheduler {
        fun post(task: Runnable, delayMs: Long = 0)
        fun cancel(task: Runnable)
    }
    private data class Session(val id: String, val keys: String, val app: String, val rate: Int,
        @Volatile var recording: Boolean = false, var sequence: Int = 0)
    @Volatile private var current: Session? = null
    val active get() = current != null
    private val retry = object : Runnable {
        override fun run() {
            val session = current ?: return
            if (session.recording) return
            transport.begin(session.id, session.keys, session.app, session.rate)
            if (current === session && !session.recording) scheduler.post(this, 600)
        }
    }
    private val timeout = Runnable { fail(timeoutMessage) }

    fun begin(keys: String, app: String?, bluetooth: Boolean) {
        stop()
        current = Session(identity(), keys, app.orEmpty(), if (bluetooth) 8000 else 16000)
        stateChanged(State.CONNECTING)
        scheduler.post(timeout, 4000)
        retry.run()
    }

    fun receive(sessionID: String, ready: Boolean, packetMs: Int, error: String) {
        val session = current?.takeIf { it.id == sessionID } ?: return
        if (!ready) { fail(error); return }
        if (session.recording) return
        session.recording = true
        scheduler.cancel(retry); scheduler.cancel(timeout)
        stateChanged(State.RECORDING)
        capture.start(session.rate, packetMs.takeIf { it == 20 || it == 60 } ?: 20, { frame ->
            // Capture invokes frames serially on its audio worker; lifecycle writes are volatile.
            if (current === session && session.recording) transport.frame(session.id, session.sequence++, frame)
        }, { message ->
            scheduler.post(Runnable { if (current === session) fail(message) })
        })
    }

    fun stop() {
        val previous = current
        current = null
        previous?.recording = false
        scheduler.cancel(retry); scheduler.cancel(timeout)
        capture.stop()
        if (previous != null) transport.end(previous.id)
        stateChanged(State.IDLE)
    }

    private fun fail(message: String) { stop(); failed(message) }
}
