# Changelog / 更新记录

## Local build 35 / 本机构建 35

- Add a speed option to the phone model picker for supported Codex desktop sessions, including model/effort selection and a visible Fast indicator. Advertise tiers from the Mac model catalog and confirm updates through native readback; unknown receipts are never retried automatically.
- 手机端 Codex 模型菜单新增加速开关，选模型和推理强度后也能选择加速，开启后显示状态。可用选项来自 Mac 模型目录，原生回读确认后才显示成功；未知回执不自动重发。仅用于现有桌面会话的后续请求，加速可能增加用量。

## Local build 34 / 本机构建 34

- Accept phone actions from user intent instead of cached control availability. Standard Send resolves the current native start/queue behavior without comparing stale composer settings; explicit operation targets and permission confirmations remain exact. Recover menus through the same adapter, merge concurrent snapshot reads, and preserve control authority during content-only updates.
- 手机操作不再被旧控制缓存提前拒绝。普通发送按最新原生状态直接发送或入队，不比较旧模型/权限展示；明确选择的操作对象与权限确认保持绑定。设置菜单沿相同后端自动恢复，合并并发快照，正文增量不再撤销操作权限。

## Local build 33 / 本机构建 33

- Refresh verified control state automatically before a new send, interrupt, approval, queue change, session setting or creation. Keep the original task, approval and selected options; a changed target stops the action. Coalesce native dirty events during synchronization and recover missing same-view Codex state after disconnect. Unknown writes keep their original receipt and are never resent automatically.
- 发送、停止、审批、队列变更、会话设置和新建前自动核对操作状态，保留原任务、审批内容及已选选项；目标发生变化时停止操作。同步途中收到的新状态会继续补同步，Codex 断线后同一视图自动恢复读取；未知写入保留原回执，不自动重发。

## Local Mac build 32 / Mac 本机构建 32

- Keep history and reply-part reads available on the verified open session while native updates invalidate control snapshots; still reject reads from a closed or replaced view and revoke stale control leases. Codex fills missing or incomplete reply content from native history and reconciles previous partial replies through unique native items, including text items merged during projection.
- 原生更新使控制快照失效时，历史和回复片段仍沿已验证的当前会话读取；关闭或切换会话后拒绝旧读取，过期控制授权继续撤销。Codex 从原生历史补齐缺失或不完整的回复，仅通过同一会话内唯一原生消息识别旧部分回复，包括展示时被合并的文本片段。

## Local build 30 / 本机构建 30

- Pulling down at the top of a phone conversation checks for earlier messages directly, including after a cached history endpoint. Codex refreshes its native snapshot at that boundary and reads the verified snapshot before paging; automatic scrolling still stops at the confirmed endpoint.
- 手机会话顶部下拉直接重新检查更早消息，不再被缓存的历史终点挡住。Codex 在历史边界读取新原生快照，并使用核验后的快照分页；自动滚动加载仍在已确认终点停止。

- Keep the open menu panel's top edge fixed as task counts change; refresh its anchor on reopening. 修复 Mac 悬浮面板随会话任务数量增减上下移动，重新打开时按菜单图标当前位置定位。

## Local Android build 29 / Android 本机构建 29

- Android: “Stop waiting” now ends waiting in the chat or interrupts a verified current turn; retained unknown receipts no longer block different messages, while duplicate text/attachments remain protected.
- 安卓：“停止等待”现在留在聊天页结束等待或停止已核验轮次；保留未知回执供查询，允许不同新消息并防止重复发送原文或原附件。

## Local build 28 / 本机构建 28

- Open images in a full-screen viewer with pinch zoom, panning and double-tap zoom/reset; reset the view for each newly opened image. 图片尽量全屏预览，支持双指缩放、放大后拖动、双击放大及还原，每次打开新图片恢复完整画面。
- Reconcile Codex's native history revision before returning earlier messages to the phone, including when the desktop streams a patch instead of a full snapshot. 修复 Codex 下拉加载旧消息时，原生增量更新尚未处理便返回旧快照的时序问题。

