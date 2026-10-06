# API 37 双 Agent 会话测试与修复报告

以下初始阶段完成详细测试计划、调用链梳理、十类缺陷修复与分层验证。**整体仍是部分验收：真实 Claude 审批被 HTTP 429 阻塞，生产 UDP/WSS 全链路与多设备竞争尚未验收。** 本报告不将合成结果算作真实 Agent 成功。

- 初始阶段范围：Android API 37；Codex、Claude Code；英文与简体中文。该阶段仅安装隔离 review 包；后续 build 62 已交付 Mi 10/Mac，build 63 的当前契约清理见下方说明。
- 计划：[AGENT-SESSION-TEST-PLAN.md](AGENT-SESSION-TEST-PLAN.md)。架构：[SESSION-TESTABILITY.md](SESSION-TESTABILITY.md)。
- 本地证据：`.local/agent-session-qa/VALIDATION.md` 及逐次日志。私有授权、Keystore、回执保留在测试目录中，不提交到 Git。
- 共享工作树有本轮以前的 ZCode 清理改动。本次未提交或推送；不能将全部工作区差异归为本轮修复。

## 修复闭环

| ID | 原问题 | 修复与验证 |
| --- | --- | --- |
| D01 | 打开审批后，会话能力恢复但按钮不刷新；能力丢失也可能保留旧状态 | 弹窗订阅当前状态刷新、关闭时释放回调；API 37 真实触摸红→绿，覆盖两个 Agent 的允许、拒绝、选项、回答 |
| D02 | 页面取消读取误取消必须保留的发送准备回调，造成等待不结束 | 统一取消谓词，preserved 保护必须保留的准备与回执回调（build 63 已删除旧协议执行）；JVM 与真实 SessionClient pending 回归通过 |
| D03 | 模型列表取消只认识旧请求，profile 2 分页/选项请求残留 | ReadScope 关联逻辑操作与实际 wire 请求；取消阻止晚到回包继续派生读取，120 次刷新/取消通过 |
| D04 | Claude 同名工具审批可能按顺序错配 | 仅唯一关联可决定；歧义保留“在 Mac 处理”只读卡片，不显示猜测内容；指纹和错配回归通过 |
| D05 | Claude 审批点击后确认延迟，超时后无法补确认 | 提交前保留只读 observer、单次点击后激活；仅原请求/原决定的证据可确认；不补点，重启后未知不自动变为可重试 |
| D06 | 新建弹窗跨前后台或能力重新发现后，模型选项不恢复 | 同草稿只读重载选项，关闭释放回调；保留草稿且创建请求数为零的红→绿回归通过 |
| D07 | 审批写能力消失后，“检查结果”也被禁用 | 只读查询仅要求连接/授权及无在途查询；显式重试仍要求写能力；JVM 与加密 UI 回归通过 |
| D08 | 队列项不可 steer/delete 时按钮仍可点 | 按每条记录 canSteer/canDelete 与当前全局能力共同启用，刷新 key 纳入能力变化；API 37 队列回归通过 |
| D09 | canDecide=false 的选项审批仍显示可点选项 | UI 和提交入口都校验卡片权限；只读卡片零提交的红→绿回归通过 |
| D10 | Codex 同 view 返回旧缓存，漏广播或 owner 变化后快照无法恢复 | 消费 verifyNativeOwner，执行有界 discovery 与新快照；换 owner/失败撤旧租约，迟到旧失败不撤新租约；临时 IPC 与 Service 红→绿，76 项相关测试通过；新 Core 沿原 Codex 会话只读核验再次通过 |

每项修复保留失败证据；完整原始日志索引见本地报告。没有为让测试通过而放宽设备、lease、fingerprint 或回执校验。

## 验证结果与边界

