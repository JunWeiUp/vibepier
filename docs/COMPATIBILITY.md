# Compatibility and provider capabilities / 兼容性与会话能力

This describes the checked-in adapters, not a guarantee that every listed desktop version has passed every real-device workflow. Availability is checked again at runtime. The final release acceptance work remains in [TODO.md](../TODO.md).

## Platforms

| Component | Current target | Evidence and limits |
| --- | --- | --- |
| Mac app / CLI | macOS 14+, Apple silicon release package | SwiftPM declares macOS 14. The release scripts package arm64; Intel distribution is not currently validated. |
| Android | Android 13 / API 33 minimum; compile/target API 35 | Source declares these levels. Minimum-API, large-type and screen-reader acceptance must be tested separately; see [Lint decisions](ANDROID-LINT.md). |
| Relay | Linux amd64 or arm64, systemd service behind HTTPS | Standard-library Go module; source build needs Go 1.22+. Public clients use WSS. |
| AU05 | Optional Ulanzi Vibe Key AU05 | Phone controls do not depend on the hardware being present. Firmware behavior is not inferred from a USB acknowledgment alone. |

## Provider matrix

**Conditional** means the Mac verifies the interface, session identity and current state before performing the operation. It does not mean “always available.”

| Capability | Codex desktop | Claude Code sessions | ZCode desktop |
| --- | --- | --- | --- |
| List projects/sessions | Yes, local index | Yes, local transcripts | Yes, read-only native storage |
| Read conversation / history / images | Compatible desktop subscription | Local transcript plus desktop state where available | Native history; supported local image references |
| Reply | Conditional, original desktop owner | Conditional; desktop delivery, or CLI resume if no live owner/desktop is available | Conditional; text only, verified original session |
| Start a session | Conditional, configured creation on builds 12553/12947; saved single-root project with a unique name; live creation acceptance pending | Known project; first turn through installed `claude` CLI | Conditional native workspace flow; only the supported built-in provider configuration |
| Attach files/images | Yes, within selected session and size limits | New-session images use vision blocks; other files and existing-session attachments use file references | No |
| Approval / questions | Recognized native requests and supported asynchronous questions | Recognized desktop requests; ambiguous/multiple pending requests refused | No |
| Queue / steer / delete queued message | Supported native follow-up queue | No equivalent queue controls | No |
| Model / effort / permission settings | Available choices from adapter | Desktop menus or subsequent phone-launched CLI requests | Verified native menus; supported choices only |
| Interrupt | Exact active-turn identity | Owned CLI run or verified busy desktop session | Exact observed active turn |
| Context usage | Only when desktop supplies it | Accurate value only for a supported open desktop session | Unavailable |
| Markdown / workspace browsing | Scoped to the open, trusted session | Scoped to the open, trusted session | Scoped to the open, trusted session |

Lock/unlock, phone-side selection of installed Mac app shortcuts and phone APK delivery are shared Mac features, not provider-specific capabilities.

## Codex

The current source allowlist is desktop build **11645, 12404, 12553 or 12947** (`CFBundleVersion`). An unknown build is rejected for opening/control; merely seeing its local list does not prove compatibility. The adapter uses versioned desktop IPC, validates the original thread owner and supports only recognized request shapes. A provider update requires protocol inspection and delivery/receipt tests before changing the allowlist.

Once an IPC mutation reaches the socket write boundary, a timeout, disconnect, handler error or malformed response is an unknown outcome, regardless of diagnostic language. Successful replies must match the request method and selected owner. Sending requires a native turn ID, interrupting requires the original turn ID, and approvals, settings and queue changes require their native acknowledgment fields. An explicit conditional settings rejection remains a rejection. No automatic resend is performed.

Build **12947** was checked against the installed desktop archive: coordination method versions and the nine mutation-handler request/receipt branches used here match 12553. A live read-only IPC probe passed initialize, owner discovery and a version-11 conversation snapshot from the matching owner. Existing IPC receipt tests cover malformed/wrong-owner/timeout responses; no live message was sent by this compatibility check. The new-session allowlist remains separate.

Legacy deep-link/AX new-session creation has a separate contract currently inspected for **build 12553**. A deep link explicitly selects the native project ID, directory and Codex mode and only prefills the first plain-text message. The adapter requires one focused composer with the complete expected body, the expected project selector and a unique enabled native Send button; it rechecks those element identities before one accessibility action. Known worktree instruction controls are refused for a request targeting the existing directory. There are no timed Return presses or alternate submission fallbacks. Duplicate project names, multi-root projects, unrecognized native labels/schemas and other builds are not treated as verified creation targets.

