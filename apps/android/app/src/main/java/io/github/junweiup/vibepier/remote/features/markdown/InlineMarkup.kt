package io.github.junweiup.vibepier.remote.features.markdown

internal object InlineMarkup {
    data class Run(val text: String, val bold: Boolean = false, val italic: Boolean = false, val code: Boolean = false)
    private val token = Regex("""(?<!\\)(`+)([^`]+)\1|(?<!\\)\*\*(.+?)(?<!\\)\*\*|(?<![\\\p{L}\p{N}_])__(.+?)(?<!\\)__(?![\p{L}\p{N}_])|(?<![\\*])\*([^*\n]+)(?<!\\)\*(?!\*)""")
    fun parse(source: String, depth: Int = 0): List<Run> {
        if (depth > 3) return listOf(Run(source))
        val runs = mutableListOf<Run>(); var offset = 0
        for (match in token.findAll(source)) {
            if (match.range.first > offset) runs.add(Run(source.substring(offset, match.range.first)))
            val code = match.groupValues[1].isNotEmpty()
            val bold = match.groupValues[3].isNotEmpty() || match.groupValues[4].isNotEmpty()
            val body = if (code) match.groupValues[2] else if (bold) match.groupValues[3].ifEmpty { match.groupValues[4] } else match.groupValues[5]
            if (code) runs.add(Run(body, code = true))
            else runs.addAll(parse(body, depth + 1).map { it.copy(bold = it.bold || bold, italic = it.italic || !bold) })
            offset = match.range.last + 1
        }
        if (offset < source.length) runs.add(Run(source.substring(offset)))
        return runs
    }
}
