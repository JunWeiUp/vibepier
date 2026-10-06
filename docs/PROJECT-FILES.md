# Project files / 项目文件

The open conversation's folder button opens a read-only browser of its trusted workspace. Codex and Claude Code advertise `projectFiles` only when this Mac implementation is available. Both Mac and Android must be updated. This is a workspace browser, not a general Mac filesystem browser.

会话标题栏的文件夹按钮打开当前会话工作目录。界面参照 `files.html` 的项目文件设计：石墨色分层背景、薄荷色主操作、目录树、路径面包屑和底部操作栏。Mac 与 Android 需一起更新。

## Navigation / 使用

- **All / 全部**: expand folders in place; the breadcrumb and folder action menu move into a directory. Entries show language tiles, sizes and Git A/M/D state; changed folders have an amber dot. Search matches file names across the workspace.
- **Turn changes / 本轮改动**: files in structured file-edit steps after the latest user message, merged by path. This is distinct from all uncommitted Git changes. The folder badge and the completed reply's change card use this list.
- **Recent / 最近打开**: the last 20 opened paths in this workspace, stored only on this phone in encrypted preferences.
- **Source / 源码**, **Changes / 改动**, **Preview / 预览**: numbered UTF-8 source with lightweight syntax colors, a diff against HEAD, and bounded Markdown/image previews. New untracked files are shown as added source. Deleted tracked files can still show their diff.
- Tap a supported file link to open it; line hints scroll to that source line. Existing Markdown links retain the session-reference reader, including its exact external-document permissions.
- Copy text/path, find text, quote a path and optional line into the reply, add a supported attachment, open an inert document on the Mac, or show it in Finder. Quoting edits the draft without sending it.

目录页提供“全部 / 本轮改动 / 最近打开”；搜索覆盖工作目录文件名。“本轮改动”来自最新用户消息后的结构化文件编辑步骤，不等于工作区全部未提交改动。源码和 diff 支持行号，Markdown/图片可预览。引用只写入回复草稿，不自动发送；现有外部 Markdown 引用继续走原来的精确授权阅读器。

Text pages continue loading while the source list is hidden; failures after a partial read show an error and a retry action. HTML/HTM files open in a rendered preview with a Source tab. Inline styles, scripts and data images work in an isolated WebView; network/CDN resources, sibling files, frames, file/content access, downloads and external navigation are blocked. Switching tabs preserves the preview; closing/reloading destroys it.

源码列表尚未显示时也会继续读取后续分块；中途失败会显示错误及重试按钮。HTML/HTM 默认网页预览，可切换源码；支持内嵌样式、脚本和 data 图片。预览不访问网络/CDN、旁边文件、iframe、手机文件或应用接口，不触发下载或外部跳转。切换标签保留预览状态，关闭或重新加载时销毁。

Image and video RPCs require `binaryVersion=1` and return a scoped Binary transfer profile. Missing or unsupported versions fail closed; inline base64 image responses and text-chunk video transfers are removed. Markdown and source-text pagination remain supported.

图片与视频 RPC 必须携带 `binaryVersion=1`，只返回限定作用域的 Binary 传输描述；缺失或不支持的版本直接拒绝。已移除 base64 图片响应和文本分块视频传输；Markdown 与源码文本分页保留。

## Boundaries / 边界

The provider validates the authorized device, selected session and view version before capturing the request. The Mac derives cwd and turn data itself. File reads use descriptor checks and reject symlink escapes. UTF-8 files are limited to 2 MiB; each directory returns up to 200 visible entries, searches up to 100 results, and diffs up to 128 KiB. Hidden dotfiles are omitted. Large, binary and unreadable files have explicit states.

Filesystem reads retain VibePier's bounded asynchronous workers and deadlines; Markdown/text snapshots are invalidated on session close. Git ignores external diff/textconv helpers, hooks and fsmonitor. Opening on Mac is a separate device action: executable permissions, executable/container types and known launching handlers are refused; Finder reveal remains available. A successful open request reports dispatch, not proof that the user saw the document.

权限由 Mac 会话状态决定，不采用手机传入的 cwd 或引用白名单；目录/读取拒绝符号链接越界。文件上限 2 MiB、目录 200 项、搜索 100 项、diff 128 KiB。保留异步读取和超时、会话切换失效、加密最近记录。可执行文件或可能运行代码的默认打开方式被拒绝，可改为访达显示。

## Implementation and validation / 实现与验证

- Mac: `Providers/Shared/SessionProjectFiles.swift`, `SessionMarkdownFiles.swift`, the Codex and Claude provider bridges.
- Android: `features/files`, `ConversationPanel`, `ConversationMessageRenderer`, Markdown links and session read cancellation.
- Protocol additions: `fileChanges`, `readFile`, `readImageFile`, `fileDiff`, `searchFiles`, `openFile`; `browseFiles` gains root, branch, size and status fields. No relay format change.
- Tests: temporary-repository Git state/diff/search, missing/deleted paths, symlink escape, binary/oversized files, executable refusal, invalidated queued reads and bridge authorization; JVM tests cover file links, diff rows, syntax tokens and draft quoting.
- Emulator review uses the `files` fixture in the isolated `.review` build. Fixtures never enter the production source set. UI screenshots demonstrate the native views with synthetic content; they do not prove a live provider edited those files.
