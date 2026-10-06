# API 37 双 Agent 会话测试计划

**本文是执行计划，不是测试结果。** 表中的 NOT RUN 是计划占位，不用于推断实际执行状态；最终结果以 `.local/agent-session-qa/VALIDATION.md` 及其引用的逐项证据为准。既有测试函数和历史报告不能替代对应候选版本的运行证据。架构依据、已实现接缝与后续建议见 [SESSION-TESTABILITY.md](SESSION-TESTABILITY.md)。

## 范围与执行约定

真实 Codex、Claude Code 的创建、模型、发送和审批验证限于已授权的专用测试项目。执行前须核对项目真实路径、设备身份与测试授权；不得以本计划扩大授权范围，不安装 Mi 10、不打包交付。测试目录、会话与审批必须实际存在并可核验。

本轮 Android 运行验证**仅 API 37**，覆盖简体中文、英文；生产路由验收目标包括直连 UDP、WSS 中继。已实现的 native 测试接缝使用真实 TCP，仅证明测试通道及其下游链路，不能填作生产 UDP/WSS 结果。该任务明确范围覆盖 agent.md 的日常“不做模拟器、默认安装 Mi 10”流程；本轮结束不安装 Mi 10。不扩展 API 33/35/36、不加小屏矩阵。JVM/Swift 单测本身不绑定 Android API，不能称为 API 37 验收。

| 层级 | 可证明什么 | 不能证明什么 |
| --- | --- | --- |
| L1 单元/协议测试 | 纯状态、identity、fingerprint、lease、journal 与回调次序 | Android 真点击、网络或真实桌面动作 |
| L2 API 37 instrumentation / 合成 transport | Android 生命周期、按钮点击、加密组包、真实 SharedPreferences/Keystore 行为 | 真实 Codex/Claude 操作、实际 UDP/WSS 路由 |
| L3 API 37 → Mac → 原生 Agent | 实际路由、桌面展示、真实原生回执、专用项目结果 | 未实际执行的异常注入组合 |

每个结果使用 `PASS / FAIL / BLOCKED / NOT RUN`。PASS 必须附操作步骤、版本、对应证据；环境不满足记 BLOCKED；尚未执行记 NOT RUN。L1/L2 通过不能替代 L3。对照目标与现状差距导致失败时，记录 FAIL，不删断言使其通过。

## 准备与执行入口

1. 记录当前 commit、未提交文件清单、被测 APK/Mac 二进制版本与源码关系。共享工作树可能被其他 Agent 修改，开始和结束都核对；不能拿已安装旧版结果验证当前源码。
2. 现场 `adb devices -l`，仅选择专用 API 37 emulator serial；核对 `ro.kernel.qemu=1`、`ro.build.version.sdk=37`。双设备用两个独立 API 37 模拟器及独立授权身份。禁止连接或安装到 Mi 10。
3. 真实端分别核对当前 Codex/Claude desktop、CLI 版本、登录、Mac 访问专用项目的能力；不通过读取私有凭据或 TCC 数据库确认。选实际发现的 `codex.currentV1` / `claude.currentV1`，记录能力，不能因名称存在就当作可写。
4. 在已授权的专用项目内准备无敏感数据的 fixture。每个用例使用独立 case 子目录/消息标记；创建前记录 native thread 集合，发送前记录原生消息/turn 边界，审批前记录原 request 的脱敏关联别名。不得改动用户业务项目。
5. 真实审批使用当前原生权限模式下能产生一次性审批的无害动作，例如在专用目录写一个 case 标记文件。原生若自动放行，该次不能计作审批测试；记录 BLOCKED 并查明权限模式，不降低权限或给永久授权来伪造覆盖。
6. UDP 组确认双方实际活动路由；中继组选择 WSS 并确认实际中继路径，不能以“配置了中继地址”替代路由证据。切换路径后重新确认授权与协商。合成 probe 的 `Transport.mode` 字符串不能作为实际路由证据。

### 安全的单元与构建入口（按需执行）

