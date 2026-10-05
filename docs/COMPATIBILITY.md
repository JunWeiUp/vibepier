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

| Capability | Codex sessions | Claude Code sessions | ZCode desktop |
| --- | --- | --- | --- |
| List projects/sessions | Yes, local index | Yes, local transcripts | Yes, read-only native storage |
| Read conversation / history / images | Compatible desktop subscription or registered owned App Server thread | Local transcript plus desktop state where available | Native history; local images and session-owned artifact attachments |
| Reply | Conditional, original desktop owner or connected owned App Server thread; background send requires idle | Conditional; desktop delivery, or CLI resume if no live owner/desktop is available | Conditional; text only, verified original session |
| Start a session | Configured background App Server using the Mac's existing account and a verified project; no screen unlock or desktop takeover | Known project; first turn through installed `claude` CLI | Conditional native workspace flow; only the supported built-in provider configuration |
| Attach files/images | Yes, within selected session and size limits | New-session images use vision blocks; other files and existing-session attachments use file references | No |
| Approval / questions | Recognized native requests and supported asynchronous questions | Recognized desktop requests; ambiguous/multiple pending requests refused | No |
| Queue / steer / delete queued message | Compatible desktop threads only; unavailable on owned background threads | No equivalent queue controls | No |
| Model / effort / permission settings | Available choices from adapter | Desktop menus or subsequent phone-launched CLI requests | Verified native menus; supported choices only |
| Phone Plan / Execute | Verified native collaboration catalog and mode evidence; runtime-verified desktop or owned App Server; independent permissions | Native plan permission mode; verified desktop settings and headless first-turn creation | Independent native plan checkbox and permission radio choices; permissions are preserved |
| Interrupt | Exact active-turn identity | Owned CLI run or verified busy desktop session | Exact observed active turn |
| Context usage | Only when the selected native backend supplies it | Accurate value only for a supported open desktop session | Unavailable |
| Markdown / workspace browsing | Scoped to the open, trusted session | Scoped to the open, trusted session | Scoped to the open, trusted session |

Lock/unlock, phone-side selection of installed Mac app shortcuts and phone APK delivery are shared Mac features, not provider-specific capabilities.

## Phone plan mode / 手机计划模式

The source adds **Task mode → Plan / Execute** beside the phone composer and in new-session options. An available `executionMode` capability and a complete native `executionModes` catalog are required. Changing an existing session requires a verified idle owner; an active turn is not switched mid-flight. These controls have English/Chinese emulator coverage with a synthetic encrypted Mac endpoint. Native desktop acceptance and production installation are still separate requirements.

ZCode execution catalogs include the required nonempty `name` for every `id`; the phone rejects incomplete catalogs. New-session option reads retry transient native readiness failures at most twice within the same visible, authorized draft. After persistent failure, Start reloads options even with an empty message; no creation or send is retried automatically.

ZCode 执行目录的每个 `id` 都需提供非空 `name`，手机严格拒绝不完整目录。新会话选项遇到原生状态暂不可用时，在同一可见、已授权草稿范围内最多追加两次只读重试；持续失败可点「开始」重载，空消息也可重载。不会自动重复创建或发送。

Codex desktop sessions use the packaged native `collaborationMode/list` catalog and owner-bound thread settings. The default owned background App Server path uses its reviewed bundled **0.160.0** stable/experimental schemas and native collaboration choices. The setter acknowledgment is insufficient: settings require native readback, and creation requires the requested mode on the exact initial native turn; incomplete evidence remains unknown. Permissions remain independent. The separate optional managed App Server backend supports future-turn mode settings only on its reviewed **0.159.0** experimental contract, with matching `thread/settings/updated` evidence. Desktop build numbers do not gate these options; malformed or missing native choices remain unavailable.

Claude Code maps Plan to native `permissionMode: plan`. The phone hides the separate permission selector while Plan is selected. Returning to Execute uses the advertised safe default unless a nonplan permission was explicitly chosen; it does not restore full access automatically. Existing desktop settings require actual native selection readback. Saving settings for a future headless CLI launch does not establish this capability. Plan creation requires matching first-user-message permission evidence.

