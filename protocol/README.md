# VibePier protocols

This directory owns cross-platform contracts and synthetic interoperability fixtures.

- [Authenticated control channel](specs/secure-control.md): device enrollment keys, transport handshake, encryption, and replay behavior.
- `fixtures/control-v1.properties`: independently generated HKDF, HMAC, and AES-GCM vectors consumed by Swift and JVM tests.
- [Relay routing](specs/relay.md): admission, peer addressing, bounds, and lifecycle.
- `fixtures/relay-hello.json`: relay routing handshake vectors consumed directly by Swift, JVM and Go tests. Relay deployment authentication is separate from device authorization.

Fixed keys and nonces in fixtures are public test data. Never copy them into a deployment. A protocol change must update its specification and all affected client/server tests together.

## Application dock configuration

The authenticated session RPC supports `applications` (installed app names/identifiers plus slot configuration and `revision`) and `applicationShortcutSet` (`index`, `bundleID`, `revision`). An empty identifier clears an existing slot; the next index adds a slot, up to 64. The Mac checks the installed catalog and performs a revision compare-and-set. Identical retransmission is idempotent; conflicting stale selections fail and require refresh. No path, local runtime command, launch action or unlock action may be supplied through these operations.

任务完成通知复用加密会话信封，使用 `notificationSubscribe` 建立接收路由和 `taskCompleted` 事件，不增加明文通道。See [task notification protocol and behavior](../docs/TASK-NOTIFICATIONS.md).

### Android application versions

Authorized `appVersion` requests carry `packageName`, integer `versionCode` and bounded `versionName`. Replies carry `ok` and an optional `latest` object with `versionCode`/`versionName` from the Mac's explicitly registered APK. This operation reports installed state only; it never registers releases or installs software. Reports are per authorized device, independent of provider sessions. `apkAvailable` also signals a newly registered update.

授权手机通过 `appVersion` 上报已安装版本；Mac 返回显式登记 APK 的版本，手机按构建号显示更新提示。手机上报不能改变最新版，未新增明文通道或静默安装。
