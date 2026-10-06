# VibePier for Android

原生 Android 客户端，用手机查看和继续 Mac 上适配的 AI 会话，操作桌面快捷键、应用和语音。需要 Android 13（API 33）以上，当前编译和目标 API 为 35。无需 AU05 硬件。

完整介绍见 [中文 README](../../README.zh-CN.md) / [English README](../../README.md)。

## 第一次连接

1. 运行 Mac 上的 VibePier，并打开 Android 应用。
2. 新安装默认使用蓝牙。允许系统所需的附近设备权限；Android 11 及以下扫描需要位置权限。
3. 手机发现 Mac 后自动申请授权，在 Mac 弹窗允许这台手机。无需先打开会话页申请访问。
4. 看到当前 Mac 应用后，即可使用遥控与会话入口。Mac 的桌面按键需要辅助功能权限。

授权保存在 Android Keystore，使用相同签名的 `adb install -r` 更新会保留授权与设置。每台手机单独授权；Mac 撤销授权后，该手机不能继续控制。当前蓝牙发现会选择首个匹配的 Mac，多台 Mac 同时广播时请仅开启目标 Mac 的蓝牙服务。

## 会话和设置

设置 → 通用 → 语言支持“跟随系统 / 简体中文 / English”。选择立即生效并由 Android 保存，重启后保持，也可在系统的应用语言设置中修改。切换后仍停留在设置页。

会话列表可按最近会话或项目浏览，并切换支持的 Codex、Claude Code 来源。实际发送、审批、模型设置等能力由 Mac 返回，桌面接口不匹配时不能强行执行。历史、草稿和已读内容可离线查看；缓存不会授予发送权限。废弃或未知来源的旧导航不会恢复到其他来源，旧草稿与未决回执保留原身份隔离，禁止重新发送其旧操作。发送结果不确定时保留原请求回执，避免自动重复发送。

会话列表右上角菜单提供两个独立操作：

- **锁屏**：锁定当前 Mac。正在执行桌面输入操作时提示稍后重试。
- **解锁**：使用已设置的 Mac 登录密码解锁，并保持解锁状态。未设置密码时打开“Mac 锁屏自动解锁”设置。

密码通过已授权的加密通道提交，由 Mac 校验后存入 Mac 钥匙串，手机不保存。临时桌面操作的自动解锁在操作结束后重新锁屏；手动“解锁”不会自动复锁。解锁失败后停止重复尝试，需手动解锁或重新设置。不能解开 FileVault 开机登录，也不能远程开机。

会话标题栏文件夹入口支持目录树、文件名搜索、本轮改动、最近打开、源码/diff/预览和引用到回复；详见[项目文件](../../docs/PROJECT-FILES.md)。需同步更新 Mac。

支持的会话还可阅读 Markdown、展开命令或文件修改、查看图片和添加附件。内容按需加载；退出页面会取消旧页面读取，回前台先显示缓存再同步。

## 遥控、应用和语音

主页保留四个快捷键、圆形语音按钮和右下删除按钮。“按住说话/松开结束”和快捷键提示位于圆内，删除键固定140×48dp；上方快捷键内容超出可用空间时仅该区滚动，语音与删除始终可见。语音只在圆内开始，松开、滑出、失焦或退后台都会结束；滑回不会重新触发。删除和滚轮支持按住连发。应用切换后停止旧应用的连续操作。

点“编辑”配置通用或应用专属快捷键；未覆盖的按键继承通用设置。底部 Mac 应用栏由 Mac 的“手机遥控”窗口配置，顺序固定，超出一屏可横滑。点其他应用打开或激活，再点已选应用隐藏整个应用，不关闭窗口。

默认使用 Mac 麦克风。开启“手机语音按钮的收音来源”后，需要手机录音权限以及 Mac 上合适的虚拟音频设备。音频只在按住手机语音按钮期间采集，经蓝牙、同网 Wi-Fi 或已建立的 UDP 直连传输；云中继不转发手机音频，会回退到 Mac 麦克风。Mac 在结束或中断后恢复原输入设备。

