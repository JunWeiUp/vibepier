package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.ReplyPartGrouping

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplyPartGroupingTest {
    private fun js(index: Int, title: String = "cua_repl · js", toolName: String = title) = ReplyPartGrouping.Entry("js-$index", index, "tool", title, toolName)

    @Test fun adjacentSameToolRowsFoldAndEveryDifferentEntryKeepsItsBoundary() {
        val entries = listOf(js(0), js(1), ReplyPartGrouping.Entry("text", 2, "text"), js(3), js(4, "functions · exec"), js(5),
            ReplyPartGrouping.Entry("command", 6, "command"), js(7), ReplyPartGrouping.Entry("file", 8, "file"), js(9), ReplyPartGrouping.Entry("thinking", 10, "thinking"), js(11))
        assertEquals(listOf(listOf(0, 1), listOf(2), listOf(3), listOf(4), listOf(5), listOf(6), listOf(7), listOf(8), listOf(9), listOf(10), listOf(11)), ReplyPartGrouping.runs(entries))
        assertEquals(ReplyPartGrouping.Summary("calls", 2, "cua_repl · js"), ReplyPartGrouping.summary(entries.take(2)))
    }

    @Test fun explicitToolIdentitySurvivesChangingActionTitlesButDifferentToolsStaySeparate() {
        val entries = listOf(js(0, "打开窗口", "cua_repl.js"), js(1, "截图", "cua_repl.js"), js(2, "截图", "another.js"))
        assertEquals(listOf(listOf(0, 1), listOf(2)), ReplyPartGrouping.runs(entries))
        assertEquals(ReplyPartGrouping.Summary("calls", 2, "cua_repl.js"), ReplyPartGrouping.summary(entries.take(2)))
    }

    @Test fun missingIndicesOrToolMetadataNeverMergeByDisplayTitle() {
        assertEquals(listOf(listOf(0), listOf(1)), ReplyPartGrouping.runs(listOf(js(1), js(3))))
        for (title in listOf("", "x".repeat(400), "未知工具前缀…", "读取 a…", "Read", "cua_repl · js")) {
            assertEquals(listOf(listOf(0), listOf(1)), ReplyPartGrouping.runs(listOf(js(0, title, ""), js(1, title, ""))))
        }
    }

    @Test fun defaultFoldAndExplicitChoiceSurviveAppendPrependAndOpenBodies() {
        val original = listOf(js(4), js(5)); val flags = linkedMapOf<String, Boolean>()
        assertFalse(ReplyPartGrouping.expanded(original, flags, emptySet()))
        ReplyPartGrouping.remember(original, flags, true)
        val prepended = listOf(js(2), js(3)) + original
        assertTrue(ReplyPartGrouping.expanded(prepended, flags, emptySet()))
        ReplyPartGrouping.remember(prepended, flags, false)
        val enlarged = listOf(js(0), js(1)) + prepended + js(6)
        assertFalse(ReplyPartGrouping.expanded(enlarged, flags, setOf("js-4")))
        ReplyPartGrouping.remember(enlarged, flags, true)
        assertTrue(ReplyPartGrouping.expanded(enlarged + js(7), flags, emptySet()))
    }

    @Test fun jsKindAndToolKindCanShareTheSameStableToolIdentity() {
        assertEquals(listOf(listOf(0, 1)), ReplyPartGrouping.runs(listOf(js(0), ReplyPartGrouping.Entry("js-1", 1, "js", "cua_repl · js", "cua_repl · js"))))
    }

    @Test fun semanticOperationsMergeParameterChangesAndKeepOtherClassesSeparate() {
        val types = listOf("file-read", "file-search", "web-search", "web-fetch", "agent", "image-view", "image-generation", "attachment")
        val entries = types.flatMapIndexed { index, type ->
            (0..1).map { part -> ReplyPartGrouping.Entry("$type-$part", index * 2 + part, "tool", "参数-$part", "operator-$part", type) }
        }
        assertEquals(types.indices.map { listOf(it * 2, it * 2 + 1) }, ReplyPartGrouping.runs(entries))
        assertEquals(ReplyPartGrouping.Summary("file-read", 2), ReplyPartGrouping.summary(entries.take(2)))
    }

    @Test fun nativeTypeOverridesNamesAndMcpNeverImpersonatesABuiltin() {
        val entries = listOf(
            ReplyPartGrouping.Entry("grep", 0, "tool", "搜索 a", "Grep", "file-search"),
            ReplyPartGrouping.Entry("glob", 1, "tool", "查找 *.kt", "Glob", "file-search"),
            ReplyPartGrouping.Entry("mcp-1", 2, "tool", "读取 a", "Read", "tool:server.Read"),
            ReplyPartGrouping.Entry("mcp-2", 3, "tool", "读取 b", "Read", "tool:server.Read"),
            ReplyPartGrouping.Entry("mcp-3", 4, "tool", "读取 c", "Read", "tool:another.Read"),
        )
        assertEquals(listOf(listOf(0, 1), listOf(2, 3), listOf(4)), ReplyPartGrouping.runs(entries))
    }

    @Test fun oldGeneratedTitlesDoNotSupplyMissingSemanticIdentity() {
        val titles = listOf("读取 a", "读取 b", "搜索 a · src", "查找 *.kt", "搜索网页 a", "搜索网页 b", "访问 https://a", "访问 https://b", "子任务 · a", "子代理 · b")
        assertEquals(titles.indices.map { listOf(it) }, ReplyPartGrouping.runs(titles.mapIndexed { index, title -> js(index, title, "") }))
        assertEquals(listOf(listOf(0, 1)), ReplyPartGrouping.runs(listOf(js(0, "读取 a", "Read"), js(1, "读取 b", "Read"))))
        assertEquals(listOf(listOf(0), listOf(1)), ReplyPartGrouping.runs(listOf(js(0, "读取 a", "server.Read"), js(1, "读取 b", "another.Read"))))
    }

    @Test fun thinkingAndTypedNoticesGroupButFailuresAndDifferentNoticeTypesAreBoundaries() {
        val entries = listOf(
            ReplyPartGrouping.Entry("thought-1", 0, "thinking", "第一段"), ReplyPartGrouping.Entry("thought-2", 1, "thinking", "第二段"),
            ReplyPartGrouping.Entry("compact-1", 2, "notice", "压缩 a", groupType = "notice:compaction"), ReplyPartGrouping.Entry("compact-2", 3, "notice", "压缩 b", groupType = "notice:compaction"),
            ReplyPartGrouping.Entry("model", 4, "notice", "模型切换", groupType = "notice:model_change"),
            ReplyPartGrouping.Entry("failed", 5, "notice", "压缩失败", groupType = "notice:compaction", status = "failed"),
            ReplyPartGrouping.Entry("declined", 6, "notice", "未执行", groupType = "notice:compaction", status = "declined"),
            ReplyPartGrouping.Entry("compact-3", 7, "notice", "压缩 c", groupType = "notice:compaction"),
        )
        assertEquals(listOf(listOf(0, 1), listOf(2, 3), listOf(4), listOf(5), listOf(6), listOf(7)), ReplyPartGrouping.runs(entries))
        assertEquals(ReplyPartGrouping.Summary("thinking", 2), ReplyPartGrouping.summary(entries.take(2)))
        assertEquals(ReplyPartGrouping.Summary("notice", 2), ReplyPartGrouping.summary(entries.subList(2, 4)))
        assertEquals(listOf(listOf(0), listOf(1)), ReplyPartGrouping.runs(listOf(
            ReplyPartGrouping.Entry("a", 0, "notice", "模型切换"), ReplyPartGrouping.Entry("b", 1, "notice", "上下文已压缩"))))
    }

    @Test fun prosePlansAndApprovalBoundariesCannotBeOverriddenByToolMetadata() {
        for (type in listOf("text", "plan", "approval")) {
            val entries = listOf(js(0), ReplyPartGrouping.Entry(type, 1, type, "cua_repl · js", "cua_repl.js", "tool:cua_repl.js"), js(2))
            assertEquals(listOf(listOf(0), listOf(1), listOf(2)), ReplyPartGrouping.runs(entries))
            assertEquals(null, ReplyPartGrouping.Entry(type, 0, "tool", "Read", "Read", type).identity)
        }
        for (tool in listOf("AskUserQuestion", "request_user_input", "ExitPlanMode", "EnterPlanMode", "TodoRead", "TodoWrite")) {
            assertEquals(null, ReplyPartGrouping.Entry(tool, 0, "tool", tool).identity)
            assertEquals(null, ReplyPartGrouping.Entry(tool, 0, "tool", "有参数的标题", tool).identity)
        }
    }

    @Test fun allNewCategoriesPreserveMissingPageBoundaryAndCachedExplicitChoices() {
        for (type in listOf("file-read", "file-search", "web-search", "web-fetch", "agent", "image-view", "image-generation", "attachment", "thinking", "notice:compaction")) {
            fun entry(index: Int) = ReplyPartGrouping.Entry("$type-$index", index, if (type.startsWith("notice:")) "notice" else if (type == "thinking") "thinking" else "tool", "标题-$index", groupType = type)
            assertEquals(listOf(listOf(0), listOf(1)), ReplyPartGrouping.runs(listOf(entry(0), entry(2))))
            val flags = linkedMapOf<String, Boolean>(); val original = listOf(entry(4), entry(5))
            assertFalse(ReplyPartGrouping.expanded(original, flags, emptySet()))
            ReplyPartGrouping.remember(original, flags, true)
            val enlarged = listOf(entry(3)) + original + entry(6)
            assertTrue(ReplyPartGrouping.expanded(enlarged, flags, emptySet()))
            ReplyPartGrouping.remember(enlarged, flags, false)
            assertFalse(ReplyPartGrouping.expanded(listOf(entry(2)) + enlarged, flags, setOf("$type-4")))
        }
    }

    @Test fun runningDoesNotHideFailedOrInterruptedMembers() {
        val entries = listOf("running", "failed", "failed", "declined").mapIndexed { index, status -> js(index).copy(status = status) }
        assertEquals(listOf("running" to 1, "failed" to 2, "declined" to 1), ReplyPartGrouping.statusCounts(entries))
        assertEquals(listOf("completed" to 4), ReplyPartGrouping.statusCounts(entries.map { it.copy(status = "completed") }))
    }
}
