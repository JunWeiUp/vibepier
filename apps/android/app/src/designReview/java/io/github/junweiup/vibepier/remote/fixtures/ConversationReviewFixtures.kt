package io.github.junweiup.vibepier.remote.fixtures

import io.github.junweiup.vibepier.remote.BuildConfig
import io.github.junweiup.vibepier.remote.MainActivity

import org.json.JSONArray
import org.json.JSONObject

/** Synthetic UI-only fixtures. MainActivity never enables them in a production build. */
internal object ConversationReviewFixtures {
    private const val THREAD = "00000000-0000-4000-8000-000000000001"
    fun conversation(kind: String): JSONObject {
        check(BuildConfig.DESIGN_REVIEW)
        val messages = JSONArray().put(JSONObject().put("id", "user-1").put("role", "user").put("text", "请检查手机语音的音频传输，保留已有的快捷键配置。")
            .put("images", JSONArray().put(JSONObject().put("id", "user-1#0"))))
            .put(JSONObject().put("id", "assistant-1").put("role", "assistant").put("text", "已定位到蓝牙小包传输中的等待开销。\n\n我会保持手机与 Mac 的设置一致，先验证音频是否连续，再检查转写。\n\n```swift\nlet packetMilliseconds = 60\nlet samples = rate * packetMilliseconds / 1000\n```\n\n验证完成后，这里会同步显示结果。").put("parts", steps()))
        if (kind == "design") {
            messages.put(JSONObject().put("id", "quote-user").put("role", "user").put("text", "> 手机端只有按住语音时才使用手机麦克风。\n> 松开后恢复 Mac 的默认输入。\n\n请保留这个行为，**把引用和正文区分开**。"))
            messages.put(JSONObject().put("id", "design-assistant").put("role", "assistant").put("text", "## 这次的调整\n\n> 保留手机语音行为，优先改善会话的阅读体验。\n> `Mac 默认输入` 在松开后恢复。\n\n引用现在有独立侧线，**结论用字重强调**。正文和引用之间留出空间。\n\n- 会话标题更突出，项目与时间作为辅助信息。\n- 多行列表使用悬挂缩进，窄屏也能顺着读。\n\n1. 打开会话并查看消息。\n2. 使用 `Command + Control` 等快捷键。\n\n```swift\nfunc restoreInput() {\n    switchToPreviousDevice()\n}\n```\n\n长标识符也要完整显示：VeryLongConversationIdentifierThatShouldWrapAcrossSmallScreenWithoutLosingAnyCharacters。").put("hasMore", true).put("nextOffset", 1000))
        }
        if (kind == "files") messages.put(JSONObject().put("id", "files-assistant").put("role", "assistant")
            .put("text", "已把 BLE 包长改为 60ms，并在 [PhoneMicrophone.swift](apps/macos/Sources/VibePierCore/Audio/PhoneMicrophone.swift:42) 里同步帧大小。手机端的采集循环不需要改。"))
        val approvals = JSONArray()
        if (kind == "approval") approvals.put(JSONObject().put("id", "approval-1").put("fingerprint", "fixture-request-1").put("title", "执行命令").put("canDecide", true)
            .put("details", "工作目录：/Users/demo/Documents/code/vibepier\n\n命令：\nswift test --filter PhoneMicrophoneTests\n\n原因：验证音频帧编码与会话结束行为。\n\n作用范围：仅本次命令，不保留长期授权。\n\n" + (1..35).joinToString("\n\n") { "检查项 $it：确认测试目录、参数与权限范围完整可见。" }))
        return JSONObject().put("ok", true).put("event", "snapshot").put("threadId", THREAD).put("title", "优化手机语音与快捷控制")
            .put("capabilities", JSONObject().put("markdownFiles", true).put("projectFiles", kind == "files"))
            .put("messages", messages).put("approvals", approvals).put("status", if (kind in listOf("approval", "queued")) "active" else "idle").put("canSend", true).put("hasOlder", true).put("activeTurnId", "fixture-turn").put("composer", JSONObject().put("model", "gpt-6.1-sol").put("effort", "medium").put("mode", "auto"))
            .put("queuedMessages", if (kind == "queued") JSONArray().put(JSONObject().put("id", "queued-1").put("text", "先保留原来的配置，同时检查第一次打开会话时的加载耗时，完成后告诉我结果。").put("status", "queued").put("canSteer", true).put("canDelete", true)).put(JSONObject().put("id", "queued-2").put("text", "补充：图标缓存也一起验证。").put("status", "pending").put("canSteer", false).put("canDelete", false)) else JSONArray())
    }
    private fun step(id: String, kind: String, title: String, status: String, text: String) =
        JSONObject().put("id", id).put("kind", kind).put("title", title).put("status", status).put("text", text)
    /** One reply holding every kind of step, the way the desktop shows a turn. */
    private fun steps() = JSONArray()
        .put(step("p-think", "thinking", "思考", "", "先确认是传输还是转写的问题：对比实际收到的帧数和按住时长。"))
        .put(step("p-text-1", "text", "", "", "已定位到蓝牙小包传输中的等待开销。\n\n我会保持手机与 Mac 的设置一致，先验证音频是否连续，再检查转写。"))
        .put(step("p-cmd-1", "command", "swift test --filter PhoneMicrophoneTests", "completed", "Test Suite 'PhoneMicrophoneTests' passed\nExecuted 6 tests, with 0 failures (0 unexpected) in 0.412 seconds")
            .put("durationMs", 4210).put("cwd", "/Users/demo/VibePier").put("description", "运行麦克风相关测试"))
        .put(step("p-cmd-2", "command", "grep -rn packetMilliseconds Sources", "failed", "grep: Sources/Legacy: No such file or directory").put("exitCode", 2).put("durationMs", 38))
        .put(step("p-file", "file", "/Users/demo/VibePier/Sources/VibePierCore/PhoneMicrophone.swift", "completed",
            "*** update /Users/demo/VibePier/Sources/VibePierCore/PhoneMicrophone.swift\n@@ -40,3 +40,4 @@\n-let packetMilliseconds = 20\n+let packetMilliseconds = 60\n+let samples = rate * packetMilliseconds / 1000\n let encoder = ADPCMEncoder()")
            .put("added", 2).put("removed", 1).put("files", JSONArray().put(JSONObject().put("path", "PhoneMicrophone.swift").put("kind", "update").put("added", 2).put("removed", 1))))
        .put(step("p-shot", "tool", "查看图片", "completed", "/Users/demo/VibePier/docs/remote.png").put("images", JSONArray().put(JSONObject().put("id", "p-shot#0"))))
        .put(step("p-cmd-3", "command", "git status --short", "completed", " M Sources/VibePierCore/PhoneMicrophone.swift").put("durationMs", 120))
        .put(step("p-tool", "tool", "读取 docs/phone-microphone.md", "completed", "结果：\n# 手机麦克风\nBLE 使用 8k/60ms 独立 IMA-ADPCM 帧。").put("hasMore", true).put("nextOffset", 40))
        .put(step("p-plan", "plan", "计划", "", "- [x] 对比帧数\n- [x] 改为 60ms 包\n- [ ] 真机验证转写"))
        .put(step("p-run", "command", "./gradlew testDebugUnitTest", "running", ""))
        .put(step("p-text-2", "text", "", "", "```swift\nlet packetMilliseconds = 60\nlet samples = rate * packetMilliseconds / 1000\n```\n\n验证完成后，这里会同步显示结果。"))
    val newRequests = mutableListOf<String>()
    val newRequestBodies = mutableListOf<JSONObject>()
    val approvalRequestBodies = mutableListOf<JSONObject>()
    var creationOptionsReads = 0
    private fun entry(name: String, path: String, size: Long = -1, status: String = "", changed: Boolean = false) = JSONObject().put("name", name).put("path", path)
        .put("directory", size < 0).apply { if (size >= 0) put("size", size); if (status.isNotEmpty()) put("status", status); if (changed) put("changed", true) }
    private val folders = mapOf(
        "" to listOf(entry("apps", "apps", changed = true), entry("android", "android", changed = true), entry("docs", "docs", changed = true),
            entry("Package.swift", "Package.swift", 2200), entry("README.md", "README.md", 1100)),
        "apps" to listOf(entry("macos", "apps/macos", changed = true)),
        "apps/macos" to listOf(entry("Sources", "apps/macos/Sources", changed = true)),
        "apps/macos/Sources" to listOf(entry("VibePierCore", "apps/macos/Sources/VibePierCore", changed = true), entry("VibePierApp", "apps/macos/Sources/VibePierApp")),
        "apps/macos/Sources/VibePierCore" to listOf(entry("Audio", "apps/macos/Sources/VibePierCore/Audio", changed = true), entry("CodexBridge.swift", "apps/macos/Sources/VibePierCore/CodexBridge.swift", 21504),
            entry("ConversationActivity.swift", "apps/macos/Sources/VibePierCore/ConversationActivity.swift", 14336, "M"), entry("Daemon.swift", "apps/macos/Sources/VibePierCore/Daemon.swift", 49152),
            entry("libkwdm.dylib", "apps/macos/Sources/VibePierCore/libkwdm.dylib", 3_400_000)),
        "apps/macos/Sources/VibePierCore/Audio" to listOf(entry("AudioManager.swift", "apps/macos/Sources/VibePierCore/Audio/AudioManager.swift", 6200),
            entry("PhoneMicrophone.swift", "apps/macos/Sources/VibePierCore/Audio/PhoneMicrophone.swift", 9800, "M"), entry("TalkInputRouter.swift", "apps/macos/Sources/VibePierCore/Audio/TalkInputRouter.swift", 5100)),
        "docs" to listOf(entry("phone-microphone.md", "docs/phone-microphone.md", 3100, "A"), entry("VibePier.md", "docs/VibePier.md", 18000)),
        "android" to listOf(entry("PhoneAudioCodec.kt", "android/PhoneAudioCodec.kt", 4100, "M")))
    private const val SOURCE = "import AVFoundation\n\n/// Streams the phone's microphone into BlackHole while the talk key is held.\nfinal class PhoneMicrophone {\n    private let rate: Int\n    private var frames = 0\n\n    let packetMs = transport == .ble ? 60 : 20\n    // BLE writes are slow; fewer, larger frames\n    let samples = rate * packetMs / 1000\n\n    func begin(session: String) {\n        guard !running else { return }\n        engine.start()\n        log(\"phone mic began\")\n    }\n\n    func end() {\n        restoreInput()\n        engine.stop()\n    }\n}\n"
    private const val DIFF = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -5,7 +5,9 @@ final class PhoneMicrophone {\n     private let rate: Int\n     private var frames = 0\n \n-    let packetMs = 20\n+    let packetMs = transport == .ble ? 60 : 20\n+    // BLE writes are slow; fewer, larger frames\n+    let samples = rate * packetMs / 1000\n \n     func begin(session: String) {\n         guard !running else { return }\n@@ -17,4 +19,5 @@ final class PhoneMicrophone {\n     func end() {\n+        restoreInput()\n         engine.stop()\n     }\n"

    private fun files(op: String, fields: JSONObject): JSONObject? {
        val path = fields.optString("path")
        return when (op) {
            "browseFiles" -> JSONObject().put("ok", true).put("folder", fields.optString("folder")).put("root", "vibepier").put("rootPath", "/Users/demo/Documents/code/vibepier")
                .put("branch", "feat/project-files").put("entries", JSONArray(folders[fields.optString("folder")] ?: emptyList<JSONObject>())).put("truncated", false)
            "fileChanges" -> JSONObject().put("ok", true).put("root", "vibepier").put("rootPath", "/Users/demo/Documents/code/vibepier").put("branch", "feat/project-files").put("git", true)
                .put("gitChanged", 5).put("files", JSONArray()
                    .put(JSONObject().put("path", "apps/macos/Sources/VibePierCore/Audio/PhoneMicrophone.swift").put("kind", "update").put("added", 18).put("removed", 3).put("status", "M"))
                    .put(JSONObject().put("path", "android/PhoneAudioCodec.kt").put("kind", "update").put("added", 9).put("removed", 4).put("status", "M"))
                    .put(JSONObject().put("path", "docs/phone-microphone.md").put("kind", "add").put("added", 15).put("removed", 0).put("status", "A")))
            "readFile" -> when {
                path.endsWith(".dylib") -> JSONObject().put("ok", true).put("path", path).put("name", path.substringAfterLast('/')).put("size", 3_400_000).put("unavailable", "tooLarge")
                else -> {
                    val text = if (path.endsWith(".md")) "# 手机麦克风\n\n手机设置 → 语音键收音可选 Mac 或手机，默认 Mac。\n\n## 传输格式\n\n| 通道 | 采样率 | 包长 |\n| --- | --- | --- |\n| Wi-Fi | 16 kHz | `20ms` |\n| BLE | 8 kHz | `60ms` |\n" else SOURCE
                    JSONObject().put("ok", true).put("path", path).put("name", path.substringAfterLast('/')).put("size", text.toByteArray().size).put("text", text)
                        .put("version", "review-file").put("nextOffset", -1).apply { if (path.contains("PhoneMicrophone")) put("status", "M") }
                }
            }
            "fileDiff" -> if (path.endsWith(".md")) JSONObject().put("ok", true).put("git", true).put("status", "A").put("untracked", true)
                else JSONObject().put("ok", true).put("git", true).put("status", "M").put("diff", DIFF).put("added", 4).put("removed", 1)
            "searchFiles" -> {
                val query = fields.optString("query").lowercase()
                val all = folders.values.flatten().filter { !it.optBoolean("directory") && it.optString("name").lowercase().contains(query) }
                JSONObject().put("ok", true).put("query", fields.optString("query")).put("results", JSONArray(all)).put("truncated", false)
            }
            "openFile" -> JSONObject().put("ok", true).put("opened", true).put("locked", false)
            else -> null
        }
    }

    fun reply(op: String, fields: JSONObject, kind: String): JSONObject {
        check(BuildConfig.DESIGN_REVIEW)
        if (op == "newOptions") creationOptionsReads++
        if (kind == "files") files(op, fields)?.let { return it }
        return when (op) {
            "codexUsage" -> JSONObject().put("ok", true).put("accountId", "demo-account").put("resetEligible", true).put("availableCount", 3).put("cardDetailsKnown", true).put("fetchedAt", System.currentTimeMillis() / 1000)
                .put("windows", JSONArray().put(JSONObject().put("limitId", "codex").put("windowDurationMins", 10080).put("remainingPercent", 7).put("resetsAt", System.currentTimeMillis() / 1000 + 3600)))
                .put("resetCards", JSONArray().put(JSONObject().put("id", "demo-gift").put("available", true).put("expiresAt", System.currentTimeMillis() / 1000 + 7200)))
            "lockScreen" -> JSONObject().put("ok", true).put("locked", true)
            "unlockScreen" -> JSONObject().put("ok", true).put("locked", false)
            "list" -> JSONObject().put("ok", true).put("nextOffset", -1).put("threads", JSONArray()
                .put(JSONObject().put("id", THREAD).put("title", "优化手机语音与快捷控制").put("project", "VibePier").put("pinned", true).put("status", "running").put("updatedAt", System.currentTimeMillis() - 120000))
                .put(JSONObject().put("id", "00000000-0000-4000-8000-000000000002").put("title", "检查应用启动时的连接状态与错误提示").put("project", "桌面工具").put("status", "approval").put("updatedAt", System.currentTimeMillis() - 3600000))
                .put(JSONObject().put("id", "00000000-0000-4000-8000-000000000003").put("title", "整理下一版的交互改进").put("project", "").put("updatedAt", System.currentTimeMillis() - 86400000))).also { result ->
                    val query = fields.optString("search"); val rows = result.getJSONArray("threads")
                    val filtered = JSONArray()
                    for (i in 0 until rows.length()) { val row = rows.getJSONObject(i); if (row.optString("title").contains(query, true) || row.optString("project").contains(query, true)) filtered.put(row) }
                    result.put("threads", filtered)
                }
            "projects" -> JSONObject().put("ok", true).put("projects", JSONArray()
                .put(JSONObject().put("cwd", "/Users/demo/VibePier").put("project", "VibePier").put("count", 1).put("running", 1).put("updatedAt", System.currentTimeMillis() - 120000))
                .put(JSONObject().put("cwd", "/Users/demo/桌面工具").put("project", "桌面工具").put("count", 1).put("updatedAt", System.currentTimeMillis() - 3600000)))
            "parts" -> {
                val all = steps(); val items = (0 until all.length()).map { all.getJSONObject(it) }.filter { !fields.optBoolean("headersOnly") || it.optString("kind") != "text" }
                val start = fields.optInt("offset").coerceIn(0, items.size); val end = minOf(start + 8, fields.optInt("before", items.size).coerceIn(start, items.size))
                val rows = items.subList(start, end).mapIndexed { i, row ->
                    JSONObject(row.toString()).apply {
                        if (fields.optBoolean("sequence")) {
                            put("index", start + i); put("bodyVersion", "${row.optString("text").hashCode()}|${row.optString("status")}")
                            if (optString("kind") !in setOf("text", "plan")) { remove("text"); remove("hasMore"); remove("nextOffset"); put("bodyDeferred", true) }
                        } else if (fields.optBoolean("headersOnly")) { remove("text"); remove("hasMore"); remove("nextOffset"); put("bodyVersion", "${row.optString("text").length}|${row.optString("status")}") }
                    }
                }
                JSONObject().put("ok", true).put("parts", JSONArray(rows)).put("partCount", items.size).put("nextOffset", if (end < items.size) end else -1)
            }
            "open" -> JSONObject().put("ok", true).put("opening", true)
            "new" -> {
                newRequests.add(fields.optString("id"))
                newRequestBodies.add(JSONObject(fields.toString()))
                if (kind == "new-receipt-unknown") JSONObject().put("ok", false).put("unknown", true)
                else JSONObject().put("ok", true).put("threadId", "00000000-0000-4000-8000-000000000004").put("title", fields.optString("text").take(40))
            }
            "receipt" -> when (kind) {
                "new-receipt-notfound" -> JSONObject().put("ok", true).put("state", "notFound")
                "new-receipt-complete" -> JSONObject().put("ok", true).put("state", "complete").put("receipt", JSONObject().put("ok", true).put("threadId", "00000000-0000-4000-8000-000000000004").put("title", "Created fixture"))
                else -> JSONObject().put("ok", true).put("state", "unknown")
            }
            "newOptions" -> JSONObject().put("ok", true).put("models", JSONArray().put(JSONObject().put("id", "gpt-6.1-sol").put("name", "GPT-6.1-Sol").put("efforts", JSONArray(listOf("low", "medium", "high", "xhigh", "max", "ultra")))).put(JSONObject().put("id", "gpt-6-astra").put("name", "GPT-6-Astra").put("efforts", JSONArray(listOf("low", "medium", "high", "xhigh", "max", "ultra")))))
                .put("creationVersion", 1).put("composer", JSONObject().put("model", "gpt-6.1-sol").put("effort", "medium").put("mode", "auto"))
                .put("capabilities", JSONObject().put("attachments", true))
                .put("permissionModes", JSONArray().put(JSONObject().put("id", "auto").put("name", "Default permissions"))
                    .put(JSONObject().put("id", "guardian-approvals").put("name", "Approve for me"))
                    .put(JSONObject().put("id", "full-access").put("name", "Full access").put("requiresConfirmation", true)))
            "composerOptions" -> JSONObject().put("ok", true).put("models", JSONArray().put(JSONObject().put("id", "gpt-6.1-sol").put("name", "GPT-6.1-Sol").put("efforts", JSONArray(listOf("low", "medium", "high", "xhigh", "max", "ultra")))).put(JSONObject().put("id", "gpt-6-astra").put("name", "GPT-6-Astra").put("efforts", JSONArray(listOf("low", "medium", "high", "xhigh", "max", "ultra")))))
            "settings", "interrupt" -> JSONObject().put("ok", true).put("accepted", true)
            "browseFiles" -> JSONObject().put("ok", true).put("entries", JSONArray().put(JSONObject().put("name", "README.md").put("path", "README.md").put("directory", false)).put(JSONObject().put("name", "界面截图.png").put("path", "界面截图.png").put("directory", false)))
            "readMarkdownFile" -> {
                val text = "# 项目说明\n\n在会话中查看 **Markdown 文档**。\n\n- [x] 预览与源码\n- [ ] 下一步计划\n\n| 应用 | 用时 | 状态 |\n| --- | ---: | :---: |\n| Codex | 1 小时 20 分钟 | 正常 |\n| 终端 | 35 分钟 | 正常 |\n\n```swift\nlet preview = true\n```\n"
                JSONObject().put("ok", true).put("threadId", fields.optString("threadId")).put("path", fields.optString("path")).put("name", fields.optString("path").substringAfterLast('/'))
                    .put("text", text).put("size", text.toByteArray(Charsets.UTF_8).size).put("version", "review-markdown-1").put("nextOffset", -1)
            }
            "attachmentReference" -> JSONObject().put("ok", true).put("attachmentId", fields.optString("attachmentId")).put("name", fields.optString("path")).put("size", 256000).put("mime", if (fields.optString("path").endsWith("png")) "image/png" else "text/markdown")
            "appshotApps" -> JSONObject().put("ok", true).put("apps", JSONArray().put(JSONObject().put("id", "com.apple.finder").put("name", "Finder")))
            "appshot" -> JSONObject().put("ok", true).put("attachmentId", fields.optString("attachmentId")).put("name", "Finder.jpg").put("size", 320000).put("mime", "image/jpeg")
            "message" -> {
                val all = steps(); val part = (0 until all.length()).map { all.getJSONObject(it) }.firstOrNull { it.optString("id") == fields.optString("messageId") }
                val text = part?.optString("text") ?: "\n\n> 补充说明：引用和正文在展开后仍使用一致样式。\n\n全文已加载完成。"
                val start = fields.optInt("offset").coerceIn(0, text.length); val end = minOf(start + 12000, text.length)
                JSONObject().put("ok", true).put("text", text.substring(start, end)).put("nextOffset", if (end < text.length) end else -1)
            }
            "history" -> conversation(kind).put("hasOlder", false)
            "send" -> if (kind == "failure") JSONObject().put("ok", false).put("error", "Mac 暂未响应，草稿已保留") else JSONObject().put("ok", true).put("accepted", true)
            "approve" -> {
                approvalRequestBodies.add(JSONObject(fields.toString()))
                JSONObject().put("ok", true).put("submitted", true)
            }
            else -> JSONObject().put("ok", true)
        }
    }
}
