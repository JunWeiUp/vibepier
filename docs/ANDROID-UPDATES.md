# Android versions and updates / Android 版本与更新

The settings footer displays `VERSION (VERSION_CODE)`. Each changed APK delivered to a user must use a higher `VERSION_CODE`; repeated builds for the same delivery do not increment it again. Product version names remain independently managed in `VERSION`.

设置底部显示产品版本及构建号。每次交付内容有变化的 APK 必须递增根目录 `VERSION_CODE`，同一轮交付的重复构建无需重复递增。

## Register an update / 登记新版

`scripts/release/android.sh` produces a signed APK and adjacent `.apk.json` containing package name, version name/code and SHA-256. The script never installs or changes application settings. Keep both files together.

In the Mac **Install APK** page, choose the APK and select **Register as latest update**. Alternatively run `vibepier android-update /absolute/path/to/app.apk` against the running Mac app. This explicit local action verifies the digest, refuses downgrades or changed content with the same build code, and persists a private copy. Choose **Send latest update** for an authorized phone; normal phone system installation confirmation still applies. Generic APK delivery remains separate.

Mac“安装 APK”页选择文件后点击“登记为最新更新”，或执行上述 CLI。登记时校验摘要，拒绝降级及同构建号不同内容，保存独立 APK 副本。选择授权手机后点击“发送最新更新”；手机仍需正常确认系统安装。任意 APK 的普通下发不改变最新版本。

## Reporting and indicators / 上报和红点

Foreground phones report the installed version through the authenticated encrypted `appVersion` operation on resume/connection and every 30 seconds. The Mac persists reports per device and displays them beside the available version. A phone report never changes the available release. An `apkAvailable` event prompts another check after registration.

The settings entry and footer show a red dot only when the Mac reports a strictly higher build code. Opening settings does not dismiss it; installing the newer build and reporting clears it. Version state is discarded when the connection changes. Tapping the newer-version footer requests the registered APK from the authorized Mac immediately; no additional Mac send action is needed. The phone still requires normal system installation confirmation. An offline phone cannot discover new releases.

手机在前台启动、连接后及每 30 秒通过加密授权连接上报已安装版本，Mac 按设备保存并展示。Mac 登记的 APK 是最新版唯一来源。构建号更高时，设置入口和底部版本栏显示红点；打开设置不消除红点，安装新版后重查消除。连接变化清除旧提示，离线无法发现新版。点击“发现新版本”的版本栏即向授权 Mac 申请已登记新版并开始接收，无需再到 Mac 点击下发；手机仍需正常确认系统安装。

Installation results show one toast per transfer/result, persisted across app restarts. Receipt retries to the Mac run independently, so being offline or awaiting acknowledgment does not repeat the toast.

每次安装结果只提示一次，并持久保存提示状态；重开应用也不重复。向 Mac 上报回执独立重试，离线或等待回执确认不会反复弹出安装成功提示。

## Validation / 验证

Tests use synthetic artifacts and temporary directories for digest mismatch, duplicate registration, downgrade rejection, device isolation and restart persistence. Android tests cover strict version parsing/comparison; the `app-versions` emulator probe covers footer indication and clearing. The encrypted-loopback `apk` probe checks that opening a known update stages it exactly once and starts receiving without a Mac send action; repeated opening/refresh does not repeat the request. These checks do not substitute for real-device installation receipts.

## APK transfer speed / APK 下发速度

Upgraded Mac and Android apps negotiate a relay-only APK download profile: 7200-character encrypted-session fragments, 128 KiB chunks and up to four outstanding chunks. Bluetooth stays single-flight at 8 KiB; local UDP framing is unchanged. Phones show synced progress, average download speed and estimated remaining seconds, followed separately by verification and system installation confirmation. Old peers continue using the existing transfer format, including the download that first upgrades a phone.

新版 Mac 与手机通过云中继下发 APK 时，会协商大分片及四块并发下载；下载界面增加速度与预计剩余时间。断线后按连续落盘长度续传，完整 SHA-256 校验和系统安装确认照常保留。手机连接 Wi-Fi 但应用选择云中继时，也使用中继策略；不自动切换网络路径。旧手机首次接收新版仍走原协议，双方升级后才启用提速。

See [wire protocol](../protocol/README.md#apk-relay-download-profile-1--apk-中继下载配置-1) and the [isolated throughput experiment](DEVELOPMENT.md#apk-relay-throughput-experiment).

### Build 11 update actions / 更新动作

The phone version row and receive/install entry open one update detail. When a newer version is already known, the same tap immediately requests the authorized Mac's registered newer APK; arbitrary package URLs are not accepted. Requests bind the installed package/version and are not automatically repeated after an unknown result. The Mac reuses the same active registered transfer and rejects a conflicting APK instead of replacing it.

Mac preparation uses two bounded workers and validates the original authorization and registration at completion. Typed stages distinguish preparing, pending, transferring, verified, permission, system installation and terminal results. Busy stages disable new sending; only cancellable stages expose Cancel. The system installer still needs normal phone confirmation.

手机版本与安装入口统一展示；已发现新版时，点击入口直接申请下发，仅来自授权 Mac 已登记新版。未知结果不自动重发，同一新版可复用在途任务，冲突包拒绝覆盖。Mac 文件复制与哈希脱离会话队列，完成前核对原授权及登记版本；传输/权限/系统确认/成功各有对应按钮，不把“收到”视为“装好”。

## Binary channel / 二进制通道

New peers prefer the [binary file channel](BINARY-FILE-TRANSFER.md), including direct HTTPS and streaming relay transfer. The chunked protocol above remains for legacy peers/Bluetooth.

新版优先使用独立二进制文件通道，支持局域网 HTTPS 直连及公网流式转发；上述分片方式供旧端和蓝牙使用。
