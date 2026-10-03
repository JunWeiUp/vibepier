package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.files.ProjectFiles
import io.github.junweiup.vibepier.remote.features.markdown.MarkdownFileLinks

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectFilesTest {
    @Test fun diffNumbersOldAndNewLinesAcrossHunks() {
        val rows = ProjectFiles.diff("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -5,3 +5,4 @@ class A\n keep\n-old\n+new\n+more\n@@ -20,1 +21,1 @@\n-x\n+y\n\\ No newline at end of file\n")
        assertEquals(ProjectFiles.Row.HUNK, rows[0].kind)
        assertEquals(listOf(5, 6), rows.filter { it.kind != ProjectFiles.Row.HUNK }.take(2).map { it.old })
        assertEquals(listOf(6, 7), rows.filter { it.kind == ProjectFiles.Row.ADD }.take(2).map { it.new })
        assertEquals(21, rows.first { it.text == "y" }.new)
        assertEquals(ProjectFiles.Row.NOTE, rows.last().kind)
        assertTrue(ProjectFiles.diff("Binary files a/x and b/x differ").single().kind == ProjectFiles.Row.NOTE)
    }

    @Test fun highlightFindsStringsCommentsKeywordsAndStopsAtLineComments() {
        val tokens = ProjectFiles.highlight("let name = \"a // b\" // note", "swift")
        assertEquals(listOf(ProjectFiles.Tone.KEYWORD, ProjectFiles.Tone.STRING, ProjectFiles.Tone.COMMENT), tokens.map { it.tone })
        assertEquals(11, tokens[1].start)
        assertEquals(ProjectFiles.Tone.COMMENT, ProjectFiles.highlight("# heading", "py").single().tone)
        assertTrue(ProjectFiles.highlight("#if DEBUG", "swift").none { it.tone == ProjectFiles.Tone.COMMENT })
        assertTrue(ProjectFiles.highlight("plain words here", "md").isEmpty())
    }

    @Test fun htmlExtensionsAreCaseInsensitiveAndSpecific() {
        assertTrue(ProjectFiles.isHtml("report.HTML")); assertTrue(ProjectFiles.isHtml("page.htm"))
        assertFalse(ProjectFiles.isHtml("page.html.txt")); assertFalse(ProjectFiles.isHtml("html"))
    }

    @Test fun kindsSizesAndImages() {
        assertEquals("sw", ProjectFiles.kind("Sources/A.swift").tag)
        assertEquals("{}", ProjectFiles.kind("Package.resolved").tag)
        assertEquals("·", ProjectFiles.kind("Makefile").tag)
        assertEquals("", ProjectFiles.extension(".gitignore"))
        assertTrue(ProjectFiles.isImage("a/B.PNG")); assertFalse(ProjectFiles.isImage("png"))
        assertEquals("512 B", ProjectFiles.size(512)); assertEquals("9.8 KB", ProjectFiles.size(10035)); assertEquals("21 KB", ProjectFiles.size(21504))
        assertEquals("3.2 MB", ProjectFiles.size(3_400_000))
    }

    @Test fun recentKeepsNewestFirstWithoutDuplicates() {
        var saved: String? = null
        listOf("a", "b", "a", "c").forEach { saved = ProjectFiles.remember(saved, it, limit = 2) }
        assertEquals(listOf("c", "a"), ProjectFiles.parse(saved))
        assertEquals(emptyList<String>(), ProjectFiles.parse(null))
    }

    @Test fun quoteInsertsAtTheCursorWithSpacing() {
        assertEquals("看下 `a/B.kt:3` " to 14, ProjectFiles.quote("看下", 2, "a/B.kt", 3))
        assertEquals("x `p` y" to 5, ProjectFiles.quote("x y", 1, "p", null))
        assertEquals("`p` " to 4, ProjectFiles.quote("", 0, "p", null))
    }

    @Test fun anyFileLinksAcceptCodePathsButNotWordsAnchorsOrUrls() {
        assertEquals(42, MarkdownFileLinks.parseTarget("Sources/A.swift:42", anyFile = true)?.line)
        assertEquals("Makefile", MarkdownFileLinks.parseTarget("tools/Makefile", anyFile = true)?.label)
        assertNull(MarkdownFileLinks.parseTarget("Sources/A.swift"))
        assertNull(MarkdownFileLinks.parseTarget("#section", anyFile = true))
        assertNull(MarkdownFileLinks.parseTarget("https://x.dev/a.js", anyFile = true))
        assertNull(MarkdownFileLinks.parseTarget("word", anyFile = true))
        assertEquals(1, MarkdownFileLinks.find("见 [A.kt](a/A.kt) 和 [站点](https://x.dev)", anyFile = true).size)
    }
}