| 验证 | 结果 | 证明范围 |
| --- | --- | --- |
| make test | PASS：Swift 810 项，30 项显式 opt-in 跳过；Android 322 项；Go race；插件 7 项 | 单元、协议和合成依赖；跳过项不算真实验收 |
| make lint | PASS | Swift 格式、Android lint、Go vet、协议生成、本地化、仓库/安装器检查；临时 Git index 处理原有未暂存删除，未改真实索引 |
| QA runner | PASS：46 项 | 明确 API/模拟器/APK/runner 校验、结果判定与证据保存；零测试不能判通过 |
| API 37 冻结核心矩阵 | PASS：24/24（12 探针 × 2 语言） | 12 个核心探针 × 2 种语言，原生响应主要合成；与扩展组共用 acceptance-final 中的同组 APK |
| API 37 扩展矩阵 | PASS：24/24（12 扩展探针 × 2 语言） | 加密协商、授权、私有存储、列表/附件/图片/Markdown 等 |
| 审批重复触摸 | PASS：前两轮合计 120 次合成决定 | 两个 Agent 的控件真实触摸，不代表真实桌面审批 120 次 |
| 后台稳定性 | PASS：30 分钟，123 次断线恢复 | API 37、认证加密 UDP 合成 host，非真实 Agent 压力测试；对应 candidate-02，非后续 APK 自动继承 |
| 原生 Mac Codex | PASS：创建、模型目录、后续发送、回复结束、允许与拒绝 | 精确原生 message/turn/request 身份、允许后的测试标记、拒绝后的 declined 状态 |
| 原生 Mac Claude | PARTIAL / BLOCKED | 模型目录、创建和桌面续发的原生提交身份已核实；模型回复与审批触发被 HTTP 429 限流，不能算成功 |
| API 37 → 测试 TCP → 真实 Mac adapters | PASS：双 Agent 选项；Codex 创建/续发及原操作只读恢复 | 复用生产 SessionClient 加密、Inbox、Service、Coordinator、Bridge；未覆盖生产 UDP/WSS、BLE 配对和真实审批页面全链路 |

原生验收过程：[NATIVE-LIFECYCLE-ACCEPTANCE.md](NATIVE-LIFECYCLE-ACCEPTANCE.md)。真实 Codex 待决审批最终已处理，Claude 限流测试已核验中断，未留测试审批待决。

## 测试自身的修正

旧 Android 探针先前使用旧协议、忽略发现和页面请求取消次序；新建回执探针还复用了其他用例的 provider/偏好，本轮改成独立身份与偏好而不清数据。本轮迁移到 profile 2，通过生产 SessionClient 加密/解密；原状态、回执、范围与重复提交断言保留。

真实手机用例有两次独立测试假设错误，失败历史保留：

1. Codex 回执的消息身份对应用户行 clientId，UI 行 id 属于另一命名空间。修正后用原会话、角色、完整输入共同核对，不退化为文本包含匹配。
2. 当前轮 snapshot 不包含所有历史。原创建和续发均 confirmed 后，读取原授权/原 journal；就绪快照 idle、complete、有 lease，再读取一页 history，两条消息全部匹配。没有重发创建或续发来掩盖失败。

测试网关采用独立授权与私有 journal，补齐与生产一致的 adapter 事件连接。只读恢复只允许原已确认会话，不接受任意会话或自动恢复执行变更。

## 未闭环项与下一步

| 项目 | 状态 | 完成条件 |
| --- | --- | --- |
| Claude 真实回复/审批 | BLOCKED：HTTP 429 | 限流解除后用新的独立用例触发真实审批，核对一次决定、原生结果及手机状态；不重发旧未知操作 |
| 手机正常 UI → 生产 UDP/WSS → 桌面审批 | NOT RUN | 每种实际路由完成创建/发送/审批身份闭环，保留真实路由证据；测试 TCP 不能替代 |
| 两台授权设备竞争、Mac 重启后的真实未决恢复 | NOT RUN（已有合成覆盖） | 在隔离环境按 A09/A11/R01 执行，证明一次原生动作和设备隔离 |
| 锁屏/解锁、真实模型切换后的配置回读 | 未完成完整矩阵 | 按 S04/M01 独立取证，不用目录读取或提交成功代替配置生效 |

验证原则：只读恢复先于任何重试；失败→记录边界→最小修复→原用例复测→相关回归→保存候选与证据。BLOCKED/NOT RUN 保持可见，不用跳过替代通过。

## English summary

