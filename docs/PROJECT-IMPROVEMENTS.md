# Reliability and interaction improvements / 可靠性与交互改进

Build 11 continues the published preview with focused fixes. The existing public beta remains build 8; the newer source and local packages do not replace that release or imply installation on a phone. Native sending acceptance remains deferred by the maintainer's existing decision.

| Area | Result |
| --- | --- |
| Voice source | Refresh the effective microphone source when capabilities change. Losing the phone-audio path stops the current recording and releases the gesture; it does not change source during the same hold. |
| Activity and attachments | Save non-content navigation and pending picker ownership. Restore the same authorization epoch, provider and thread; defer the returned attachment until that page is ready. Changed authorization or unrecoverable creation-dialog ownership asks for reselection. |
| Session actions | One stable Stop task action in the header; Send and Queue send have visible labels. Stop waiting stays in the chat, interrupts a verified turn or ends local waiting, and preserves unconfirmed receipts with duplicate-send protection. |
| Conversation rendering | Reconcile by message ID, retain unchanged views and live process expansion, and preserve a visible-row scroll anchor. Navigation, actions and timeline rendering have separate helpers. |
| Updates | One phone update detail shows installed/registered versions, connection and receiving/installing state. Request only the authorized Mac's registered newer APK. Unknown requests are not automatically repeated. |
| Mac APK preparation | Two bounded workers perform immutable copying and hashing outside session routing. Completion validates the original phone key/reservation. Cancellation, revocation, a replaced key or registered release cannot publish obsolete work. |
| APK actions | Typed preparation/transfer/permission/installation/terminal stages drive buttons. Busy transfers cannot be replaced implicitly; system-owned installation cannot be cancelled from the Mac. Devices show identity and online state. |
| Notifications and settings | Completion notifications open the correct provider's recent list without exposing conversation content. Settings update existing segmented choices instead of replacing focused nodes. |
| Mac feedback and devices | Restore defaults confirms success before clearing drafts. Command feedback belongs to an operation and clears recovered errors. Online phones are deduplicated by authorized ID across transport routes. |
| Claude history | Stream metadata and maintain a private disposable offset/ID index. Decode requested turns only, with a shared bounded body cache; fetch older parts/images by their original IDs. Native JSONL and receipt evidence remain intact. |
| History limits | A requested turn exceeding the 8 MiB decoding budget is explicitly unavailable on the phone; its complete source remains on the Mac. Large histories are not silently truncated or used to infer success. |
| Relay | A 12 MiB shared output budget includes queued and in-flight frames across rooms. Closing drains reservations. Fixed close categories and aggregate counts omit rooms, endpoints and payloads. This is not a bound on total process RSS. |
| Diagnostics | Preview/copy fixed transport categories, path, authorization and reconnection counts on the phone. No addresses, device identities, credentials, message bodies or raw exceptions enter the report. |
| Packaging and CI | Build-number directories and source/digest sidecars preserve previous artifacts. Source/staging changes and conflicting bytes are rejected. Android candidate PR checks use one API 35 smoke plus the related runtime/conversation/APK probes. |

The Claude transcript projection, history store, Android timeline/state now have explicit ownership boundaries. Keep later behavior changes separate from additional structural moves; the single-submit and unknown-receipt policy still applies.

## Validation boundaries

Unit tests use temporary files, synthetic JSONL, synthetic devices/processes and injected audio/events. Android runtime probes use the separate `.review` application and synthetic conversations; APK installation probes target only an installation fixture. These checks do not prove real provider sending, physical-device background behavior or Apple notarization. Hosted API 35 evidence exists only after that workflow actually runs, independently of local API 37 results.

## 中文

本轮构建为 11；已发布 beta 仍为 build 8，不移动旧 tag，也不把本地包当作已下发。优先修正麦克风通路、页面重建与附件目标、任务动作、APK 准备与安装阶段；设置分类和已选首页布局延续现有规范。

麦克风通路失效立即停止，不在一次按住中切换收音来源。附件恢复绑定持久授权身份、服务商与会话；无法确认则要求重选。停止任务只保留顶部入口，发送与排队明示，停止等待留在聊天页，有可核验轮次则停止任务，否则结束本地等待并保留回执和防重复发送保护。消息按 ID 局部更新并保持阅读位置。

Mac 文件准备不再占用会话队列，旧工作完成时验证原授权与版本；传输状态驱动按钮，不隐式覆盖正在执行的任务。恢复默认失败保留草稿，在线设备按授权 ID 去重。通知进入对应服务商列表，设置刷新保留控件与焦点。

Claude 使用元数据索引与有界页面缓存，不保留整段历史投影；旧正文、附件与原生回执证据仍在完整源文件中。单轮超过安全解码预算时明确说明无法在手机加载，不静默截断。中继预算计入正在写出的数据，断线释放额度；诊断只展示固定分类，不含地址、正文或凭据。

构建产物进入独立构建号目录，记录源码 commit、dirty 标记、源码摘要和产物摘要，拒绝覆盖不同内容。CI 仅增加相关的单 API 35 冒烟；模拟器与真实设备/原生发送证据继续分别记录。
