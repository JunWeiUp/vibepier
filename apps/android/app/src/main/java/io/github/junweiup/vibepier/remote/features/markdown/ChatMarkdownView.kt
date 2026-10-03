package io.github.junweiup.vibepier.remote.features.markdown

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.features.remote.Palette

import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import android.view.View
import android.view.Gravity
import android.widget.HorizontalScrollView
import android.widget.LinearLayout

/** Rich display text drawn entirely by CanvasLabel; no selectable TextViews or embedded web content. */
@android.annotation.SuppressLint("ViewConstructor") // Created in code with required model/callback arguments, never XML-inflated.
internal class ChatMarkdownView(context: Context, private val openMarkdown: ((MarkdownFileLinks.Link) -> Unit)? = null, private val anyFile: Boolean = false) : LinearLayout(context) {
    var renderedBlocks = 0; private set
    init { orientation = VERTICAL }
    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
    private fun fill(color: Int, radius: Int) = GradientDrawable().apply { setColor(color); cornerRadius = dp(radius).toFloat() }
    private fun label(text: CharSequence, size: Float = 15f, color: Int = Palette.text) = CanvasLabel(context).apply {
        this.text = text; textSize = size; setTextColor(color); lineSpacingExtra = 3f
    }
    fun render(raw: String, startBlock: Int = 0, maxBlocks: Int = Int.MAX_VALUE): Int {
        removeAllViews()
        val blocks = MarkdownBlocks.parse(raw)
        var cost = 0; renderedBlocks = 0
        blocks.drop(startBlock).take(maxBlocks).takeWhile { block ->
            val estimate = if (block.kind == MarkdownBlocks.Kind.TABLE) (minOf(block.cells.size, 31) * minOf(block.cells.firstOrNull()?.size ?: 1, 6) * 2 + 40) else 4
            if (renderedBlocks > 0 && cost + estimate > 480 && maxBlocks != Int.MAX_VALUE) false else { cost += estimate; renderedBlocks++; true }
        }.forEachIndexed { index, block ->
            val view: View = when (block.kind) {
                MarkdownBlocks.Kind.HEADING -> label(inline(block.text), if (block.level <= 2) 19f else 16f).apply { typeface = Typeface.DEFAULT_BOLD }
                MarkdownBlocks.Kind.PARAGRAPH -> label(inline(block.text))
                MarkdownBlocks.Kind.LIST -> LinearLayout(context).apply {
                    orientation = HORIZONTAL
                    addView(label(block.detail, if (block.taskChecked == null) 14f else 18f,
                        if (block.taskChecked == false) Palette.muted else Palette.green).apply {
                        if (block.taskChecked != null) contentDescription = if (block.taskChecked) context.getString(R.string.task_done) else context.getString(R.string.task_not_done)
                    }, LayoutParams(dp(if (block.taskChecked == null) 25 else 30), -2))
                    addView(label(inline(block.text)), LayoutParams(0, -2, 1f))
                }
                MarkdownBlocks.Kind.TABLE -> table(block)
                MarkdownBlocks.Kind.QUOTE -> LinearLayout(context).apply {
                    orientation = HORIZONTAL; background = fill(Palette.surface2, 10)
                    setPadding(0, dp(12), dp(14), dp(12))
                    addView(View(context).apply { background = fill(Palette.accent, 2); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }, LayoutParams(dp(3), -1))
                    addView(label(inline(block.text), 14f, Palette.muted), LayoutParams(0, -2, 1f).apply { marginStart = dp(12) })
                    contentDescription = context.getString(R.string.markdown_quote, block.text)
                }
                MarkdownBlocks.Kind.CODE -> LinearLayout(context).apply {
                    orientation = VERTICAL; background = Ui.roundRect(context, Palette.surface1, 10, Palette.outline); setPadding(dp(12), dp(10), dp(12), dp(12))
                    addView(label(block.detail.ifBlank { context.getString(R.string.code) }.take(24), 10f, Palette.muted), LayoutParams(-1, -2).apply { bottomMargin = dp(8) })
                    addView(label(block.text, 13f).apply { typeface = Typeface.MONOSPACE; lineSpacingExtra = 2f })
                }
                MarkdownBlocks.Kind.DIVIDER -> View(context).apply { setBackgroundColor(Palette.outline); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
            }
            addView(view, LayoutParams(-1, if (block.kind == MarkdownBlocks.Kind.DIVIDER) dp(1) else -2).apply { topMargin = if (index == 0) 0 else dp(if (block.kind == MarkdownBlocks.Kind.LIST) 5 else 12) })
            if (block.kind !in setOf(MarkdownBlocks.Kind.CODE, MarkdownBlocks.Kind.TABLE) && openMarkdown != null) {
                MarkdownFileLinks.find(block.text, anyFile).take(12).forEach { link ->
                    addView(Ui.button(context, context.getString(R.string.view_reference, link.label), Ui.Button.TEXT) { openMarkdown.invoke(link) }.apply {
                        gravity = Gravity.START or Gravity.CENTER_VERTICAL
                        typeface = Typeface.MONOSPACE
                        background = Ui.inset(context, Ui.roundRect(context, Palette.accentContainer, 8), 7)
                        contentDescription = link.line?.let { context.getString(R.string.document_line_description, link.label, link.path, it) } ?: context.getString(R.string.document_link_description, link.label, link.path)
                    }, LayoutParams(-1, -2).apply { topMargin = dp(4) })
                }
            }
        }
        return blocks.size
    }
    private fun table(block: MarkdownBlocks.Block): View {
        val columns = block.cells.firstOrNull()?.size ?: 1
        val available = (resources.displayMetrics.widthPixels - dp(64)).coerceAtLeast(dp(160))
        // Fixed column widths keep every cell aligned while allowing long text and headers to wrap.
        val columnWidth = (available / columns.coerceAtLeast(1)).coerceIn(dp(132), dp(220))
        val grid = LinearLayout(context).apply {
            orientation = VERTICAL; background = fill(Palette.surface1, 10); clipToOutline = true
        }
        var firstRow = 1
        var firstColumn = 0
        val controls = LinearLayout(context).apply { orientation = VERTICAL }
        fun renderRows() {
        grid.removeAllViews()
        controls.removeAllViews()
        val page = (listOf(block.cells.first()) + block.cells.drop(firstRow).take(30)).map { it.drop(firstColumn).take(6) }
        page.forEachIndexed { rowIndex, cells ->
            if (rowIndex > 0) grid.addView(View(context).apply {
                setBackgroundColor(Palette.outline); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LayoutParams(-1, dp(1)))
            val row = LinearLayout(context).apply {
                orientation = HORIZONTAL
                setBackgroundColor(if (rowIndex == 0) Palette.surface3 else if (rowIndex % 2 == 0) Palette.surface2 else Palette.surface1)
            }
            cells.forEachIndexed { columnIndex, source ->
                if (columnIndex > 0) row.addView(View(context).apply {
                    setBackgroundColor(Palette.outline); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }, LayoutParams(dp(1), -1))
                val content = source.replace(Regex("<br\\s*/?>", RegexOption.IGNORE_CASE), "\n")
                row.addView(label(inline(content), 14f).apply {
                    setPadding(dp(12), dp(10), dp(12), dp(10))
                    if (rowIndex == 0) typeface = Typeface.DEFAULT_BOLD
                    gravity = Gravity.TOP or when (block.alignments.getOrNull(firstColumn + columnIndex)) {
                        MarkdownBlocks.ColumnAlignment.CENTER -> Gravity.CENTER_HORIZONTAL
                        MarkdownBlocks.ColumnAlignment.RIGHT -> Gravity.END
                        else -> Gravity.START
                    }
                    if (rowIndex > 0) contentDescription = "${block.cells[0][firstColumn + columnIndex]}：${inline(content)}"
                }, LayoutParams(columnWidth, -1))
            }
            grid.addView(row, LayoutParams(-2, -2))
        }
        if (columns > 6) controls.addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            if (firstColumn > 0) addView(Ui.button(context, context.getString(R.string.table_previous_columns), Ui.Button.TEXT) { firstColumn = (firstColumn - 6).coerceAtLeast(0); renderRows() })
            addView(Ui.label(context, context.getString(R.string.table_columns_range, firstColumn + 1, minOf(firstColumn + 6, columns), columns), Ui.CAPTION, Palette.muted))
            if (firstColumn + 6 < columns) addView(Ui.button(context, context.getString(R.string.table_next_columns), Ui.Button.TEXT) { firstColumn += 6; renderRows() })
        }, LayoutParams(-1, -2))
        if (block.cells.size > 31) controls.addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            if (firstRow > 1) addView(Ui.button(context, context.getString(R.string.table_previous_rows), Ui.Button.TEXT) { firstRow = (firstRow - 30).coerceAtLeast(1); renderRows() })
            addView(Ui.label(context, context.getString(R.string.table_rows_range, firstRow, minOf(firstRow + 29, block.cells.lastIndex), block.cells.lastIndex), Ui.CAPTION, Palette.muted))
            if (firstRow + 30 < block.cells.size) addView(Ui.button(context, context.getString(R.string.table_next_rows), Ui.Button.TEXT) { firstRow += 30; renderRows() })
        }, LayoutParams(-1, -2))
        if (openMarkdown != null) MarkdownFileLinks.find(page.flatten().joinToString("\n"), anyFile).take(12).forEach { link ->
            controls.addView(Ui.button(context, context.getString(R.string.view_reference, link.label), Ui.Button.TEXT) { openMarkdown.invoke(link) }, LayoutParams(-1, -2))
        }
        }
        renderRows()
        val scrolling = HorizontalScrollView(context).apply {
            isFillViewport = false; isHorizontalScrollBarEnabled = true; isScrollbarFadingEnabled = false
            setPadding(0, 0, 0, dp(6)); clipToPadding = false
            contentDescription = context.getString(R.string.table_description, columns, (block.cells.size - 1).coerceAtLeast(0))
            addView(grid, LayoutParams(-2, -2))
        }
        return LinearLayout(context).apply { orientation = VERTICAL; addView(scrolling, LayoutParams(-1, -2)); addView(controls, LayoutParams(-1, -2)) }
    }
    private fun inline(source: String): CharSequence {
        val result = SpannableStringBuilder()
        for (run in InlineMarkup.parse(source)) {
            val start = result.length
            // Keep literal inline code intact; document actions are rendered below the prose.
            result.append(if (run.code) run.text else run.text.replace(Regex("(?<!!)\\[([^]\\n]+)]\\((<[^>]+>|[^)\\n]+)\\)"), "$1"))
            if (run.code) {
                result.setSpan(TypefaceSpan("monospace"), start, result.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                result.setSpan(BackgroundColorSpan(Palette.surface3), start, result.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                result.setSpan(ForegroundColorSpan(Palette.green), start, result.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            if (run.bold || run.italic) result.setSpan(StyleSpan(if (run.bold && run.italic) Typeface.BOLD_ITALIC else if (run.bold) Typeface.BOLD else Typeface.ITALIC), start, result.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return result
    }
}