Success requires a thread ID absent from the pre-open index snapshot, the requested directory and complete first-message text in the native index, and the corresponding first `user.text` rollout record with its message ID and original turn ID. Injected context records, a matching title/timestamp, a moved old thread, a later matching message or an ambiguous simultaneous creation cannot confirm success. After opening or attempting submission, failures remain unknown and are not automatically resent. These policy/receipt checks have synthetic regression coverage; **actual new-composer accessibility recognition and native creation are still release-acceptance requirements**, not claimed as passed here. The current selectors recognize the provider's English and Simplified Chinese labels.

All providers share a receipt validator before durable completion: malformed or oversized replies, mismatched session identities, missing acknowledgments and contradictory unknown/success flags cannot finish a mutation reservation. Lock/unlock success also requires the requested resulting lock state. Receipt lookups must match the original session; an unresolved result stays unresolved across restart.

The names refer to the Codex desktop application. They do not imply support for every CLI, cloud-hosted conversation or independent app using a similar name.

### Codex account usage and gifted resets / Codex 账户用量与重置卡

The session-list menu exposes **Codex usage** independently of the selected session/provider. A short-lived, account-only `codex app-server` connection reads `account/rateLimits/read`; it never starts a thread. The local bundled CLI 0.159.2 read path is verified. Prefer the multi-bucket response; missing windows/counts remain unavailable. The device displays local-time reset/expiry dates and the authoritative available-card count even if detail rows are capped.

Selecting a specific available card and confirming sends `account/rateLimitResetCredit/consume` with that card ID and one stable, device/account/operation-scoped idempotency key. The Mac re-reads usage, checks the account/card and a five-hour or weekly window at 10% or less remaining. Unknown/expired cards, changed accounts, missing details and missing confirmation are refused. A transport timeout never triggers a second redemption. The phone retains uncertain operations and offers receipt checks; unresolved native outcomes require checking on the Mac before using another card. Reset success is retained even if the following usage refresh fails. This feature does not purchase credits or change provider sessions.

会话列表菜单中的 **Codex 使用情况** 显示当前 Mac 账户的剩余额度、额度重置时间、赠送卡数量及到期时间，与具体会话无关。点击卡片后须确认使用一张，Mac 再次检查账户、卡片状态与可重置额度。超时保留原操作，禁止自动重发或改用另一张卡；可检查回执，仍未知时先在 Mac 核对。只有数量而无卡片详情时需先刷新，不盲目代选。开发测试采用模拟兑换结果，不消费真实赠送卡。

