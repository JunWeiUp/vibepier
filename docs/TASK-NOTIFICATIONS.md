# Task completion notifications / 任务完成通知

## 中文

在手机设置中点击「任务完成通知」，授予系统通知权限。以后可从同一入口管理声音或关闭此类通知。Mac 检测到 Codex、Claude 或 ZCode 的新一轮任务正常完成后，通过手机现有的授权加密连接发送通知；无需停留在会话页，返回首页或切到后台也可接收。

- 复用原生任务活动检测器的确定完成信号，失败、中断、首次扫描历史及重复完成版本不触发通知。
- 通知仅显示服务商名称和完成提示，不包含会话标题、消息正文或附件；点击直接打开完成任务的对应会话，支持冷启动及应用已打开的情况；通知绑定原 Mac 的授权身份，切换或重新配对后旧通知不跳转。每个服务商保留一条最新通知。
- 手机保存最近 256 个完成事件的去重标识（加密存储）。权限关闭期间的事件不会在开启权限后补发。
- 需要更新 Mac 和 Android 两端并保持连接。没有离线推送、离线消息补发或进程被系统终止后的唤醒；断开连接、退出后台服务或强行停止应用时不保证通知。系统勿扰模式、通知设置和省电策略仍可能限制提醒。

## English

Open **Task completion notifications** in the phone settings and grant notification permission. Use the same entry to manage sound or disable this channel. Newly confirmed Codex, Claude and ZCode task completions travel over the existing authorized, encrypted Mac connection. Notifications work on the home screen and while the app is in the background; an open conversation is not required.

- Reuses the native activity detector's confirmed completion signal. Failures, interruptions, initial history scans and repeated completion revisions do not alert.
- Only the provider name and a completion prompt appear, with no conversation title, message body or attachments. Tapping opens the completed conversation, both on cold launch and while the app is open. Notifications are bound to the original Mac authorization identity; stale notifications cannot navigate after switching or re-pairing. Each provider retains its latest notification.
- The phone stores the last 256 event identities in encrypted preferences for deduplication. Enabling permission does not replay events received while notifications were disabled.
- Requires updated Mac and Android apps and a live connection. There is no offline push, offline replay or wake-up after process termination. Disconnecting, stopping the background service or force-stopping the app prevents delivery. System notification, Do Not Disturb and battery policies can limit alerts.

## Implementation

`ConversationActivityLedger.completionEvent` compares native completion revisions against an established baseline independently of unread state. `ConversationActivity.refresh` forwards new events to `SessionRemote`, which uses existing trusted routes, the bounded event queue and encrypted session envelopes. The `notificationSubscribe` read-only operation establishes a route after connection or authorization, even when no conversation has been opened. Existing transport heartbeats maintain the route lease.

Event payload: `{"event":"taskCompleted","eventId":"<64 lowercase hex SHA-256>","provider":"codex|claude|zcode","threadId":"<session ID>"}`. The identity hashes provider, session ID and completion revision separated by NUL; the session ID is included only inside the encrypted event to route the notification, without titles or content.

The Android session client belongs to `RemoteSender` and survives Activity recreation while `RemoteConnectionService` retains the connection. UI callback detachment leaves encrypted event handling active. `TaskCompletionNotifications` validates and deduplicates authenticated events before posting to the `task_completion` notification channel. Design-review fixtures do not subscribe or post completion notifications.

Android permission and channel behavior follows [Android notification permission documentation](https://developer.android.com/develop/ui/views/notifications/notification-permission).

## Quick reply / 快捷回复

A task-completion notification offers **Reply** (Android `RemoteInput`), usable from the shade or lock screen. The text is sent only through the live, authenticated session client of the authorization that posted the notification, as an ordinary journaled `send`; the notification is then replaced with the actual state (sending, sent, unknown or not sent). An unknown result is never resent automatically, and a missing connection or a session the phone has not opened asks the user to open VibePier instead.

任务完成通知提供「回复」（Android `RemoteInput`），可在通知栏或锁屏直接使用。文字只经发出该通知的同一授权、当前在线的已认证会话客户端，以普通的带回执 `send` 发送；随后通知改为真实状态（发送中、已发送、结果未知或未发送）。结果未知时绝不自动重发；连接未就绪或手机尚未打开该会话时，提示打开 VibePier 处理。

