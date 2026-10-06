# VibePier design / 视觉与交互规范

VibePier should feel like a small extension of the desk: readable, quiet and quick to operate with one hand. The phone emphasizes a large voice control and stable button locations. The Mac uses a compact menu panel with separate settings windows. Prefer clear state and restrained color over decorative framing.

## Color and surfaces

Android currently uses the dark palette. macOS follows the system appearance. Source authorities are Android [Palette](apps/android/app/src/main/java/io/github/junweiup/vibepier/remote/features/remote/Pads.kt) and Mac [VibeAppearance](apps/macos/Sources/VibePierApp/DesignSystem/Appearance.swift).

| Token | Dark | macOS light | Use |
| --- | --- | --- | --- |
| Background | `#0F1416` | `#F3F5F6` | Page/window base |
| Surface | `#161C1F` | `#FFFFFF` | Primary groups |
| Surface 2 | `#1C2427` | `#EEF1F3` | Nested content |
| Surface 3 | `#242D31` | `#E3E8EA` | Tonal controls |
| Text | `#E9EEF0` | `#172126` | Main content |
| Secondary | `#A3AFB4` | `#55636A` | Supporting labels |
| Accent | `#72D4B9` | `#0B7A63` | Primary action, live work, selection |
| Warning | `#E8B86F` | `#865300` | Pending approval / caution |
| Danger | `#E8837C` | `#B4232D` | Error / stop |

Separate surfaces through lightness. Do not outline every card, color every button mint, or use color as the only indication of state. Supporting colors for providers and usage charts must not replace primary status text.

## Typography and spacing

Use system fonts. Android's shared type scale is title 18sp, headline 16sp, body 15sp, label 13sp, caption 12sp and overline 11sp; prominent remote-control labels may use their own hierarchy. Use 4/8dp spacing increments and 12–16dp container corners. Mac groups commonly use 12pt padding and 14pt corners. Scale text with platform settings; do not shrink it to hide clipping.

Small-looking icons must retain a useful interaction area. Shared Android controls use at least a 48dp target even when the visible pill/icon is smaller. Labels need semantic accessibility text; decorative icons must not produce duplicate announcements. Large-type and screen-reader acceptance remain explicit test work, not a consequence of these rules alone.

The key editor sizes its preset column count from localized label width; large-type modifier controls use two columns. The voice caption and key chip live inside the circular microphone control; the source label sits above it. The icon, caption and key chip shift down together by 20% of the disc radius, placing the icon closer to the center. A separate fixed action row holds the release hint and the 140×48dp Delete target. Use the general portrait layout; only the upper context/shortcut region may scroll when content exceeds its space, while voice, Delete and the application dock stay visible. Do not add small-screen variants or dedicated small-screen acceptance work unless the user requests it (see agent.md). Captions wrap at the system font size; the circular gesture boundary is preserved. Delete shows a single icon and label, with its complete binding retained in accessibility semantics.

## Interaction rules

- Android custom actionable controls share a mint hover layer, bounded press ripple and a 2dp keyboard-focus ring. Feedback is drawn above content so selection/background refreshes cannot erase it. Display-only labels stay quiet; disabled controls retain their existing dimmed treatment and do not highlight. The circular voice pad uses a circular hover/focus ring and its existing held animation. Hover never sends a remote action. 安卓自绘可操作控件统一提供薄荷色悬停、限定范围的按下涟漪和 2dp 键盘焦点描边；静态文字无反馈，禁用沿用变淡状态且不高亮。圆形语音键采用圆环反馈，保留按住动画；悬停不触发远程操作。
- Keep the remote surface compact: connection/current-app context above the controls, a prominent circular voice button, deletion at its lower right, and a stable application dock.
- A voice press begins only inside the circle. Releasing, leaving the hit region, losing focus, navigation or disconnection ends it. Re-entering does not restart the same gesture. One pointer owns the gesture.
- Saved application slots stay in place. A temporary current-app slot does not reorder the user's configured shortcuts. Do not allow an application-state update during a touch to turn a launch into an unintended hide.
- Use segmented controls for primary choices and smaller chips for secondary filters. A selected item carries text/accessibility state as well as color.
- Preserve drafts and read position during normal navigation. Show cached data as cached; do not infer current mutation capability from it.
- Pending operations stay visibly pending. Unknown results ask for verification; they are not labeled failed-and-safe-to-repeat. Unsupported actions explain the next useful step on the Mac.
- Opening the Mac menu must not ask for microphone access. Permission requests belong to the relevant explicit action or setting.
- Keep the Mac menu panel's top edge fixed during each opening when task counts or status content change. Resize downward and retain scrolling for long content; reopening uses the menu item's current system position. Mac 菜单面板在同次打开期间固定顶部，会话任务数量或状态内容变化时向下伸缩，内容较多时保留滚动；重新打开按菜单图标当前位置定位。

