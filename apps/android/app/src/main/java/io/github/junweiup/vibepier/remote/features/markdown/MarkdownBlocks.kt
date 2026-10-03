package io.github.junweiup.vibepier.remote.features.markdown

/** Display parser shared by chat and Markdown documents. Fenced code stays literal, including streamed fences. */
internal object MarkdownBlocks {
    enum class Kind { PARAGRAPH, HEADING, QUOTE, CODE, LIST, TABLE, DIVIDER }
    enum class ColumnAlignment { LEFT, CENTER, RIGHT }
    data class Block(
        val kind: Kind,
        val text: String,
        val detail: String = "",
        val level: Int = 0,
        val cells: List<List<String>> = emptyList(),
        val alignments: List<ColumnAlignment> = emptyList(),
        val taskChecked: Boolean? = null
    )
    private val fence = Regex("^\\s{0,3}(`{3,}|~{3,})(.*)$")
    private val heading = Regex("^\\s{0,3}(#{1,6})\\s+(.+)")
    private val quote = Regex("^\\s{0,3}> ?(.*)$")
    private val bullet = Regex("^\\s{0,3}([-+*]|\\d+[.)])\\s+(.+)$")
    private val task = Regex("^\\[([ xX])\\](?:[ \\t]+(.*))?$")
    private val divider = Regex("^\\s{0,3}(?:-{3,}|\\*{3,}|_{3,})\\s*$")
    private val tableDelimiter = Regex(":?-+:?")
    private fun special(line: String) = fence.matches(line) || heading.matches(line) || quote.matches(line) || bullet.matches(line) || divider.matches(line)
    private data class TableRow(val cells: List<String>, val hasPipe: Boolean)
    private fun tableRow(line: String): TableRow? {
        // Four-space indentation belongs to code, not a document table.
        if (line.startsWith("    ") || line.startsWith('\t')) return null
        val value = line.trim(); if (value.isEmpty()) return null
        val cells = mutableListOf<String>(); val cell = StringBuilder()
        var offset = 0; var codeTicks = 0; var lastPipe = -1; var hasPipe = false
        while (offset < value.length) {
            val char = value[offset]
            if (char == '\\' && offset + 1 < value.length) {
                val next = value[offset + 1]
                if (next != '|') cell.append(char)
                cell.append(next); offset += 2; continue
            }
            if (char == '`') {
                var end = offset + 1
                while (end < value.length && value[end] == '`') end++
                val count = end - offset
                if (codeTicks == count) codeTicks = 0
                else if (codeTicks == 0 && hasClosingTicks(value, end, count)) codeTicks = count
                cell.append(value, offset, end); offset = end; continue
            }
            if (char == '|' && codeTicks == 0) {
                cells.add(cell.toString().trim()); cell.clear(); hasPipe = true; lastPipe = offset
            } else cell.append(char)
            offset++
        }
        cells.add(cell.toString().trim())
        if (hasPipe && value.first() == '|') cells.removeAt(0)
        if (lastPipe == value.lastIndex && cells.isNotEmpty()) cells.removeAt(cells.lastIndex)
        return TableRow(cells, hasPipe)
    }
    private fun hasClosingTicks(value: String, start: Int, count: Int): Boolean {
        var offset = start
        while (offset < value.length) {
            if (value[offset] == '\\') { offset += 2; continue }
            if (value[offset] != '`') { offset++; continue }
            var end = offset + 1
            while (end < value.length && value[end] == '`') end++
            if (end - offset == count) return true
            offset = end
        }
        return false
    }
    private fun tableHeader(lines: List<String>, index: Int): Pair<TableRow, TableRow>? {
        if (index + 1 >= lines.size) return null
        val header = tableRow(lines[index]) ?: return null
        val delimiter = tableRow(lines[index + 1]) ?: return null
        if (!header.hasPipe || !delimiter.hasPipe || header.cells.isEmpty() || header.cells.size != delimiter.cells.size) return null
        if (!delimiter.cells.all { tableDelimiter.matches(it) }) return null
        return header to delimiter
    }
    fun parse(raw: String): List<Block> {
        val lines = raw.replace("\r\n", "\n").split('\n'); val blocks = mutableListOf<Block>(); var i = 0
        while (i < lines.size) {
            val line = lines[i]
            if (line.isBlank()) { i++; continue }
            val code = fence.matchEntire(line)
            if (code != null) {
                val marker = code.groupValues[1]; val body = mutableListOf<String>(); i++
                while (i < lines.size && !Regex("^\\s{0,3}" + Regex.escape(marker.first().toString()) + "{" + marker.length + ",}\\s*$").matches(lines[i])) body.add(lines[i++])
                if (i < lines.size) i++
                blocks.add(Block(Kind.CODE, body.joinToString("\n"), code.groupValues[2].trim())); continue
            }
            val h = heading.matchEntire(line)
            if (h != null) { blocks.add(Block(Kind.HEADING, h.groupValues[2].replace(Regex("\\s+#+\\s*$"), "").trimEnd(), level = h.groupValues[1].length)); i++; continue }
            val table = tableHeader(lines, i)
            if (table != null) {
                val columnCount = table.first.cells.size
                val rows = mutableListOf(table.first.cells)
                val alignments = table.second.cells.map {
                    if (it.startsWith(':') && it.endsWith(':')) ColumnAlignment.CENTER
                    else if (it.endsWith(':')) ColumnAlignment.RIGHT else ColumnAlignment.LEFT
                }
                i += 2
                while (i < lines.size && lines[i].isNotBlank() && !special(lines[i])) {
                    val row = tableRow(lines[i]) ?: break
                    if (!row.hasPipe) break
                    rows.add(List(columnCount) { column -> row.cells.getOrElse(column) { "" } }); i++
                }
                blocks.add(Block(Kind.TABLE, "", cells = rows, alignments = alignments)); continue
            }
            if (divider.matches(line)) { blocks.add(Block(Kind.DIVIDER, "")); i++; continue }
            if (quote.matches(line)) {
                val body = mutableListOf<String>()
                while (i < lines.size) {
                    val q = quote.matchEntire(lines[i]) ?: break
                    body.add(q.groupValues[1]); i++
                }
                blocks.add(Block(Kind.QUOTE, body.joinToString("\n"))); continue
            }
            val item = bullet.matchEntire(line)
            if (item != null) {
                val taskItem = task.matchEntire(item.groupValues[2])
                val checked = taskItem?.groupValues?.get(1)?.let { it != " " }
                val body = mutableListOf(taskItem?.groupValues?.get(2) ?: item.groupValues[2]); i++
                while (i < lines.size && lines[i].startsWith("  ") && lines[i].isNotBlank() && !special(lines[i]) && tableHeader(lines, i) == null) body.add(lines[i++].trimStart())
                val marker = item.groupValues[1]
                val detail = when (checked) { true -> "☑"; false -> "☐"; null -> if (marker.first().isDigit()) marker else "•" }
                blocks.add(Block(Kind.LIST, body.joinToString("\n"), detail, taskChecked = checked)); continue
            }
            val body = mutableListOf(line); i++
            while (i < lines.size && lines[i].isNotBlank() && !special(lines[i]) && tableHeader(lines, i) == null) body.add(lines[i++])
            blocks.add(Block(Kind.PARAGRAPH, body.joinToString("\n")))
        }
        return blocks
    }
}