This API 37-only effort produced a detailed plan, architecture guide and ten targeted fixes. Unit/static checks, synthetic Android approvals and cancellation tests, a 30-minute reconnect soak, real Codex native decisions, and encrypted test-TCP phone integration provide separate evidence. Claude native responses and approval triggering remain blocked by HTTP 429. Production UDP/WSS UI-to-native acceptance and real multi-device/restart scenarios remain unverified. The initial QA stage did not install production apps. Build 62 was subsequently delivered to Mi 10 and Mac; build 63 follows the current-contract cleanup described below. No Git submission was performed by this QA task.


## 后续安装交付 / Subsequent installation

用户随后授权双端安装：正式 build 62 已经通过 ADB 覆盖安装到 Mi 10，并按同签名原址流程安装到 `/Applications/VibePier.app`。手机 UID/配置和 Mac 应用目录/签名身份保留；Mac 已重新运行，收到 Mi 10 的 build 62 上报，最新版 APK 登记为62。未更新250；独立 CLI 未安装更新。安装证据在 `.local/session-qa-install/VALIDATION.md`。上文“未安装”描述的是测试阶段，安装完成不改变仍未完成的真实验收项。

Following explicit installation authorization, signed build 62 was installed on Mi 10 with ADB replacement and on the Mac through the identity-preserving updater. The running Mac received the phone's build 62 report. This delivery does not resolve the remaining native/production-route acceptance gaps.

## Build 63：仅当前契约与现场修复

按“旧客户端全部移除、统一最新版”的前提，删除旧业务协议执行、文本文件分块、bulk 包装、旧单手机中继主机分支及旧凭据/偏好自动迁移。当前协议边界见 [CURRENT-PROTOCOLS.md](CURRENT-PROTOCOLS.md)。

现场发送失败根因是旧 ZCode 索引条目使整个会话服务初始化失败，并非已经证实的网络断连。当前索引已移除退役记录；Mac build 63 启动已确认服务就绪。

最终验证：Swift 819 项（30 项 opt-in 跳过）、Android 340 项、Go race、插件 7 项、make lint 均通过；冻结 APK 的 API 37 中英矩阵 52/52 通过，含审批、模型/创建、发送/取消、加密协商、图片/上传/视频及 APK。两项初始测试失败分别由旧断言和缺少测试安装来源权限造成，修正后原用例与完整矩阵通过。证据 `.local/current-only/VALIDATION.md`。

交付：Mac 已原址更新至 63；Mi 10 现场已无旧包，正式签名全新安装 63 成功。手机锁屏，重新配对、Mac 收到版本及实际发送仍待验收，不能算闭环成功。250 未更新；中继源码已清理但未部署线上。既有 Claude HTTP 429 与生产端到端未验收边界继续保留。

English: build 63 removes old-client execution and runtime migration. Final unit/static checks and 52 API37 synthetic cases passed. Mac and Mi 10 have build 63 installed; the phone's previous package was already absent, so fresh pairing awaits unlock. Production send/approval acceptance remains pending. Relay changes were not deployed.

## Build 64：生产能力发现回复修复

用户现场确认双端 build 63，Mac 状态确认两台手机均已授权连接，但会话列表为空并提示升级。根因是生产 `providers`/`notificationSubscribe` 回复在清理时遗漏 `agentCapabilities`，而当前 Android 仍依赖该字段选择 adapter。此前合成及原生测试网关自行构造了完整字段，未覆盖这一生产入口遗漏；52/52 不能证明该入口正确。

修复在生产入口统一生成当前助手目录、默认 adapter 标记及 profile 2 声明，并通过 coordinator 建立当前协商状态。内部 capability version 1 是现用能力格式，不恢复旧手机业务执行。仅 Mac 更新至 64，手机 63 无需更改。用户明确要求不再测试，故本次仅构建与安装，不执行新的测试或宣称真机会话已验收。

English: the production discovery response omitted the current capability directory while test gateways constructed it independently. Mac build 64 restores this current metadata without old-client execution. Android 63 remains unchanged. Tests were not run for this fix at the user's explicit request; build/installation evidence is separate from runtime acceptance.

## Build 65：Codex 初始内容与订阅竞态