Native phone UI examples in both READMEs use original emulator captures with synthetic data. [Capture provenance](assets/previews/README.md) distinguishes them from concept illustrations and real-device acceptance.

The conversation composer has an independent **Plan / Execute** task-mode control alongside permissions and model selection. New-session options use the same choices. Show the current verified mode, disable switching while busy or unconfirmed, and dismiss the menu before submitting a change. When Plan includes a native permission mode, hide conflicting permission choices and disclose the default permission on the Execute option.

会话输入区域和新建选项提供独立「计划/执行」入口，显示已核验当前模式；忙碌或待确认时禁用切换，选中后先关闭菜单。计划模式绑定原生权限时隐藏冲突的权限入口，执行选项明确显示采用的默认权限。

## Brand assets

The mark combines a V-shaped approach, a horizontal pier and a separated endpoint. Use the original geometry; do not add provider logos or turn the icon into a screenshot.

| Asset | Source / output |
| --- | --- |
| Editable icon and standalone mark | [icon.svg](assets/brand/icon.svg), [mark.svg](assets/brand/mark.svg) |
| Native asset generator | [brand-assets.swift](scripts/dev/brand-assets.swift), run `make brand-assets` on macOS |
| Mac app icon | [VibePier.icns](apps/macos/Resources/VibePier.icns) |
| Menu mark and task indicators | [MenuBarIcon](apps/macos/Sources/VibePierApp/DesignSystem/MenuBarIcon.swift), [TaskActivityCompositeIcon](apps/macos/Sources/VibePierApp/DesignSystem/TaskActivityCompositeIcon.swift) |
| Android foreground and themed layer | [foreground](apps/android/app/src/main/res/drawable/ic_launcher_foreground.xml), [monochrome](apps/android/app/src/main/res/drawable/ic_launcher_monochrome.xml) |
| README concepts | [at the desk](assets/readme/work-within-reach.png), [away from the keyboard](assets/readme/away-from-the-keyboard.png) |
| Social preview / article cover | [social preview](assets/brand/social-preview.png), [Chinese cover](assets/launch/cover.zh-CN.png) |

