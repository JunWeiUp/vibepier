package io.github.junweiup.vibepier.remote.features.markdown

import java.net.URLDecoder

/** File references are inert until tapped; the Mac validates their actual session workspace. */
internal object MarkdownFileLinks {
    data class Link(val label: String, val path: String, val line: Int? = null)

    /** `anyFile` admits every local path (the project browser opens it); otherwise only Markdown documents. */
    fun parseTarget(target: String, label: String = "", anyFile: Boolean = false): Link? {
        var path = target.trim().removeSurrounding("<", ">")
        if (path.isBlank() || path.any { it == '\u0000' || it == '\n' || it == '\r' }) return null
        path = try { URLDecoder.decode(path.replace("+", "%2B"), "UTF-8") } catch (_: IllegalArgumentException) { return null }
        val suffix = Regex("(?::([1-9][0-9]*)(?::[1-9][0-9]*)?|#L([1-9][0-9]*))$").find(path)
        val line = suffix?.let { it.groupValues.drop(1).firstOrNull(String::isNotEmpty)?.toIntOrNull() }
        if (suffix != null) path = path.substring(0, suffix.range.first)
        // Check after removing a line hint: README.md:12 is a file, not a URL scheme.
        if (Regex("^[a-zA-Z][a-zA-Z0-9+.-]*:").containsMatchIn(path) || path.startsWith("//") || path.any { it == '\u0000' || it == '\n' || it == '\r' }) return null
        if (path.startsWith("#") || path.endsWith("/")) return null
        if (!isMarkdown(path) && !(anyFile && looksLikeFile(path))) return null
        return Link(label.ifBlank { path.substringAfterLast('/') }, path, line)
    }

    /** A path with a file name: an extension, or a slash before a plain name. Bare words such as "foo" stay text. */
    fun looksLikeFile(path: String): Boolean {
        val name = path.substringAfterLast('/')
        return name.isNotEmpty() && !name.contains(' ') && (path.contains('/') || Regex("\\.[A-Za-z0-9]{1,10}$").containsMatchIn(name))
    }

    fun isMarkdown(path: String) = path.lowercase().let { it.endsWith(".md") || it.endsWith(".markdown") }

    fun resolve(link: Link, documentPath: String): Link = if (link.path.startsWith('/')) link else {
        val parent = documentPath.substringBeforeLast('/', "")
        link.copy(path = if (parent.isEmpty()) link.path else "$parent/${link.path}")
    }

    fun find(raw: String, anyFile: Boolean = false): List<Link> {
        val links = linkedMapOf<Pair<String, Int?>, Link>()
        var fence: Char? = null; var fenceLength = 0
        raw.lineSequence().forEach { line ->
            val mark = Regex("^ {0,3}(`{3,}|~{3,})(.*)$").find(line)
            if (mark != null) {
                val token = mark.groupValues[1]
                if (fence == null) { fence = token[0]; fenceLength = token.length }
                else if (token[0] == fence && token.length >= fenceLength && mark.groupValues[2].isBlank()) fence = null
                return@forEach
            }
            if (fence != null) return@forEach
            var index = 0
            while (index < line.length) {
                if (line[index] == '\\') { index += 2; continue }
                if (line[index] == '`') {
                    val start = index
                    while (index < line.length && line[index] == '`') index++
                    val end = line.indexOf("`".repeat(index - start), index)
                    index = if (end < 0) index else end + index - start
                    continue
                }
                if (line[index] != '[') { index++; continue }
                val start = index++
                val labelEnd = line.indexOf(']', index)
                if (labelEnd < 0 || line.getOrNull(labelEnd + 1) != '(') continue
                var cursor = labelEnd + 2; var depth = 1; var angle = false
                val targetStart = cursor
                while (cursor < line.length) {
                    val char = line[cursor]
                    if (char == '\\') { cursor += 2; continue }
                    if (char == '<' && cursor == targetStart) angle = true
                    else if (char == '>') angle = false
                    else if (!angle && char == '(') depth++
                    else if (!angle && char == ')' && --depth == 0) break
                    cursor++
                }
                if (depth != 0) continue
                index = cursor + 1
                if (start > 0 && line[start - 1] == '!') continue
                val target = line.substring(targetStart, cursor).replace(Regex("\\\\([()\\\\ ])"), "$1")
                parseTarget(target, line.substring(start + 1, labelEnd), anyFile)?.let { links[it.path to it.line] = it }
            }
        }
        return links.values.toList()
    }
}
