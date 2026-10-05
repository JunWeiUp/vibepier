# Mac updates and file permissions / Mac 更新与文件权限

Keep VibePier at `/Applications/VibePier.app` and retain its signing identity when updating it. The explicit local updater checks the existing and candidate bundle IDs, signing certificates, designated requirements and entitlements before stopping the app. It keeps the installed bundle directory in place, backs up its contents, updates them at that path and verifies the result. It restores the backup at the same path if verification fails. It associates the existing app LaunchAgent with the bundle while retaining its other settings. Building and preparing a candidate do not install or launch it.

更新时保持 `/Applications/VibePier.app` 路径与签名身份。显式本机更新脚本先核验新旧包的标识、证书、代码要求与 entitlements，再停止应用；保留原应用目录，备份后原址更新，验签失败原址恢复。现有登录任务补充应用关联，其他设置保留。构建及准备候选不安装、不启动应用。

The bundle directory and existing `Contents`/`Info.plist` stay in place. Signed executables are replaced with new files at the same paths, as required to avoid stale kernel code-signature caches; see [Apple's updater guidance](https://developer.apple.com/documentation/security/updating-mac-software).

保留应用目录和现有 `Contents`/`Info.plist`，已签名可执行文件则在原路径替换为新文件，避免内核缓存旧签名导致启动失败。

## Local updates / 本机更新

The Mac menu shows the running app's version and build below **VibePier**; the phone-remote settings sidebar repeats it at the bottom. It reads the installed app's Bundle metadata, so the value identifies the running Mac app rather than the available Android APK or a source checkout.

Mac 菜单中 **VibePier** 标题下方显示当前版本与构建号，手机遥控设置窗口的侧栏底部也显示。数据来自正在运行的 Mac 应用 Bundle，与已登记的安卓 APK 版本分开。

Build an ordinary staged bundle, then inspect the update plan:

```sh
./scripts/build/macos.sh
python3 scripts/install/macos.py --dry-run
```

The staged preview is ad-hoc signed. For an existing certificate-signed local installation, the updater can sign a private candidate with the exact installed certificate, designated requirement and entitlements, provided that certificate's signing identity is already available in Keychain. It never imports a key or replaces the established identity with an ad-hoc signature. A missing identity or incompatible signed candidate stops the update before the installed app is changed. The updater updates the app and its bundled helper; the standalone CLI is a separate delivery.

普通 staging 预览采用 ad-hoc 签名。已有证书签名的本机安装可复用钥匙串中现存的同一签名身份，对私有候选保留原证书、代码要求和 entitlements；不会导入密钥，也不会把已授权身份降级成 ad-hoc。身份缺失或已签名候选不兼容时，在修改现有应用前停止。脚本更新应用与内嵌文件助手，独立 CLI 另行交付。

Run the explicit update only when installation is intended:

```sh
python3 scripts/install/macos.py --apply
```

The updater retains a recoverable backup and an installation report. It does not reset, edit or copy TCC authorization records. Permission retention remains a macOS decision: matching code identity is necessary for compatible updates, but an identity migration, a user revocation or system policy can require manual authorization again. Public release signing uses Developer ID Application; switching from Apple Development to Developer ID is an identity migration. See Apple's [code requirement guidance](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) and [background-task association guidance](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos).

脚本保留可恢复备份和安装报告，不重置、修改或复制 TCC 授权记录。权限是否继续有效由 macOS 决定；迁移签名身份、用户撤销授权或系统策略仍可能要求手动授权。公开发行使用 Developer ID Application，从 Apple Development 切换过去属于身份迁移。

## Permission status and repair / 权限状态与修复

The **Mac permissions** page has a clickable file-access status. **Access confirmed** means the latest checked file could be read; **Permission required** means an actual read was denied; **Not verified** means there is no usable check yet. The button retries only the most recent real file operation on a bounded background worker. It does not scan unrelated private directories, read TCC databases or treat one readable file as proof of Full Disk Access. macOS has no general public API for that grant; the authoritative switch remains in System Settings. See [Apple's explanation](https://developer.apple.com/forums/thread/114452).

「Mac 权限访问」页面增加可点击的文件访问状态：「已可访问」表示最近检查的文件可读，「需要授权」表示实际读取被拒绝，「尚未验证」表示没有可用检查。点击后仅在有界后台工作器中重查最近实际访问的文件，不扫描无关私有目录或读取 TCC 数据库。单个文件可读不能证明完全磁盘访问已经授权，系统设置开关仍是准确依据。

An observed file-permission denial opens repair guidance once in the running installed app, even if the first-launch guide was shown previously. If VibePier is already enabled in Full Disk Access but reads are still denied after a reinstall, remove the obsolete entry, add the current `/Applications/VibePier.app`, enable it, then quit and reopen VibePier. Folder-specific permissions can also be reviewed under **Privacy & Security → Files and Folders**. Files that disappeared or have an unsupported format are not classified as revoked authorization.

安装版运行中首次遇到真实文件权限拒绝，会重新显示修复引导，不受“首次引导已显示”记录阻止，同一进程的后续拒绝不会反复弹窗。若重装后完全磁盘访问开关已开但仍读不了，移除旧条目，重新添加当前 `/Applications/VibePier.app` 并开启，退出后重新打开。单目录授权也可在「隐私与安全性 → 文件与文件夹」检查。文件丢失或格式不支持不会误判成授权被撤销。

## Unlock preferences / 解锁偏好

The optional unlock password is stored in the current Mac user's `Library/Application Support/vibepier/preferences/unlock.json`, in plain text with `0600` file and `0700` directory permissions. It is outside the app bundle and Android data, so signed app replacement and APK updates preserve it. It is excluded from portable settings, diagnostics and receipts. First access migrates the old Keychain item only after the local preferences commit succeeds. An explicit clear saves an empty record, preventing legacy restoration.

可选解锁密码按用户选择明文存于 Mac 本地偏好，覆盖安装 Mac 应用或 APK 均保留；手机不保存密码，设置导出、诊断与回执不包含密码。旧钥匙串密码在偏好写入成功后迁移删除，清除操作保留空记录，避免恢复旧密码。手动解锁被确认后清除旧失败状态；锁屏时失败仍暂停，避免反复尝试。
