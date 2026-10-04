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

Build 11 adds `androidUpdateStage` with the existing request UUID, production `packageName` and installed integer `versionCode`. Only an authorized device may request the Mac's registered newer artifact. The reply identifies a preparing or current transfer phase; it is not an installation receipt. Same-request and same-artifact repeats reuse preparation/transfer state, while a conflicting active artifact is rejected. Completion checks the original device key and registered digest. The phone does not automatically resend an unknown result; `apkOffer`/installation receipts remain the source of receiving and installation state. No URL, path, credential or provider session may select a different APK.

build 11 的 `androidUpdateStage` 只允许授权手机申请 Mac 已登记的较新正式包，携带请求 UUID、包名和已安装构建号。重复同请求/同包复用状态，冲突任务拒绝覆盖；完成时复核原授权和登记摘要。准备/接受请求不代表安装成功，未知结果不自动重发，不允许手机指定下载地址或本地路径。

## APK relay download profile 1 / APK 中继下载配置 1

The authorized, session-encrypted `apkOffer` request may include `downloadVersion: 1`. Only an actual `relay:` route returns `download: {version: 1, token: <offer request id>, fragmentChars: 7200, chunkBytes: 131072, window: 4}`. The token belongs to the device, immutable transfer and current relay peer. An offer without this capability clears the previous profile; absent/unrecognized replies retain legacy single-flight behavior. The relay service itself does not change.

A negotiated `apkChunk` carries the offer's `downloadToken` and `durableOffset`, the contiguous byte count already synced to private storage, in addition to `transfer`, `offset` and `limit`. Requested offsets are not progress acknowledgments. Retries may acknowledge older progress but cannot decrease the Mac's displayed count. A mismatched token/peer/transfer is rejected. Terminal `apkStatus` receipts retain their existing meaning, including SHA-256 verification before `received`.

Only those chunk responses use 7200-character base64 fragments. Their existing `vibepier-session1` frame gains `request`, identifying a live negotiated APK request; all other replies remain 900-character fragments. Android validates the pending request and current relay connection before accepting a fast fragment, requires the decrypted response ID to match, and checks transfer/offset/exact requested chunk length before writing. Fast assemblies allow at most 56 fragments and retain the 300000-byte plaintext bound, eight-assembly bound, absolute expiry and replay checks. Every serialized fast frame must fit the existing 8192-byte outer plaintext limit; encrypted control frames remain limited to 16384 bytes. The Android dispatch queue retains 2048 frames and adds an 8 MiB byte ceiling. Cached fast response frames cannot be resent on another peer route.

蓝牙仍使用 8 KiB 文件块、900 字符分片和单请求；局域网 UDP 保持 128 KiB 文件块及原有分片策略。只有当前中继连接完成协商后，APK 才启用 7200 字符分片与最多四个并发块；手机连接 Wi-Fi 本身不代表使用局域网传输。普通消息不改变格式。旧端继续原协议，首次升级下载无法提前启用新能力。

Android counts network requests, buffered replies and a disk write together in the four-slot window. Out-of-order blocks stay in memory; only the next contiguous block is appended and synced before its slot is released. Cancellation and file commits share a generation guard; old work cannot reopen a retired snapshot. A failed append attempts to truncate back to its previous length. Reconnect resumes from the private file's actual synced length, renegotiates the profile, and still verifies the full SHA-256 before installation. No installation or user confirmation is implied by download completion.

并发窗口总计最多四块（512 KiB 原始文件数据，不含有独立上限的加密组包／JSON 缓冲）。取消、切换连接或替换任务后废弃旧请求；同步落盘前不报告完成，不以稀疏文件或最大请求偏移续传，最终摘要不符不得安装。

## Binary file capability 1 / 二进制文件凭据 1

`attachmentStart`/`newAttachmentStart` may request `binaryVersion:1`; the authorized response may contain a `binary` profile. Completion binds `binaryTicket` to the original device/scope/attachment. `apkOffer` advertises `binaryVersion:1`; `apkBinary` requests a new profile bound to `transfer` and durable `offset`. `fileCancel` revokes only a ticket issued to the authenticated caller. Offers contain version, opaque id, kind, size/offset, direct port/certificate pin, independent read/write tokens, `encoding:raw`, and an optional HTTPS relay endpoint. Read/write capabilities travel only in HTTP authorization headers. See [framing, routing and security](../docs/BINARY-FILE-TRANSFER.md).

`apkProgress` carries the issued `binaryTicket` and confirmed `durableOffset` for the same authorized transfer; it cannot mark verification or installation complete.