The generator is the editable geometry authority and exports SVG/PNG, ICNS and Android vector layers. Edit it before regenerating; do not separately hand-patch derived geometry. The menu uses an 18pt native mark with connection state, preserving warning/battery symbols and independent task indicators. Android keeps the foreground inside the adaptive-icon safe region and supplies a monochrome layer. Its critical pixels fit the central 66dp circle in the 108dp canvas, following [Android adaptive icon guidance](https://developer.android.com/codelabs/basic-android-kotlin-compose-training-change-app-icon).

Check native icons at 16/32px, menu icons in light/dark appearances, and Android launcher masks/themed icons. [Android resource fixtures](assets/brand/previews/android-icon-fixtures.png) render the shipped adaptive/monochrome resources at small sizes; [provenance](assets/brand/previews/android-icon-fixtures.txt) records the synthetic rendering. [Task indicator previews](assets/brand/previews/task-icon-fixtures-comparison.png) are synthetic renderings of production drawing code, not desktop screenshots.

## Documentation imagery

Editorial illustrations use graphite, mint and generous empty space. They communicate the concept and must be labeled as illustrations. [Generation records](assets/GENERATION-PROMPTS.md) describe the covers. Do not use concept art or review fixtures as proof of product behavior. Screenshots use synthetic projects and contain no account, device, host, conversation or credential data; keep raw private captures outside published assets.

## 中文说明

整体采用石墨灰底色、按明度分层的无描边容器，薄荷绿只用于主操作、工作状态和选中项。Android 当前为深色，Mac 跟随系统明暗。手机保持大圆形语音键、右下删除键和固定应用入口，不因状态刷新改变触摸中的操作目标。

普通小按钮仍保留 48dp 触摸范围；文字跟随系统字号并提供无障碍语义。松手、滑出、失焦、切页或断连结束语音；草稿、未知回执和缓存状态须明确保留。完整大字/读屏验收仍见 TODO。

图标几何以 Swift 生成器为准，导出 SVG、PNG、ICNS 和 Android 前景/单色层。插画和封面是概念图，不能充当应用截图；截图只使用脱敏演示数据。页面和组件约束见[页面结构](docs/PAGE-STRUCTURE.md)与[组件规范](docs/COMPONENT-GUIDELINES.md)。

首页采用已选第一版：按住说话与快捷键提示放进圆形按钮内，麦克风来源独占圆上方一行；圆内图标、标题和快捷键整体下移圆半径的 20%，让图标更靠近圆心；松手提示和140×48dp删除键位于固定操作行。采用统一竖屏画布，首页无纵向滚动；可用屏幕宽度或高度不足时，顶部、语音、删除和应用 dock 的文字、按钮及间距一起等比缩小；画布按缩放比例扩大逻辑宽度，让各行继续铺满可用宽度，避免出现额外左右留白，并保持完整显示。系统栏与刘海安全区域不参与缩放，底部应用 dock 保留横向滑动；常规屏幕保留原有布局。

HTML/HTM project files default to Preview, with Source available in the same tab strip. Keep original document styling and interactive state across tab switches; native actions stay outside the webpage. HTML/HTM 默认预览，源码标签并列，原页面风格与交互状态保留；底部应用操作独立于网页。

Image previews use the available screen with the image fitted inside the main viewport. Keep system insets and compact, reachable close/retry controls; avoid a compact half-screen dialog. Pinch zoom and pan belong to the image surface. Double-tap alternates between a detailed view and the original fitted view. Bound zoom and pan, and reset when a new preview opens. 图片预览尽量占满可用屏幕，保留系统安全边距与简洁易点的关闭/重试入口，图片占主要空间。双指缩放、拖动仅作用于图片；双击切换局部放大与完整画面。缩放与拖动有边界，重新打开时重置。

Build 11 keeps Stop task in one header location, labels Send/Queue send visibly and reserves Stop waiting for returning to the list while Mac work continues. Message updates retain row identity, expansion and visible-row anchors. Microphone capability changes refresh the effective source and terminate a lost phone-audio path without switching during a hold. Settings update existing choice nodes.

build 11 将停止任务固定在顶部，发送/排队明示；停止等待只返回列表并说明 Mac 任务继续。消息更新保留行身份、展开态与阅读位置，通路失效结束手机录音且不在同一次按住中切换来源，设置刷新不重建焦点选项。

The Mac app picker uses a fixed header, shortcut actions and search field above a scrolling grouped list. App names are left-aligned; bundle IDs use muted caption text. Initial-letter badges identify rows without implying that Mac app icons are available. The selected app has a mint checkmark and tinted row. Shortcut configuration uses numbered rows; all interactive rows retain at least 48dp touch targets.

Mac 应用选择页采用固定标题、快捷栏操作和搜索框，下方应用列表独立滚动。应用名称左对齐，包名使用弱化的辅助文字；首字标识用于区分行，不假装已获取 Mac 应用图标。当前应用用薄荷绿勾选与浅色底标记，快捷栏配置使用位置编号，各操作保留至少 48dp 触摸区域。

## Mac permission setup / Mac 权限引导

First installed launch presents a dedicated Full Disk Access guide and opens its System Settings pane once. Keep a permanent menu-bar entry, explain the +/select/enable/restart sequence, and provide a Finder reveal action. Guide presentation never represents an authorization grant; do not display a verified status without a supported check. Accessibility remains separate and microphone remains on demand.

安装后首次启动显示完全磁盘访问引导并打开系统设置一次；菜单栏保留入口，明确添加、开启及重启步骤，可在 Finder 定位当前应用。不把打开引导当成授权成功；辅助功能独立，麦克风按需申请。

Show a clickable file-access status with distinct not-verified, checking, access-confirmed and permission-required states. Its result refers to the last actual file operation, with an explicit explanation that it does not verify every folder or the Full Disk Access switch. Recheck in the background and keep the button stable while busy. An observed permission denial can reopen repair guidance once per running installed app regardless of its first-launch marker. Offer both Full Disk Access and Files and Folders settings.

文件访问状态按钮区分尚未验证、检查中、已可访问和需要授权，说明状态对应最近实际文件操作，不代表所有目录或完全磁盘访问开关。后台重查时保留按钮位置。安装版进程首次遇到真实权限拒绝时可重新显示修复引导，不受首次显示记录阻止；提供完全磁盘访问及文件与文件夹设置入口。

## AI coding assistant switches / AI 编程助手开关

The Mac menu places a compact assistant card after the phone connection card: header plus enabled count; Codex and Claude Code rows each show a mark, name, visibility status and native switch. Mint accents follow VibePier. Controls remain disabled while saving, and failures show inside the card. “Enabled” describes phone access, not runtime health.

Mac 手机连接卡片下新增助手卡片，标题右侧显示启用数，每行包含标记、名称、已启用/已关闭和原生开关。沿用薄荷绿；保存期间禁用操作，失败原位显示。手机只展示启用标签，全关闭给出空状态及 Mac 开启提示。