A complete pending Claude `ExitPlanMode` request can be accepted once or rejected on the phone only when its native input contains the bounded full plan and no extra permissions, permission rules or nonempty `allowedPrompts`. File-only/incomplete plans and ambiguous approvals require the Mac. The adapter rechecks the original request, makes one verified click and waits for the matching native single-use answer; disappearance alone cannot confirm approval.

手机已有会话及新建选项均提供独立「任务模式」。Mac 回读真实模式后才确认；缺少能力、目录或空闲原生持有方时不可切换，不通过提示词前缀模拟计划。Codex 计划模式与权限独立；Claude 计划模式绑定原生权限，退出时采用安全默认。Claude 仅允许对完整且无额外权限的原生计划审批作单次批准/拒绝；不完整计划须在 Mac 处理。未知设置/新建回执继续查询原操作，不自动补发。功能证据为隔离测试与中英文模拟器，安装与真实原生效果分别验收。

## Codex

Desktop build numbers no longer gate opening, control, configured creation or Plan / Execute options. Updates with compatible interfaces continue working without an allowlist change. The desktop path still uses versioned IPC, validates the original thread owner and accepts only recognized request/receipt shapes. Phone-created threads retain the independent bundled CLI/schema checks below. Actual interface or receipt failures are reported without retrying uncertain mutations; an unrecognized desktop build alone is not an error.

Once an IPC mutation reaches the socket write boundary, a timeout, disconnect, handler error or malformed response is an unknown outcome, regardless of diagnostic language. Successful replies must match the request method and selected owner. Sending requires a native turn ID, interrupting requires the original turn ID, and approvals, settings and queue changes require their native acknowledgment fields. An explicit conditional settings rejection remains a rejection. No automatic resend is performed.

Build **12947** was checked against the installed desktop archive: coordination method versions and the nine mutation-handler request/receipt branches used here match 12553. A live read-only IPC probe passed initialize, owner discovery and a version-11 conversation snapshot from the matching owner. Existing IPC receipt tests cover malformed/wrong-owner/timeout responses; no live message was sent by this compatibility check. These desktop checks do not establish acceptance of background creation.

The retained legacy deep-link/AX new-session path has a separate contract currently inspected for **build 12553**; it is not the default configured-creation route or an automatic fallback from App Server. A deep link explicitly selects the native project ID, directory and Codex mode and only prefills the first plain-text message. The adapter requires one focused composer with the complete expected body, the expected project selector and a unique enabled native Send button; it rechecks those element identities before one accessibility action. Known worktree instruction controls are refused for a request targeting the existing directory. There are no timed Return presses or alternate submission fallbacks. Duplicate project names, multi-root projects, unrecognized native labels/schemas and other builds are not treated as verified creation targets.

Success requires a thread ID absent from the pre-open index snapshot, the requested directory and complete first-message text in the native index, and the corresponding first `user.text` rollout record with its message ID and original turn ID. Injected context records, a matching title/timestamp, a moved old thread, a later matching message or an ambiguous simultaneous creation cannot confirm success. After opening or attempting submission, failures remain unknown and are not automatically resent. These policy/receipt checks have synthetic regression coverage; **actual new-composer accessibility recognition and native creation are still release-acceptance requirements**, not claimed as passed here. The current selectors recognize the provider's English and Simplified Chinese labels.

All providers share a receipt validator before durable completion: malformed or oversized replies, mismatched session identities, missing acknowledgments and contradictory unknown/success flags cannot finish a mutation reservation. Lock/unlock success also requires the requested resulting lock state. Receipt lookups must match the original session; an unresolved result stays unresolved across restart.

The supported contracts are the named Codex desktop versions and bundled App Server versions. They do not imply support for arbitrary CLIs, cloud-hosted conversations or independent apps using a similar name.

### Codex account usage and gifted resets / Codex 账户用量与重置卡

The session-list menu exposes **Codex usage** independently of the selected session/provider. A short-lived, account-only `codex app-server` connection reads `account/rateLimits/read`; it never starts a thread. The local bundled CLI 0.159.2 read path is verified. Prefer the multi-bucket response; missing windows/counts remain unavailable. The device displays local-time reset/expiry dates and the authoritative available-card count even if detail rows are capped.

