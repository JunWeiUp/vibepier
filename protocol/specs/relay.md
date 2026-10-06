# Relay routing protocol

The relay is an authenticated WebSocket router. It does not implement phone enrollment or decrypt the [control channel](secure-control.md). Use WSS for public connections; the sample deployment terminates TLS at Nginx and forwards to loopback.

## Admission

The first text message must arrive within 10 seconds and fit in 1024 bytes. This admission deadline is absolute: pings and partial fragments do not renew it. HTTP upgrades require GET, HTTP/1.1 or later, the Connection/Upgrade headers, WebSocket version 13 and a 16-byte Base64 client nonce. Up to 128 upgraded connections, including unauthenticated peers, are admitted per relay process; further upgrades receive HTTP 503 until capacity is released.

```text
<protocol> hello <role> <room> <unix-seconds> <nonce> <hex-hmac>
```

The HMAC is SHA-256, keyed by the UTF-8 server secret, over:

```text
<protocol>|<role>|<room>|<unix-seconds>|<nonce>
```

The current Mac selects `vibepier-relay2` with role `host`; Android selects `vibepier-relay1` with role `client`. Version is covered by the signature. These are the only accepted role/version pairs: relay2 host and relay1 client. A relay1 host or relay2 client is rejected with `bad-role` before joining a room; there is no single-phone compatibility mode. The current pairing-code prefix `vibepierrelay1` is a separate format and remains supported. These relay routing versions do not enable the old VibeBar application protocol or plaintext desktop control.

Rooms match `[A-Za-z0-9_-]{1,64}`. The accepted nonce length is 16–64 characters; production clients generate random hexadecimal nonces. Clock skew is at most 120 seconds. Nonces are retained for five minutes to reject reused admission requests; the nonce table is bounded. Incorrect version, role, room, clock, signature or replay returns `<protocol> error <reason>` and closes the connection. Admission success returns `<protocol> ok`.

Shared known-answer vectors live in [relay-hello.json](../fixtures/relay-hello.json). The relay2 host and relay1 client vectors describe current contracts. The retained relay1 host HMAC vector is a shared cryptographic/rejection fixture, not an accepted handshake; an otherwise valid signature does not make that retired role/version pair admissible. Fixed fixture secrets and nonces are not deployment credentials.

## Multiple phones

A room has one host. A newer host replaces the old host, and a late callback from a replaced connection must not remove its successor. The relay2 host supports up to 32 concurrent phone connections. Joining or replacing a host never evicts phones, including phones that arrived while no host was online; a new phone never replaces another phone. Each phone connection receives a server-generated random 32-character hexadecimal peer ID; this is a routing ID, not a trusted device UUID.

Mac topology notifications:

```text
vibepier-relay2 peer up <peer-id>
vibepier-relay2 peer down <peer-id>
```

Phones receive `vibepier-relay1 peer up` / `peer down` when a ready host becomes available or leaves. Each phone sends its secure handshake or encrypted frame as the text message body. The server routes it to the Mac as:

```text
vibepier-relay2 from <peer-id> <base64-original-message>
```

The Mac binds that routing peer to the authenticated device/session and replies only to that peer:

```text
vibepier-relay2 to <peer-id> <base64-secure-response>
```

The phone receives the decoded secure response. An unwrapped host message is dropped. Unknown/disconnected peer IDs do not fall back to another phone or a room broadcast. Reserved relay control prefixes from a phone are not forwarded as application messages. Room authentication alone never authorizes a secure control session.

## Bounds and lifecycle

Phone text messages are limited to 1 MiB; routed-host messages have a 2 MiB bound to allow the Base64 envelope. Aggregate fragmented messages share the same limits. The inner secure-control protocol imposes its smaller 16 KiB wire / 8 KiB plaintext limits independently. Per-connection server outbound queues are bounded by 4 MiB and 2048 frames; oversized or slow connections are closed. Android queues at most 256 bounded secure-control frames, binds each queued write to its original connection, and closes/reconnects on queue overflow rather than accumulating data or moving queued controls to a new socket.

Framing follows [RFC 6455 sections 5.2–5.5](https://www.rfc-editor.org/rfc/rfc6455.html#section-5.2): clients mask frames, servers do not; reserved bits and nonminimal/overflowing lengths are rejected. Control frames must be final and at most 125 bytes. Text fragments retain their order across interleaved pings; unexpected continuations, interleaved data messages and invalid UTF-8 are rejected. VibePier's relay protocol uses text messages only and does not negotiate extensions or binary messages.

The server sends WebSocket ping frames every 25 seconds and uses a 75-second idle timeout. Transport heartbeat and input-release leases on the Mac/phone are separate and shorter. The service retains no conversation history or durable room database. Logs contain connection metadata and rejection reasons, not application plaintext; reverse-proxy access logs may contain IPs and request paths.

A successful relay admission is only the first step. Clients must also complete phone authorization, the secure handshake, and application-state exchange. A bare HTTP 426 response verifies only that the WebSocket endpoint is reachable.

## File-channel admission

`POST /files/register` uses the same fresh, protocol-bound hello in `X-VibePier-Authorization`, and requires the current `vibepier-relay2` host contract. Retired host1 and all client registrations are rejected; room binding, clock and nonce replay checks remain mandatory. Per-transfer read/write capabilities, bounded streaming and device authorization at the endpoints are unchanged. Removing host1 does not change the current file registration or phone download/upload formats.

## Relay and direct UDP

The authorized application channel may exchange UDP candidates and probe tokens, including STUN-derived public mappings. Direct packets still require the same device/session cryptography. A direct route is an optimization and may be unavailable behind restrictive NAT/firewalls. Session traffic remains relay-routed; microphone frames require BLE, local Wi-Fi or direct UDP, not the relay.

Deployment, credentials and DNS recovery are documented in [DEPLOYMENT.md](../../docs/DEPLOYMENT.md); metadata exposure is documented in [PRIVACY.md](../../docs/PRIVACY.md).

## 中文说明

中继最多接受 128 个 WebSocket 连接，包含尚未认证的连接；握手正文上限 1024 字节，必须在 10 秒内完成，ping 和分片不会延长期限。帧格式、掩码、长度、分片顺序和 UTF-8 均校验，控制帧不允许分片且最多 125 字节。手机发送队列最多容纳 256 个加密控制帧，队列过满会关闭并重连；旧连接的待发内容不会被转发到新连接。

当前仅接受 Mac `vibepier-relay2`/`host` 与 Android `vibepier-relay1`/`client` 两种角色协议组合。旧 relay1 host 在入房前拒绝，删除单手机替换和默认路由回退；host 重连保留全部手机，回复必须带同房间 peer ID。HMAC 仍绑定协议、角色、房间、时间和 nonce；文件注册同样仅接受当前 host2，文件能力与流式通道不变。`vibepierrelay1` 是当前配对码格式，继续保留，不属于已删除的 host1 兼容。
