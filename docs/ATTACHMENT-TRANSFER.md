# Attachment transfer / 附件传输

Android reads system-selected content into private storage with a 10 MiB limit. File copying, format conversion, streaming SHA-256, chunk reads/base64 and session encryption run on background workers. The upload keeps bounded chunk buffers rather than a full in-memory file. Supported JPEG/PNG/WebP/GIF files retain their original bytes; this optimization does not silently reduce image quality.

A non-Bluetooth `attachmentStart` (or `newAttachmentStart`) requests `uploadVersion: 1`. A supporting Mac returns an `upload` profile with version 1, token equal to the attachment UUID, 512 fragment characters for Wi-Fi/direct UDP or 7200 for the relay, 64 KiB chunks and a three-slot window. Three 64 KiB base64 RPC chunks stay within the existing 384 KiB provider request budget; the fourth per-device assembly slot remains available to ordinary RPC. An absent/invalid profile keeps the original serial, encrypted path; Bluetooth uses its existing 8 KiB serial chunks.

The Mac requests missing fragments after 150 ms, with at most three recovery rounds and a fixed packet lifetime. The phone retains at most 2 MiB of encrypted fragment frames for selective resend, clears them on completion/cancellation, and verifies the active request and authorization before replaying them.

Each reservation covers both background encoding and an outstanding request. Reordered acknowledgements advance confirmed byte progress once; offsets/attachment IDs must match. Progress is throttled to roughly 150 ms and updates the existing label instead of rebuilding the composer. Leaving the page, changing authorization/provider/view, or cancelling stops the upload, removes pending attachment retries, and prevents completion. No AI turn is submitted by an upload.

Wi-Fi/direct UDP session fragments use the authenticated direct channel when it is ready, including when the connection was first discovered through the relay. The relay remains the encrypted route when there is no authenticated direct channel. A negotiated 7200-character upload remains on the relay if a direct channel becomes available mid-transfer; it cannot silently move oversized frames onto UDP. Optional capability 16 authenticates already encrypted upload fragments with a connection-scoped HMAC instead of a second per-fragment AES pass; see [secure control](../protocol/specs/secure-control.md#attachment-fragment-authentication--附件分片认证).

The Mac's negotiated chunks are aligned, bounded, scoped to the authorized device and session/draft, and may arrive out of order. Exact retries are idempotent; conflicting bytes are refused. Chunk receipts explicitly report `durable: false`: bytes have been received/written, not guaranteed across a crash. Completion requires every chunk, one file synchronization, exact size/SHA-256 and a readable image format before persisting the completed manifest. A restarted incomplete fast upload lacks its in-memory coverage map and cannot complete or resume implicitly; remove it and start a fresh attachment ID. Existing serial uploads keep their per-chunk durable behavior.

## 中文说明

相册选择后，文件复制、格式转换、流式摘要、分块读取/编码及加密均在后台完成，单附件仍限 10 MiB，不通过降低原图质量换取速度。Wi-Fi 附件上传协商后使用 64 KiB 分块、三块并行；Wi-Fi/直连使用 MTU 内的 512 字符网络分片，中继使用 7200 字符分片；没有新版协商能力时保留串行加密方式，蓝牙仍为 8 KiB 串行。

已认证 Wi-Fi 直连可直接承载会话附件，避免在显示“直连”时仍绕云中继。整块附件只做一次会话 AES-GCM 加密；协商能力位 16 后，网络分片用连接专属 HMAC 验证，不逐片重复调用密钥库做 AES。普通控制、回复和未协商连接仍沿用原加密策略。

上传进度按 Mac 已确认字节计算，并限频更新现有标签，不反复重建输入区。取消、切换会话/授权/服务商会停止上传与自动补发，上传本身不会提交 AI 消息。Mac 只在全部分块、落盘同步、完整 SHA-256 和图片格式校验成功后标记附件完成；分块接收回执不代表最终保存成功。重启后未完成的快速上传不得按文件长度误认为完整，需要新附件重新上传。

## Validation / 验证

`AttachmentUploadWindowTest` covers bounded reservations and reordered/duplicate/incorrect acknowledgement offsets. Swift attachment tests cover out-of-order writes, exact retries, conflicts, missing parts, restart refusal and completed-file recovery; packet/control tests cover operation binding, BLE refusal, capability gating, changed keys/peers and replay rejection. `attachment-upload` instrumentation uses isolated preferences, synthetic file data, Android Keystore and a delayed synthetic host to compare transfer framing, progress and UI responsiveness. Synthetic timings do not establish real-device network throughput.

`attachment-network-upload` and the opt-in `AttachmentNetworkProbeTests` host exercise real emulator-to-Mac UDP with the production phone codec and Mac authenticated assembly/storage. The synthetic host deliberately drops a fragment and verifies selective recovery and SHA-256 completion; it never connects to a provider or production trust store.

## Binary channel / 二进制通道

New peers prefer the [binary file channel](BINARY-FILE-TRANSFER.md), including direct HTTPS and streaming relay transfer. The chunked protocol above remains for legacy peers/Bluetooth.

新版优先使用独立二进制文件通道，支持局域网 HTTPS 直连及公网流式转发；上述分片方式供旧端和蓝牙使用。
