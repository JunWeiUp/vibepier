package io.github.junweiup.vibepier.remote.features.sessions

import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import io.github.junweiup.vibepier.remote.features.remote.Palette

internal object ReplyTextStyle {
    /** Diffs colored line by line: additions green, removals red, file and hunk headers muted. */
    fun styled(kind: String, text: String): CharSequence {
        if (kind != "file") return text
        val out = SpannableStringBuilder(text)
        var start = 0
        for (line in text.split('\n')) {
            val color = when {
                line.startsWith("***") || line.startsWith("@@") || line.startsWith("+++") || line.startsWith("---") -> Palette.muted
                line.startsWith("+") -> Palette.green
                line.startsWith("-") -> Palette.red
                else -> null
            }
            if (color != null && line.isNotEmpty()) out.setSpan(ForegroundColorSpan(color), start, start + line.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            start += line.length + 1
        }
        return out
    }
}
