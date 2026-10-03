package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.voice.PhoneMicCapture

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Record only in the explicitly invoked emulator test; stores no audio. */
object PhoneMicrophoneProbe {
    fun run(resources: android.content.res.Resources): String {
        val capture = PhoneMicCapture(resources)
        try {
            for (rate in listOf(8000, 16000)) {
                val frames = AtomicInteger()
                val error = AtomicReference<String?>(null)
                val ready = CountDownLatch(5)
                capture.start(rate, { bytes ->
                    check(bytes.size == 4 + rate / 100)
                    frames.incrementAndGet(); ready.countDown()
                }, { error.set(it); while (ready.count > 0) ready.countDown() })
                check(ready.await(5, TimeUnit.SECONDS)) { "Timed out recording at $rate" }
                check(error.get() == null) { error.get() ?: "capture failure" }
                capture.stop()
                Thread.sleep(100)
                val stopped = frames.get()
                Thread.sleep(150)
                check(frames.get() == stopped) { "Capture continued after stop" }
            }
            return "PASS: Android AudioRecord 8k/16k capture, packet lengths, stop privacy (no saved audio)\n"
        } catch (e: Throwable) {
            capture.stop()
            throw e
        }
    }
}
