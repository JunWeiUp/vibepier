package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.remote.Keys

import org.junit.Assert.*
import org.junit.Test

class KeysTest {
    @Test fun acceptsSpacedModifierNamesAndPlusKey() {
        assertEquals("cmd+ctrl", Keys.normalize("Command + Control"))
        assertEquals("cmd+ctrl+k", Keys.normalize(" Command + Control + K "))
        assertEquals("cmd++", Keys.normalize("Command + +"))
        assertEquals("cmd+ctrl", Keys.normalize("cmd+command+Control"))
        assertNull(Keys.normalize("com mand + control"))
        assertNull(Keys.normalize("cmd+ctrl+alt+shift+k"))
    }

    @Test fun togglesModifiersWithoutDiscardingTheBaseKey() {
        assertEquals("ctrl+cmd+k", Keys.toggleModifier("command+k", "ctrl", true))
        assertEquals("k", Keys.toggleModifier("Command + k", "cmd", false))
        assertEquals("", Keys.toggleModifier("Control", "ctrl", false))
        assertEquals("cmd", Keys.toggleModifier("", "cmd", true))
        assertTrue(Keys.hasModifier("Command + Control", "ctrl"))
    }

    @Test fun basePresetRetainsModifiersAndCombinationPresetReplacesAll() {
        assertEquals("cmd+ctrl+return", Keys.choosePreset("cmd+ctrl+k", "return"))
        assertEquals("cmd+ctrl", Keys.choosePreset("rcmd", "cmd+ctrl"))
        assertNull(Keys.choosePreset("cmd+ctrl+alt+shift", "return"))
    }
}
