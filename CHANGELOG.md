# Changelog / 更新记录

## Unreleased — builds 11–21 / 未发布构建 11–21

- Edit phone key names together with shortcuts on Android or macOS; names sync, inherit per application and are included in settings export/import. Android 与 macOS 支持同时编辑手机按键名称和快捷键，名称随配置同步、按应用继承，并纳入设置导出/导入。
- Preview workspace MP4 links and embeds from Claude Code/Codex conversations on the phone with play/pause/seek, bounded encrypted downloads and temporary-file cleanup (128 MiB maximum; H.264/AAC tested on an emulator). 手机可直接预览 Claude Code/Codex 会话中项目目录内的 MP4 链接与媒体嵌入，支持播放/暂停/拖动、有界加密下载和临时文件清理（最大 128 MiB，模拟器验证 H.264/AAC）。
- Add an independent pinned HTTPS file helper and streaming self-hosted relay for attachments/APKs, retaining device capabilities, digest verification and cancellation. 新增独立固定证书 HTTPS 文件助手及自建中继流式附件/APK传输，保留设备授权、摘要校验与取消。
- Preserve conversation scroll anchors when prepending history and partial replies. 加载历史及早期回复片段时保留滚动锚点。

- Tapping a discovered Android update requests the registered APK immediately, without another Mac send action; phone system installation confirmation remains required. 手机点击“发现新版本”直接申请下发已登记 APK，无需在 Mac 再点发送；保留手机系统安装确认。
- Fix microphone-path cleanup and authorization-bound activity/attachment recovery.
- Clarify stop/queue/wait actions, reconcile conversation views, preserve focused settings and open the notified provider.
- Prepare APKs on bounded workers; expose installation stages and request registered updates from an authorized phone.
- Index Claude history, bound cached bodies, retain old message/image access and late native receipt evidence.
- Correct restore-defaults feedback and unique online-device counts; add redacted connection diagnostics.
- Bound aggregate relay output and publish immutable build-scoped source/digest metadata.

修正录音通路、授权绑定的页面与附件恢复、停止/排队/等待语义；会话局部重用、设置焦点和通知入口保持稳定。Mac APK 采用有界工作器与明确安装阶段，手机可申请已登记更新。Claude 历史按索引读取并保留旧消息/图片/迟到回执；恢复默认与在线设备计数准确。中继共享总发送额度，产物按构建号保留源码与摘要追溯。


## Local builds 9–10 / 本地构建

- Lowered the home voice control contents toward the center and persisted installation-toast deduplication independently of Mac receipt retries. 首页语音键内容整体下移，安装结果提示持久去重，不再随 Mac 回执重试重复弹出。
- Accelerated negotiated relay APK downloads with larger fragments, a bounded four-chunk window, durable progress and speed/ETA display; retained legacy/BLE behavior and installation verification. 云中继 APK 下发支持大分片、四块并发、连续落盘进度及速度提示，保留旧端兼容和安装校验。

## 0.1.0-beta.1 — first public preview

