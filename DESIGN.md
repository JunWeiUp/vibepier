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

The key editor sizes its preset column count from localized label width; large-type modifier controls use two columns. The voice caption and key chip live inside the circular microphone control; the source label sits above it. A separate fixed action row holds the release hint and the 140×48dp Delete target. Use the general portrait layout; only the upper context/shortcut region may scroll when content exceeds its space, while voice, Delete and the application dock stay visible. Do not add small-screen variants or dedicated small-screen acceptance work unless the user requests it (see agent.md). Captions wrap at the system font size; the circular gesture boundary is preserved. Delete shows a single icon and label, with its complete binding retained in accessibility semantics.

## Interaction rules

- Keep the remote surface compact: connection/current-app context above the controls, a prominent circular voice button, deletion at its lower right, and a stable application dock.
- A voice press begins only inside the circle. Releasing, leaving the hit region, losing focus, navigation or disconnection ends it. Re-entering does not restart the same gesture. One pointer owns the gesture.
- Saved application slots stay in place. A temporary current-app slot does not reorder the user's configured shortcuts. Do not allow an application-state update during a touch to turn a launch into an unintended hide.
- Use segmented controls for primary choices and smaller chips for secondary filters. A selected item carries text/accessibility state as well as color.
- Preserve drafts and read position during normal navigation. Show cached data as cached; do not infer current mutation capability from it.
- Pending operations stay visibly pending. Unknown results ask for verification; they are not labeled failed-and-safe-to-repeat. Unsupported actions explain the next useful step on the Mac.
- Opening the Mac menu must not ask for microphone access. Permission requests belong to the relevant explicit action or setting.

Native phone UI examples in both READMEs use original emulator captures with synthetic data. [Capture provenance](assets/previews/README.md) distinguishes them from concept illustrations and real-device acceptance.

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

首页采用已选第一版：按住说话与快捷键提示放进圆形按钮内，麦克风来源独占圆上方一行；松手提示和140×48dp删除键位于固定操作行。采用通用竖屏布局，顶部内容超出可用空间时仅该区滚动，语音、删除、应用dock不随滚动移动；后续不做小屏专项适配，见 agent.md。

HTML/HTM project files default to Preview, with Source available in the same tab strip. Keep original document styling and interactive state across tab switches; native actions stay outside the webpage. HTML/HTM 默认预览，源码标签并列，原页面风格与交互状态保留；底部应用操作独立于网页。
