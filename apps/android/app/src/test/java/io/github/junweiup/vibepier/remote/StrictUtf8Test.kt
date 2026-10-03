package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.security.StrictUtf8
import org.junit.Assert.*
import org.junit.Test

class StrictUtf8Test {
    @Test fun exactLargeBodiesAndValidReplacementCharacterSurvive() {
        for (value in listOf("", "a+/=".repeat(50_000), "界😀\u0000�".repeat(20_000))) {
            assertEquals(value, StrictUtf8.decode(value.toByteArray(Charsets.UTF_8)))
        }
    }
    @Test fun invalidEncodingsAreRejectedRatherThanReplaced() {
        for (value in listOf(listOf(0x80), listOf(0xc0, 0x80), listOf(0xe0, 0x80, 0x80), listOf(0xed, 0xa0, 0x80), listOf(0xf4, 0x90, 0x80, 0x80), listOf(0xe7, 0x95))) {
            try { StrictUtf8.decode(value.map { it.toByte() }.toByteArray()); fail("Accepted invalid UTF-8") }
            catch (_: java.nio.charset.CharacterCodingException) {}
        }
    }
}