Selecting a specific available card and confirming sends `account/rateLimitResetCredit/consume` with that card ID and one stable, device/account/operation-scoped idempotency key. The Mac re-reads usage, checks the account/card and a five-hour or weekly window at 10% or less remaining. Unknown/expired cards, changed accounts, missing details and missing confirmation are refused. A transport timeout never triggers a second redemption. The phone retains uncertain operations and offers receipt checks; unresolved native outcomes require checking on the Mac before using another card. Reset success is retained even if the following usage refresh fails. This feature does not purchase credits or change provider sessions.

会话列表菜单中的 **Codex 使用情况** 显示当前 Mac 账户的剩余额度、额度重置时间、赠送卡数量及到期时间，与具体会话无关。点击卡片后须确认使用一张，Mac 再次检查账户、卡片状态与可重置额度。超时保留原操作，禁止自动重发或改用另一张卡；可检查回执，仍未知时先在 Mac 核对。只有数量而无卡片详情时需先刷新，不盲目代选。开发测试采用模拟兑换结果，不消费真实赠送卡。

Protocol reference: [OpenAI app-server account methods](https://learn.chatgpt.com/docs/app-server). Availability and outcomes are determined by the signed-in account and service response.

## Claude Code

History is read from the Mac's local Claude Code transcripts. If a live terminal owns a session, phone sending is refused to avoid forking that session. A verified desktop owner receives the message through the desktop adapter. With no owner, the installed desktop app (started if needed, after unlocking a locked Mac) adopts the session and receives the message, so it renders live there; only when Claude Desktop is not installed does the `claude` CLI resume it headlessly. Creating a session requires that CLI and a known project; the first turn runs headlessly and, as soon as it ends, the session is imported into Claude Desktop and brought forward, after which every turn renders live in the desktop app. A CLI that exits without recording the first message is a definitive failure; mode readback mismatches are warnings.

Desktop controls require Accessibility and exact host/session matching. Only a single recognized, actionable pending desktop approval/question can be answered. Unsupported cards, stale requests and ambiguous windows require handling on the Mac. There is no blanket desktop-version promise for this accessibility-based integration. Sending requires exact host matching, the full composer body and a new native transcript receipt. Approvals/questions use one verified click, recheck the original request, and require a matching native `once`/`deny` acknowledgment; cancellation, log rotation or absence alone do not prove an answer. Unknown results remain unresolved for inspection on the Mac.

Claude sending also requires a unique enabled text area and verified input focus in the original window immediately before paste and submission. Sidebar link matching uses the exact session route; ambiguous targets are refused. Revise/navigation selects one input method with no retry click or Escape fallback. Menu cleanup uses an advertised native cancellation action only, because Escape can stop a task. These source safeguards still require acceptance against the actual supported desktop UI.

Headless Claude output must provide one valid terminal result and reach EOF on both pipes. A line beyond 8 MiB, malformed or missing terminal output, or incomplete pipe shutdown is reported as unverified output rather than successful completion. This diagnostic does not retry the submitted prompt. The history and native session remain the authority for inspecting what ran.

## ZCode

History images support native `zcode-artifact://<session>/tool-result-<UUID>` attachment references. The Mac resolves one matching `.txt` artifact under the selected session's CLI artifact directory and decodes its persisted image data URL on the bounded image workers. Cross-session references, ambiguous matches, symlinks, missing artifacts and non-image bodies are refused. The directory scan is capped at 10,000 entries and input at 48 MiB. This supports existing attachment previews; phone attachment submission remains unavailable. Other artifact layouts and binary tool artifacts are not supported by this reader.

历史图片支持 ZCode 的 `zcode-artifact:` 附件地址：Mac 仅在当前会话的 CLI 附件目录中寻找唯一匹配的 `.txt` 文件，由有界图片工作线程解码其中的图片 data URL。跨会话地址、重复匹配、符号链接、文件缺失及非图片内容均拒绝；目录扫描最多 10,000 项，输入最多 48 MiB。此功能用于历史图片预览，手机向 ZCode 发送附件仍不支持；其他存储布局及二进制工具产物暂不支持。

Configured creation reads the native model, reasoning and permission choices for the current phone/project/draft. Before the first message, it revalidates menu identity and selection, requires explicit full-access confirmation, and refuses changed or ambiguous native controls. These checks have synthetic coverage; actual native creation acceptance remains pending. Creation attachments are unsupported.

新建配置读取原生模型、推理和权限菜单，按手机、项目和草稿绑定；首条发送前重新核对菜单及选中项，完全访问须明确确认。选项变化或控件不确定时拒绝执行。已有隔离测试，真实原生新建仍待验收；新建附件暂不支持。

The adapter reads native session storage without modifying it. Mutations use the running `dev.zcode.app` desktop, Accessibility, original session-ID verification and native menus. It will not overwrite an existing composer draft. Attachments, approvals, queues and context-capacity reporting are disabled. New-session support additionally requires the configured built-in agent-provider list to be exactly the supported native `glm` provider; mixed providers are refused.

Phone control preparation can reveal the selected native ZCode session, verify its copied session ID and restore the previously active app. Passive history opening does not navigate the desktop. Plan / Execute uses the native plan checkbox independently from the file permission radio choices (`build`, `edit`, `yolo`). Both may be checked simultaneously; changing execution mode preserves the chosen permissions. New drafts default to a non-full-access permission choice. Full access still requires confirmation. Creation verifies the native menu selections across paste, rechecks the project and exact draft before a single Send, and binds the mode proof to the confirmed new session and first native human message. Current native human messages do not persist a mode field; late reconciliation requires the original operation's retained proof rather than inventing one.

手机执行准备会定位所选 ZCode 原生会话、核对复制的会话 ID，并恢复此前的前台应用；普通历史浏览不切换桌面会话。计划／执行使用原生计划复选项，独立于文件操作权限的单选项（`build`、`edit`、`yolo`）。两者可以同时勾选；切换执行方式保持选定权限，新草稿默认选择非完全访问权限。完全访问仍须确认。新建在粘贴前后回读原生菜单，发送前重查目录和完整草稿，并将模式证据绑定到新会话及首条原生用户消息。当前原生用户消息不保存模式字段；迟到回执使用原操作保留的证据，不能虚构。

ZCode's exact native default directory (`~/.zcode/workspace/default`) uses the unique “Work outside a project” menu entry when creating a task; it is not searchable as a regular project. The adapter verifies the resulting full directory before loading options or submitting. ZCode 原生默认目录使用唯一的“不在项目中工作”入口，普通目录仍按完整路径搜索；加载选项和发送前都核对最终目录，不能用任意名为 default 的目录代替。

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
| 列表、历史、图片、Markdown | 兼容桌面订阅或已登记的自有 App Server 会话 | 已接入本地记录与适配的桌面状态 | 已接入原生记录及受限本地图片 |
| 回复、新建、设置、停止 | 已有桌面核对实际接口与原 owner；默认新建走自有后台且无需解锁，后台发送须空闲 | 区分桌面、终端与本机 CLI；终端占用时不旁路续写 | 校验原生会话及菜单；新建仅支持指定原生 provider 配置 |
| 手机计划/执行 | 运行时核验的桌面或自有 App Server 原生目录与模式证据，权限独立 | 原生计划权限模式；已有设置须桌面实读，新建核验首条权限 | 原生计划复选项独立于权限单选项；切换保持权限 |
| 附件 | 支持 | 新会话图片作为视觉内容发送；其他文件与已有会话附件作为文件引用 | 不支持 |
| 审批与问答 | 支持识别出的原生/异步请求 | 仅适配且无歧义的桌面请求 | 不支持 |
| 队列及引导 | 仅兼容桌面会话；自有后台会话不支持队列、引导与队列删除 | 不支持对应队列功能 | 不支持 |
| 上下文用量 | 所选原生后端提供时显示 | 需适配的已打开桌面会话 | 不支持 |

Codex 桌面打开、控制、新建与计划/执行选项不再按构建号白名单禁用；升级后接口仍兼容即可继续使用，实际接口或回执异常才报错，未知操作不自动重发。默认新建与自有会话续写使用单独核验的内置 App Server 契约，不代表所有场景已完成真机验收。Claude 不能对已有终端占用的会话另起进程续写；桌面发送以新增原生消息 ID 和完整正文确认，审批只提交一次并等待匹配的原生回答记录，未知结果不自动重发；ZCode 不直接修改数据库，也不覆盖已有草稿。ZCode 权限选项仅识别上述已适配的原生名称；未知、重复或未适配语言的权限模式拒绝在手机切换，完全访问保留明确确认。VibePier 自身仍支持中英文界面。平台最低版本声明、编译成功与实际设备验收必须分别记录。

Codex 操作开始写入桌面接口后，超时、断线、处理错误或无效回执均保留为“结果未知”，不再靠中英文错误文字推断。成功回复必须匹配请求方法及原桌面实例，并包含相应的原生消息、任务或操作确认；不会自动重发。所有服务商的回执还会统一校验会话身份、确认字段及传输大小，缺失或矛盾的回复不能把持久记录标成完成。锁屏/解锁需确认目标屏幕状态，查回执需匹配原会话，重启不清除未知操作。

Codex 旧深链/AX 新建采用单独的版本约束，目前按构建 12553 的原生接口实现。目标须为已保存、单根目录且名称唯一的本地项目；核对完整正文、项目及唯一可用的原生发送按钮后，只尝试一次。已移除定时重复 Return，也不会改用其他提交方式。成功需新会话 ID、准确目录、完整首条正文及原生消息/turn ID 一起确认；上下文注入、标题/时间接近、移动旧会话或并发同文新建都不能代替该回执。原生中英文控件的实际识别与真实新建流程仍待现场验收，不能用隔离测试代替。

Claude Code：会话无持有方时，由已安装的 Claude 桌面（必要时先解锁 Mac 并启动应用）导入并接收消息，因此在桌面实时显示；只有未安装 Claude 桌面时才用 `claude` CLI 无界面续写。新建仍需该 CLI 与已知项目：首轮无界面运行，结束后立即导入 Claude 桌面并切到前台，之后每轮都在桌面实时显示。CLI 未写入首条消息即退出视为确定失败；模式回读不一致仅作提醒。

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

构建 **12947** 已核对本机桌面协议版本及九个操作处理分支，与 12553 保持一致；实际只读 IPC 握手、会话归属发现及 v11 状态订阅通过。此次未向真实会话发送测试消息，桌面检查不能替代默认后台新建的独立原生契约与实际验收。

Claude transcript API errors are shown as localized notices, with retries coalesced within each turn and raw gateway details omitted. HTTP 429 means the upstream account rate limit delayed a reply; a successful creation receipt only confirms the session and first message, not a completed model reply. No automatic resend is added.

Claude 会话中的 API 错误会显示为本地化提示，同一轮重试合并展示，不转发网关原始错误。HTTP 429 表示上游账户限流阻碍了回复；创建成功回执仅确认会话和首条消息，不代表模型已完成回复。此提示不会自动重发。

Android shows a persistent waiting banner for provider API/rate-limit errors, approvals, disconnected or unconfirmed requests, and active turns without visible progress for 60 seconds. Silence is a warning, not proof of failure. “Cancel current task” uses the existing verified turn-specific interrupt operation; a draft does not hide it. “Stop waiting” stays in the conversation: it interrupts a verified cancellable turn, or ends local waiting while retaining the draft and unresolved receipts for checking. Detached sends no longer block different messages; repeating their text or attachments remains blocked until the receipt is resolved. It does not claim to stop an offline Mac or undo an unconfirmed creation. Claude API blockers clear on subsequent native assistant progress, a new prompt, or an interrupt marker; history retains the original failure.

安卓会持续提示服务商 API/限流错误、等待审批、连接中断、结果待确认，以及运行中超过 60 秒没有可见进展的情况；没有新进展不等于任务已失败。“取消当前任务”复用校验当前轮次的停止操作，有草稿也可使用。“停止等待”保留在聊天页：有可核验的轮次时发送停止请求，否则结束本地等待并保留草稿与未知回执供查询。已结束等待的发送不再阻塞不同的新消息，但原文或原附件仍须先确认回执；不宣称已经停止离线 Mac 或撤销待确认的新建请求。Claude 的当前 API 阻塞提示在原生回复继续、新提示词或中断标记出现后清除，历史错误保留。

### Default background App Server creation / 默认后台 App Server 新建

The phone's `newOptions` and configured `new` use the default `codex.currentV1` path with **desktop ownership**. The bundled App Server only persists an empty native thread in the Mac's existing Codex home (`thread/start`, name, archive/unarchive) and then unsubscribes, so it never remains a second writer. If the Mac is locked, it is unlocked first with the configured password; the thread is opened in the Codex desktop app via `codex://threads/<id>`, the desktop owner is discovered over IPC, and the first message is submitted once with `thread-follower-start-turn`. The conversation therefore renders live in the desktop app from its first turn, and later sends, interrupts, approvals and settings go through the same owner IPC. The desktop turn ID is the creation proof; model, mode and speed readback mismatches are returned as `warnings`, not as unknown. Any failure before the first-turn submission (unlock unavailable, desktop owner not found, empty-thread verification) is a definitive failure that reports the empty thread; only a lost reply after submission stays unknown. Threads created by earlier builds under the private background registry are handed to the desktop owner the next time the phone opens them while no background turn is running. Phone-triggered unlocks stay open for two idle minutes and then relock; local keyboard/mouse use or an explicit phone unlock cancels that relock.

手机的 `newOptions` 和配置式 `new` 使用默认 `codex.currentV1` 的**桌面持有**路径：内置 App Server 只在 Mac 原生 Codex home 中持久化一个空会话（`thread/start`、命名、归档/取消归档），随即取消订阅，不再充当第二个写入方。Mac 锁屏时先用已配置的密码解锁，再以 `codex://threads/<id>` 在 Codex 桌面打开该会话，经 IPC 找到桌面持有方后，用 `thread-follower-start-turn` 单次提交首条消息，因此从首轮起即在桌面实时显示；后续发送、中断、审批与设置都走同一持有方 IPC。以桌面返回的 turn ID 作为新建凭据；模型、模式、速度回读不一致以 `warnings` 返回，不再判为未知。首轮提交前的任何失败（无法解锁、找不到桌面持有方、空会话校验失败）均为确定失败并附带空会话；仅提交后回复丢失才保持未知。旧版本登记在私有后台注册表中的会话，会在手机下次打开且后台无运行中任务时移交给桌面持有方。手机触发的自动解锁在空闲两分钟后复锁；本机键鼠操作或手机显式解锁会取消该复锁。

Model, reasoning effort, permissions, Plan / Execute, Fast mode and attachments remain available only when the selected native catalog/contract advertises them. Sending on a registered background thread requires a healthy connected backend and verified idle state; queue, queue deletion and steer are disabled. Native thread/turn/message identity, complete first-message content and requested configuration evidence are required for confirmation. A response, title, registry record or incomplete mode proof alone cannot claim successful creation. Timeouts keep the original unknown receipt; there is no automatic resend or switch to desktop input. Isolated tests do not substitute for locked-screen, native account, attachment and phone-to-Mac acceptance.

模型、推理、权限、计划／执行、加速和附件保留，但须由所选原生目录与契约提供。自有后台发送必须连接健康且已核验空闲，队列、队列删除和引导关闭。成功须匹配原生会话／轮次／消息身份、完整首条内容及请求的配置证据；单独的响应、标题、登记记录或不完整模式证据不能宣称创建成功。超时保留原未知回执，不自动重发或转交桌面输入。隔离测试不能替代锁屏、真实账号、附件及手机到 Mac 的实际验收。

The ownership registry is private and bounded to 256 threads, 256 retained input proofs per thread and 2 MiB. It stores configuration and input digests, never credentials or message bodies; a full/corrupt registry rejects new writes without deleting unknown records. A stable file lock serializes app/CLI ownership updates and input reservations. Proxy loss triggers bounded-backoff read-only recovery for opened threads; old connection callbacks cannot supply new approvals or settings. Approvals/questions are submitted once. A native request-resolved event does not identify which decision was adopted, so that response remains unknown; actual task progress can continue. Desktop-only asynchronous question cards are not actionable on this backend. Lost operation-specific settings proof remains unknown instead of being inferred from the current model selection.

后台归属记录最多 256 个会话、每会话 256 条输入摘要、总计 2 MiB；只存配置与摘要，不存凭据或正文，满额或损坏时拒绝新写入，不删除未知记录。App 与 CLI 的归属写入及消息预留使用稳定文件锁；proxy 断线后，已打开会话按有界退避恢复读取，旧连接回调不能提供新审批或设置。审批／问答只提交一次；原生“请求已解决”事件不能证明采用了哪项决定，因此回执保留未知，实际任务可以继续。桌面专用异步问答卡片不能在此后台作答；设置操作丢失专属证据后，不凭当前选项猜测成功。

App Server can acknowledge a turn before its first user item becomes readable. The gateway retains that turn ID immediately and allows up to 10 seconds of bounded read-only confirmation; timeout still remains unknown. On the reviewed 0.160.0 contract, null preset instructions mean the native built-in expansion and null/default service tier means standard speed. Other requested mode/model/effort fields remain exact. After restart, creation receipt lookup matches the original authorized client/operation, registered thread and full input digest, then verifies the original turn's persisted native settings and user item. Current settings and registry intent cannot substitute for historical evidence. Rollout reads are limited to 8 MiB and complete JSONL records; missing, ambiguous or oversized evidence stays unknown without resubmission.

App Server 的轮次确认可能早于首条用户消息可读。网关立即保留轮次 ID，再最多等待 10 秒进行有界只读核验；超时仍保留未知。已审核的 0.160.0 契约中，预设指令 null 表示采用原生内置展开，速度 null／default 表示标准速度；模式、模型和推理等其他请求字段继续精确核对。重启后，创建回执按原授权手机／操作、登记会话及完整输入摘要匹配，再核验原轮次持久原生配置和用户消息，不能用当前设置或登记意图冒充历史证据。原生 JSONL 读取限 8 MiB 且只解析完整记录；缺失、歧义或超限时保持未知，不重发。

Codex list/activity discovery includes the `vibepier` originator used by configured phone-created threads, while retaining archive, subagent and other-origin filters. 手机创建的 Codex 会话纳入列表与活动检测；旧 AX 创建回执的来源校验保持独立。


### Agent option catalogs / Agent 选项缓存

Mac startup primes Codex’s local catalog, the currently visible Claude desktop model menu, and ZCode’s native option catalog once. Claude CLI creation and headless session settings discover full model IDs through the configured Anthropic-compatible `/v1/models` endpoint, with bounded pagination, a 60-second configuration-scoped memory cache, and explicit refresh. Choices and settings validation use the same directory; unavailable discovery reports an error instead of inventing alias choices. Credentials stay on the Mac; only user-level API settings, environment keys/tokens and the configured user API key helper are supported. OAuth-only discovery and project-level model/credential overrides are explicitly unsupported. Desktop-owned sessions continue to use their native menus. Model version and reasoning effort are separate choices. A desktop host first encountered later loads once for that host. ZCode persists only bounded presentation choices in a private file; drafts, native owner proof, permissions to mutate, device keys and receipts are not persisted with it. Explicit Refresh options rereads the source. Phone detail menus reuse the fetched catalog while overlaying the current session selection. Mutation preparation still renews target authorization, and native submission/settings must prove actual application. Cached menus never prove success.

Mac 启动时预读一次 Codex 本地目录、当前可见 Claude 桌面模型菜单和 ZCode 原生选项目录；Claude CLI 新建使用本地支持的模型别名。之后首次遇到的 Claude 桌面来源读一次。ZCode 在私有文件中仅保存有界的选项展示数据，不保存草稿、原生会话身份、写操作授权、设备密钥或回执。手机详情页复用取得的目录，并叠加当前会话选中项；点「刷新选项」重新读取。提交前仍更新目标授权，并核对实际提交/设置结果。

| Agent | New-session options | Speed |
| --- | --- | --- |
| Codex | Local visible models, reasoning levels, Plan/Execute, permission mode, attachments | Owned background and verified desktop sessions, when the selected model/runtime advertises priority |
| Claude Code | Supported CLI aliases, reasoning levels, coupled Plan/Execute permissions, image attachments | Unavailable |
| ZCode | Actual native account model choices, available reasoning level, independent Plan/Execute and permissions | Unavailable; new attachments unavailable |

| Agent | 新会话可选项 | 加速 |
| --- | --- | --- |
| Codex | 本机可见模型、推理强度、计划/执行、权限、附件 | 自有后台及已核验桌面会话，且当前模型/运行时支持 priority |
| Claude Code | 支持的 CLI 模型别名、推理强度、与权限关联的计划/执行、图片附件 | 暂不支持 |
| ZCode | 原生账号实际模型、可用推理强度、独立的计划/执行及权限 | 暂不支持；新建附件暂不支持 |

Profile 2 desktop mutations use the same preparation-aware waiting policy as native controls: creation waits up to 60 seconds, configuration and message submission 45 seconds, and other mutations at least 30 seconds. Reads retain their normal deadline. Timeout retains the original unknown receipt and never resubmits. A ZCode creation failure during control preparation, before the Send boundary, reports that the message was not submitted; settings operations themselves still retain uncertainty after a native control change.

Profile 2 的桌面操作按准备耗时等待：创建最多 60 秒，配置和消息提交 45 秒，其他变更至少 30 秒；读取沿用普通期限。超时保留原未知回执，不重发。ZCode 新建在 Send 之前的控件准备失败会明确返回消息未提交；独立设置操作在原生控件变更后的不确定结果仍保持待确认。

Stopping a creation wait immediately restores a separate editable draft in the same dialog. It ends only the local wait and receipt query; the Mac may continue the original creation. The original unresolved draft/receipt remains available under Earlier creation receipts. Late replies cannot lock or replace the new draft. Matching first-message text or attachment IDs in the same project still require checking the old result before resubmitting; a different message uses a different draft and operation ID.

新建会话中停止等待后，同一弹窗立即恢复独立可编辑草稿；停止的是本地等待和回执查询，Mac 仍可能继续原新建。原未确认草稿和回执保留在「核对先前新建结果」，迟到回包不会重新锁住或覆盖新草稿。同一项目的相同首条文字或附件仍需先核对原结果；不同消息使用独立草稿和操作 ID。

A profile 2 native mutation rejection preserves its adapter error code and bounded plain-text diagnostic instead of replacing it with a generic unsupported-state message. Mac unlock failures therefore instruct the phone user to unlock the Mac manually. Malformed or oversized diagnostics fall back to the generic translated message; unknown receipts remain unknown, with no automatic retry.

Profile 2 原生变更被拒绝时保留适配器错误码及有界的纯文本原因，不再替换成笼统的「不支持或未就绪」。Mac 解锁失败会在手机明确提示手动解锁；格式不合法或超长的原因采用通用本地化提示。未知回执仍待确认，不会自动重发。

After restoring a project through an Agent tab or reconnect, a missing workspace reference is refreshed with a bounded read-only project lookup before listing sessions, reading creation options or preparing creation. The exact directory must resolve uniquely on the same adapter and authorization/view scope. Late replies after switching tab/host are discarded. Refreshing choices replaces unavailable model/permission/effort IDs while preserving message text and keeping full-access confirmation explicit.

切换 Agent tab 或重连后恢复项目时，如果协议项目引用缺失，会先通过有界的只读项目查询恢复，再加载会话或新建选项。完整目录必须在同一适配器和授权／视图范围内唯一匹配；切 tab／Mac 后到达的旧回包会被丢弃。刷新选项会替换失效的模型、权限和推理值，同时保留首条文字，完全访问仍需明确确认。

Desktop menu startup warming never attempts a screen unlock. While locked, ZCode keeps its last private catalogue and Claude skips native menu warming. An explicit authorized desktop action may still use the configured unlock workflow. A failed unlock is not silently reset or repeatedly retried.

桌面菜单的启动预读不尝试解锁屏幕。锁屏时 ZCode 保留私有目录缓存，Claude 跳过原生菜单预读；明确的已授权桌面操作仍可使用已配置的自动解锁。失败标记不被静默重置，不会反复尝试密码。
