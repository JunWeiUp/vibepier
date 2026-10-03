package io.github.junweiup.vibepier.remote.features.voice

import io.github.junweiup.vibepier.remote.R
import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.util.concurrent.atomic.AtomicBoolean

/** No background service: lifecycle/gesture release stops recording immediately. */
class PhoneMicCapture(private val resources: android.content.res.Resources) {
    private data class Capture(val active: AtomicBoolean = AtomicBoolean(true), var recorder: AudioRecord? = null)
    private var capture: Capture? = null
    @SuppressLint("MissingPermission") // Caller explicitly checks RECORD_AUDIO before beginning.
    @Synchronized fun start(rate: Int, frame: (ByteArray) -> Unit, failed: (String) -> Unit, packetMs: Int = 20) {
        require(rate in intArrayOf(8000, 16000) && packetMs in intArrayOf(20, 60))
        stop()
        val state = Capture()
        capture = state
        Thread({
            var recorder: AudioRecord? = null
            try {
                val minimum = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                check(minimum > 0) { resources.getString(R.string.mic_format_unsupported) }
                recorder = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, rate, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum * 2, rate / 5))
                check(recorder.state == AudioRecord.STATE_INITIALIZED) { resources.getString(R.string.mic_open_failed) }
                synchronized(this) {
                    if (!state.active.get()) return@Thread
                    state.recorder = recorder
                    recorder.startRecording()
                }
                check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) { resources.getString(R.string.mic_not_recording) }
                val samples = ShortArray(rate * packetMs / 1000)
                while (state.active.get()) {
                    var offset = 0
                    while (offset < samples.size && state.active.get()) {
                        val read = recorder.read(samples, offset, samples.size - offset, AudioRecord.READ_BLOCKING)
                        check(read > 0) { resources.getString(R.string.mic_interrupted) }
                        offset += read
                    }
                    if (state.active.get()) frame(PhoneAudioCodec.encode(samples))
                }
            } catch (error: Exception) {
                if (state.active.getAndSet(false)) failed(error.message ?: resources.getString(R.string.mic_record_failed))
            } finally {
                synchronized(this) {
                    state.recorder = null
                    try { recorder?.stop() } catch (_: Exception) {}
                    recorder?.release()
                    if (capture === state) capture = null
                }
            }
        }, "vibepier-phone-mic").apply { isDaemon = true; start() }
    }
    @Synchronized fun stop() {
        val state = capture ?: return
        state.active.set(false)
        try { state.recorder?.stop() } catch (_: Exception) {}
        capture = null
    }
}
