# Migration and updates / 迁移与更新

VibePier has independent Mac/Android identities, secure-store namespaces, Bluetooth service IDs and authenticated wire messages. It does not connect to the old VibeBar service or accept its plaintext protocol. An old app and the new app being installed on the same machine does not create a bridge between them.

## Moving from an older project

1. Keep a recoverable copy of the old source/configuration outside this repository. Do not copy its Git directory, logs, credentials, provider transcripts or private test outputs into the public tree.
2. Stop the old desktop service before using the new app for hardware or desktop input. Keep rollback material until the new setup is verified; avoid two runtimes owning the same AU05 or shortcuts.
3. Install the independent VibePier Mac app and signed Android app. Grant the new Mac app its own permissions and approve each phone through the new Bluetooth flow.
4. Configure the relay separately and sync it over the newly approved BLE connection. Old pairing codes and device authorization are not portable authorization for the new project.
5. Re-enter settings manually unless they are represented by VibePier's documented portable format. Arbitrary legacy JSON is not accepted as a supported migration archive.

Do not overwrite a working app's signing identity or uninstall a phone app merely to make an update command succeed. Confirm the intended package, signing identity and backup first.

## Moving between VibePier installations

[Settings export/import](SETTINGS-TRANSFER.md) carries an explicit allowlist of device settings, keyboard mappings and application slots. Run an import preview first. It does not copy relay configuration, passwords, phone authorization, scripts, provider credentials or session content. A new phone enrolls again; a new Mac receives fresh permissions and credentials.

Do not restore Android encrypted private preferences onto another device: their keys are bound to Android Keystore. Cloud and device-transfer backup of these stores is excluded. Corrupt storage blocks writes; it is not automatically replaced with a blank store that could lose uncertain receipts.

## Updating an existing pair

Keep the Mac bundle ID, Android application ID and Android signing key. Verify both app versions and their connection before exercising mutations. Where a new relay option is introduced, first keep the phone on BLE, apply the Mac configuration, update the phone, let it sync, and then return to Cloud relay. Each phone needs its own successful sync.

System DNS is the default. An old saved relay code without `dns=alidns` does not opt into the new DNS recovery setting. If a deployment intentionally depends on that option, follow [the explicit configuration flow](DEPLOYMENT.md#optional-android-dns-recovery) before replacing a known-working phone build.

Rollback requires compatible protocol, secure storage and signing identities, not just an older executable. Keep a prior signed artifact and a separately protected configuration backup; do not downgrade into plaintext transport or destructively reset a device to recover connectivity.

## 中文说明

新项目与旧 VibeBar 的应用标识、授权、密钥及协议均独立，不保留旧服务转发或明文兼容。先保留可恢复备份并停用旧服务，再安装新应用、授予新权限、逐台蓝牙授权，单独配置中继。旧目录和私人记录不进入公开仓库。

VibePier 之间可通过白名单格式迁移设置，先执行 `--dry-run`；密码、设备授权、中继、脚本和会话不迁移。新手机需重新授权，Android 加密缓存不能跨设备直接恢复。升级使用相同正式签名并保留数据；涉及中继/DNS 选项时，先蓝牙同步，再切回云中继。
