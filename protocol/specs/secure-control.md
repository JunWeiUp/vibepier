# Authenticated control channel v1

Implementation status: BLE, UDP, relay, and relay-negotiated direct UDP use this authenticated channel. The Swift transport tests exercise encrypted wire messages, privacy before enrollment, sender binding, replay rejection, and per-phone routing. Android JVM vectors and emulator probes exercise the client and Keystore paths. The remaining full release acceptance work is tracked in [TODO.md](../../TODO.md); passing protocol tests does not replace real-device acceptance.

Each authorized phone has a random 32-byte root key issued after encrypted BLE enrollment and explicit approval on the Mac. Transport keys use HKDF-SHA256 with empty salt, a 32-byte output, and the UTF-8 context `vibepier-control-v1/handshake`, `/phone`, or `/mac`. This separates handshake authentication and the two AES-256-GCM directions. See [RFC 5869](https://www.rfc-editor.org/rfc/rfc5869).

## Signed version and capability negotiation

Handshake format **2** negotiates application protocol **1** before controls or session RPC can be used. The AES-GCM frame format and HKDF contexts remain version 1. Pre-negotiation development builds are not compatible; update the Mac and phone together. A signed incompatibility reply is shown as an update notice on the phone. Unknown, malformed or unauthenticated packets are ignored, without a legacy/plaintext fallback.

The phone sends one ASCII line:

```text
vibepier-secure-hello2 <device-uuid> <client-nonce-uuid> <unix-seconds> <versions> <capabilities> <hex-hmac>
```

The HMAC-SHA256 input is the first **six** fields joined with `|`, using the derived handshake key. `versions` is a comma-separated, strictly increasing list of 1–8 canonical decimal integers in 1–255; currently only `1` is supported. `capabilities` is a canonical decimal bitmask in 0–65535. The Mac accepts only known devices, valid signatures and a timestamp within 120 seconds. It intersects the offered capabilities with those supported by the transport, issues a fresh random session UUID and replies:

```text
vibepier-secure-ready2 <device-uuid> <client-nonce-uuid> <session-uuid> <selected-version> <selected-capabilities> <hex-hmac>
```

The reply HMAC covers its first six fields in the same form. The phone accepts only its outstanding client nonce within a 10-second handshake window, protocol `1`, and a subset of its offered capabilities containing every required bit. A reply for an older attempt cannot replace the current connection. Controls are not queued while negotiation is pending.

| Bit | Capability | Requirement |
| --- | --- | --- |
| 1 | Remote controls and app presence | Required |
| 2 | Configuration, app shortcuts and icons | Required |
| 4 | Encrypted session RPC, including lock/unlock and APK operations | Required |
| 8 | Phone audio and microphone control | Optional; BLE and UDP support it, cloud relay does not |
| 16 | Authenticated wrapper for already encrypted attachment fragments | Optional; never used for ordinary controls |

The baseline is `7`; current UDP advertises `31`, BLE advertises `15`, and relay advertises `23` (older negotiated connections continue with `15`/`7`). Unknown offered bits are not selected. Both endpoints enforce the negotiated audio bit before encrypting or accepting microphone/audio messages; ordinary session content containing similar words is unaffected. The phone uses the Mac microphone when phone audio is unavailable. A held voice gesture releases the path it actually started even if capabilities change before release.

An authenticated offer with no common protocol or a missing required capability receives:

```text
vibepier-secure-incompatible2 <device-uuid> <client-nonce-uuid> <version-or-capabilities> <supported-versions> <supported-capabilities> <hex-hmac>
```

The reason is the literal `version` or `capabilities`. The six fields before the HMAC are signed; no usable session is created. An unauthenticated offer never receives this reply. The phone retains the pending nonce until its normal deadline when retrying a refusal, avoiding unnecessary replay-receipt churn.

The Mac binds the session to the transport peer and authorized device. Hello replay receipts last five minutes. A retry from the same peer and exactly the same signed offer returns the existing challenge/refusal without resetting counters; changed offers reusing a nonce and replays from another peer are rejected. Unexpired receipts are never evicted to admit new traffic. Limits are 64 sessions and 512 hello receipts per transport instance, with at most 4 sessions and 64 receipts per device so one phone cannot consume all handshake capacity.

## Encrypted frames

```text
vibepier-secure1 <device-uuid> <session-uuid> <positive-sequence> <base64-box>
```

The box consists of a random 12-byte nonce, ciphertext, and a 16-byte authentication tag. AAD is UTF-8:

```text
vibepier-control-v1|<phone-or-mac>|<device-uuid>|<session-uuid>|<sequence>
```

Each direction uses its own derived AES key and monotonically increasing signed 64-bit sequence, starting at one. A 1024-sequence sliding receive window accepts reordering and rejects duplicates and older packets. The window advances only after successful authentication. Plaintext is limited to 8192 bytes and an outer frame to 16384 bytes.

Sessions expire after 30 seconds without authenticated traffic. Existing application lease and held-key timers remain shorter and still release controls on disconnection. A new host process issues new session UUIDs, so captured commands from before a restart cannot execute again. Authorization is checked against the current trust store on receive and send; revoking or rotating a device key invalidates its prior transport sessions. Trust-change observers retire only the affected peers, release their held keys, disconnect their session routes and end owned phone audio without waiting for the normal lease deadline. This does not undo a provider action already accepted before revocation.

## Session RPC assembly on the Mac

The inner `vibepier-session1` object contains exactly `type`, `sender`, `device`, `packet`, `part`, `parts`, and `data`. The authenticated sender must equal the enrolled device UUID. `packet` is a UUID; `part` and `parts` are numeric integers, never booleans or strings, with `0 <= part < parts <= 512`. A frame is at most 4096 bytes. Each non-final chunk is 900 Base64 ASCII bytes; the final chunk is nonempty and no longer than 900 bytes. The assembled AES-GCM body is limited to 300,000 plaintext bytes, with AAD `vibepier-session-v1|phone|<device>|<packet>`.

`SessionPacketInbox` accepts at most eight incomplete packets, with a maximum of four from one device. Each assembly expires 30 seconds after its first accepted chunk; duplicates cannot extend that deadline or replace already received bytes. After authentication, the request must contain a UUID `id` and a finite numeric `sentAt` within 180 seconds of the Mac clock (Unix milliseconds). Only then is the packet recorded as seen and passed to command handling with its original plaintext bytes.

Packet replay records last five minutes, with limits of 2048 per device and 8192 total. Full capacity rejects new packets until records expire rather than evicting live records. Stop/revocation clears partial assemblies without forgetting accepted packets prematurely. These are packet-level memory/replay limits; the durable mutation journal separately protects operation IDs across disconnects/restarts. Android response handling has its own policy below.

Mac 会话请求分片最多占用 8 个未完成包、每台设备最多 4 个；30 秒期限从首个分片计算，不随重传续期。重复分片只能包含相同字节。完整消息须通过设备/包/方向认证、大小限制、请求 UUID 和时间校验。重放记录保存 5 分钟，每台最多 2048 条、全局 8192 条；容量不足时拒绝新包，不提前清除旧记录。持久操作回执另行防止不确定请求被重复执行，手机回复接收器的规则见下节。

## Session response assembly on Android

Mac replies use the same seven-field envelope and 900-byte Base64 chunking, with AAD direction `mac`. Android validates the recipient-bound `sender`/`device`, UUID packet ID, numeric integral indices, a 4096-byte frame limit and a 300,000-byte plaintext limit. Base64 must be canonical, decrypted text must be valid UTF-8, and protocol flags must be JSON booleans. A reply has a UUID request `id` and boolean `ok`, or a nonempty event name. Contradictory `ok: true` with `unknown: true` is rejected.

At most eight response assemblies are retained for 45 seconds from their first chunk. Identical retransmissions do not reset that clock or progress; conflicting duplicate bytes are ignored. Missing-content requests retry at most three times after progress stalls; a timer from an old assembly cannot act on its replacement. Accepted packet IDs are retained for five minutes, at most 4096, without evicting live records to admit more. These guards supplement the outer secure channel's sequence replay window.

Before clearing a saved mutable request, the phone additionally verifies its request ID, provider when supplied, session and operation-specific confirmation: accepted delivery, approval fingerprint/submission, created session/cwd, or explicit lock state. Unknown replies preserve the original request. This is separate from the Mac's durable operation journal and never authorizes a resend on its own.

Android 校验相同信封格式、Mac 方向认证、完整 UTF-8 与布尔类型；每包最多 300,000 字节明文。最多保留 8 个分片包，每包固定 45 秒期限；补包最多尝试 3 次，旧定时器不能修改新一轮组装。已接收包记录保留 5 分钟、最多 4096 条，不提前驱逐。清除未知操作前还须核对原操作的服务商、会话和具体成功证据；结果不确定不会自动重发。

## Durable mutation admission

The Mac reserves a device-scoped operation ID and request fingerprint on disk before executing a mutation. Fresh execution is separately bounded to 16 requests/2 MiB per device and 64/8 MiB globally; duplicate pending IDs do not create more work. Durable receipt state/replays remain available when fresh execution capacity is exhausted; an unknown receipt can be reported without starting another provider reconciliation request. An unreliable store reports unknown rather than not found. Only the first provider completion callback is consumed, and a disconnect does not release capacity for work that still runs.

A definitive provider result must also be saved before the phone receives a definitive mutation reply. If result storage fails, the reply has `ok: false` and `unknown: true`, preserving the phone's pending intent. The journal retains retired markers when old completed bodies are removed: a lookup returns `state: unknown` with `retired: true`, never `notFound`, so an old operation cannot become fresh merely through retention cleanup. Storage quotas and persistence behavior are documented under [Mac receipts](../../docs/PRIVACY.md#mac-operation-receipts--mac-操作回执).

Mac 在执行变更前持久预留设备级操作编号和指纹，并限制仍在处理的请求。回调结果只有成功保存后才作为确定结果发送；保存失败仍返回未知，手机继续保留原请求。过期正文清理后留下退役标记，查询仍是受保护的未知状态，不会变成允许重新执行的“未找到”。

## Integration invariants

- Only discovery and explicit enrollment may run before authorization, and must not expose application metadata or execute controls.
- The sender in an inner message must match the authenticated device; an encrypted packet cannot impersonate another phone.
- All application state, settings, audio, and control responses use the authenticated session that originated the request.
- A legacy plaintext control command never triggers a compatibility downgrade.
- BLE and UDP retain their existing bounded framing and cleanup behavior; the relay routes opaque content without device keys.

The shared vectors use fixed nonces solely to verify implementations. Production encryption must always generate fresh nonces.

## 中文说明

握手格式 2 对应用协议版本和功能位一起签名，再建立现有 AES-GCM v1 加密通道。当前应用协议为 1，基础功能位为 7，BLE/UDP 增加手机音频位后为 15，中继为 7。版本无交集或缺少基础功能时，已授权设备收到签名的不兼容回复；手机显示更新提示，不回退旧握手或明文。手机音频未协商成功时使用 Mac 麦克风，按住期间能力变化也必须释放原来启动的按键路径。

完整原始握手的重试不会重置重放窗口；每台设备限制 4 个会话和 64 条握手回执，避免单台占满全局容量。撤销或更换密钥后，旧包不能再执行或接收私有状态；对应按键、音频和会话路由清理不等待常规超时，其他手机继续使用。已接受的服务商操作不能通过撤销授权倒退。真机 BLE/Wi-Fi/中继验收仍按发布清单单独完成。

## Attachment fragment authentication / 附件分片认证

Capability `16` allows phone-to-Mac attachment fragments to avoid a second AES-GCM encryption pass. The phone still encrypts the **whole RPC chunk once** with the existing `SessionEnvelope` AES-256-GCM key, a fresh nonce and device/packet/direction AAD. Each outer frame is:

```text
vibepier-bulk1 <device-uuid> <session-uuid> <sequence> <base64-session-frame> <hex-hmac>
```

The connection-scoped authentication key is `HMAC-SHA256(handshake-key, UTF8("vibepier-bulk-key-v1|phone|<device>|<session>"))`. The frame tag covers the fields `vibepier-bulk-frame-v1`, `phone`, and all five wire fields before the tag, joined with `|`. Android derives this short-lived key once through Keystore; per-fragment HMAC runs in the background with this derived key, never an exported root key. A fresh handshake replaces the derived key, and disconnect drops it.

The Mac accepts this form only on a live, root-bound, capability-16 connection and the original peer. It verifies the tag before advancing the shared replay window. Its body must be a bounded `vibepier-session1` upload fragment with the exact eight fields plus an optional `fragmentChars` field (512 or 7200), matching sender/device, UUID packet/upload and at most 7200 base64 characters. UDP uses 512-character fragments (up to 256 parts) to fit the MTU; the relay uses 7200-character fragments (up to 56 parts). Reassembly retains a fixed 30-second lifetime and the existing 300000-byte plaintext limit; the decrypted RPC must be `attachmentChunk` or `newAttachmentChunk`, version 1, and the exact outer attachment ID. Provider storage then enforces the device/session or verified creation-draft scope. No raw control, password, microphone, message body or unencrypted attachment can execute through this path. Packet metadata is visible; file bytes, names, scope and provider credentials remain encrypted. Replies and other traffic keep the existing AES-GCM transport wrapper.

新增能力位 `16` 仅允许已加密附件分片使用连接级 HMAC 认证，避免逐分片再次进行 AES-GCM 加解密。整块附件 RPC 的 AES-GCM、随机 nonce、设备/包/方向绑定保持不变；连接认证、防重放、完整分片重组、上传归属及最终 SHA-256 校验仍必须全部通过。未协商该能力时继续双层加密，不增加明文降级或新配对要求。

Cross-platform independent vector: [control-bulk-v1.json](../fixtures/control-bulk-v1.json). Upload flow, limits and completion semantics: [attachment transfer](../../docs/ATTACHMENT-TRANSFER.md).

For negotiated uploads the Mac issues authenticated `uploadMissing` events for incomplete packets after 150 ms, at most three times without extending the packet lifetime. The phone resends only requested fragments from its bounded 2 MiB ciphertext cache, after checking the pending upload and current authorization. Missing parts do not trigger another encryption pass or a provider action.