“使用统计 → App 用时”需单独开启，显示 Mac 实际前台停留时间和全天时间轴；锁屏、睡眠和未记录时段不计为应用使用。手机可查看按 Mac 来源隔离的离线快照。

## 三种连接方式

| 方式 | 使用方法 | 条件 |
| --- | --- | --- |
| 蓝牙 | 新安装默认；连接状态菜单可重新选择 | 首次必须在附近通过蓝牙授权 |
| Wi-Fi | 选择 Wi-Fi，自动发现或填写 Mac 局域网地址 | 已授权、同网且 UDP 47800 可达 |
| 云中继 | 先用已授权蓝牙同步 Mac 配置，再选择云中继 | 自建 WSS 服务；部署命令见根 README |

三种方式的控制、状态、配置和音频均经过应用层认证加密；明文遥控包不会执行。协议见 [secure-control.md](../../protocol/specs/secure-control.md)。BLE 服务 UUID 为 `A5780001-2BD2-4D66-ABE6-7C9F0F4B9100`，命令、状态、授权特征分别以 `A5780002`、`A5780003`、`A5780004` 开头。

中继配置由 Mac 通过已授权蓝牙安全同步；也可粘贴 Mac 生成的配对码。配对码含中继密钥，不应公开。应用不内置公共中继，也不内置个人服务器。DNS 默认使用系统解析；只有用户在 Mac 明确开启后，手机才会在连接失败时使用 AliDNS HTTPS 恢复，并继续验证原中继域名的 TLS 证书。详见 [部署说明](../../docs/DEPLOYMENT.md#optional-android-dns-recovery)。

退后台会保留用户启动的连接，释放按键并停止录音。通知中的“断开连接”或从最近任务移除应用会停止连接；系统和厂商省电策略也可能中断。详见 [后台连接](../../docs/BACKGROUND-CONNECTION.md)。

## 本地数据

会话缓存、草稿、回执、应用图标/配置、使用统计快照和 APK 安装状态使用认证加密存储，数据密钥由 Android Keystore 保护。设备身份 UUID 和事件序号为非秘密元数据；设备控制密钥存 Keystore。中继配置单独加密保存。云备份与设备迁移均被排除。

收到的 APK 暂存在应用私有目录，经 SHA-256 校验后交给 Android 系统安装器，仍需系统允许安装来源及用户确认。应用允许截图；系统截图与录屏由系统或用户管理。完整边界见 [隐私说明](../../docs/PRIVACY.md)。

## 构建和验证

在仓库根目录执行，需要 JDK 17 和 Android SDK 35：

```sh
./apps/android/gradlew -p apps/android :app:assembleDebug
./apps/android/gradlew -p apps/android :app:testReleaseUnitTest :app:lintRelease
```

正式 APK 使用固定的 release 签名，配置方式见 [Android signing](../../docs/DEPLOYMENT.md#android-signing)：

```sh
./scripts/release/android.sh
```

构建和打包不安装、不启动应用。显式安装时，先核对设备身份，再指定唯一设备；同一手机的 USB 和 Wi-Fi ADB 不重复安装：

```sh
adb devices -l
adb -s PHONE_SERIAL install -r dist/VibePier-0.1.0-beta.1-android.apk
```

也可从 Mac 的“向手机安装 APK”下发给已授权手机；传输成功不等于系统安装成功，应核对安装回执。

评审样本只在 `designReview` 源集中，独立包名为 `io.github.junweiup.vibepier.remote.review`，显示名称 **VibePier Review**。只在模拟器安装该包，正式 APK 不包含评审对话数据。专项 instrumentation 通过 `-e test screen-controls`、`private-storage`、`enrollment`、`relay-store`、`background-connection` 等选择，运行方式见后台连接文档。

```text
app/src/main/           生产实现、平台资源、Manifest
app/src/production/     debug/release 的评审功能禁用入口
app/src/designReview/   仅模拟器评审样本和评审标签
app/src/test/           JVM 单元测试和共享协议样本读取
app/src/androidTest/    Android Keystore、UI、生命周期专项验证
```
