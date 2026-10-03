package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.voice.PhoneAudioCodec

import org.junit.Assert.*
import org.junit.Test

class PhoneAudioCodecTest {
    @Test fun sixtyMillisecondPacketsUseTheSameIndependentHeader() {
        for (count in listOf(480, 960)) {
            val packet = PhoneAudioCodec.encode(ShortArray(count) { 1000 })
            assertEquals(4 + count / 2, packet.size)
            assertEquals(232.toByte(), packet[0])
            assertEquals(3.toByte(), packet[1])
            assertTrue(packet.drop(2).all { it == 0.toByte() })
        }
    }
    @Test fun silentAndConstantFramesAreIndependent() {
        val silence = PhoneAudioCodec.encode(ShortArray(160))
        assertEquals(84, silence.size)
        assertTrue(silence.all { it == 0.toByte() })
        val constant = PhoneAudioCodec.encode(ShortArray(320) { 1000 })
        assertEquals(164, constant.size)
        assertEquals(232.toByte(), constant[0])
        assertEquals(3.toByte(), constant[1])
        assertTrue(constant.drop(2).all { it == 0.toByte() })
        assertArrayEquals(silence, PhoneAudioCodec.encode(ShortArray(160)))
    }
    @Test fun packetBoundsAndPredictorHeader() {
        val samples = ShortArray(160) { if (it % 2 == 0) Short.MIN_VALUE else Short.MAX_VALUE }
        val packet = PhoneAudioCodec.encode(samples)
        assertEquals(0.toByte(), packet[0])
        assertEquals(128.toByte(), packet[1])
        assertEquals(84, packet.size)
    }
}
