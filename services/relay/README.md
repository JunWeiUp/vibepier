# vibepier-relay

Self-hosted WebSocket relay for VibePier, implemented in Go using only the standard library. One room connects one Mac and up to 32 phones. The relay routes encrypted application frames; a relay credential does not grant phone authorization.

See the root [English deployment guide](../../README.md#deploy-your-own-relay) or [中文部署指南](../../README.zh-CN.md#自建云中继部署命令与接入方法) for complete commands: server preparation, binary installation, Nginx/WSS, private secret import, phone synchronization and verification.

From the repository root:

```sh
./services/relay/deploy.sh ubuntu@YOUR_SERVER_IP amd64
# Use arm64 for an ARM Linux server.
```

The script requires SSH, sudo, systemd 247+, and local Go 1.22+. It installs `/usr/local/bin/vibepier-relay`, enables `vibepier-relay.service`, and creates a root-only `/etc/vibepier-relay/secret` on first use. Upgrades preserve the secret. It does not print the secret or modify Nginx. The default listener is loopback `127.0.0.1:47801`; expose WSS through the supplied [Nginx snippet](nginx-vibepier-relay.conf).

```sh
# On the server:
sudo systemctl status vibepier-relay --no-pager
sudo journalctl -u vibepier-relay -n 50 --no-pager
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:47801/
```

HTTP 426 proves the WebSocket endpoint is reachable; separately verify authenticated Mac/phone traffic. Credential rotation, upgrades, troubleshooting and packaging are in [DEPLOYMENT.md](../../docs/DEPLOYMENT.md). Protocol details and shared vectors are in [relay.md](../../protocol/specs/relay.md).

```sh
cd services/relay
go test -race ./...
go vet ./...
go build ./cmd/vibepier-relay
```

The module's interoperability tests also read `../../protocol/fixtures` relative to the repository root; keep the full repository when running tests.

本中继需自行部署，不提供公共服务。中继认证与 Mac 对手机的授权相互独立；密钥不应出现在日志、问题反馈或公开配对码中。安装脚本保留已有密钥，不自动修改 Nginx。完整中文命令保留在根 README。

## Sending capacity and diagnostics / 发送额度与诊断

All rooms share a 12 MiB output-payload budget, including data queued and being written. The 4 MiB per-connection and 128-connection limits remain; slow or overloaded destinations close rather than discard replies. Closing drains reservations. This output budget leaves room for the runtime/readers but does not prove a total RSS bound under the service's MemoryMax. Logs report fixed close reasons and aggregate counts without room, endpoint or message text.

全部房间共享 12 MiB 发送数据额度，计入队列和正在写出的帧；保留单连接 4 MiB 与 128 连接限制，过载关闭并释放额度，不静默丢回执。日志只记录固定原因与聚合数，不含房间、地址或正文。发送额度不等同进程 RSS 上限。

## Streaming files / 文件流

Install the additional `/vibepier/relay/files/` location from `nginx-vibepier-relay.conf`. File registration uses fresh host HMAC admission; one-use read/write capabilities route a bounded live pipe. Attachment and APK content are visible to the HTTPS relay; authorized endpoints still validate complete expected digests. No file bodies are stored on the relay. See [binary file transport](../../docs/BINARY-FILE-TRANSFER.md).

增加该路径的 Nginx 配置，关闭双向缓冲；文件正文仅流式转发，不落服务器磁盘。图片及 APK 均仅采用 HTTPS，服务器可读取正文，现有设备授权与控制加密不变。