```sh
swift test --package-path apps/macos --filter 'AgentSessionServiceTests|AgentSessionCoordinatorTests|SessionReceiptJournalTests|CodexBackgroundSessionsTests|ClaudeBridgeTests'
apps/android/gradlew -p apps/android testReleaseUnitTest \
  --tests '*SessionAgentClientTest' --tests '*SessionAgentConversationTest' \
  --tests '*SessionControlPreparationTest' --tests '*SessionResponseInboxTest' \
  --tests '*SessionCreationDraftTest' --tests '*SessionWaitingPolicyTest'
apps/android/gradlew -p apps/android lintRelease assembleDesignReview assembleDesignReviewAndroidTest
```

按失败用例选择相关测试，不因写文档重跑全套。构建不应自动安装、启动 Agent 或改变配置。构建工具/依赖不可用时保存失败日志并记 BLOCKED，不能改用真实 Agent 操作代替测试。

### API 37 探针入口

使用新的 [`scripts/check/android-session-qa.py`](../scripts/check/android-session-qa.py)。它要求显式选择已启动的 API 37 模拟器，校验 review/test APK manifest、runner、设备和 API 后安装；不会创建 AVD 或安装生产包。语言参数是 **`en,zh-CN`**，不是 `en-US`。默认 12 个 probe × 2 种语言共 24 个 L2 实例，不能与下文八格 L3 路由矩阵混为一谈。

保留已有授权与数据的执行示例（serial 须现场核对，输出目录须新建）：

```sh
python3 scripts/check/android-session-qa.py \
  --serial emulator-5580 \
  --output .local/agent-session-qa/matrix-01 \
  --app-apk apps/android/app/build/outputs/apk/designReview/app-designReview.apk \
  --test-apk apps/android/app/build/outputs/apk/androidTest/designReview/app-designReview-androidTest.apk \
  --locales en,zh-CN
```

`emulator-5580` 仅为示例，执行前须现场核对；`--output` 必须不存在，不得覆盖已有证据。主模拟器已有授权、Keystore 和未决操作必须保留，不使用 `--reset-review-data`，也不通过卸载重装清除数据。恢复类 probe 在隔离 case 内构造生命周期，不重置原测试身份。真实 native 操作未决时，先沿原身份和 journal 只读核对，不运行会重新安装 APK 的通用入口。

定向回归可用 `--probes approval-actions --locales en,zh-CN` 并选择新的输出目录。`DEFAULT_PROBES` 为 `session-response,codex,providers,new-session-receipts,new-session-composer,composer,codex-panel,session-blocker,plan-mode,provider-access,approval-actions,session-cancellation`。`agent-open` 已在允许集合中，通过 `--probes agent-open` 显式选择，不属于默认矩阵；其他可选 probe 以脚本 `PROBES` 为准。`background-soak` 仅在单独选择时允许 `--timeout 2400`，默认仍为 240 秒。`native-phone-gateway` 不进入通用 runner，使用独立显式授权及 0600 bootstrap 流程。

summary 记录两 APK 的 SHA256/size、Git HEAD/diff 摘要与 runner SHA256。安装使用已验证的只读 APK 副本，并在验证前后、安装前后核对共享源文件，变化即停止；Git 元数据不可读标为 unavailable，不据此推断源码一致。

脚本输出 `summary.json`、逐 locale/probe 日志和 crash 日志，失败时补截图/UI hierarchy/system 日志；未执行、超时、中断和证据抓取失败均保留。成功须满足唯一 `INSTRUMENTATION_CODE: -1`、正确 probe、精确主 locale、非空且以 `PASS:` 开始的 stream；零测试/中断不能通过。总体退出码 0/1/2 分别表示全通过、用例或证据失败、环境准备失败；完整结果还应核对 summary 的 complete/passed 和 cleanupErrors。

[`ApprovalActionsProbe.kt`](../apps/android/app/src/androidTest/java/io/github/junweiup/vibepier/remote/ApprovalActionsProbe.kt) 对 Codex/Claude 与 allow/deny 循环，覆盖能力恢复/丢失、提交中防重复及确认后关闭。决定按钮使用 `MotionEvent.ACTION_DOWN/ACTION_UP` 和 `uiAutomation.injectInputEvent` **真实触摸分发**；进入页面的辅助步骤仍有 performClick。它校验 provider、allow 和 fingerprint，但 native 结果为合成，属于 L2，不能计作真实桌面审批或 UDP/WSS E2E。它直接承接 A02/A03/A04 与 D01 的部分回归，不代表 A05 全部卡片复用场景或其他故障用例已覆盖。

