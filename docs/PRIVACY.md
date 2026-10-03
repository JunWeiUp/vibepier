# Privacy and local data / 隐私与本地数据

VibePier connects your phone to your own Mac and an optional relay you operate. The application does not require a VibePier account or a hosted VibePier service. Your AI desktop application continues to use its own provider account, network endpoints, and data policies.

VibePier 连接你自己的手机和 Mac，可选中继也由你自行部署。无需 VibePier 账户或托管服务；AI 桌面应用仍使用其自身的服务账户、网络接口及数据政策。

## Where data goes / 数据去向

| Data / 数据 | Storage and destination / 存放及用途 |
| --- | --- |
| Device authorization / 手机授权 | Mac Keychain and Android Keystore; separate identity for each phone. / 两端安全存储，每台手机单独授权。 |
| Relay endpoint, room, secret / 中继配置 | Mac keeps the secret in Keychain; Android encrypts the saved setup using Keystore. Approved BLE transfers the setup. / 密钥不写入普通配置摘要，经已授权蓝牙同步。 |
| Session text, drafts, cached images and request receipts / 会话、草稿、缓存图像与回执 | Read from the supported provider on the Mac, transmitted on an authenticated encrypted channel, cached in encrypted Android preferences. / 来自 Mac 会话，手机缓存经过认证加密。 |
| Mac configuration, session receipts, activity metadata / Mac 配置、回执、活动信息 | Local user support directory with private file permissions; not all local files have application-level encryption. / 保存在当前用户支持目录，文件权限受限，但并非所有文件均另行加密。 |
| Mac login password for optional unlock / 可选解锁密码 | Submitted over the authorized channel, verified on Mac, saved in Mac Keychain; not persisted on the phone. / 仅 Mac 钥匙串持久保存。 |
| Phone microphone / 手机麦克风 | Captured only during the phone voice action, sent to Mac over BLE/local Wi-Fi/direct UDP. No phone audio forwarding through the relay. / 仅语音操作期间采集，中继不转发手机音频。 |
| Application usage / 应用用时 | Optional; local Mac timeline with up to 90 days of history and an encrypted phone snapshot. / 默认关闭，开启后记录前台停留，手机保存加密快照。 |
| APK delivery / APK 下发 | Received into the Android app's private file directory, verified by SHA-256, then handed to the system installer. The APK bytes themselves are not additionally encrypted at rest. / 安装文件暂存应用私有目录，内容本身不额外做落盘加密，安装由系统确认。 |
| Screenshots / 截图 | Screenshots and screen recording are allowed; their storage/sharing follows the OS or capturing tool. / 允许截图和录屏，由系统或截取工具管理。 |

The Mac's own session providers may retain conversation files and uploaded attachments independently of VibePier. Deleting the Android app does not delete those provider records or the Mac's authorization entry. Revoke a lost phone on the Mac as well as securing the phone account/device.

卸载手机应用不会删除 Mac 上的会话来源记录或手机授权项。手机丢失后应在 Mac 撤销其授权。不要把卸载 VibePier 当成清除 AI 服务商历史记录。

## Local control / 本机控制

The CLI/app control socket is local to the current Mac user. It requires a private parent directory and a `0600` socket, checks the connected peer's effective user ID on both ends, and does not expose a TCP endpoint. A same-user process can invoke local commands; this is not a sandbox between applications running as that user. Requests are limited to 1 MiB and replies to 8 MiB, excluding the required final newline. The server reads each request and writes each reply within separate two-second absolute I/O deadlines; the client's timeout covers connect, write and reply together. A timeout does not undo an action already handed to a provider, and the transport never automatically repeats it.

本机控制接口仅面向当前 Mac 用户，两端均校验对方用户身份；它不是同一用户下不同应用之间的隔离沙箱。请求上限 1 MiB、回复上限 8 MiB（不含行尾换行），服务端每次读入/写出各有 2 秒总期限。客户端超时不会撤销已经交给服务商的操作，也不会自动重发。

## Network metadata / 网络元信息

