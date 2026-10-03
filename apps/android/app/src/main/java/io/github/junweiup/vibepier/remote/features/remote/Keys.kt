package io.github.junweiup.vibepier.remote.features.remote

/**
 * Hotkeys the buttons send, written the way the Mac reads them (`vibepier keys`
 * lists every name): key names joined with "+", such as `cmd+shift+4`.
 */
object Keys {
    val modifiers = linkedMapOf("cmd" to "⌘ Command", "ctrl" to "⌃ Control",
        "alt" to "⌥ Option", "shift" to "⇧ Shift")
    private val aliases = mapOf("command" to "cmd", "lcmd" to "cmd", "control" to "ctrl",
        "lctrl" to "ctrl", "option" to "alt", "opt" to "alt", "lalt" to "alt", "lshift" to "shift")
    private val modifierNames = modifiers.keys + setOf("rcmd", "rcommand", "rctrl", "rshift", "ralt", "ropt", "fn", "globe")
    /** The AU05 factory keys, except talk, which VibePier holds as right Command. */
    val defaults = mapOf(
        "knob-left" to "wheel-up",
        "knob-right" to "wheel-down",
        "cancel" to "escape",
        "confirm" to "return",
        "talk" to "rcmd",
        "knob-press" to "backspace",
    )

    /** Quick picks in the editor. */
    val presets = listOf(
        "cmd+ctrl", "cmd+shift", "cmd+alt",
        "return", "escape", "space", "tab", "backspace", "rcmd", "fn",
        "wheel-up", "wheel-down", "up", "down", "left", "right",
        "cmd+return", "cmd+z", "cmd+c", "cmd+v", "volumeup", "volumedown",
    )

    private val namedKeys = setOf(
        "cmd", "command", "lcmd", "rcmd", "rcommand", "shift", "lshift",
        "rshift", "alt", "option", "opt", "lalt", "ralt", "ropt",
        "ctrl", "control", "lctrl", "rctrl", "fn", "globe", "return",
        "enter", "escape", "esc", "backspace", "delete", "forwarddelete", "del",
        "tab", "space", "spacebar", "up", "down", "left", "right",
        "pageup", "pagedown", "home", "end", "wheel-up", "wheelup", "scroll-up",
        "scrollup", "wheel-down", "wheeldown", "scroll-down", "scrolldown", "click", "left-click",
        "leftclick", "right-click", "rightclick", "middle-click", "middleclick", "volumeup", "volumedown",
        "mute",
    )

    private val otherNames = setOf(
        "minus", "equal", "equals", "plus", "comma", "period", "dot", "slash", "backslash",
        "semicolon", "quote", "apostrophe", "grave", "backtick", "leftbracket", "rightbracket",
        "capslock", "caps", "insert", "pgup", "pgdn", "rightarrow", "leftarrow", "uparrow", "downarrow",
        "numlock", "clear", "kpenter", "application", "menu", "power", "help", "printscreen",
        "scrolllock", "pause", "mouse1", "mouse2", "mouse3", "kp/", "kp*", "kp-", "kp+", "kp.", "kp=",
    ) + (1..24).map { "f$it" } + (0..9).map { "kp$it" }

    /** "cmd++" is Command and the plus key, so "+" only splits after another character. */
    internal fun parts(text: String) = text.split(Regex("(?<=[^+])\\+"))

    private fun known(name: String) =
        name in namedKeys || name in otherNames || (name.length == 1 && name[0].code in 33..126)

    /** The hotkey in canonical form, or null if the Mac would not understand it. */
    fun normalize(text: String): String? {
        val t = text.trim().lowercase().replace(Regex("\\s*\\+\\s*"), "+")
        if (t.isEmpty() || t.any { it.isWhitespace() }) return null
        val names = parts(t).map { aliases[it] ?: it }.distinct()
        if (names.size > 4 || !names.all(::known)) return null
        return names.joinToString("+")
    }

    fun hasModifier(text: String, modifier: String) = normalize(text)?.let { modifier in parts(it) } ?: false

    /** Empty is valid while composing; null means the edit would be invalid. */
    fun toggleModifier(text: String, modifier: String, enabled: Boolean): String? {
        if (modifier !in modifiers) return null
        val current = if (text.isBlank()) emptyList() else normalize(text)?.let(::parts) ?: return null
        val values = current.filter { it != modifier }.toMutableList()
        if (enabled) values.add(0, modifier)
        val result = (values.filter { it in modifierNames } + values.filter { it !in modifierNames }).joinToString("+")
        return if (result.isEmpty()) "" else normalize(result)
    }

    fun choosePreset(text: String, preset: String): String? {
        val selected = normalize(preset) ?: return null
        if (parts(selected).any { it in modifierNames }) return selected
        val current = if (text.isBlank()) emptyList() else normalize(text)?.let(::parts) ?: return null
        return normalize((current.filter { it in modifierNames } + parts(selected)).joinToString("+"))
    }

}
