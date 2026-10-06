package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionClient
import io.github.junweiup.vibepier.remote.core.ui.CanvasLabel
import io.github.junweiup.vibepier.remote.features.markdown.MarkdownFileViewer
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import org.json.JSONObject

/** Real read-only dialog and synthetic RPC pages; never reads or modifies a desktop file. */
object MarkdownFileViewerProbe {
    private data class Read(val operation: String, val params: JSONObject, val reply: (JSONObject) -> Unit)

    fun run(test: Instrumentation): String {
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval"))
        val open = mutableListOf<MarkdownFileViewer>()
        val requests = mutableListOf<Read>()
        var originalProvider: String? = null
        var originalListMode: String? = null
        var fixtureClient: SessionClient? = null
        fun main(action: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { action() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
            test.waitForIdleSync()
        }
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun displayed(viewer: MarkdownFileViewer) = views(viewer.dialog.window!!.decorView).filterIsInstance<CanvasLabel>()
            .filter { it.isShown }.joinToString("\n") { it.text.toString() }
        fun control(viewer: MarkdownFileViewer, text: String): View = views(viewer.dialog.window!!.decorView).firstOrNull {
            val description = it.contentDescription?.toString()
            it.isShown && (description == text || description == activity.getString(R.string.choice_switch, text, activity.getString(R.string.document_kind)) || description == activity.getString(R.string.choice_selected, text, activity.getString(R.string.document_kind)) ||
                (it.isClickable && it is CanvasLabel && it.text.toString() == text))
        } ?: error("Missing MD control: $text")
        fun click(viewer: MarkdownFileViewer, text: String) = main {
            val button = control(viewer, text); check(button.isEnabled) { "MD control disabled: $text" }; button.performClick()
        }
        fun reply(index: Int, value: JSONObject) = main { requests[index].reply(value) }
        fun bytes(text: String) = text.toByteArray(Charsets.UTF_8).size
        fun page(text: String, size: Int = bytes(text), next: Int = -1, version: String = "snapshot-v1", thread: String = "md-fixture") = JSONObject()
            .put("ok", true).put("threadId", thread).put("path", "docs/设计说明.md").put("name", "设计说明.md")
            .put("text", text).put("size", size).put("nextOffset", next).put("version", version)
        fun viewer(path: String = "docs/设计说明.md", current: () -> Boolean = { true }, closed: () -> Unit = {}): MarkdownFileViewer {
            lateinit var result: MarkdownFileViewer
            main {
                result = MarkdownFileViewer(activity, "md-fixture", path, "claude", { operation, params, callback ->
                    requests.add(Read(operation, JSONObject(params.toString()), callback))
                }, current, closed)
                open.add(result); result.show()
            }
            return result
        }
        fun awaitRequests(count: Int) {
            val until = SystemClock.elapsedRealtime() + 2000
            while (requests.size < count && SystemClock.elapsedRealtime() < until) { SystemClock.sleep(25); test.waitForIdleSync() }
            check(requests.size >= count) { "Expected $count MD requests, got ${requests.size}" }
        }
        fun field(value: Any, name: String): Any? = value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)
        fun invoke(value: Any, name: String) = value.javaClass.getDeclaredMethod(name).apply { isAccessible = true }.invoke(value)
        fun invoke(value: Any, name: String, argument: String) = value.javaClass.getDeclaredMethod(name, String::class.java).apply { isAccessible = true }.invoke(value, argument)
        fun waitFor(description: String, condition: () -> Boolean) {
            val until = SystemClock.elapsedRealtime() + 3000
            var ready = false
            while (!ready && SystemClock.elapsedRealtime() < until) {
                main { ready = condition() }
                if (!ready) SystemClock.sleep(25)
            }
            check(ready) { "Timed out waiting for $description" }
        }
        try {
            SystemClock.sleep(250); test.waitForIdleSync()
            val first = viewer("/Users/demo/My Project/设计说明.md")
            main {
                check(requests.single().operation == "readMarkdownFile")
                check(requests.single().params.getString("threadId") == "md-fixture")
                check(requests.single().params.getString("provider") == "claude")
                check(requests.single().params.getString("path") == "/Users/demo/My Project/设计说明.md")
                check(requests.single().params.getInt("offset") == 0 && !requests.single().params.has("version"))
                check(!control(first, activity.getString(R.string.document_copy_all)).isEnabled)
            }
            reply(0, JSONObject().put("ok", false).put("error", "文件不存在或无权限"))
            main { check(displayed(first).contains("文件不存在或无权限")); check(!control(first, activity.getString(R.string.document_copy_all)).isEnabled) }
            click(first, activity.getString(R.string.retry))
            check(requests.size == 2 && requests[1].params.getInt("offset") == 0)
            val small = "# 设计标题\n\n这是 **正文**，包含 `code`。\n"
            reply(1, page(small))
            main { check(displayed(first).contains("设计标题")); check(control(first, activity.getString(R.string.document_copy_all)).isEnabled) }
            val readsBeforeTabs = requests.size
            click(first, activity.getString(R.string.document_source))
            main { check(displayed(first).contains(small)); check(requests.size == readsBeforeTabs) }
            click(first, activity.getString(R.string.document_preview))
            main { check(displayed(first).contains("设计标题")); check(requests.size == readsBeforeTabs); first.dismiss() }

            // Offsets are UTF-8 bytes, and a paging failure must preserve readable earlier content.
            val paged = viewer()
            val head = "# 分页说明\n\n保留已经读取的内容。\n"
            val tail = "\n最后一段已完整读取。\n"
            val whole = head + tail
            val firstPage = requests.lastIndex
            reply(firstPage, page(head, bytes(whole), bytes(head)))
            awaitRequests(firstPage + 2)
            val secondPage = requests.lastIndex
            main {
                check(requests[secondPage].params.getInt("offset") == bytes(head))
                check(requests[secondPage].params.getString("version") == "snapshot-v1")
                check(requests[secondPage].params.getString("path") == "docs/设计说明.md")
            }
            reply(secondPage, JSONObject().put("ok", false).put("error", "连接暂时中断"))
            main {
                check(displayed(paged).contains("保留已经读取的内容"))
                check(displayed(paged).contains(activity.getString(R.string.document_error_retained, "连接暂时中断")))
                check(!control(paged, activity.getString(R.string.document_copy_all)).isEnabled)
            }
            click(paged, activity.getString(R.string.document_source))
            main { check(displayed(paged).contains(head)); check(requests.size == secondPage + 1) }
            click(paged, activity.getString(R.string.retry))
            val versionMismatch = requests.lastIndex
            main {
                check(requests[versionMismatch].params.getInt("offset") == bytes(head))
                check(requests[versionMismatch].params.getString("version") == "snapshot-v1")
            }
            reply(versionMismatch, page(tail, bytes(whole), version = "different-snapshot"))
            main {
                check(displayed(paged).contains(head))
                check(!displayed(paged).contains(tail))
                check(!control(paged, activity.getString(R.string.document_copy_all)).isEnabled)
            }
            click(paged, activity.getString(R.string.retry))
            reply(requests.lastIndex, page(tail, bytes(whole)))
            main { check(displayed(paged).contains(whole)); check(control(paged, activity.getString(R.string.document_copy_all)).isEnabled); paged.dismiss() }

            // Explicit reloading creates a new generation; earlier callbacks cannot replace it.
            val reloaded = viewer()
            reply(requests.lastIndex, page("# 原内容\n"))
            click(reloaded, activity.getString(R.string.reload))
            val older = requests.lastIndex
            reply(older, JSONObject().put("ok", false).put("error", "读取失败"))
            click(reloaded, activity.getString(R.string.reload))
            val newer = requests.lastIndex
            reply(older, page("# 过期回执不能显示\n"))
            main { check(!displayed(reloaded).contains("过期回执不能显示")); check(!control(reloaded, activity.getString(R.string.document_copy_all)).isEnabled) }
            reply(newer, page("# 新内容\n"))
            main { check(displayed(reloaded).contains("新内容")); reloaded.dismiss() }

            // Closing and switching sessions invalidate asynchronous receipts.
            var closeCount = 0
            val dismissed = viewer(closed = { closeCount++ })
            val delayed = requests.lastIndex
            main { dismissed.dismiss(); dismissed.dismiss(); check(closeCount == 1); check(!dismissed.dialog.isShowing) }
            reply(delayed, page("# 已关闭的私密内容\n"))
            main { check(!dismissed.dialog.isShowing && closeCount == 1) }
            var currentSession = true
            val switched = viewer(current = { currentSession })
            val wrongSession = requests.lastIndex
            main { currentSession = false }
            reply(wrongSession, page("# 原会话内容不能串入\n"))
            main { check(!displayed(switched).contains("原会话内容不能串入")); switched.dismiss() }
            val requestsBeforeInvalid = requests.size
            val invalid = viewer(current = { false })
            main { check(!invalid.dialog.isShowing && requests.size == requestsBeforeInvalid); invalid.dismiss() }

            // Empty files remain read-only; wrong-thread data does not enter the document.
            val empty = viewer()
            reply(requests.lastIndex, page(""))
            main { check(displayed(empty).contains(activity.getString(R.string.document_empty))); empty.dismiss() }
            val wrongThread = viewer()
            reply(requests.lastIndex, page("# 其他会话内容\n", thread = "other-thread"))
            main { check(!displayed(wrongThread).contains("其他会话内容")); check(!control(wrongThread, activity.getString(R.string.document_copy_all)).isEnabled); wrongThread.dismiss() }

            // Showing another local display chunk is independent of network paging.
            val large = viewer()
            val largeText = "# 大文档\n\n" + "已经读取的行。\n".repeat(5000) + "文档最后一行。\n"
            reply(requests.lastIndex, page(largeText))
            click(large, activity.getString(R.string.document_source))
            val beforeDisplay = requests.size
            main { check(!displayed(large).contains("文档最后一行")); check(control(large, activity.getString(R.string.document_copy_all)).isEnabled) }
            click(large, activity.getString(R.string.document_show_more))
            main { check(displayed(large).contains("文档最后一行")); check(requests.size == beforeDisplay) }
            lateinit var clipboard: ClipboardManager
            main { clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager }
            var previous: android.content.ClipData? = null
            main { previous = clipboard.primaryClip }
            try {
                click(large, activity.getString(R.string.document_copy_all))
                main { check(clipboard.primaryClip?.getItemAt(0)?.text?.toString() == largeText) }
            } finally {
                main {
                    if (previous != null) clipboard.setPrimaryClip(previous!!) else if (android.os.Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip()
                    large.dismiss()
                }
            }
            // Ten thousand small blocks must keep the current page's view tree bounded.
            val shortLists = viewer()
            val listText = (1..10_000).joinToString("\n", postfix = "\n") { "- 条目${it.toString().padStart(5, '0')}" }
            reply(requests.lastIndex, page(listText))
            val listReads = requests.size
            main {
                check(views(shortLists.dialog.window!!.decorView).size <= 700) { "MD list created too many views on its first page" }
                check(displayed(shortLists).contains("条目00001"))
                check(!displayed(shortLists).contains("条目00121"))
            }
            click(shortLists, activity.getString(R.string.document_next_page))
            main {
                check(views(shortLists.dialog.window!!.decorView).size <= 700)
                check(displayed(shortLists).contains("条目00121"))
                check(!displayed(shortLists).contains("条目00001"))
                check(requests.size == listReads)
            }
            click(shortLists, activity.getString(R.string.document_previous_page))
            main { check(displayed(shortLists).contains("条目00001")); check(requests.size == listReads); shortLists.dismiss() }

            // Oversized clipboard operations show an explicit alternative without replacing clipboard data.
            val oversized = viewer()
            val oversizedText = "- " + "copy-limit-row".repeat(2) + "\n"
            val copyLimitedDocument = oversizedText.repeat(7_000)
            check(copyLimitedDocument.length > 200_000)
            reply(requests.lastIndex, page(copyLimitedDocument))
            var clipboardBeforeLimit: android.content.ClipData? = null
            main { clipboardBeforeLimit = clipboard.primaryClip }
            click(oversized, activity.getString(R.string.document_copy_all))
            main {
                check(displayed(oversized).contains(activity.getString(R.string.document_copy_large)))
                val now = clipboard.primaryClip
                check(now?.description?.label?.toString() == clipboardBeforeLimit?.description?.label?.toString())
                check(now?.itemCount == clipboardBeforeLimit?.itemCount)
                check(now?.getItemAt(0)?.text?.toString() == clipboardBeforeLimit?.getItemAt(0)?.text?.toString())
                oversized.dismiss()
            }
            // Use the actual session header and picker, then check all supported provider routes.
            lateinit var panel: ConversationPanel
            main {
                panel = (activity as MainActivity).sessionNavigation.panel as ConversationPanel
                fixtureClient = field(panel, "client") as SessionClient
                originalProvider = fixtureClient!!.provider
                originalListMode = fixtureClient!!.listMode
                fixtureClient!!.listMode = "recent"
                panel.javaClass.getDeclaredField("search").apply { isAccessible = true }.set(panel, "")
                panel.javaClass.getDeclaredField("projectCwd").apply { isAccessible = true }.set(panel, "")
                invoke(panel, "showDrawer")
            }
            fun latestMenu(): AlertDialog? = (field(panel, "auxiliaryDialogs") as Set<*>).filterIsInstance<AlertDialog>().lastOrNull { it.isShowing }
            fun clickMenu(text: String) = main {
                val menu = latestMenu() ?: error("No session menu for: $text")
                val button = views(menu.window!!.decorView).filterIsInstance<CanvasLabel>().firstOrNull { it.text.toString() == text && it.isClickable }
                    ?: error("Missing menu entry: $text")
                check(button.isEnabled); button.performClick()
            }
            fun openFixtureSession() {
                waitFor("fixture session row") { views(panel).any { it.contentDescription?.toString()?.startsWith(activity.getString(R.string.session_open_session) + "优化手机语音与快捷控制，VibePier") == true } }
                main { views(panel).first { it.contentDescription?.toString()?.startsWith(activity.getString(R.string.session_open_session) + "优化手机语音与快捷控制，VibePier") == true }.performClick() }
                waitFor("fixture conversation") { field(panel, "ready") == true && field(panel, "drawer") == false }
            }
            fun openFromHeader(): MarkdownFileViewer {
                main { views(panel).first { it.contentDescription?.toString() == activity.getString(R.string.session_more_session_actions) }.performClick() }
                clickMenu(activity.getString(R.string.session_view_markdown_files))
                waitFor("MD file list") { latestMenu()?.let { menu -> views(menu.window!!.decorView).filterIsInstance<CanvasLabel>().any { it.text.toString() == "README.md" && it.isClickable } } == true }
                main {
                    val menu = latestMenu()!!
                    check(views(menu.window!!.decorView).filterIsInstance<CanvasLabel>().none { it.text.toString() == "界面截图.png" && it.isClickable })
                }
                clickMenu("README.md")
                waitFor("README preview") { (field(panel, "markdownViewer") as? MarkdownFileViewer)?.let { displayed(it).contains("项目说明") } == true }
                lateinit var selected: MarkdownFileViewer
                main {
                    selected = field(panel, "markdownViewer") as MarkdownFileViewer
                    check(selected.dialog.isShowing)
                    check(displayed(selected).contains("Markdown 文档"))
                }
                return selected
            }
            for (provider in listOf("codex", "claude")) {
                main {
                    if (fixtureClient!!.provider != provider) invoke(panel, "switchProvider", provider)
                    panel.javaClass.getDeclaredField("search").apply { isAccessible = true }.set(panel, "")
                    panel.javaClass.getDeclaredField("projectCwd").apply { isAccessible = true }.set(panel, "")
                    invoke(panel, "showDrawer")
                }
                openFixtureSession()
                val closedByUser = openFromHeader()
                if (provider == "codex") {
                    // Let Android's clipboard preview from the copy checks leave the foreground.
                    test.waitForIdleSync(); SystemClock.sleep(5000)
                    test.uiAutomation.takeScreenshot().also { bitmap ->
                        java.io.File(activity.externalCacheDir!!, "markdown-preview.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                        bitmap.recycle()
                    }
                }
                click(closedByUser, activity.getString(R.string.document_close))
                main { check(!closedByUser.dialog.isShowing && field(panel, "markdownViewer") == null) }
                val fromHeader = openFromHeader()
                // Refreshing the conversation invalidates a document from its previous generation.
                main {
                    val thread = field(panel, "thread") as String
                    val title = field(panel, "title") as String
                    panel.javaClass.getDeclaredMethod("open", String::class.java, String::class.java).apply { isAccessible = true }.invoke(panel, thread, title)
                    check(!fromHeader.dialog.isShowing && field(panel, "markdownViewer") == null)
                }
                waitFor("refreshed fixture conversation") { field(panel, "ready") == true }
                val beforeDrawer = openFromHeader()
                main {
                    invoke(panel, "showDrawer")
                    check(!beforeDrawer.dialog.isShowing && field(panel, "markdownViewer") == null)
                }
            }
            return "PASS: MD read params/provider, first error retry, preview/source without reread, UTF-8 snapshot paging, retained partial document/retry, changed-version rejection, reload generation, close/session callback cancellation, wrong-thread rejection, empty document, bounded display paging/full copy, 10,000-list page view limit, oversized-copy notice/clipboard preservation; actual session header→MD picker→README, non-MD filtering, user close/refresh/return-list dismissal and Codex/Claude routes\n"
        } finally {
            main {
                open.forEach { it.dismiss() }
                originalProvider?.let { fixtureClient?.provider = it }
                originalListMode?.let { fixtureClient?.listMode = it }
                activity.finish()
            }
        }
    }
}