Protocol reference: [OpenAI app-server account methods](https://learn.chatgpt.com/docs/app-server). Availability and outcomes are determined by the signed-in account and service response.

## Claude Code

History is read from the Mac's local Claude Code transcripts. If a live terminal owns a session, phone sending is refused to avoid forking that session. A verified desktop owner receives the message through the desktop adapter. With no owner, a running supported desktop may adopt the session; otherwise the installed `claude` CLI can resume it. Creating a session requires that CLI and a known project; the first turn runs headlessly and can later be adopted by the desktop.

Desktop controls require Accessibility and exact host/session matching. Only a single recognized, actionable pending desktop approval/question can be answered. Unsupported cards, stale requests and ambiguous windows require handling on the Mac. There is no blanket desktop-version promise for this accessibility-based integration. Sending requires exact host matching, the full composer body and a new native transcript receipt. Approvals/questions use one verified click, recheck the original request, and require a matching native `once`/`deny` acknowledgment; cancellation, log rotation or absence alone do not prove an answer. Unknown results remain unresolved for inspection on the Mac.

Claude sending also requires a unique enabled text area and verified input focus in the original window immediately before paste and submission. Sidebar link matching uses the exact session route; ambiguous targets are refused. Revise/navigation selects one input method with no retry click or Escape fallback. Menu cleanup uses an advertised native cancellation action only, because Escape can stop a task. These source safeguards still require acceptance against the actual supported desktop UI.

Headless Claude output must provide one valid terminal result and reach EOF on both pipes. A line beyond 8 MiB, malformed or missing terminal output, or incomplete pipe shutdown is reported as unverified output rather than successful completion. This diagnostic does not retry the submitted prompt. The history and native session remain the authority for inspecting what ran.

## ZCode

Configured creation reads the native model, reasoning and permission choices for the current phone/project/draft. Before the first message, it revalidates menu identity and selection, requires explicit full-access confirmation, and refuses changed or ambiguous native controls. These checks have synthetic coverage; actual native creation acceptance remains pending. Creation attachments are unsupported.

新建配置读取原生模型、推理和权限菜单，按手机、项目和草稿绑定；首条发送前重新核对菜单及选中项，完全访问须明确确认。选项变化或控件不确定时拒绝执行。已有隔离测试，真实原生新建仍待验收；新建附件暂不支持。

The adapter reads native session storage without modifying it. Mutations use the running `dev.zcode.app` desktop, Accessibility, original session-ID verification and native menus. It will not overwrite an existing composer draft. Attachments, approvals, queues and context-capacity reporting are disabled. New-session support additionally requires the configured built-in agent-provider list to be exactly the supported native `glm` provider; mixed providers are refused.

Permission changes require the recognized native labels `计划模式`, `变更前确认`, `自动编辑`, and `完全访问`. Unknown, duplicate or unsupported-language permission options are refused instead of receiving opaque IDs; full access always retains its explicit confirmation requirement. The VibePier interface language can still be English or Chinese. This restriction concerns the provider’s own permission menu and does not claim support for unverified translations.

For ZCode creation, the existing-ID snapshot covers all projects and archived tasks; it refuses an incomplete or over-limit baseline instead of truncating it. Confirmation requires the requested directory and full first eligible human message. Existing-session sends use the first human message after the original anchor; a later same-text message cannot confirm the submission. Receipt text is limited to 120,000 UTF-8 bytes and 64 text parts. Raw JSON for those parts is capped at 2 MiB and decoded outside SQLite so older system SQLite versions cannot truncate embedded NUL characters. These are receipt-integrity limits, not an extension of the phone's existing 32 KB send limit.

## Uncertain and delayed results

Provider mutation caches bind the trusted phone identity to the original operation and request fingerprint. They do not borrow a success from another phone, session, operation kind or approval. A repeated unknown request is never executed again. Completed response bodies may be retired under memory pressure, while operation markers remain; a retired result is unknown, not permission to resend.

A creation timeout can be checked without another submission. Within the same Mac process, Codex/Claude retain bounded, read-only native observers after confirmed submission; ZCode retains its original submission proof. The returned new thread ID and directory survive the phone's receipt query. Missing/ambiguous native evidence stays unknown. Restart can discard provider-local evidence, but the durable journal still retains the unresolved operation and prevents automatic replay. Check the native app before deciding what to do next.

## When an adapter stops working

Keep the provider build/version, VibePier version and a sanitized reproduction. Do not bypass compatibility checks, manually edit provider databases, or retry an uncertain send as a new message. Review the result on the Mac and report it using [CONTRIBUTING.md](../CONTRIBUTING.md).

Source authorities: [CodexBridge](../apps/macos/Sources/VibePierCore/Providers/Codex/CodexBridge.swift), [ClaudeBridge](../apps/macos/Sources/VibePierCore/Providers/Claude/ClaudeBridge.swift), [ZCodeBridge](../apps/macos/Sources/VibePierCore/Providers/ZCode/ZCodeBridge.swift), [ZCodeDesktop](../apps/macos/Sources/VibePierCore/Providers/ZCode/ZCodeDesktop.swift).

## 中文能力表

| 能力 | Codex | Claude Code | ZCode |
| --- | --- | --- | --- |
| 列表、历史、图片、Markdown | 已接入，打开会话需兼容桌面版本 | 已接入本地记录与适配的桌面状态 | 已接入原生记录及受限本地图片 |
| 回复、新建、设置、停止 | 校验桌面构建、会话归属与任务身份后执行 | 区分桌面、终端与本机 CLI；终端占用时不旁路续写 | 校验原生会话及菜单；新建仅支持指定原生 provider 配置 |
| 附件 | 支持 | 新会话图片作为视觉内容发送；其他文件与已有会话附件作为文件引用 | 不支持 |
| 审批与问答 | 支持识别出的原生/异步请求 | 仅适配且无歧义的桌面请求 | 不支持 |
| 队列及引导 | 支持 | 不支持对应队列功能 | 不支持 |
| 上下文用量 | 桌面提供时显示 | 需适配的已打开桌面会话 | 不支持 |

Codex 当前源码仅允许构建号 11645、12404、12553、12947，不代表所有场景都完成了真机验收。Claude 不能对已有终端占用的会话另起进程续写；桌面发送以新增原生消息 ID 和完整正文确认，审批只提交一次并等待匹配的原生回答记录，未知结果不自动重发；ZCode 不直接修改数据库，也不覆盖已有草稿。ZCode 权限选项仅识别上述已适配的原生名称；未知、重复或未适配语言的权限模式拒绝在手机切换，完全访问保留明确确认。VibePier 自身仍支持中英文界面。平台最低版本声明、编译成功与实际设备验收必须分别记录。

Codex 操作开始写入桌面接口后，超时、断线、处理错误或无效回执均保留为“结果未知”，不再靠中英文错误文字推断。成功回复必须匹配请求方法及原桌面实例，并包含相应的原生消息、任务或操作确认；不会自动重发。所有服务商的回执还会统一校验会话身份、确认字段及传输大小，缺失或矛盾的回复不能把持久记录标成完成。锁屏/解锁需确认目标屏幕状态，查回执需匹配原会话，重启不清除未知操作。

Codex 旧深链/AX 新建采用单独的版本约束，目前按构建 12553 的原生接口实现。目标须为已保存、单根目录且名称唯一的本地项目；核对完整正文、项目及唯一可用的原生发送按钮后，只尝试一次。已移除定时重复 Return，也不会改用其他提交方式。成功需新会话 ID、准确目录、完整首条正文及原生消息/turn ID 一起确认；上下文注入、标题/时间接近、移动旧会话或并发同文新建都不能代替该回执。原生中英文控件的实际识别与真实新建流程仍待现场验收，不能用隔离测试代替。

Claude 粘贴和提交前均核对原窗口、唯一可用文本区及实际焦点。原生点击先选定一种方式，辅助功能失败或回执延迟后不补发第二次点击；关闭菜单不再发送可能触发“停止”的 Escape。鼠标按下后即使失焦也会释放；用户中途新复制的剪贴板内容会保留。这些属于源码保护，实际原生界面仍须单独验收。

ZCode 新建前记录所有项目及归档任务的 ID，确认时检查目标目录和完整首条有效用户消息；已有会话发送则检查原锚点后的第一条用户消息，不能用后续同文消息代替回执。原生回执缓存按服务端传入的已验证手机身份隔离，手机自报身份不能覆盖。

服务商回执按可信手机身份、原操作 ID、请求指纹和会话保存，不能借用另一台手机或另一项审批的成功结果。未确认操作不因缓存满而淘汰；已完成正文退役也保留操作标记，不允许重执行。新建超时后可以只读查询原生首条消息，保留新会话 ID 和目录；进程重启后若缺失原生核验依据，仍保持未知，不能据此自动重发。

Conversation image previews run outside provider queues with bounded concurrency and a six-second response deadline. A macOS folder-permission prompt can leave an individual image unavailable until approved locally; it must not stall session lists, text, or replies.

Native accessibility traversal bounds child retrieval, queued nodes and total time. An unreadable or truncated scope provides no control candidates, so a partial tree cannot establish a unique composer or action. Claude route discovery examines top-level web areas without traversing their transcript content. These checks complement, rather than replace, the supported native-version and action/receipt contracts.

Claude headless first turns and CLI continuations admit at most four concurrent processes per phone and eight across all phones. If full, the Mac reports capacity without launching another process. Opening a creation receipt or disconnecting a phone does not free a running process slot.

Claude 无界面首轮及 CLI 续写最多同时运行每台手机 4 个、所有手机合计 8 个进程。达到上限时，Mac 返回容量提示且不启动新进程；取得创建回执或手机断线不会提前释放仍在运行的进程名额。

### New-session image input

Claude creation uses the installed CLI's `--input-format stream-json` with one user message containing text and image blocks, as described in the [official streaming input documentation](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode). Uploaded images are validated and, when needed, resized to at most 2048 pixels and 512 KiB each; the maximum is six attachments. Non-image files retain managed local references. Native confirmation compares the first human message's full text and every image digest, along with session ID and project directory. The subprocess stdin writer is asynchronous, bounded to ten seconds, and cannot block the provider queue if the child stops reading. Pending input bytes count against 8 MiB per phone / 16 MiB globally while the existing four/eight process limits remain. Synthetic upload, process-input and native-transcript fixtures are verified; actual provider acceptance is still required before release.

Claude 新建会话将文字与图片一起作为首条原生消息提交，图片按需压缩到最长边 2048 像素、每张最多 512 KiB；其他文件继续使用受管理的本地引用。回执须匹配首条人类消息的完整正文、全部图片摘要、会话和项目，不能仅凭相同文字确认图片已送达。标准输入采用异步写入和 10 秒期限，保留进程数及输入内存限制。隔离测试不替代实际原生应用验收。

构建 **12947** 已核对本机桌面协议版本及九个操作处理分支，与 12553 保持一致；实际只读 IPC 握手、会话归属发现及 v11 状态订阅通过。此次未向真实会话发送测试消息，新建会话仍使用单独的版本限制。

Claude transcript API errors are shown as localized notices, with retries coalesced within each turn and raw gateway details omitted. HTTP 429 means the upstream account rate limit delayed a reply; a successful creation receipt only confirms the session and first message, not a completed model reply. No automatic resend is added.

Claude 会话中的 API 错误会显示为本地化提示，同一轮重试合并展示，不转发网关原始错误。HTTP 429 表示上游账户限流阻碍了回复；创建成功回执仅确认会话和首条消息，不代表模型已完成回复。此提示不会自动重发。

Android shows a persistent waiting banner for provider API/rate-limit errors, approvals, disconnected or unconfirmed requests, and active turns without visible progress for 60 seconds. Silence is a warning, not proof of failure. “Cancel current task” uses the existing verified turn-specific interrupt operation; a draft does not hide it. Without a fresh cancellable turn, “Stop waiting” only leaves the view, retaining drafts and unresolved receipts. It does not claim to stop an offline Mac or undo an unconfirmed creation. Claude API blockers clear on subsequent native assistant progress, a new prompt, or an interrupt marker; history retains the original failure.

安卓会持续提示服务商 API/限流错误、等待审批、连接中断、结果待确认，以及运行中超过 60 秒没有可见进展的情况；没有新进展不等于任务已失败。“取消当前任务”复用校验当前轮次的停止操作，有草稿也可使用。无法确认可停止的轮次时，“停止等待”仅退出页面并保留草稿与未知回执，不宣称已经停止离线 Mac 或撤销待确认的新建请求。Claude 的当前 API 阻塞提示在原生回复继续、新提示词或中断标记出现后清除，历史错误保留。

### Configured creation on build 12947 / 构建 12947 配置式新建

The phone's `newOptions` and configured `new` flow support builds **12553 and 12947**. Build 12947's bundled CLI JSON schema was checked for `thread/start` project, settings and response fields; its desktop v2 start-turn and v11 snapshot contracts were already inspected. This flow creates an empty thread and verifies its project/settings. Before closing the bootstrap process, it names that exact thread, archives it to flush the native rollout, and restores it with identity/project/empty-history checks; only then can the desktop resume it and submit once through the verified owner. Native `thread/start` alone does not persist an empty rollout. An isolated native CLI restart/resume probe covers persistence without submitting a model turn. The legacy deep-link/AX composer path retains its separate 12553 restriction. Injected tests do not substitute for a live phone-to-desktop creation check.

手机的 `newOptions` 和配置式 `new` 支持构建 **12553、12947**。已核对 12947 内置 CLI 的 `thread/start` 项目、配置及返回字段，以及先前检查的桌面 v2 首轮提交和 v11 快照协议。此路径先创建空会话并核验项目/配置，在关闭引导进程前对该新会话设置名称、归档以写入原生历史、恢复并核对会话身份/项目/空历史，随后才交由桌面 owner 提交一次；原生 `thread/start` 本身不会保存空会话的完整历史。隔离原生 CLI 的重启恢复测试覆盖持久化，未提交模型轮次；旧深链/AX 输入框路径仍单独限制为 12553。隔离测试不能替代手机到桌面的真实新建验收。

Codex list/activity discovery includes the `vibepier` originator used by configured phone-created threads, while retaining archive, subagent and other-origin filters. 手机创建的 Codex 会话纳入列表与活动检测；旧 AX 创建回执的来源校验保持独立。