旧 `scripts/check/android-emulator.py` 仍只接受 API 33/35/36，新入口只导入其结果校验函数；本轮不调用旧入口启动其他 API。真实 native 接缝由 `NativePhoneGatewayTests` / `NativePhoneGatewayProbe` 独立执行，不启用 `codexFixture` 等合成结果；它使用测试专用 TCP，生产 L3 路由和正常应用 UI 仍须独立验收。

## 必跑矩阵

| 单元格 | Provider | Android locale | 活动路由 | 必跑用例 | 状态 |
| --- | --- | --- | --- | --- | --- |
| C-Z-D | Codex | zh-CN | UDP 直连 | C01、M01、S01、A01、A02、A03 | NOT RUN |
| C-E-D | Codex | en | UDP 直连 | 同上 | NOT RUN |
| C-Z-R | Codex | zh-CN | WSS 中继 | 同上 | NOT RUN |
| C-E-R | Codex | en | WSS 中继 | 同上 | NOT RUN |
| L-Z-D | Claude | zh-CN | UDP 直连 | 同上 | NOT RUN |
| L-E-D | Claude | en | UDP 直连 | 同上 | NOT RUN |
| L-Z-R | Claude | zh-CN | WSS 中继 | 同上 | NOT RUN |
| L-E-R | Claude | en | WSS 中继 | 同上 | NOT RUN |

L2 的页面、禁用原因、错误、等待与回执提示覆盖两种语言。其余故障用例按下表层级执行；涉及 L3 的故障用例每个 provider、每条路由至少一次，默认 zh-CN，再以 en 核验结果文案。多设备至少覆盖 A=UDP/B=WSS 和交换路由；不能只记录“两台在线”。

## 创建、模型与发送用例

下表每一行默认 **NOT RUN**。步骤中的“注入”只用于隔离测试；L3 使用真实正常入口，不能修改生产日志伪造回执。

| ID / 层级 | 前置与步骤 | 断言与证据 |
| --- | --- | --- |
| C01 / L2+L3 | 进入对应 provider 的专用项目 → 新建 → 等 options 完成 → 输入唯一标记并提交一次 → 等创建回执、原生首条与回复 → 打开桌面同会话 | 一个新 native thread/session；cwd 正确；首条只出现一次；手机/native 身份一致。分别记录“已建线程、已提交首条、回复结束、桌面可见”。Codex 首条应在桌面执行；Claude CLI 首轮后 adopt 是否成功单列，不把 CLI 成功当作桌面实时成功 |
| C02 / L1+L2 | 创建选项读取挂起；切项目或 provider，再释放旧响应；同 draft 重读；选中模型后让新目录不再提供它并提交 | 旧响应不替换当前 draft/cwd；同 draft 只读刷新不重复创建；已删除选项拒绝或要求重新选择，零 native 创建 |
| C03 / L1+L2 | 在 reserve 后、native 已创建后分别丢弃回复；查询原 operation，再重建客户端 | 保存原 draft 与 operation；迟到回执保留新 thread/cwd；原首条不得重发；有线程无首条时显示部分结果或 unknown，不假定完成 |
| M01 / L2+L3 | 新建时从实际目录选模型；创建后再次打开模型菜单，选另一可用项并发送标记消息；只有一个模型则记录该分支 BLOCKED | 选择来自该 provider 的真实目录；配置回读 effectiveOptions 与所选一致；发送用原生身份证明。无模型标签串到另一 provider；桌面/手机一致或明确回读 warning，不能宣称全项成功 |
| M02 / L1+L2 | options/configure 回调挂起；切会话或 adapter；返回旧模型结果；注入回读不一致和不支持 effort/serviceTier | 不污染新页面；不支持项不下发；configure 缺有效回读保持 unknown；未知配置不自动重复提交 |
| S01 / L2+L3 | 打开已创建会话，等完整 snapshot/可写状态 → 发送唯一文本一次 → 等原生消息和 turn → 等回复结束 | native 用户消息恰好一条、目标身份正确；“提交确认”与“任务完成”区分；中英文等待/错误提示完整；切换 provider 后无串会话 |
| S02 / L1+L2 | pending send 已保存后模拟断线/超时；连续点击发送或重进页面；核对结果 | 同一未知原文不重复写；只发 operation.get；晚到确认可清 pending；不能凭未找到消息判 rejected |
| S03 / L1+L2 | snapshot 准备期间使 lease 过期/dirty，再返回新完整快照；另一分支持续 dirty 到准备期限 | 可恢复分支只读重试后首次提交一次；持续变化有界结束并解释不可用，零 native 变更；不无限等待、不反复点击 |
| S04 / L3 | 分别准备锁定桌面、无可用解锁条件的场景，尝试新建/发送；只操作专用测试会话 | 可解锁时按实际桌面路径执行；不可解锁时明确失败/不可用，不转后台补发。记录锁屏准备是否可执行及恢复结果，不把假 ScreenLock 测试当真机证据 |

