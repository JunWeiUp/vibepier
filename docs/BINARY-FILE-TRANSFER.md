# Binary file transfers / 二进制文件传输

Images/attachments and APKs negotiate an independent file capability through the existing authenticated, encrypted session RPC. Legacy peers/Bluetooth retain the existing encrypted session transfer. A missing local helper does not advertise APK binary support; no plaintext control fallback is added.

## Routes and authorization / 路径与授权

`VibePierFileServer`, a signed child bundled beside the Mac app/CLI executable, listens on an ephemeral HTTPS port. It generates an in-memory P-256 TLS certificate; Android pins the exact SHA-256 received inside the encrypted offer. Only that connection uses the pin; global trust and hostname policies are unchanged. The Mac issues independent random 256-bit read/write capabilities for one device, operation, scope, immutable file and offset. Capabilities expire after ten minutes, reject replayed bodies, and are revoked on cancellation, trust changes or completion. The helper receives no pairing keys, provider credentials or desktop access; its private stdin pipe issues capabilities. It exits when the parent closes the pipe. Incoming sockets/handshakes, active files, buffers and file sizes are bounded.

The phone probes the authenticated transport's IP for direct HTTPS. If the direct connection cannot be established before sending a body, it uses the configured HTTPS relay. There is no automatic second-route body replay after a partial/uncertain transfer. The relay accepts file registrations only with a fresh authenticated host proof using existing nonce/replay checks. Bodies stream through bounded `io.Pipe` buffers with backpressure, not relay storage. Independent one-use producer/consumer tokens prevent cross-file access; disconnect, completion, cancellation and expiry close pipes. Nginx file locations must disable request/response buffering. Existing WebSocket/control settings and room secrets are preserved. Public file requests honor the existing explicit `VIBEPIER_RELAY_PROXY` setting and environment proxy policy; authenticated LAN connections bypass HTTP proxies.

## Data and durability / 数据与落盘

Both attachments and APKs use raw binary bodies inside HTTPS, with no additional application-layer encryption. Thus the relay can read both image and APK content; this reduced confidentiality was explicitly accepted by the user. Device/session authorization and expected hashes remain inside the original encrypted control channel. Mac attachment completion requires the receiving worker's final fsync, imports into the original device/session attachment record, and verifies the complete SHA-256/image format before success. Uploading never submits an AI message. Byte-send progress stays below 100% until completion is confirmed.

APK bytes use HTTPS transport protection without extra application-layer encryption. Consequently the relay can read APK content; it still cannot issue phone control actions or change the authenticated expected size/hash. Android downloads a continuous byte stream, writes/syncs in batches of up to 1 MiB, and resumes from the last durable file length. A new capability binds each requested offset. Full digest/package validation precedes the unchanged system install confirmation and signing checks. Download, verification and installation remain distinct.

图片及 APK 都通过独立二进制通道传输，只保留 HTTPS，不做额外应用层加密。用户已明确接受这一隐私调整：公网服务器能读取图片和 APK 内容。设备授权、作用域、随机短期凭据、摘要和安装签名检查保留。局域网优先手机与 Mac 直连；失败且尚未发送正文时才选择公网，部分传输失败不自动重放正文。APK 按最多 1 MiB 批量落盘，以实际同步长度续传；收到文件不等于安装成功，系统确认仍需用户操作。

## Build and validation / 构建与验证

Mac packaging builds the helper from `services/relay/cmd/vibepier-file-server` with Go and signs it before the containing bundle. CLI archives include the sibling helper. Build/package commands never run it or install keys/settings. `services/relay/nginx-vibepier-relay.conf` includes the additional file location.

Go tests cover exact body sizes, truncation/extra bytes, capability replay, cancellation/device isolation, APK offset binding and real HTTPS cloud producer/consumer cleanup. Opt-in `VIBEPIER_BINARY_HELPER_TEST_EXECUTABLE=<helper>` Swift tests use synthetic authorization/private directories to exercise TLS upload and attachment manifest completion. Emulator `binary-files` uses synthetic data and a separately launched test helper; no providers or APK installers run. Synthetic loopback/emulator speeds must not be described as real-device Wi-Fi throughput.

构建包含 Go 文件助手，按与应用一致的发布方式签名，不修改系统证书或全局 TLS 设置。测试区分单元测试、模拟器网络测速和真机验收；模拟数据不发送给 AI，也不触发系统安装。