Android transport diagnostics contain fixed event/error categories. They exclude received JSON, exception messages/causes, relay URLs, candidate IP addresses, and pairing/session content. The Mac does not log the configured relay URL/room or invalid shortcut text. These restrictions apply to VibePier's own diagnostics, not OS logs or third-party provider logs. Optional USB hardware frame debugging remains off by default; review debug output before sharing it.

Android 连接日志只记录固定事件与错误类别，不写入收到的 JSON、异常原文、中继地址、候选 IP 或配对/会话内容。Mac 也不记录配置的中继地址/房间或无效快捷键原文。该约束不涵盖系统和第三方应用日志；USB 硬件帧调试默认关闭，分享调试输出前仍需检查。

WSS protects the relay connection, while the application-level channel encrypts business payloads end to end between approved devices. The relay or reverse-proxy operator still sees client IPs, room/routing identifiers, online periods, message sizes and timing. Server and Nginx access logs may retain this metadata according to your deployment settings. Avoid publishing logs without reviewing them.

A negotiated direct UDP path exchanges endpoint information and can use STUN infrastructure to discover public mappings. The current STUN endpoints are `stun.miwifi.com:3478`, `stun.chat.bilibili.com:3478` and `stun.l.google.com:19302`. Networks and STUN operators can observe this connectivity metadata. Direct connectivity is best effort; NAT/firewall rules may keep traffic on the relay.