## 审批与“点击无响应”用例

| ID / 层级 | 前置与步骤 | 断言与证据 |
| --- | --- | --- |
| A01 / L2+L3 | 产生一条可手机决定的审批 → 点击卡片“审阅请求”一次 → 有 detailsOnDemand 时等详情 → 阅读到底 | 可见弹窗或明确加载/失败提示；不得静默无变化。截图/录屏记录点击前后，L2 记录详情读取计数。页面切换期间的旧卡片点击不作用于新会话 |
| A02 / L2+L3 | 新鲜审批，核对目标/完整内容 → 阅读到底 → Allow once/允许一次 → 观察原生决定及标记动作 | 一次提交、一次原生允许；原 fingerprint/submitted 回执后 UI 结算；没有永久允许；专用标记动作完成。关闭弹窗或网络发出不足以通过 |
| A03 / L2+L3 | 为新的独立请求重复准备 → Deny/拒绝 → 观察原生记录和文件基线 | 原生拒绝恰好一次，预定文件动作未执行；手机显示原请求已处理；不得把之前允许的结果误关联本次拒绝 |
| A04 / L2 | 展示长详情；未到底点击 allow；滚到底再观察；另开新请求测试 deny；逐一设置 disconnected、缺控制、unsupported、已提交 | allow 阅读门禁有效；deny 依当前独立规则处理；各禁用态有可见原因。缺控制证据只触发一次页面级刷新；得到新控制后按钮可恢复，不保持无解释灰态 |
| A05 / L2 | 同 ID/fingerprint 的卡片被 timeline 复用；分别触发同页内容刷新、切 thread、切 provider、退后台/返回，再真实分发点击 | 当前有效卡片能打开；旧 scope 卡片不能打开新目标。用 hit test/实际按钮点击覆盖，不仅直接调用 showApproval；按三层计数定位 UI handler、request、native 是否发生 |
| A06 / L1+L2 | 打开 fingerprint F1/revision R1 弹窗；提交前刷新为同 ID 的 F2 或 R2；点击旧按钮 | 旧选择不得批准新内容；提示重审或返回 agent_approval_changed/对应安全拒绝；native 变更计数 0；不能只更新请求指纹继续发送 |
| A07 / L1+L2 | Allow/Deny 分别在 native 已执行后丢回包 → 点击“检查结果” → 注入匹配的迟到确认，再注入重复和错误 fingerprint/operation/target 回执 | unknown 时不提供新的相反决定；匹配确认仅结算原操作；错误回执不能清 pending；native 总调用 1，重复回执不重复执行或污染当前页 |
| A08 / L1+L2 | 保存原决定但在 Mac reserve 前丢请求；operation.get 返回 notFound → 用户显式重试原选择；让原包与重试包乱序到达 | 同 operationId、同原 body，仅 requestId 更新；Mac 至多执行一次；notFound 前不允许自动重发。再以 unknown/accepted 替代 notFound，必须只读核对 |
| A09 / L1+L2+L3 | 两个独立授权 API 37 设备打开同一审批；A 允许后 B 用旧页面拒绝；L1 另测 B 使用 A lease/operation 及 A 撤权 | B 旧决定拒绝/刷新，原生一次决定；B 不能借 A lease；日志与回执按可信设备隔离；撤权后的新变更不执行。L3 不伪造鉴权数据，仅经各自正常 UI |
| A10 / L1+L2 | 详情请求挂起时审批在桌面消失或 fingerprint 改变，再回旧详情；提交后在等待时切 provider/thread | 旧详情不再打开；旧完成只更新原操作，不能关闭新弹窗、恢复新页面权限或把 approvedHere 加到错误会话 |
| A11 / L1+L2+L3 | 未决审批提交后重建 Android Activity/进程；另测 Mac 在持久 reserve 后重启；重连后核对原操作 | pending 保留；重新获取 lease；只读恢复，native 不重复决定。原生证据已丢时允许持续 unknown，不能恢复成 notFound。L1 在临时文件重建对象；L3 仅正常重启被测实例，不修改生产 journal |
| A12 / L1+L2 | Mac reserve 失败、native 成功后 complete 失败、Android pending 保存/清除失败四分支 | reserve/pending 保存失败零 native 执行；complete/清除失败保留未知而非显示成功；恢复后只读核对原 operation；检查日志调用次序 |
| A13 / L1+L2+L3 | 触发原生问题或选项审批，按实际 allowedDecisions/选项提交；Claude 同 host 多 pending 场景单列 | 问题必填约束与原生选项一致；不能默认 allow。Claude 多 pending 或不支持的计划 scope 明确引导 Mac，零猜测点击；未能产生原生分支记 BLOCKED |
| A14 / L1+L2 | 假原生动作返回“已点击”但无匹配原生答案，或 owner 在动作前变化 | 不确认成功；动作前可确定拒绝，动作后缺证据 unknown；不再补点、不换 driver、不把卡片消失当答案 |

