# Portable settings / 设置导出与导入

Use the CLI with VibePier running on the Mac. These commands transfer selected settings; they do not transfer device authorization or conversation history.

```sh
# Choose a new output filename; existing files are never replaced.
vibepier preferences export ./vibepier-preferences.json

# On the destination Mac, validate without changing anything.
vibepier preferences import ./vibepier-preferences.json --dry-run

# Apply after reviewing the JSON file.
vibepier preferences import ./vibepier-preferences.json
```

## Included

- AU05 firmware button mappings and configured hardware settings.
- Desktop keyboard actions, their press/release/hold behavior, and temporary input-switch preference.
- Mac-configured application shortcut slots, heartbeat mode and firmware binding replay preference.
- Phone general/per-application button mappings and their display names.

The export is a versioned JSON allowlist, capped at 256 KiB. The CLI publishes it as a new file with mode 0600. It never overwrites an existing path; use a local filesystem supporting hard links for atomic publication, then copy the result wherever you need it. App identifiers and custom display names are included, so review the file before sharing it publicly.

## Excluded

Passwords, device keys and UUIDs, relay endpoint/room/secret, pairing data, provider credentials, conversation text, drafts, request receipts, attachments, usage records, executable shell/AppleScript actions, open-file actions and local project/tool paths are not exported. Optional tracking, agent integration and other destination privacy choices remain local. Android-only transport/microphone preferences are not transferred.

This is not a full backup. A new phone still needs its own Bluetooth authorization, a new Mac needs its own permissions, and a relay must be configured separately. A received file cannot install scripts or enroll a device.

## Import behavior

Import merges included button/action entries, preserves unmentioned entries, and replaces the included device-settings/application-slot sections. Existing local scripts, credentials, paths and enrollment remain in place. Phone mappings retain the destination server identity and receive new change versions so connected phones synchronize correctly. Repeating an identical phone mapping import does not create new revisions.

The full archive is validated before changes begin. Config and phone mappings are each saved atomically. If saving phone mappings fails after the config save, the importer attempts to restore the previous config and reports the failure; if that restoration also fails, it explicitly reports that manual recovery is needed. Keep the original export when moving between machines. The process reloads the running app's config; configured hardware values may be applied to a connected AU05.

## 中文说明

在运行 VibePier 的 Mac 上使用以上命令。`--dry-run` 只验证格式、范围及手机按键合并是否可行；去掉该参数才导入。导出包含设备设置、桌面/手机快捷键及应用入口，不包含密码、中继、设备授权、脚本、路径、会话或草稿。

按钮按条目合并，未提及的项目保留；文件中包含的设备设置与应用入口整体替换。目标 Mac 已有的密码、脚本、隐私选择和授权保留。手机按键使用目标 Mac 的身份和新版本同步，不能用导出文件绕过首次授权。

导出文件不可覆盖已有文件，以 0600 权限保存；原子发布需要支持硬链接的本地文件系统，成功后可自行复制到移动磁盘。文件仍包含应用标识与自定义名称，公开前请检查。导入会重新加载配置，已连接 AU05 的相应设置可能随之更新；它不是完整备份或旧协议兼容工具。
