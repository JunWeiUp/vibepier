package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.sessions.ConversationImage
import org.junit.Assert.assertEquals
import org.junit.Test

class ConversationImageTest {
    @Test fun imageTilesCropCenterWithoutStretching() {
        assertEquals(listOf(100, 0, 300, 200), ConversationImage.crop(400, 200, 100, 100))
        assertEquals(listOf(0, 50, 200, 250), ConversationImage.crop(200, 300, 100, 100))
    }
}