By default Android uses system DNS. Optional AliDNS HTTPS recovery must be explicitly enabled for the relay on the Mac. After a failed system connection, it sends the relay hostname to `dns.alidns.com`; AliDNS can see the hostname and requesting IP. It does not receive the room secret, device keys, or session contents. TLS continues to verify the original relay hostname. See [configuration](DEPLOYMENT.md#optional-android-dns-recovery).

中继与反向代理能看到 IP、房间/路由标识、在线时段、流量大小及时序，日志保留由部署者控制。UDP 直连协商与 STUN 也涉及公网地址元信息。DNS 默认使用系统解析；只有明确开启 AliDNS HTTPS 恢复后，失败连接才会把中继域名交给该解析服务，仍校验原域名证书，不发送房间密钥或会话内容。

## Backup and recovery / 备份与恢复

Android declares `allowBackup=false`, disables the old full-backup mechanism, and excludes app storage from both cloud backup and device-to-device transfer on newer Android versions. These are OS backup controls, not protection against a compromised OS or a manually copied screenshot. See [Android backup rules](https://developer.android.com/identity/data/autobackup).

Private preference keys are tied to the Android installation/Keystore. Copying the encrypted files to another device does not restore authorization or make them readable. Updates signed by the same Android release key retain existing app data; uninstalling or clearing data loses local drafts, caches, receipts and enrollment. Do not clear data merely to resolve an ambiguous send: first verify the result on the Mac.

Android 私有数据已排除云备份与设备迁移；复制加密文件不能恢复另一台手机的密钥。相同签名覆盖更新可保留数据，卸载/清数据会丢失本地草稿、缓存、回执和授权。发送结果不确定时，应先在 Mac 确认，避免用清数据解决后重复发送。

The phone retains uncertain mutation requests until their results are reconciled or explicitly handled. Admission is capped at 128 records and 8 MiB; reaching that limit refuses new submissions rather than discarding older uncertain work. Active in-memory requests have separate 64-request/2 MiB limits. Unlock-password verification is excluded from durable request storage and is never automatically repeated on timeout. A malformed or mismatched reply cannot clear a saved uncertain mutation or its draft.

手机不会为了腾空间而自动丢弃未确认的操作。未知回执达到 128 条或 8 MiB 时拒绝新请求；内存中活动请求另限 64 条/2 MiB。密码验证不写入持久回执，超时不自动重试。格式错误或会话/结果不匹配的回复不会清除未知回执及草稿。

## Mac operation receipts / Mac 操作回执

The private `codex-receipts.json` filename is retained for upgrade compatibility; its `SessionReceiptJournal` implementation now serves every provider. The journal is read with a 16 MiB file bound and validates record/payload sizes before use. Missing, corrupt, oversized, non-regular, linked or unreadable stores are not interchangeable: only a genuinely missing file starts empty. New reservations account for the maximum 300,000-byte result before any action is dispatched, within 16 MiB overall and 4 MiB per device. Up to 2000 active records and 20,000 total records including retired markers are allowed. Full capacity pauses new mutations without deleting earlier IDs.

A saved completion removes its original request body; the definitive result is immutable. On a later admission, completed operations older than seven days can discard their response body and retain a compact retired marker with the original ID/fingerprint/scope. Unknown operations retain their intent for reconciliation and are never automatically retired. A retired marker returns an unknown/protected state rather than `notFound`; it never makes the operation eligible for re-execution. Do not delete the journal to make space while results are uncertain. A store that fails during publication stops accepting fresh writes until it is reloaded and validated.

Writes use a `0600` temporary file in the private directory, file synchronization, atomic rename and directory synchronization. A stable adjacent `.lock` and content revision check prevent cooperating stale writers from overwriting newer reservations. The lock file must remain in place while the service runs. These filesystem controls do not protect against another process already running with the same user's privileges.

Mac 回执文件上限 16 MiB，每台设备按 4 MiB 预算；执行操作前还会为最大结果预留空间。最多保留 2000 条活动记录和 20,000 条含退役标记的总记录。存储损坏或超限时停止接受新操作，保留原文件，不通过清空恢复。

确认结果成功落盘后移除原请求正文，首次确定结果不可覆盖。后续接收新操作时，超过七天的已完成操作可清理回复正文，但保留编号、指纹和作用范围；未知操作不自动清理。退役标记仍阻止重放，不会返回“未执行”。不要通过删除回执文件释放空间来处理不确定结果。文件按 `0600` 权限原子替换并同步，稳定锁文件与版本校验防止旧写入者覆盖新记录；发布过程出错后须重新加载校验，才会继续接受新写入。

## Defaults / 默认值

Automatic unlock, usage tracking and phone microphone capture require separate configuration/permission. The normal voice shortcut uses the Mac microphone. No hosted relay is preconfigured, no personal relay DNS exception is embedded, and DNS recovery is off unless explicitly selected.

自动解锁、应用用时统计、手机麦克风均需另外设置或授权；语音默认使用 Mac 麦克风。未内置托管中继、个人服务器或个人域名 DNS 特例，DNS 恢复默认关闭。

### Provider-local receipts / 服务商进程内回执

Claude/ZCode mutations and Codex creation also reserve process-local client/operation fingerprints. The cache has per-client/global record and byte budgets, preserves unresolved identities, and may retire completed response bodies without permitting re-execution. Bounded read-only observers can retain a creation baseline or first-message text until confirmation or process exit. These caches are not a replacement for the durable device-scoped receipt journal: a restart can remove native lookup evidence while the original durable reservation remains unknown. Disconnecting a phone does not discard an in-progress operation. ZCode unresolved native proof storage separately refuses admission at its count/byte limits.

进程内缓存可能保留核验新建所需的首条消息或 ID 基线，确认后释放观察器，进程结束后清除；容量有每机和全局上限。手机断线不清除进行中的操作，丢失原生证据也不能删除持久化的未知标记或自动重发。

## Codex quota and reset cards / Codex 额度与重置卡

Account credentials remain with the local Codex app-server. The authorized phone receives remaining percentages, reset times, card metadata and an account identifier over the encrypted device channel. It stores uncertain reset intent in the encrypted receipt store; the Mac journal retains the matching operation. Opening or refreshing the panel never consumes a card. Only an explicit card selection and confirmation can consume an existing gifted card; no purchase API is used.

账户凭据不发送到手机。手机只接收额度、时间、卡片信息和账户标识，未确认的兑换操作按已有加密回执机制保存；打开或刷新面板不会消耗卡片，也不购买额度。

The app picker shares installed application names and bundle identifiers with authorized phones. It scans `/Applications`, `/System/Applications`, and `~/Applications` (up to two nested directories), and saves the shared dock selection on the Mac. It does not share application paths or start an app when selected.

手机应用选择器向已授权手机提供已安装应用的名称与标识符，选择结果保存到 Mac 并同步到其他手机。文件预览仍受 macOS 文件夹访问权限限制：首次读取文稿、桌面或下载目录中的会话文件时，需要在 Mac 的系统提示中允许对应目录；不要求完全磁盘访问权限。图片读取超时不会阻塞会话正文。
