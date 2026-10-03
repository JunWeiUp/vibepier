# Localization / 本地化

Android uses default English resources in `app/src/main/res/values` and Simplified Chinese in `values-zh-rCN`. Home strings are in `strings.xml`; shared control/settings strings are in `controls.xml`; session UI is in `sessions.xml`; composer, media, tool output and Markdown text are in `readers.xml`; connection, authorization, updates and microphone notices are in `runtime.xml`; app usage is in `usage.xml`. Use the current view or Activity context so the OS-selected app locale is respected. Do not retain a process-global locale/context for labels.

The current migration covers the home Activity, shared tabs, settings shell, key editor, remote pads, app dock, navigation errors, conversation panel, approvals, composer, attachments, image viewer, tool groups and Markdown reader. Android-owned connection, session-client, usage, update and voice notices now use the same resources. Mac UI, runtime, session authorization, transport and feature notices use the compiled catalog described below, together with all three provider adapters, shared session presentation, hardware diagnostics and CLI help/setup notices. Provider/system diagnostic text is preserved as received. A passing resource check certifies parity for existing resources, not complete product translation.

## Adding text

- Add the same resource key in both locales. Use indexed format fields such as `%1$s` and `%2$d`; plural quantities use Android `plurals`, not English suffix concatenation.
- Preserve deliberate leading/trailing spaces using Android resource quoting. Keep punctuation with the translated phrase where word order can change.
- Translate labels and explanations, not wire operation names, saved shortcut tokens, provider IDs, app names, user messages or project paths. `Keys` owns the keyboard grammar; `KeyLabels` supplies localized display names. Saving a translated preset must still send the canonical key, such as `ctrl+space`.
- Non-UI state machines accept semantic events or injected presentation text. They should not need an Android Activity to resolve a notice.
- Bluetooth connection handling uses the authenticated transport state, never a translated status label. `PhoneVoiceController` accepts the localized timeout message from its UI adapter.
- `AppUsageMath` returns minute quantities, and snapshots retain category IDs. `AppUsageLabels` formats durations, category names and cache summaries; raw seconds and source IDs are never translated.
- `ReplyPartGrouping` returns group types, original tool names and status counts. `ReplyPartLabels` resolves titles and plurals for the view's locale; grouping keys and cached expansion state remain unchanged. Exact legacy title recognition is protocol data handling, not display translation.
- Use localized accessibility descriptions and selected/held state. Truncated visual hints must retain their useful full meaning for accessibility.

## Verification

```sh
python3 scripts/check/localization.py
make test-android lint-android
```

The repository CI checks key parity, resource kinds, format arguments and plural categories. Android Lint checks native resource formatting as well. The emulator `controls-localization` probe resolves real English/Chinese resources, opens the key editor at 320/400dp and 1x/1.5x font scale, selects a localized preset, adds a modifier and verifies the canonical saved binding. It uses synthetic profiles and never sends keys to a Mac. See [development](DEVELOPMENT.md) for invocation.

The `screen-controls`, `composer`, `markdown` and `tool-groups` probes also run with both English and Simplified Chinese app locales. They exercise actual menu clicks, offline blocking, draft/attachment behavior, document paging and stale responses, plus lazy tool reads and visible mixed statuses. Fixture messages and file names retain their original text. These are isolated emulator checks, not proof of real Mac lock/unlock or provider delivery.

The `app-usage` and `enrollment` probes resolve both app locales, including immutable offline usage snapshots, source isolation and denial feedback. The full `codex` regression also uses locale-aware selectors. These checks do not enable tracking or access a real Mac.

The probe's images are native UI fixtures, not screenshots of a live remote session. Language switching, provider-generated text and real screen-reader navigation require separate acceptance. Do not translate provider messages by replacing arbitrary Chinese text at the rendering boundary.

Native fixture examples from `ControlsLocalizationProbe`, rendered on an API 37 emulator with English resources, a 320dp viewport and 1.5x font scale:

- [Key editor, scrolled to the reachable Save button](../assets/previews/android-key-editor-en-large.png). The local callback saved `ctrl+space`; it was not sent to a Mac.
- [Voice control in its held state](../assets/previews/android-voice-en-large.png). This isolated view uses the production drawing code on the app surface color; no microphone capture or real input was started.
- Session-list menu: [English](../assets/previews/android-screen-controls-en.png) / [简体中文](../assets/previews/android-screen-controls-zh-CN.png). Both lock/unlock buttons are fully visible and exercise synthetic confirmation/offline responses. Session content behind the menu is demonstration data.

App usage examples from the native English probe: [totals and app rows](../assets/previews/android-app-usage-en-top.png), [actual usage intervals and categories](../assets/previews/android-app-usage-en-bottom.png). All records are synthetic. The same page is checked at 320dp and 1.5x font scale: [app rows](../assets/previews/android-app-usage-en-large-top.png) and [timeline](../assets/previews/android-app-usage-en-large-bottom.png). Compact rows put the app name above its duration; timeline tick labels reduce automatically when they would overlap, keeping the time positions and full accessibility description.

## macOS catalog