## 恢复、隔离与路由用例

| ID / 层级 | 步骤 | 断言与证据 |
| --- | --- | --- |
| R01 / L1+L2+L3 | 挂起创建/发送/审批之一，在 UDP 与 WSS 间切换再恢复；分别核对原 operation | 连接恢复不产生新变更；仍使用原操作身份，目标 provider/session 不变；记录实际切换路线而非设置页选项 |
| R02 / L1+L2 | 对 observer 输入连续 content-only 事件、乱序/缺口/旧 streamEpoch；随后提供权威 snapshot | 普通内容流不无故撤销有效控制；控制变化/序列缺口要求 resync；旧流不恢复旧 lease；不会因为刷新频繁导致按钮永久失效 |
| R03 / L1+L2+L3 | Codex A 与 Claude B 各自创建/发送；快速切页，延迟 A 回调直到 B 已打开；重启后再打开两者 | 目录、模型、消息、审批、回执均隔离；持久 descriptor 不恢复写权限；两边 desktop/native ID 与手机正确对应 |
| R04 / L2+L3 | zh-CN/en 下走失联、权限不足、审批已变更、unknown、notFound 与成功路径 | 提示不缺资源/不暴露原始内部对象；按钮语义区分检查结果、原选择重试、允许一次和拒绝；保留稳定常规布局，不扩大到小屏测试 |

## 已确认缺陷的专项回归

D01–D09 定义已定位边界的专项回归。当前实现接缝见配套架构文档；执行时固定候选源码及二进制，实际结果引用验证报告，不在本计划填入通过数。

