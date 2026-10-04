package io.github.junweiup.vibepier.remote.features.files


/** Pure helpers behind the project file browser: file kinds, sizes, diffs, light syntax colouring and recent files. */
internal object ProjectFiles {
    enum class Tone { KEYWORD, STRING, COMMENT, NUMBER, TYPE }
    data class Token(val start: Int, val end: Int, val tone: Tone)

    enum class Row { HUNK, CONTEXT, ADD, DEL, NOTE }
    data class DiffLine(val kind: Row, val old: Int?, val new: Int?, val text: String)

    data class Kind(val tag: String, val color: Int)

    private val imageExtensions = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff")

    fun extension(name: String) = name.substringAfterLast('/').let { if ('.' in it.drop(1)) it.substringAfterLast('.').lowercase() else "" }
    fun isImage(name: String) = extension(name) in imageExtensions
    fun isVideo(name: String) = extension(name) == "mp4"
    fun isHtml(name: String) = extension(name) in setOf("html", "htm")
    fun isMarkdown(name: String) = extension(name) in setOf("md", "markdown")

    /** A two- or three-letter tag on a tinted tile, coloured by language family. */
    fun kind(name: String): Kind = when (val ext = extension(name)) {
        "swift" -> Kind("sw", 0xFFE8A07A.toInt())
        "kt", "kts", "java" -> Kind(if (ext == "java") "jv" else "kt", 0xFFB7A2EE.toInt())
        "md", "markdown", "txt", "rst" -> Kind(if (ext == "txt") "txt" else "md", 0xFFD6DDE0.toInt())
        "json", "yml", "yaml", "toml", "plist", "xml", "gradle", "properties", "resolved", "lock" -> Kind("{}", 0xFF86B4EE.toInt())
        "js", "jsx", "ts", "tsx", "mjs", "cjs" -> Kind(if (ext.startsWith("t")) "ts" else "js", 0xFFE8D27A.toInt())
        "py", "rb", "go", "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm", "sh", "zsh", "bash", "php", "lua", "sql" -> Kind(ext.take(2), 0xFF72D4B9.toInt())
        "html", "htm", "css", "scss", "svg" -> Kind(ext.take(3), 0xFFE8837C.toInt())
        in imageExtensions -> Kind("img", 0xFF86B4EE.toInt())
        "" -> Kind("·", 0xFF7F8C92.toInt())
        else -> Kind(ext.take(3), 0xFF7F8C92.toInt())
    }

    fun size(bytes: Long): String = when {
        bytes < 1024 -> "$bytes B"
        bytes < 10 * 1024 -> String.format(java.util.Locale.US, "%.1f KB", bytes / 1024.0)
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        else -> String.format(java.util.Locale.US, "%.1f MB", bytes / 1024.0 / 1024.0)
    }

    /** Unified diff text as numbered rows; file headers become nothing, hunk headers stay as separators. */
    fun diff(text: String): List<DiffLine> {
        val rows = mutableListOf<DiffLine>()
        var old = 0; var new = 0; var inHunk = false
        val header = Regex("^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@(.*)$")
        for (line in text.split('\n')) {
            val match = header.find(line)
            when {
                match != null -> {
                    old = match.groupValues[1].toInt(); new = match.groupValues[2].toInt(); inHunk = true
                    rows.add(DiffLine(Row.HUNK, null, null, line))
                }
                !inHunk -> if (line.startsWith("Binary files")) rows.add(DiffLine(Row.NOTE, null, null, line))
                line.startsWith("+") -> rows.add(DiffLine(Row.ADD, null, new++, line.substring(1)))
                line.startsWith("-") -> rows.add(DiffLine(Row.DEL, old++, null, line.substring(1)))
                line.startsWith("\\") -> rows.add(DiffLine(Row.NOTE, null, null, line.removePrefix("\\ ")))
                line.startsWith("diff --git") -> inHunk = false
                else -> rows.add(DiffLine(Row.CONTEXT, old++, new++, line.removePrefix(" ")))
            }
        }
        while (rows.lastOrNull()?.let { it.kind == Row.CONTEXT && it.text.isEmpty() } == true) rows.removeAt(rows.lastIndex)
        return rows
    }

    private val keywords = setOf(
        "func", "let", "var", "if", "else", "guard", "return", "for", "while", "in", "switch", "case", "default", "break", "continue",
        "class", "struct", "enum", "protocol", "extension", "import", "private", "public", "internal", "fileprivate", "static", "final",
        "override", "init", "deinit", "self", "super", "throws", "throw", "try", "catch", "do", "async", "await", "defer", "where",
        "fun", "val", "object", "interface", "when", "is", "as", "null", "true", "false", "nil", "package", "data", "sealed", "open",
        "lateinit", "companion", "const", "suspend", "def", "lambda", "from", "with", "pass", "None", "True", "False", "elif", "not",
        "and", "or", "function", "new", "this", "export", "type", "typeof", "void", "yield", "fn", "impl", "pub",
        "use", "mod", "match", "mut", "go", "chan", "select", "range", "protected", "abstract", "implements", "extends")
    private val token = Regex("""(//.*|#(?!include|import|if|endif|define|available|selector|warning|error).*$|/\*.*?(?:\*/|$)|"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?|`[^`]*`?|\b\d[\d_.xXa-fA-F]*\b|\b[A-Za-z_][A-Za-z0-9_]*\b)""")
    private val hashComments = setOf("py", "rb", "sh", "zsh", "bash", "yml", "yaml", "toml", "properties", "pl", "r", "conf", "gitignore", "")
    private val plain = setOf("md", "markdown", "txt", "rst", "csv", "log")

    /** Per-line colouring: comments, strings, numbers, keywords and capitalised type names. No state across lines. */
    fun highlight(line: String, extension: String): List<Token> {
        if (extension in plain || line.length > 2000) return emptyList()
        val tokens = mutableListOf<Token>()
        for (match in token.findAll(line)) {
            val text = match.value; val start = match.range.first; val end = match.range.last + 1
            val tone = when {
                text.startsWith("//") || text.startsWith("/*") -> Tone.COMMENT
                text.startsWith("#") -> if (extension in hashComments) Tone.COMMENT else null
                text[0] == '"' || text[0] == '\'' || text[0] == '`' -> Tone.STRING
                text[0].isDigit() -> Tone.NUMBER
                text in keywords -> Tone.KEYWORD
                text[0].isUpperCase() && text.length > 1 -> Tone.TYPE
                else -> null
            } ?: continue
            tokens.add(Token(start, end, tone))
            if (tone == Tone.COMMENT && !text.startsWith("/*")) break
        }
        return tokens
    }

    /** Recently opened paths for one workspace, newest first, at most `limit`; one per line (paths never hold newlines). */
    fun remember(saved: String?, path: String, limit: Int = 20): String =
        (listOf(path) + parse(saved).filter { it != path }).take(limit).joinToString("\n")
    fun parse(saved: String?): List<String> = saved.orEmpty().split('\n').filter(String::isNotBlank)

    /** "path:line" as the reply composer receives it, surrounded by spaces only where the draft needs one. */
    fun quote(draft: String, cursor: Int, path: String, line: Int?): Pair<String, Int> {
        val at = cursor.coerceIn(0, draft.length)
        val reference = "`" + path + (line?.let { ":$it" } ?: "") + "`"
        val before = if (at > 0 && !draft[at - 1].isWhitespace()) " " else ""
        val after = if (at < draft.length && draft[at].isWhitespace()) "" else " "
        val text = draft.substring(0, at) + before + reference + after + draft.substring(at)
        return text to at + before.length + reference.length + after.length
    }
}
