# Android versions and updates / Android 版本与更新

The settings footer displays `VERSION (VERSION_CODE)`. Each changed APK delivered to a user must use a higher `VERSION_CODE`; repeated builds for the same delivery do not increment it again. Product version names remain independently managed in `VERSION`.

设置底部显示产品版本及构建号。每次交付内容有变化的 APK 必须递增根目录 `VERSION_CODE`，同一轮交付的重复构建无需重复递增。

## Register an update / 登记新版

`scripts/release/android.sh` produces a signed APK and adjacent `.apk.json` containing package name, version name/code and SHA-256. The script never installs or changes application settings. Keep both files together.

In the Mac **Install APK** page, choose the APK and select **Register as latest update**. Alternatively run `vibepier android-update /absolute/path/to/app.apk` against the running Mac app. This explicit local action verifies the digest, refuses downgrades or changed content with the same build code, and persists a private copy. Choose **Send latest update** for an authorized phone; normal phone system installation confirmation still applies. Generic APK delivery remains separate.

Mac“安装 APK”页选择文件后点击“登记为最新更新”，或执行上述 CLI。登记时校验摘要，拒绝降级及同构建号不同内容，保存独立 APK 副本。选择授权手机后点击“发送最新更新”；手机仍需正常确认系统安装。任意 APK 的普通下发不改变最新版本。

## Reporting and indicators / 上报和红点

Foreground phones report the installed version through the authenticated encrypted `appVersion` operation on resume/connection and every 30 seconds. The Mac persists reports per device and displays them beside the available version. A phone report never changes the available release. An `apkAvailable` event prompts another check after registration.

The settings entry and footer show a red dot only when the Mac reports a strictly higher build code. Opening settings does not dismiss it; installing the newer build and reporting clears it. Version state is discarded when the connection changes. The footer directs users to the Mac to send the update; it does not silently install. An offline phone cannot discover new releases.

手机在前台启动、连接后及每 30 秒通过加密授权连接上报已安装版本，Mac 按设备保存并展示。Mac 登记的 APK 是最新版唯一来源。构建号更高时，设置入口和底部版本栏显示红点；打开设置不消除红点，安装新版后重查消除。连接变化清除旧提示，离线无法发现新版。点击版本栏可检查并提示从 Mac 下发，不会静默安装。

## Validation / 验证

Tests use synthetic artifacts and temporary directories for digest mismatch, duplicate registration, downgrade rejection, device isolation and restart persistence. Android tests cover strict version parsing/comparison; the `app-versions` emulator probe covers footer indication and clearing. These checks do not substitute for real-device installation receipts.
