# Screens and navigation / 页面结构

VibePier has native views and windows, not URL-based web routes. Provider deep links are implementation details for opening the matching desktop session; they do not create a public VibePier web router.

## Android

| Screen / entry | Content and owner | Leaving the screen |
| --- | --- | --- |
| Remote home | Connection status, current Mac app, six controls, voice button and application dock; `MainActivity` | Release held controls and recording on loss of focus/background. |
| Connection picker | Bluetooth, local Wi-Fi, cloud relay and explicit disconnect | Preserve the user's selected mode; setup sync does not silently switch it. |
| Settings | Connection/voice/privacy-related choices in `SettingsSheet`; usage page is separate | Persist settings through their owners; retain the single service transport. |
| App picker | Bottom dock Configure apps / empty slot / long-press; search installed Mac apps, add, replace or clear slots | Never launch an app on selection; retain source Mac identity and reject stale revisions. |
| Key configuration | General and application profiles with a dedicated binding editor | Keep the edited profile fixed even if the Mac's frontmost app changes. |
| App usage | Opt-in recorded usage and time-of-day segments | Respect the source Mac identity; missing periods are not invented. |
| Session list | Provider selection, project/search filters, recent sessions and new-session entry; `ConversationPanel` | Preserve navigation scope; close obsolete subscriptions. |
| Session detail | Conversation, lazy tool output, composer, attachments, supported settings/approvals/queue | Keep draft/uncertain receipts, cancel old reads and image work. |
| Markdown/image viewer | Native rendering of a permitted file/image from the current session | Cancel scope-bound work; do not turn references into arbitrary network fetches. |
| Session menu | Lock, Unlock, optional Mac unlock setup and explicit reauthorization | First connection still requests approval automatically, outside this menu. |
| APK installation | Download/verification state, confirmation and system installer | Distinguish downloaded, awaiting permission/confirmation, installed and unknown result. |

`ConversationNavigation` owns opening/closing the session overlay and document-picker return. Underlying remote controls are inaccessible while the overlay is visible. Cancelling the document picker preserves the conversation and draft. A provider change changes the complete draft/cache/request scope, not only the visible heading.

## macOS

| Window / scene ID | Contents |
| --- | --- |
| Menu-bar panel | AU05/phone connection status, task activity and entry points to settings. The menu mark also shows independent task activity. |
| `au05-settings` | Optional hardware settings, heartbeat choice, voice/input settings and explicit microphone permission action. |
| `bindings` | AU05/desktop host bindings. |
| `phone-remote` | One sidebar window with connection, phone bindings, application slots, authorized session access, relay setup and APK delivery pages. |

`PhoneRemoteNavigation` selects the desired sidebar page when a menu action opens the window. The shared `DeviceModel` observes the embedded runtime. Permission dialogs occur only when needed for an explicit feature; repeatedly opening a settings window must not create another runtime or connection.

## Required states

Every connected feature must distinguish discovery, pending authorization, ready, reconnecting and unavailable state. Cached content can remain readable while controls are unavailable. A pending request cannot be submitted again with a new identity just because the screen reopened. Error text must tell the user whether to reconnect, approve on the Mac, configure a feature, check the Mac's result, or use the desktop for an unsupported action.

A “connected” transport does not itself prove session readiness, a direct UDP path, microphone readiness or successful installation. Show these separately where the distinction affects the next action.

## 中文说明

手机以遥控首页为入口，连接、设置、改键、用时统计和会话各有独立界面。会话覆盖层统一管理来源、项目、详情、文件选择和返回；底层遥控不能同时被读屏或触摸操作。会话菜单提供锁屏、解锁及密码设置，首次授权不依赖这个菜单。

Mac 使用菜单栏面板、AU05 设置、按键绑定和手机遥控窗口。手机遥控窗口内含连接、按键、应用入口、授权、中继和 APK 六页。连接成功、会话就绪、麦克风就绪和安装成功是不同状态；界面不能混用这些提示。

See [architecture](ARCHITECTURE.md) for ownership, [design](../DESIGN.md) for appearance, and [components](COMPONENT-GUIDELINES.md) for implementation rules.

New-session dialogs keep an unresolved first message locked for result checking. Reopening restores the saved request; only an explicit retry after a Mac `notFound` response can resend it, using the same ID and body.

新建会话结果未知时，弹窗保留并锁定原首条消息，重新打开仍可检查回执；只有 Mac 明确返回未收到后，才能手动重试同一请求，不生成新 ID。

Phone key editors on Android and macOS support editing the key name together with its shortcut. Names appear on the Android remote and in both configuration lists, sync with the binding revision, and follow the general/application profile inheritance. Restore defaults/inheritance resets both fields. Names are required when saving and limited to 200 characters; application names remain separate. Settings export/import includes custom key names.

Android 与 macOS 按键编辑器支持同时修改按键名称和快捷键。名称显示在手机遥控页及两端配置列表，随按键版本同步，并遵循通用与应用专属配置继承规则。“恢复默认/继承”同时重置名称和快捷键；保存时名称不能为空，最多 200 个字符。按键名称与应用名称独立，设置导出/导入包含自定义按键名称。

MP4 links (including Markdown media embeds) in Claude Code and Codex conversations open an in-app video preview; MP4 entries in the project file browser use the same player. The phone downloads the complete file through the authorized encrypted session channel, then offers play/pause and seeking. Preview accepts MP4 files within the selected session workspace up to 128 MiB; network video links and files outside that workspace are unsupported. Playback depends on Android codec support (H.264/AAC is the tested format). Closing the viewer stops playback and removes the private temporary file; backgrounding closes the viewer and stops playback.

Claude Code 与 Codex 会话中的 MP4 链接（包括 Markdown 媒体嵌入）可打开应用内视频预览，项目文件列表中的 MP4 使用同一播放器。手机通过已有授权加密会话通道下载完整文件，再提供播放、暂停与进度拖动。支持所选会话项目目录内、不超过 128 MiB 的 MP4；暂不支持网络视频链接或项目目录外视频。编码兼容性取决于 Android 系统，已测试 H.264/AAC。关闭预览停止播放并删除私有临时文件，进入后台关闭预览并停止播放。
