# Phone assistant visibility / 手机助手可见范围

The Mac menu contains an **AI coding assistants** card with Codex and Claude Code switches and an enabled count. Only enabled providers appear in the phone conversation drawer. Enabled means permission to expose that provider to authorized phones; it does not claim that the application is installed, signed in or ready.

Mac 菜单新增「AI 编程助手」卡片，分别控制 Codex、Claude Code，并显示已启用数量。只在手机会话页展示启用项。「已启用」代表允许手机访问，不冒充服务商已连接、已登录或可执行。DeepSeek Harness 尚不是 VibePier 支持的服务商，不增加空入口。

## Behavior / 行为

- Existing configurations without provider switches preserve access to the two supported providers. Switch changes save the Mac configuration first; a save failure leaves the confirmed UI and runtime state intact.
- The authenticated session channel carries `providerAccess` (`revision`, two strict Boolean `enabled` fields). `notificationSubscribe` and `providers` return the snapshot; `providersChanged` broadcasts updates to existing authorized routes. Reconnect refreshes the snapshot. The phone caches it in encrypted preferences under the authorization identity and rejects older or conflicting same-revision policies.
- Disabled providers cannot serve fresh discovery, history, file or mutation requests. Read caches, disabled-provider retransmission frames and provider subscriptions are invalidated when policy changes; unrelated APK/control retransmissions remain available. A late read is rejected before it can expose content. Desktop tasks already running or already submitted are not interrupted.
- Existing durable mutation records and read-only receipt reconciliation remain available. Disabling does not delete drafts, attachments or uncertain operations, and receipt queries never resubmit them.
- The phone clears disabled visible caches and notifications, leaves a disabled active conversation, and selects the first remaining provider. All switches off shows an explicit empty state with a working refresh/back path. Restored navigation cannot reopen a disabled provider. Provider selection is not changed before the old draft is saved.
- For a first connection without saved policy, the current phone exposes only Codex and Claude Code when an authenticated older Mac omits `providerAccess`. A saved restrictive policy is not weakened by a host downgrade. A new phone waits for discovery before showing provider tabs. Older phone builds may retain their fixed tabs, but an updated Mac rejects disabled requests; update both ends for the complete UI behavior.

旧配置升级保留 Codex 与 Claude Code 的访问设置。保存成功后才同步；关闭会过滤新请求、停止手机订阅、清除可见缓存与通知，但不停止桌面任务，不删除草稿、附件和未知回执。关闭正在查看的助手会退出该会话；全部关闭时显示明确空状态。重连重新读取，旧修订与同修订冲突数据不能恢复已关闭内容。旧手机的固定标签需更新 APK 才能动态隐藏，Mac 后端限制对旧手机也有效。

These settings are local access policy and deliberately stay outside portable preference archives, so importing keyboard/application settings cannot silently expand phone access.

这是 Mac 本地访问策略，不加入便携设置导出；导入按键与应用设置不会改变助手访问范围。

## Local commands / 本地命令

```sh
vibepier session-provider-set codex off
vibepier session-provider-set claude on
vibepier status
```

The provider-setting command is owner-only through the local control socket. The phone cannot submit this command; enabling a provider is a Mac action. Direct file edits are applied with `vibepier reload`, which advances the policy revision when necessary.

开关写操作仅通过同用户本地控制 socket 提供，不向手机开放。直接修改配置文件后执行 reload；策略变化时补增修订号。

## Verification / 验证

Pure Swift/Kotlin policy tests cover upgrade defaults, all-off persistence, rejection of fresh disabled requests, receipts/controls, revision overflow, stale policies and malformed flags. The injected Mac model test checks save failure and confirmed-state refresh. Native Mac preview uses synthetic status. Android `provider-access` instrumentation uses an isolated encrypted peer and temporary identity to exercise real drawer transitions, cache invalidation, unknown receipt/draft retention and client recreation; it is not a real-device/network acceptance result.

验证区分单测、Mac 合成状态原生预览和 Android 合成加密连接模拟器探针；不把这些结果写成真机验收。生产安装是单独明确操作。