用户确认列表恢复，但 Codex 详情停在“没有可显示的消息”。代码分析定位两处：初始 partial 无消息被 Android 合成为空数组并结束 opening；Mac 在原生内容到达后撤销旧控制状态，随后只读订阅仍依赖该状态而可能被拒绝，后续原生事件也可能被忽略。

Android 保留未完成加载状态与已有内容，最多四次只读 snapshot 恢复，沿用原 25 秒／蓝牙 60 秒期限；只有完整消息快照才结束 opening 并保存缓存。Mac 以已绑定设备、adapter、session、view 的 nativeViews 接续只读观察，覆盖冷打开的在途快照事件；撤销控制权限不再使内容订阅失联，控制 lease 仍需重新核验。不恢复原始旧协议消息推送或自动重发写操作。

按用户要求，本次不运行测试，构建与安装记录见 `.local/codex-empty-fix/`。真实消息显示结果不能从构建成功推定。

English: preserve partial initial loading with bounded read-only snapshot recovery; keep authorized native observation independent of revoked write state. No test run was performed at the user's request; installation evidence does not imply runtime acceptance.

## Build 66：Codex 直接批准与允许此类

Codex 审批取消滚动到底的按钮门槛；授权、最新审批身份、canDecide、完整请求和未知回执检查仍保留。Claude 不在本次交互调整范围。

仅原生命令审批给出有效 `proposedExecpolicyAmendment`（若提供 `availableDecisions`，其中必须包含相同规则决定）时显示“允许此类”。手机只发送显式 `allowSimilar` 选择；Mac 重新核对 fingerprint/revision/nativeRequestId，并从原请求取规则提交 `acceptWithExecpolicyAmendment.execpolicy_amendment`，不接受手机自定义规则，不映射为整个会话放行。界面展示规则范围，后台与桌面路径一致，回执包含精确选择；锁屏通知仍仅一次性允许/拒绝。

本地已安装 Codex build 13100 的原生审批实现与本地 schema 提供语义依据。按用户要求不运行测试、不触发真实审批，构建与安装证据保存于 `.local/codex-approval-actions/`。

English: Codex approval buttons no longer require scrolling to the end. “Allow similar” is offered only for a native proposed command-rule amendment and submits the exact bound native rule; ordinary authorization and receipt checks remain. No tests or real approvals were performed at the user's request.

## Build 67：避免未完成刷新误关审批弹窗

66 安装完成附近用户报告未点击而弹窗消失。近期手机回执未发现审批提交，安装／切后台可关闭页面，现场单次原因尚不能确认。代码中另发现明确缺陷：applyPage 将 partial 或缓存缺失的 approvals 当作空集合，直接关闭当前审批。67 仅允许实时完整快照且显式审批数组确认移除／变更，partial 保留弹窗并沿用原控制权限禁用规则。Mac 保持 66。用户要求不测试，故仅构建安装，不将此分析写成已复现或已验证。

English: an incomplete or cached page must not retire an approval dialog. Android67 requires a live complete approval collection. The user's specific disappearance coincided with an app update and is not conclusively attributed; no recent phone approval submission was found. Tests were not run.

## Build 68：未提交问答不再自动收起

用户在67仍报告单选刚选中、尚未提交时页面消失，以及弹出后很快消失。单选回调源码仅修改本地答案，不发送审批请求；实际自动关闭入口包括新快照移除／修订、断线、切后台及迟到回执。68 保留未提交弹窗及答案：刷新或重连期间禁用新提交并显示原因，只有最新完整快照中的同 id/fingerprint/revision、canDecide 与有效控制状态允许操作；自身当前提交确认成功才收起。迟到旧回执只更新状态，不清当前未提交表单。外部触摸不能取消，显式关闭／返回／切会话／换授权仍可关闭。

本地Codex13100前端确认异步问答仅当前inProgress turn，已答状态按本turn accepted消息计算；未放宽历史问答或原生提交范围。现场下发时250断线，旧版本存在对应自动关闭路径，但没有把这一观察写成全部现象的唯一原因。用户要求不测试，未运行测试；仅Android68构建/安装，Mac66保持。

English: retain unsubmitted choices across snapshot/lifecycle interruptions and late receipts, with fresh identity/control validation before any submission. Native asynchronous-question lifetime remains unchanged. No tests were run at the user's request.
