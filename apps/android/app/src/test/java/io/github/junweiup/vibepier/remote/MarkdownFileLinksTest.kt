package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.markdown.MarkdownFileLinks

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownFileLinksTest {
    @Test fun extractsVideoLinksAndEmbedsWithoutGrantingCodeOrNetworkPaths() {
        val text = "[成片](<videos/My Movie.MP4>) ![视频](/demo/movie.mp4) " +
            "![图片](image.png) `[示例](hidden.mp4)` [外链](https://example.com/video.mp4)"
        assertEquals(listOf("videos/My Movie.MP4", "/demo/movie.mp4"), MarkdownFileLinks.find(text, anyFile = true).map { it.path })
        assertTrue(MarkdownFileLinks.find(text).isEmpty())
        assertTrue(io.github.junweiup.vibepier.remote.features.files.ProjectFiles.isVideo("demo.MP4"))
    }
    @Test fun acceptsRelativeAndAbsoluteMarkdownFiles() {
        assertEquals(MarkdownFileLinks.Link("设计", "docs/app-usage-design.md"),
            MarkdownFileLinks.parseTarget("docs/app-usage-design.md", "设计"))
        assertEquals(MarkdownFileLinks.Link("说明", "/Users/demo/Documents/code/vibepier/README.md"),
            MarkdownFileLinks.parseTarget("/Users/demo/Documents/code/vibepier/README.md", "说明"))
        assertEquals("docs/NOTES.MD", MarkdownFileLinks.parseTarget("docs/NOTES.MD")?.path)
        assertEquals("docs/notes.markdown", MarkdownFileLinks.parseTarget("docs/notes.markdown")?.path)
    }

    @Test fun separatesLineNumbersWithoutChangingFilePath() {
        val path = "/Users/demo/Documents/code/vibepier/docs/app-usage-design.md"
        assertEquals(MarkdownFileLinks.Link("设计第12行", path, 12),
            MarkdownFileLinks.parseTarget("$path:12", "设计第12行"))
        assertEquals(1, MarkdownFileLinks.parseTarget("README.md:1")?.line)
        assertEquals(MarkdownFileLinks.Link("README.md", "README.md", 12), MarkdownFileLinks.parseTarget("README.md#L12"))
        assertNull(MarkdownFileLinks.parseTarget("README.md:0"))
        assertNull(MarkdownFileLinks.parseTarget("README.md:-1"))
        // A too-large hint must not overflow; the valid document can still be opened.
        assertNull(MarkdownFileLinks.parseTarget("README.md:999999999999999999999")?.line)
    }

    @Test fun preservesSpacesUnicodeAndPlusSigns() {
        assertEquals("/Users/demo/My Project/说明.md", MarkdownFileLinks.parseTarget("</Users/demo/My Project/说明.md>")?.path)
        assertEquals("docs/My Report.md", MarkdownFileLinks.parseTarget("<docs/My Report.md>")?.path)
        assertEquals("docs/C++ Notes.md", MarkdownFileLinks.parseTarget("<docs/C++ Notes.md>")?.path)
        assertEquals("docs/My Report+C++.md", MarkdownFileLinks.parseTarget("docs/My%20Report+C%2B%2B.md")?.path)
    }

    @Test fun rejectsExternalLinksAndNonMarkdownTargets() {
        for (target in listOf("https://example.com/README.md", "http://example.com/doc.md", "file:///Users/demo/README.md",
            "javascript:README.md", "mailto:README.md", "README.txt", "screenshots/design.png", "", "#section")) {
            assertNull("Unexpected local file target: $target", MarkdownFileLinks.parseTarget(target))
        }
        assertNull(MarkdownFileLinks.parseTarget("https%3A%2F%2Fexample.com%2FREADME.md"))
        assertNull(MarkdownFileLinks.parseTarget("docs/README%00.md"))
    }

    @Test fun extractsRealFileLinksWhileSkippingImagesAndCodeExamples() {
        val raw = """
            查看 [产品说明](docs/PROJECT-SPEC.md) 与 [含空格的文件](</Users/demo/My Project/说明.md:8>)。
            ![示意图](docs/image.md)
            [外链](https://example.com/README.md) [普通文件](notes.txt)
            `[行内示例](example.md)`
            ```markdown
            [代码示例](example.md)
            ```
            [另一个文件](README.md)
        """.trimIndent()
        val links = MarkdownFileLinks.find(raw)
        assertEquals(listOf("docs/PROJECT-SPEC.md", "/Users/demo/My Project/说明.md", "README.md"), links.map { it.path })
        assertEquals(listOf("产品说明", "含空格的文件", "另一个文件"), links.map { it.label })
        assertEquals(8, links[1].line)
    }

    @Test fun resolvesNestedLinksAgainstCurrentDocumentDirectory() {
        val document = "/Users/demo/Documents/code/vibepier/docs/design.md"
        assertEquals(MarkdownFileLinks.Link("规格", "/Users/demo/Documents/code/vibepier/docs/PROJECT-SPEC.md", 5),
            MarkdownFileLinks.resolve(MarkdownFileLinks.Link("规格", "PROJECT-SPEC.md", 5), document))
        val absolute = MarkdownFileLinks.Link("说明", "/Users/demo/Other Project/README.md", 3)
        assertEquals(absolute, MarkdownFileLinks.resolve(absolute, document))
    }

    @Test fun ignoresEscapedLinkSyntaxAndUnclosedCodeFence() {
        assertTrue(MarkdownFileLinks.find("\\[字面链接](README.md)").isEmpty())
        assertTrue(MarkdownFileLinks.find("~~~markdown\n[示例](README.md)").isEmpty())
    }
}