The first public preview ships the applications, CLI, relay and source on `main`, with one consolidated initial commit. Android and Mac package build: **8**. Real first-message acceptance was explicitly skipped; this release does not claim that every native-provider/device flow is verified. See [release notes](https://github.com/JunWeiUp/vibepier/releases/tag/v0.1.0-beta.1) and [remaining work](TODO.md).

- Added HTML/HTM preview alongside source, including embedded styles and interactions in an isolated offline renderer; Android build 6. 新增 HTML/HTM 网页预览与源码切换，支持内嵌样式和交互，构建号升至 6。
- Added settings version/build display, authenticated installed-version reporting, Mac registered APK updates and new-version dots. 新增设置底部版本号、手机版本上报与 Mac 新版 APK 红点提醒；交付构建号递增至 5。
- Include VibePier-created Codex threads in phone lists while retaining origin/subagent/archive filters. 修复手机创建的 Codex 会话因来源筛选而在列表中不可见。
- Fixed Android file previews stalling after the first chunk and hiding errors after partial reads. 修复手机文件读取停在首个分块，以及中途失败仍显示加载中的问题。
- Persist newly created Codex empty threads through native naming/archive/restore before closing the bootstrap process, preventing desktop handoff from losing the thread. 修复 Codex 空会话未落盘便关闭引导进程，导致手机新建停在待确认的问题；仅处理本次新建且已核验的空会话。
- Enabled Codex configured session creation on desktop build 12947 after checking the bundled thread/start schema; retained independent legacy AX restrictions and unknown-result protection. 修复 12947 手机配置式新建被旧版本白名单拦截，保留独立 AX 限制与未知回执保护。
- Added Android task completion notifications over the authorized encrypted connection, with background reception, permission settings and deduplication. 安卓新增任务完成通知，支持后台接收、权限入口及去重。
- Added an Android settings language picker (system / Simplified Chinese / English), persisted by Android and synchronized with system app-language settings. 安卓设置新增语言切换，立即生效并保留选择。
- Added persistent Android waiting diagnostics and an explicit cancel action for verified active turns; leaving an unconfirmed wait preserves its receipt and draft. 安卓持续提示阻塞原因并支持手动取消当前任务，退出未知等待仍保留回执和草稿。
- Show Claude API failures and HTTP 429 account limits in phone conversation history, coalescing retries without exposing raw gateway errors or resending prompts. 手机会话显示 Claude API 错误和账户限流原因，避免误以为新建会话卡死。
- Moved voice captions inside the circular control and isolated voice/Delete from shortcut scrolling; retained a fixed 140×48dp Delete target and large-text wrapping. 首页语音提示移入圆内，语音与删除固定可见。
- Added Codex desktop build 12947 to the existing-session compatibility list after packaged protocol/handler comparison and live read-only subscription validation; new-session compatibility remains separate. 已适配 12947 的现有会话，新建版本限制独立保留。
- Added the session project-file browser with tree/search/recent views, turn-change badges/cards, source/diff/previews and draft quoting; retained asynchronous reads, session isolation and encrypted recent paths. 项目文件浏览已移植，支持本轮改动、源码/diff 和文件引用。
- Set Android 13 (API 33) as the minimum supported OS; CI targets API 33/35/36, with no Android 8–12 compatibility requirement.
- Introduced the VibePier identity, native app icons, graphite/mint design, original illustrations, English/Chinese README, and self-hosted relay deployment guide.
- Organized the repository into macOS, Android, relay, protocol, assets, scripts and documentation, with independently owned runtime, voice, navigation and conversation components.
- Added approved-device enrollment, authenticated encrypted control transport, per-phone routing, secure credential/cache storage, and explicit relay DNS recovery.
- Added signed protocol/capability negotiation, per-device handshake limits, incompatibility notices and immediate trust-change cleanup. The new handshake requires a coordinated Mac/phone update from earlier development builds.
- Hardened relay admission/framing and phone write queues, restricted transport diagnostics to fixed categories, validated complete shortcuts before input, and preserved unresolved microphone recovery records.
- Limited live Claude CLI children per phone and globally, retaining capacity until actual process exit.
- Bounded Claude CLI output, retained final pipe data before reporting completion, and added explicit minimum/target Android API workflows on disposable emulators.
- Scoped provider mutation caches to the trusted phone and original request, retained operation identities under memory pressure, and added read-only late-creation reconciliation with native first-message evidence. Approval queries now require their original submitted fingerprint.
- Removed uncertain native-click fallbacks, guaranteed mouse release after a posted press, and preserved newer user clipboard contents. Tightened Claude focus/session controls and ZCode complete first/next-message receipts and per-phone native receipt keys.
- Bounded local control socket framing, deadlines and concurrency; protected existing listeners/files during startup/stop. Added per-phone session assembly quotas, absolute expiry and bounded replay retention.
- Hardened Android reply assembly, strict receipt matching and bounded request storage. Unknown work survives malformed replies; password verification never auto-retries, and late creation receipts retain their native session ID.
- Moved the shared mutation journal into security infrastructure, added byte/record budgets and private atomic persistence, retained retired operation IDs, and bounded Mac request/event/reply work. A failed result write remains unknown.
- Preserved supported Codex, Claude Code and ZCode session workflows with provider-specific compatibility and capability checks.
- Replaced Codex creation's repeated Return/first-recent-thread heuristic with one guarded native Send and an exact first-message receipt. Build 12553's native UI acceptance remains pending; other creation layouts/builds are refused.
- Added account-wide Codex remaining quota/reset times and gifted reset cards to the session menu, with explicit confirmation, fresh account/card checks and durable uncertain receipts.
- Scoped native Codex message IDs to the phone/session and snapshot selected workspace attachments before provider submission.
- Added session-menu Lock/Unlock controls, portable non-sensitive settings, background phone connection ownership, and reproducible build/release scripts.
- Added phone-side installed Mac application selection, shared dock updates and stale-edit protection.
- Added phone new-session model/reasoning/approval controls, scoped drafts and uploads, explicit full-access confirmation, and receipt-safe draft cleanup. Claude first turns accept bounded inline images; ZCode creation attachments remain unsupported. Real native first-turn acceptance is recorded separately.
- Enforced provider admission deadlines directly even when timer callbacks are delayed, without cancelling or resending running mutations.
- Simplified default device validation to one API 35 emulator and seven core probes; full compatibility suites remain manually selectable. Recorded the remaining full-history memory limitation in the release review.
- Isolated directory/Markdown reads with bounded asynchronous workers and deadlines; partitioned RPC capacity by provider and reserved receipt lanes to prevent cross-provider starvation. Added read-only late Claude send reconciliation.
- Isolated image reads/decoding from session queues with bounded workers and single-result deadlines, preventing a file permission wait from blocking conversations.
- Bounded native accessibility child retrieval and complete-scope validation; added native read-only window checks and Android minimum-API/large-payload/localized test coverage.
- Added platform tests, shared protocol fixtures, static checks and CI definitions. Real-device, clean-build and publication gates remain tracked separately.

首次公开预览版发布应用、CLI、中继和 main 分支源码，保留一个初始提交，安装包构建号为 8。本次明确跳过真实首条发送验收，不把构建或模拟测试视为完整真机验收。主要变化包括新品牌与中英文 README、按平台/功能组织目录、授权加密连接与安全存储、按来源适配会话、锁屏/解锁、设置迁移、后台连接及构建验证流程。

Android 最低要求调整为 Android 13（API 33），CI 覆盖 API 33/35/36，不再适配 Android 8–12。

连接握手已加入签名版本/功能协商、单设备容量限制及不兼容提示；撤销授权会及时清理对应连接的控制状态。此前开发版本升级时，Mac 与手机需要一起更新。

中继握手/分片和手机发送队列增加边界校验，连接日志改用固定分类；无效组合键不会留下部分按键，麦克风恢复记录未解决前禁止覆盖。

Claude CLI 后台进程增加每台手机 4 个、合计 8 个的并发上限；仅在进程实际退出后释放名额，启动失败及时释放。

本机控制 socket 增加读写大小、总期限与并发限制，并保护已有监听实例/文件；Mac 会话分片增加每台手机配额、固定过期时间及有界重放记录。

Android 回复分片与回执匹配增加严格校验，待处理请求和回执存储有明确上限；错误回复不会丢弃未知操作。密码验证不自动重试，新建会话的迟到回执保留原生会话 ID。

Mac 共享回执存储移入安全模块，增加字节与记录预算、原子持久化及过期操作标记；异步请求、事件和回复缓存按设备限额，保存结果失败时保持未知状态。

手机新会话支持模型、推理和审批配置，保留按草稿隔离的附件、完全访问确认及迟到回执清理；Claude 首条消息支持图片，ZCode 新建附件仍不支持。真实原生首条发送验收单独记录。服务商入口直接核对截止时间，避免计时器延迟放行新请求；默认设备检查精简为单 API 35 的七项核心探针，超大 Claude 历史的内存限制作为未解决问题写入发布检查。

The consolidated initial repository preserves the upstream MIT copyright. See [NOTICE](NOTICE) and [provenance](docs/PROVENANCE.md).