| ID / 对应矩阵 / 层级 | 缺陷与可执行复现步骤 | 修复后必须满足的断言 |
| --- | --- | --- |
| D01 / A01、A04 / L2 | 审批弹窗保持打开，先给不可写页面，再通过 applyPage/updateComposer 更新为完整可写页面；反向撤销能力；分别切换 allow/deny/options/questions | 无需关闭重开，局部 update 随页面与 composer 状态更新；按钮启用、原因文案、unknown 检查入口一致；撤权立即不可提交。覆盖 API 37 中英，保留打开弹窗前后的实际点击证据 |
| D02 / S03、A07、R03 / L1+L2 | 挂起发送准备的 preserved agentRequest snapshot，切后台触发 cancelPageReads，随后返回 snapshot；另测返回时 identity/view 已变化；再挂起普通非 preserved 读取作对照 | preserved 条件覆盖整个取消谓词而非仅 v1 分支；依赖回调不丢失且最多完成一次；作用域未变可完成既定准备，已变安全结束；普通页面读取可取消；不得出现永久 sending 或偷偷重发 |
| D03 / C02 / L1+L2 | 连续打开/关闭创建面板，确保 v2 creationOptions 使用与 UI 操作 ID 不同的 requestId；挂起回包后取消，循环 120 次并最后返回旧回包 | 每次取消定位实际 transport requestId，pending/回调/选项读取配额回到基线；旧回包不能覆盖新 draft；不得取消真实 create mutation 或 receipt；v1 newOptions 取消仍正确 |
| D04 / A06、A09、A13 / L1+L2，L3 可产生时复核 | 合成同 host 两个同名工具调用 A/B，内容不同且均无 tool_result；权限日志仅 B pending，另测两者都 pending；颠倒 transcript 次序，点击展示卡片 | 不用 first 按工具名猜配对；不能展示 A 内容却批准 B。缺唯一关联时不可决定并有 Mac 处理提示；若可证明唯一配对，详情、toolUseId、requestId、fingerprint 与最终答案必须同属该请求 |
| D05 / A07、A11、A14 / L1+L2，L3 opt-in | 一次 Claude 审批点击后将原生 waitAnswered 的相符答案延迟到超过 5 秒；先观察 unknown，再交付迟到答案并 operation.get；另测错误 request/decision/host、重复答案和 Mac 重启 | 超时不补点；迟到 observer 只读原请求证据，匹配后可补确认，native 点击总计 1；不匹配保持 unknown。observer 有容量和生命周期边界；重启若丢内存证据必须如实 unknown，不能假定全部可恢复 |
| D06 / C02、R03 / L1+L2 | 新建弹窗保持打开，挂起 options 后退后台，再回前台；对照断线重连、切 provider/cwd/draft、关闭弹窗，以及已有未决创建 | `recoverCreationOptions` 在同一有效 scope、无未决创建且非 busy 时恢复只读选项；旧响应不覆盖新 draft；关闭后清理回调；保留输入与原操作，不重新 create 或发送首条 |
| D07 / A07、A11 / L1+L2 | 原审批结果 unknown，撤掉写能力但保留连接及授权，点击“检查结果”；再分别注入 disconnected、未授权、inFlight 和 notFound 后显式重试原选择 | `approvalReceiptEnabled` 允许无写能力时只读 `operation.get`，不要求 canDecide；未连接、未授权或请求进行中不可检查；重试原选择仍要求 canDecide，原 operation/fingerprint 不变，核对不得变成新审批 |
| D08 / S01、R02 / L1+L2 | 同一队列提供不同 `canSteer`/`canDelete` 组合（含 false/缺失），保留全局能力；刷新某一行能力并尝试逐行点击 | 每行 steer/delete 分别要求对应字段显式为 true、全局支持且页面未 blocked；某行允许不授权其他行；禁用点击零请求，启用仅提交该行 ID，不用全局能力替代行级权限 |
| D09 / A04、A13 / L1+L2 | 展示只读选项审批，选项内容可见但缺审批能力；保持弹窗打开，依次恢复、撤销能力，并对照已提交/unknown 状态 | 只读展示不启用选项决定按钮；按钮随当前 scope、mutableReady 和审批能力更新，点击禁用项零提交；恢复能力仍校验原 fingerprint/revision，unknown 只保留原操作核对入口 |

D10（Codex 新鲜快照）追加验证：先让同一 view 缓存 owner A / revision 100，再丢失最后一条广播；`session.snapshot` 必须触发只读 owner discovery 与新到达的完整 snapshot。分别覆盖 owner 不变、A→B 且 revision 降到 1、错误 owner 回包、discovery 失败及 snapshot 超时。失败不得回退旧 complete 状态，不签发或保留旧可用 lease；不得打开新桌面窗口、发送消息或重试变更。通过临时 Unix socket fixture 先红后绿，再对已确认的专用原生会话只读核对。

D02/D03 必须在真实 SessionClient 的 pending/cancel 边界验证，只有 SessionAgentClient 的独立测试不足以覆盖。D04 不能只测“两个 pending 因 guard 被拒绝”，还需覆盖“两个同名未决 tool_use，但仅 B 有 pending 权限请求”的危险配对。

## 已实现的 native 接缝与生产路由边界

`NativePhoneGatewayTests` / `NativePhoneGatewayProbe` 已实现隔离 Mac host 与非 BLE 测试授权接缝。它通过真实测试 TCP 传输，复用 Android SessionClient 加密、SessionPacketInbox、SessionEnvelope、AgentSessionService、私有 journal 和真实 Codex/Claude adapters；这不是生产 UDP/WSS、RemoteSender/SessionRemote 路由或 BLE 首次配对验收。接缝存在不等于任一真实用例通过，结果仍须引用独立证据。

