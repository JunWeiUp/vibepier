# Security

VibePier is a desktop-control application. Approve only phones you trust and run the Mac app under your own user account. This is a beta implementation, not an independently audited security product.

The [preview release review](docs/RELEASE-REVIEW.md) records verified boundaries and open findings. Request and subprocess quotas do not bound the entire Mac process: very large local Claude histories can still consume substantial memory.

## Reporting

Use the repository's **Security → Report a vulnerability** form if private reporting is available. If it is not, open an issue asking for a private reporting channel without including exploitation details, credentials, captured sessions, or personal data. Do not attach relay pairing codes, Mac login passwords, Keychain exports, or full conversation logs.

Reports should identify the affected version, transport/provider, a minimal reproduction using synthetic data, and the expected versus observed authorization boundary. Only the current development/beta version is maintained; do not assume old binaries receive fixes.

## Authorization and transport

- First enrollment uses encrypted Bluetooth GATT and explicit Mac approval. Discovery exposes availability, not application metadata. An existing approved phone can reconnect without another prompt.
- Each phone has its own random root key. The Mac stores device authorization in Keychain; Android imports derived keys into Android Keystore. Device revocation stops subsequent authenticated traffic and releases owned input/audio state.
- BLE, Wi-Fi UDP, relay, and negotiated direct UDP use HMAC-authenticated handshakes and directional AES-256-GCM keys. Session binding, sequence replay protection, message bounds, and shorter input leases remain active. Legacy plaintext commands do not trigger a downgrade. See the [control protocol](protocol/specs/secure-control.md).
- Relay-room authentication is separate from device authorization. A relay secret alone does not authorize desktop control. Public deployments use WSS with certificate/hostname validation; plain WS exists for explicit local development only.
- A network or relay operator can observe connection metadata, timing and packet sizes, and can interrupt service. The relay does not receive device keys or plaintext application payloads.

## Local storage and control

Passwords for optional Mac unlock and relay credentials live in Mac Keychain. A legacy development relay secret is moved to Keychain before its JSON copy is removed; failures preserve the original copy and stop migration. Ordinary configuration saves refuse plaintext relay credentials.

Android private preferences authenticate both entry names and contents; random store keys are wrapped by Android Keystore. Legacy values migrate atomically. Corrupted entries do not fall back to plaintext, and writes are blocked rather than discarding uncertain request receipts. Key loss or corruption may require manual recovery; restoring private data to a different device is not supported. See [privacy and storage](docs/PRIVACY.md).

An authorized phone may operate supported desktop apps with the Mac user's permissions. Local processes running as that same user, an already compromised OS, and a person using an unlocked authorized phone are outside the network-authorization boundary. Use OS login protection, device locks, disk encryption, and appropriate account permissions. The private local control socket is not a sandbox against other code running as the same Mac user.

## Desktop actions

Optional unlock verifies and stores a user-supplied login password. It does not bypass FileVault, boot-time login, or system authentication. Failed automated attempts stop until the user resolves the failure. Explicit unlock keeps the desktop unlocked; temporary desktop input leases restore the lock only after all relevant operations finish. A lock request during an active desktop operation is rejected with a retry message.

Mutations retain request IDs and receipts so an ambiguous timeout is not treated as permission to resend. Provider adapters must refuse actions when they cannot verify the target or supported capability. Input holds expire on disconnection, and microphone routing is restored after completion or failure.

## Test and release boundaries

Unit tests use synthetic data. Real desktop automation, audio routing and hardware tests require explicit opt-in. Emulator review builds have a separate package and are not release artifacts. Fixed keys in `protocol/fixtures` are public interoperability samples, never deployment credentials.

Public release gates are tracked in [TODO.md](TODO.md). A passing build, simulated UI test, or encrypted loopback connection is not proof of all real-device behavior.

## 中文说明

首次授权需在 Mac 明确允许，每台手机使用独立设备密钥；之后三种连接及协商出的直连都使用认证加密，不接受旧明文控制。中继密钥与手机授权相互独立；仅知道中继密钥不能操作 Mac。中继运营者仍能看到连接地址、时序和流量大小。

仅授权可信手机。Mac 运行账户已有的权限、同账户其他进程、已被攻陷的系统和已解锁手机上的本地操作，不属于网络授权机制能隔离的范围。自动解锁是单独启用的能力，不能绕过开机登录；失败后停止重复尝试。

发现漏洞时优先使用仓库的私密安全报告入口；入口未开放时，只提交索取私密联系方式的问题，不公开利用细节或个人数据。本项目处于 beta 阶段，尚未完成独立安全审计。存储与数据去向见[隐私说明](docs/PRIVACY.md)，完整发布门槛见 [TODO](TODO.md)。
