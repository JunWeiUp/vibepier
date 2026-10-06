package io.github.junweiup.vibepier.remote.core.session

/** Ordered runs only: a paragraph, another tool, or a missing index always starts a new run. */
internal object ReplyPartGrouping {
    data class Entry(
        val id: String, val index: Int, val kind: String, val title: String = "", val toolName: String = "",
        val groupType: String = "", val status: String = "",
    ) {
        val family get() = if (kind == "js") "tool" else kind
        val anchor get() = "$family:$id"
        val identity: String? get() {
            val type = groupType.trim(); val name = toolName.trim(); val shortTitle = title.trim().takeIf { it.isNotEmpty() && it.length < 400 }
            if (family in boundaries || type in boundaries) return null
            if (family == "tool" && (name in standaloneTools || shortTitle in standaloneTools)) return null
            return when (family) {
                "command" -> "command"
                "file" -> "file-edit"
                "thinking" -> "thinking"
                "notice" -> if (status in setOf("failed", "declined")) null
                    else type.takeIf { it.startsWith("notice:") && it.length > 7 } ?: shortTitle?.takeUnless(::abbreviated)?.let { "notice:$it" }
                "tool" -> when {
                    type in semanticTypes -> type
                    type.startsWith("tool:") && type.length > 5 -> type
                    name.isNotEmpty() -> builtinTypes[name] ?: "tool:$name"
                    else -> null
                }
                else -> null
            }
        }
    }

    private val boundaries = setOf("text", "plan", "approval")
    private val standaloneTools = setOf("AskUserQuestion", "request_user_input", "ExitPlanMode", "EnterPlanMode", "TodoRead", "TodoWrite")
    private val semanticTypes = setOf("command", "file-edit", "file-read", "file-search", "web-search", "web-fetch", "agent", "image-view", "image-generation", "attachment", "thinking")
    // Only exact builtin names: a namespaced MCP tool called Read still keeps its own tool identity.
    private val builtinTypes = mapOf("Read" to "file-read", "NotebookRead" to "file-read", "Grep" to "file-search", "Glob" to "file-search",
        "WebSearch" to "web-search", "webSearch" to "web-search", "WebFetch" to "web-fetch", "Task" to "agent", "Agent" to "agent",
        "imageView" to "image-view", "imageGeneration" to "image-generation")
    private fun abbreviated(title: String) = title.endsWith("…") || title.endsWith("...")
    fun runs(entries: List<Entry>): List<List<Int>> {
        val result = mutableListOf<MutableList<Int>>()
        for (index in entries.indices) {
            val row = entries[index]
            val previous = result.lastOrNull()?.lastOrNull()?.let { entries[it] }
            if (previous != null && row.identity != null && row.identity == previous.identity && previous.index + 1 == row.index) result.last().add(index)
            else result.add(mutableListOf(index))
        }
        return result
    }

    data class Summary(val kind: String, val count: Int, val name: String = "")
    fun summary(entries: List<Entry>): Summary {
        val first = entries.first()
        val identity = first.identity
        if (identity in semanticTypes) return Summary(identity!!, entries.size)
        if (first.family == "notice") return Summary("notice", entries.size)
        val name = if (first.title.isNotBlank() && entries.all { it.title == first.title }) first.title else first.toolName.ifBlank { first.title }
        return Summary("calls", entries.size, name)
    }

    /** Keep errors visible even when another member is still running. */
    fun statusCounts(entries: List<Entry>): List<Pair<String, Int>> = buildList {
        for (status in listOf("running", "failed", "declined")) {
            entries.count { it.status == status }.takeIf { it > 0 }?.let { add(status to it) }
        }
        if (isEmpty() && entries.all { it.status == "completed" }) add("completed" to entries.size)
    }

    fun expanded(entries: List<Entry>, flags: Map<String, Boolean>, expandedBodies: Set<String>): Boolean {
        val known = entries.mapNotNull { flags[it.anchor] }
        return if (known.isNotEmpty()) known.any { it } else entries.any { it.id in expandedBodies }
    }

    /** Keep every existing member as an anchor when an earlier page prepends the run's new first entry. */
    fun remember(entries: List<Entry>, flags: MutableMap<String, Boolean>, expanded: Boolean) {
        entries.forEach { flags[it.anchor] = expanded }
    }
}