此入口由独立流程显式授权，测试 bootstrap 必须为私有 0600 文件，不进入参数、日志或共享存储；不使用生产手机密钥，不为生产服务增加跳过鉴权的判断。测试 host 持有独立 directory/trust/journal，测试 sender 仍须与预置授权身份一致。`native-phone-gateway` 不在通用 runner 允许集合中。原生操作未知时保留原身份、Keystore 和 journal，不清数据、不重新导入 bootstrap、不换身份补发；跨进程查询恢复不能视为已实现能力。

生产 UDP/WSS 八格矩阵另行记录活动路由与正常 UI 证据；测试 TCP 的成功不能替代任何一格。未实际执行的项目保持计划占位，环境受阻须附缺失项；仅 API 37，不改用 Mi 10 扩大范围。

## 已有测试与新增工作边界

- L1 可复用 `SessionAgentClientTest` 的预留、notFound、重连与本地存储失败；`SessionAgentConversationTest` 的控制准备、旧 view、审批变化与未知操作只读查询；`SessionResponseInboxTest` 的回包校验。
- Mac 可复用 `AgentSessionServiceTests` 的审批 ID/fingerprint/revision、跨手机 lease、dirty 事件、晚到回调、journal 失败；`SessionReceiptJournalTests` 检验持久边界。存在测试函数不代表本轮运行通过。
- A05 的真实点击/卡片复用、A07/A11 的完整 UI 状态恢复如无现成断言，应补隔离探针；文档不声称这些缺口已经修复。原生 AX/IPC/CLI 是否真的执行只能由 L3 补证。
- 单元故障注入应控制 send/execute/journal/scheduler 回调，不通过 `sleep` 猜竞态；设置有界等待并断言执行次数。所有文件、偏好和假 journal 使用测试隔离位置。

## 结果记录与结束标准

每个实例记录：`caseId + matrixCell + layer + status + sourceRevision + binaryVersion + actualAPI + locale + route + adapter + steps + expected + actual + evidence + blocker`。同一 case 的合成与真实结果分行。证据引用脱敏截图、测试 XML/日志和专用项目结果；不记录密钥、消息正文、附件内容或完整 lease。真实 ID 仅在受限证据中保留，对公开报告用一致别名关联。

审批失败先回答三个问题：点击 handler 是否进入、客户端是否产生请求、Mac/native 是否执行；再核对 fingerprint/revision、lease、journal 阶段。没有这些证据时写“根因未定位”，不要把超时直接归因于网络或桌面权限。

完成标准：八个 L3 矩阵单元格的基础用例都有独立结果；关键审批异常在指定层级有证据；所有 FAIL/BLOCKED 保留，未跑项显式列出；修复后只回归相关用例和受影响矩阵。结束报告分别汇总创建、首条、模型回读、后续发送、审批和桌面可见性。恢复测试中主动改变的测试网络/语言/进程状态，保留失败证据；**不安装 Mi 10，不把计划、构建或合成探针当作正式交付**。

## English summary

This is a plan, not a result report. Authoritative results and exact evidence are recorded in `.local/agent-session-qa/VALIDATION.md`. The scope is Android API 37, Codex and Claude Code, Simplified Chinese and English. Production direct UDP and WSS relay remain separate acceptance targets. Real Agent actions are limited to authorized dedicated projects; do not install Mi 10.

The runner defaults to 12 probes across two locales (24 planned cases), including session-cancellation. agent-open is optional. Preserve the existing emulator authorization, Keystore and pending operations; do not reset review data. D01–D10 cover approval refresh, cancellation, late evidence, creation-option recovery, read-only receipt checks without write capability, per-row canSteer/canDelete disabled read-only option decisions and fresh Codex owner/snapshot verification.

The implemented native gateway uses an explicitly authorized test TCP channel and private 0600 bootstrap. It is excluded from the general runner and does not prove production UDP/WSS, BLE pairing or normal UI behavior. Synthetic touch probes, real native execution and durable confirmation require separate evidence. A CLI-created Claude session alone does not prove live desktop visibility.