## Local build 27 / 本机构建 27

- Accept an empty discovery search as the default unfiltered session/project list; retain strict identity and search-size/type validation. Fix host-wide read requests to include the required empty target object. 修复手机默认空搜索被 Mac 拒绝，导致列表同步及会话打开失败；保留身份和搜索边界校验，并补齐回执查询等读取的空目标对象。新增三服务商加密发现到打开/刷新回归。

## Local Mac build 26 / Mac 本机构建 26

- Show the running Mac app's version and build below the menu title and in the phone-settings sidebar. Mac 菜单标题下方与手机遥控设置侧栏底部显示当前应用版本及构建号，读取应用 Bundle 元数据。

## Local build 25 / 本机构建 25

- Coordinate the Mac/Android update for typed Agent control and native phone Plan / Execute options. 双端同步升级统一 Agent 会话协议与手机原生计划/执行选项；可选运行时默认关闭，实际原生效果验收单独记录。

## Unreleased — builds 11–21 / 未发布构建 11–21

- Add phone Plan / Execute controls for existing and new Codex/Claude Code sessions, native mode catalogs and verified configuration/first-turn receipts. Claude plan mode hides conflicting permission choices; complete native ExitPlanMode requests without extra permissions can be answered once. 已新增手机计划/执行模式及新建选项，原生核验设置与首轮；Claude 完整且无额外权限的计划审批支持单次决定。中英文模拟器及隔离测试已验证，真实原生效果验收单独记录。
- Implemented the development Agent Session profile 2, shared Swift/Kotlin operation manifest, capability-driven provider adapters and Android client with persistent unknown receipts. 已实现双端统一会话协议、能力协商与原回执恢复；新 Agent 写操作需双端同步升级。
- Added explicitly configured Codex App Server and Claude Code Mods prototype drivers with isolated state, native interface gates, bounded replay and single-use approval handling. 新后端默认关闭；Claude Mods 在原生证据验收前只读，普通 This Mac 不自动共享；尚未安装生产端。

- Retain the installed Mac bundle directory and signing identity during explicit local updates; show real file-access status and reopen repair guidance after an observed permission denial. 本机显式更新保留 Mac 应用目录与签名身份，权限页显示实际文件访问状态，读取被拒绝后重新显示修复引导。
- Task completion notifications open the exact conversation on Android, including cold launches, and reject routes from replaced Mac authorization identities. Android 任务完成通知点击直达对应会话，支持冷启动，并拒绝已切换 Mac 授权身份的旧通知跳转。
- Transfer conversation/project images and MP4s through the same raw binary HTTPS channel as attachments/APKs, with concurrent LAN/public-IPv6/relay probes, full hashes and no production encrypted-body fallback. 会话/项目图片及MP4统一使用图片上传/APK的二进制HTTPS通道，并行探测局域网/公网IPv6/中继，验证完整摘要，正式版不回退加密正文分块。
- End cancelled or timed-out phone image reads with a retry action, preserve the visible thumbnail while opening a large image, and isolate late replies from new requests. 手机图片请求取消或超时后提供重试，打开大图时保留当前缩略图，迟到回包不干扰新请求。
- On first installed Mac launch, guide Full Disk Access setup and open System Settings; retain a menu-bar permissions entry and explain manual authorization/restart. Mac 安装版首次启动默认引导完全磁盘访问并打开系统设置，菜单栏保留权限入口，明确手动授权与重启。
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

MP4 preview fix: inline-code video paths now provide playback links; missing relative paths with a repeated workspace suffix resolve inside the same workspace. 修复会话反引号 MP4 路径没有播放入口；重复项目目录前缀的缺失路径仅在当前项目内纠正。

### Phone assistant visibility / 手机助手可见范围

- Added a Mac assistant switch card and authenticated provider policy synchronization. Disabled providers disappear from the updated phone UI and reject fresh requests; existing tasks, drafts and uncertain receipts remain intact.
- Mac 新增助手开关，授权通道同步手机可见范围；关闭后的新请求被拒绝，桌面任务、草稿和未知回执保留。
