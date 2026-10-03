package io.github.junweiup.vibepier.remote.features.remote

import android.content.Context
import io.github.junweiup.vibepier.remote.R

/** Display-only localization. Wire names and shortcut parsing stay in Keys. */
internal object KeyLabels {
    private val symbols = mapOf(
        "cmd" to "⌘",
        "command" to "⌘",
        "lcmd" to "⌘",
        "shift" to "⇧",
        "lshift" to "⇧",
        "alt" to "⌥",
        "option" to "⌥",
        "opt" to "⌥",
        "lalt" to "⌥",
        "ctrl" to "⌃",
        "control" to "⌃",
        "lctrl" to "⌃",
        "fn" to "fn",
        "globe" to "fn",
        "escape" to "Esc",
        "esc" to "Esc",
        "backspace" to "⌫",
        "delete" to "⌫",
        "forwarddelete" to "⌦",
        "del" to "⌦",
        "tab" to "Tab",
        "up" to "↑",
        "down" to "↓",
        "left" to "←",
        "right" to "→",
        "pageup" to "PgUp",
        "pagedown" to "PgDn",
        "home" to "Home",
        "end" to "End",
    )
    private val names = mapOf(
        "rcmd" to R.string.key_right_command,
        "rcommand" to R.string.key_right_command,
        "rshift" to R.string.key_right_shift,
        "ralt" to R.string.key_right_option,
        "ropt" to R.string.key_right_option,
        "rctrl" to R.string.key_right_control,
        "return" to R.string.key_return,
        "enter" to R.string.key_return,
        "space" to R.string.key_space,
        "spacebar" to R.string.key_space,
        "wheel-up" to R.string.key_scroll_up,
        "wheelup" to R.string.key_scroll_up,
        "scroll-up" to R.string.key_scroll_up,
        "scrollup" to R.string.key_scroll_up,
        "wheel-down" to R.string.key_scroll_down,
        "wheeldown" to R.string.key_scroll_down,
        "scroll-down" to R.string.key_scroll_down,
        "scrolldown" to R.string.key_scroll_down,
        "click" to R.string.key_left_click,
        "left-click" to R.string.key_left_click,
        "leftclick" to R.string.key_left_click,
        "right-click" to R.string.key_right_click,
        "rightclick" to R.string.key_right_click,
        "middle-click" to R.string.key_middle_click,
        "middleclick" to R.string.key_middle_click,
        "volumeup" to R.string.key_volume_up,
        "volumedown" to R.string.key_volume_down,
        "mute" to R.string.key_mute,
    )
    fun label(context: Context, keys: String) = Keys.parts(keys).joinToString(" ") { key ->
        names[key]?.let { context.getString(it) } ?: symbols[key] ?: key.uppercase()
    }
}
