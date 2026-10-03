package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.markdown.InlineMarkup
import io.github.junweiup.vibepier.remote.features.markdown.MarkdownBlocks

import org.junit.Assert.*
import org.junit.Test

class MarkdownBlocksTest {
    @Test fun quotedParagraphIsSeparateFromAnswerAndCodeStaysLiteral() {
        val blocks = MarkdownBlocks.parse("> 原问题\n> 第二行\n\n回答\n\n```swift\n  > literal\n\n    indent\n```")
        assertEquals(listOf(MarkdownBlocks.Kind.QUOTE, MarkdownBlocks.Kind.PARAGRAPH, MarkdownBlocks.Kind.CODE), blocks.map { it.kind })
        assertEquals("原问题\n第二行", blocks[0].text)
        assertEquals("  > literal\n\n    indent", blocks[2].text)
    }
    @Test fun streamedUnclosedFenceKeepsContent() {
        val blocks = MarkdownBlocks.parse("正文\n\n```sh\n  echo hello\n")
        assertEquals("  echo hello\n", blocks.last().text)
        assertEquals("sh", blocks.last().detail)
    }
    @Test fun listNumbersHeadingsAndContinuationAreNotLost() {
        val blocks = MarkdownBlocks.parse("## 标题\n\n1. 第一步\n   继续说明\n2. 第二步\n\n---\n结论")
        assertEquals(2, blocks[0].level)
        assertEquals("1.", blocks[1].detail)
        assertEquals("第一步\n继续说明", blocks[1].text)
        assertEquals("2.", blocks[2].detail)
        assertEquals(MarkdownBlocks.Kind.DIVIDER, blocks[3].kind)
    }
    @Test fun headingKeepsProgrammingLanguageHashButRemovesSpacedClosingMarker() {
        assertEquals("C#", MarkdownBlocks.parse("# C#").single().text)
        assertEquals("标题", MarkdownBlocks.parse("## 标题 ##").single().text)
        assertEquals("C##", MarkdownBlocks.parse("### C##").single().text)
    }
    @Test fun inlineCodeIdentifiersEscapesAndNestedStylesKeepMeaning() {
        val identifier = "some__name__value"
        assertEquals(identifier, InlineMarkup.parse(identifier).joinToString("") { it.text })
        assertTrue(InlineMarkup.parse(identifier).none { it.bold || it.italic })
        val escaped = "\\*literal\\*"
        assertEquals(escaped, InlineMarkup.parse(escaped).joinToString("") { it.text })
        assertTrue(InlineMarkup.parse(escaped).none { it.italic })
        assertEquals("**literal**", InlineMarkup.parse("`**literal**`").single().text)
        val nested = InlineMarkup.parse("**重点与 `code`**")
        assertEquals("重点与 code", nested.joinToString("") { it.text })
        assertTrue(nested.last().code && nested.last().bold)
    }
    @Test fun ordinaryQuotationAndUnsupportedSyntaxStayText() {
        val text = "他说‘这是引用’。\n[label](https://example.com)"
        assertEquals(text, MarkdownBlocks.parse(text).single().text)
    }
    @Test fun documentTableKeepsHeaderAlignmentAndFollowingParagraph() {
        val blocks = MarkdownBlocks.parse("说明\n应用 | 用时 | 占比\n:--- | :---: | ---:\n编辑器 | 30 分钟 | 25%\n浏览器 | 90 分钟 | 75%\n\n表格之后")
        assertEquals(listOf(MarkdownBlocks.Kind.PARAGRAPH, MarkdownBlocks.Kind.TABLE, MarkdownBlocks.Kind.PARAGRAPH), blocks.map { it.kind })
        assertEquals(listOf("应用", "用时", "占比"), blocks[1].cells[0])
        assertEquals(listOf("浏览器", "90 分钟", "75%"), blocks[1].cells[2])
        assertEquals(listOf(MarkdownBlocks.ColumnAlignment.LEFT, MarkdownBlocks.ColumnAlignment.CENTER, MarkdownBlocks.ColumnAlignment.RIGHT), blocks[1].alignments)
        assertEquals("表格之后", blocks[2].text)
    }
    @Test fun escapedAndInlineCodePipesStayInsideTableCell() {
        val table = MarkdownBlocks.parse("| 表达式 | 说明 |\n| --- | --- |\n| `left | right` | one \\| two |\n| ``a ` | b`` | 最后一列 |").single()
        assertEquals(listOf("`left | right`", "one | two"), table.cells[1])
        assertEquals(listOf("``a ` | b``", "最后一列"), table.cells[2])
    }
    @Test fun unevenTableRowsKeepColumnCountAndUnfinishedTicksDoNotEatCells() {
        val table = MarkdownBlocks.parse("| 一 | 二 | 三 |\n| - | - | - |\n| 少一列 | 内容 |\n| 多一列 | 内容 | 保留 | 忽略 |\n| `未结束 | 下一列 | |").single()
        assertEquals(listOf("少一列", "内容", ""), table.cells[1])
        assertEquals(listOf("多一列", "内容", "保留"), table.cells[2])
        assertEquals(listOf("`未结束", "下一列", ""), table.cells[3])
    }
    @Test fun invalidDelimiterAndIndentedTableRemainText() {
        val malformed = "| 一 | 二 |\n| --- | 错误 |\n| 内容 | 内容 |"
        assertEquals(MarkdownBlocks.Kind.PARAGRAPH, MarkdownBlocks.parse(malformed).single().kind)
        assertEquals(malformed, MarkdownBlocks.parse(malformed).single().text)
        val mismatched = "| 一 | 二 |\n| --- |\n| 内容 | 内容 |"
        assertEquals(mismatched, MarkdownBlocks.parse(mismatched).single().text)
        val indented = "    | 一 | 二 |\n    | --- | --- |\n    | 内容 | 内容 |"
        assertTrue(MarkdownBlocks.parse(indented).none { it.kind == MarkdownBlocks.Kind.TABLE })
    }
    @Test fun tablesAndTasksInsideFencedCodeStayLiteral() {
        val code = "| 一 | 二 |\n| --- | --- |\n| 内容 | 内容 |\n- [x] literal"
        for (fence in listOf("```md", "~~~md")) {
            val block = MarkdownBlocks.parse("$fence\n$code\n${fence.take(3)}").single()
            assertEquals(MarkdownBlocks.Kind.CODE, block.kind)
            assertEquals(code, block.text)
            assertTrue(block.cells.isEmpty())
            assertNull(block.taskChecked)
        }
    }
    @Test fun readOnlyTaskListsKeepStatusAndContinuation() {
        val blocks = MarkdownBlocks.parse("- [ ] 待办\n  继续说明\n- [x] 已完成\n1. [X] 有序完成\n- [x]无空格的原文\n- 普通条目")
        assertEquals(listOf(false, true, true, null, null), blocks.map { it.taskChecked })
        assertEquals("待办\n继续说明", blocks[0].text)
        assertEquals("已完成", blocks[1].text)
        assertEquals("有序完成", blocks[2].text)
        assertEquals("[x]无空格的原文", blocks[3].text)
        assertEquals("•", blocks[4].detail)
    }
}