The canonical Mac catalog is [`apps/macos/Localization/Strings.json`](../apps/macos/Localization/Strings.json). Each semantic key has English and Simplified Chinese text. Run `python3 scripts/dev/localize-macos.py` after editing it; `--check` verifies locale/placeholder parity, referenced keys and the generated Swift file without changing anything. CI and `make lint-repository` run that check.

`L10n.text` resolves the catalog compiled into the shared `VibeLocalization` target. Both `VibeKit` and `VibePierCore` depend on it; a public core type alias preserves the app/CLI API without a dependency cycle. This keeps both the app and standalone CLI self-contained; copying the CLI does not require a separate resource bundle. Numbered slots such as `{0}` permit translated word order. Slot substitution operates only on the template, so braces, percent signs and backslashes inside user-supplied names or errors remain literal.

The app follows its preferred macOS language. The CLI honors `LC_ALL`, `LC_MESSAGES`, then `LANG`; unsupported languages fall back to English. `VIBEPIER_LANGUAGE=en` or `VIBEPIER_LANGUAGE=zh-Hans` explicitly overrides either process, including isolated tests. This does not change system preferences. Protocol keys, command verbs, shortcut grammar, provider accessibility selectors and user content must never be translated mechanically.

Current migrated scope: native menu/settings/phone views, task-state display, runtime and settings-archive notices, Keychain and screen-lock errors, session authorization, BLE/relay notices, remote controls, phone APK/usage/voice messages, Codex/Claude/ZCode and shared file/image/attachment presentation, hardware errors and firmware progress, CLI help/argument errors and setup notices. The catalog also covers localized approval explanations; native provider button selectors stay in their original supported languages. Unrecognized ZCode permission modes fail closed rather than acquiring generic IDs that could skip full-access confirmation. Missing tool names display a localized fallback without creating a translated grouping ID.

Diagnostic tables, technical logs, protocol identifiers, command syntax, canonical key/media names, native provider menu labels and external diagnostics retain their source form. Use `--json` where available for machine consumption; do not parse localized prose. Raw user content, file paths, native tool names and model names are never translated. Resource parity and isolated tests do not replace real-device language switching, provider delivery or screen-reader acceptance.

Control outcomes must be semantic, independent of the displayed language. ZCode send actions use a typed `UnconfirmedDesktopMutation` after entering the native Send boundary; an accessibility error cannot turn an unconfirmed send into a known rejection. Regression tests cover English, Chinese and format-like diagnostic text, without operating a real provider. This does not certify the other provider mutation boundaries.

```sh
python3 scripts/dev/localize-macos.py --check
VIBEPIER_LANGUAGE=en swift test --package-path apps/macos
VIBEPIER_LANGUAGE=zh-Hans swift test --package-path apps/macos
```

`LocalizationPreviewTests` renders the real connection and relay views with an injected synthetic CLI. It does not use `SessionRemote.shared`, request permissions or perform control operations. To save native layout fixtures, set `VIBEPIER_PREVIEW_DIR` to an output directory and `VIBEPIER_PREVIEW_APPEARANCE` to `light` or `dark`; run each language/appearance in a fresh test process. Hidden hosting windows can retain partial cached layers when switching appearances in one process. Inspect the actual saved image before treating it as evidence. These views include native scroll/field controls, so a SwiftUI `ImageRenderer` alone is insufficient.

Fixture examples: [English phone settings, dark](../assets/previews/macos-phone-remote-en-dark.png), [Chinese relay settings, light](../assets/previews/macos-relay-zh-light.png). All status/connection data is synthetic. The connection badge sits beneath the sidebar title so longer English titles remain readable.

## 中文说明

新增文案同时提供默认英文与简体中文资源；格式参数用带序号的占位符，数量变化用 plurals。资源文件中的首尾空格需要正确引用。显示名称与协议值分开：例如中文“空格”和英文“Space”都保存为 `space`，不能把翻译结果发送给 Mac。

当前已迁移首页、共享标签、设置外壳、改键、遥控按钮、应用栏、会话面板与审批、输入框、附件、图片、工具分组和 Markdown 阅读器。Android 自有的会话客户端、连接、用时、更新与语音提示也已接入同一资源体系；Mac 界面、运行时、设置迁移、钥匙串、锁屏、会话授权、传输与功能提示，以及 Codex/共享文件图片附件提示、CLI 帮助和参数错误，已采用内嵌字典；Claude/ZCode 提示、硬件错误、固件进度和 CLI 安装配置提示也已迁移。共享字典位于独立的 VibeLocalization 模块，设备库不依赖应用运行时。协议字段、技术日志、诊断表格、命令语法、按键名称和服务商原生菜单文字保持稳定，服务商或系统诊断原文保持原样。工具名缺失时只显示本地化占位，不生成随语言变化的分组 ID。ZCode 发送后的不确定状态现由错误类型表达，不依赖中文提示词；其他变更操作仍需独立审查。锁屏/解锁、输入框、Markdown 与工具分组已在中英文模拟器配置下验证；真实 Mac 锁屏与服务商投递仍是独立验收。资源一致性检查通过不代表整个产品已双语化；同时检查小屏、大字、无障碍描述与真实输入结果。
