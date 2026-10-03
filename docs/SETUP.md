# Installation and first use / 安装与首次使用

The first public beta is still in preparation. Until a release is published, use the [source-build instructions](DEVELOPMENT.md); do not treat a development output as a verified public download. Supported platforms and provider limits are listed in [COMPATIBILITY.md](COMPATIBILITY.md).

## Mac

1. Obtain the Apple-silicon app archive from the intended release and compare it with that release's `SHA256SUMS`. Extract `VibePier.app`, quit an existing VibePier instance, and put the app in `/Applications`.
2. Open it explicitly. It runs in the menu bar, so the absence of a Dock window is expected. Keep the app running while using the phone.
3. The initial preview is ad-hoc signed and **not notarized**. If macOS blocks opening, inspect the source/download and use the normal per-app approval in System Settings → Privacy & Security when appropriate. Do not disable Gatekeeper or remove quarantine recursively. See [Apple's opening-app guidance](https://support.apple.com/en-ie/102445).
4. Grant the permissions for the features you choose. The menu offers an explicit launch-at-login choice; building the project does not install a startup service.

| Permission / dependency | Needed for |
| --- | --- |
| Bluetooth | Discovering and enrolling the phone, and BLE control. |
| Local network, if requested by macOS | Local Wi-Fi/UDP phone connection. |
| Accessibility | Synthesized keys, supported desktop controls and optional unlock. Approve the installed VibePier app, not an obsolete copy. |
| Microphone | Optional audio features; requested from the relevant explicit audio setting/action. |
| Screen recording | Explicit application screenshot attachments, if used. |
| Automation | A desktop action that uses Apple Events, if configured. |
| BlackHole 2ch | Optional phone-to-Mac microphone routing; not needed for ordinary controls or the default Mac-microphone path. |

Provider accounts and projects must already work on the Mac. VibePier does not install or sign into Codex, Claude Code or ZCode for you. For voice-trigger shortcuts, configure the intended receiving application on the Mac; sending a keyboard shortcut does not itself provide speech recognition.

## Android

Install the signed release APK through Android's normal package installer and review its prompts. Updates must retain the same signing identity. The `.review` application is an emulator fixture and is not a release APK.

For an explicitly authorized ADB installation, select one physical device. USB and Wi-Fi entries can refer to the same phone; check the model and serial and process it only once. `-r` retains existing application data. A signing/version mismatch is a reason to stop and select the correct compatible package, not to uninstall the app. See [Android's ADB documentation](https://developer.android.com/tools/adb).

```sh
adb devices -l
adb -s PHONE_SERIAL shell getprop ro.product.model
adb -s PHONE_SERIAL shell getprop ro.serialno
adb -s PHONE_SERIAL install -r /path/to/VibePier-0.1.0-beta.1-android.apk
adb -s PHONE_SERIAL shell dumpsys package io.github.junweiup.vibepier.remote
```

Run those commands separately for each intended phone, using the same signed artifact. Do not select an emulator or use an unqualified `adb install` when multiple devices are connected. ADB authorization and VibePier authorization are separate.

After enrollment, the Mac's **Phone remote → Install APK** page can deliver an APK through the existing encrypted connection. The phone verifies it, requests install-source permission if needed, and opens the system installer. “Received” is not “Installed”; check the final receipt. Do not disable package verification to force an installation.

## Pair and choose a connection

Open both apps and permit nearby-device/Bluetooth discovery. Fresh Android installations select Bluetooth and automatically ask the Mac to approve the phone. Choose **Allow this phone** on the Mac. No extra “request access” step in the session page is needed.

Confirm the phone shows the current Mac application. Use Bluetooth or local Wi-Fi, or deploy your own relay using the complete [README commands](../README.md#deploy-your-own-relay). An approved BLE connection can securely sync relay settings before you choose Cloud relay. See [connection troubleshooting](CONNECTIONS.md).

## Optional features

- **Unlock:** open the phone's session-list menu and configure Mac unlock. The Mac checks the supplied login password and saves it in Keychain; the phone does not retain it. Explicit Unlock stays unlocked. This does not power on the computer or unlock FileVault at startup.
- **Phone microphone:** install **BlackHole 2ch** from its [upstream project](https://github.com/ExistentialAudio/BlackHole), then choose the phone as the voice button's source and grant Android recording permission. Routing is temporary while the phone voice action runs. BLE/local Wi-Fi/direct UDP are supported; relay-only phone audio is unavailable.
- **Usage tracking:** opt in from the usage settings. Tracking starts from that point; gaps and rest periods are not synthesized as application time.
- **AU05:** connect the optional receiver. Keep the default always-on heartbeat for established voice behavior; the on-demand mode remains experimental.

## Updates and recovery

Use the same Android signing key, retain application data and preserve Mac secure-store identities. After a relay credential or DNS-recovery change, sync each approved phone over BLE before returning to the relay. Portable preferences exclude credentials and enrollment; see [migration](MIGRATION.md).

If a phone is lost, revoke it from the Mac's session-access page. Deleting the phone application alone does not remove the Mac's authorization record. Avoid clearing app data as a generic repair: it can remove drafts, receipts and device keys. Share only sanitized diagnostics when reporting a problem.

## 中文步骤

1. 从对应发布页取得 Mac 压缩包和正式签名 APK，核对校验和。Mac 应用放入 `/Applications` 后主动打开，它驻留菜单栏。未公证预览版按系统“隐私与安全性”中的单应用确认流程处理，不关闭系统安全机制。
2. 手机正常安装 APK，更新保持原签名和数据。ADB 安装先逐台核对设备，USB/无线同机去重，再用指定序列号的 `install -r`；签名不符时停止，不卸载清数据。
3. 首次打开手机默认蓝牙，授权请求自动发往 Mac；在 Mac 点允许即可。看到当前应用后，再选择本地 Wi-Fi 或按 README 部署并同步自建中继。
4. 按需授予蓝牙、辅助功能、录音或截图权限。手机麦克风需额外安装 BlackHole 2ch，且不通过纯中继转发；普通遥控不需要它或 AU05。
5. 锁屏解锁、用时统计、手机录音分别设置。中继配置变更后，逐台手机先通过蓝牙同步再切回中继。远程下发 APK 仍需系统确认，下载完成不代表安装完成。
