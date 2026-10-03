# Deployment and distribution

The relay deployment commands are included directly in [English README](../README.md#deploy-your-own-relay) and [中文 README](../README.zh-CN.md#自建云中继部署命令与接入方法). This page covers operations and packaging details.

## Relay topology

```text
Android ── TLS/WebSocket ── Nginx :443 ── loopback :47801 ── vibepier-relay
                                                               │
Mac ───────────────────── TLS/WebSocket ─────────────────────────┘
```

The relay carries encrypted business frames. Relay-room authentication and phone authorization are separate: possessing the relay secret does not authorize a phone to control the Mac. One room supports one Mac and up to 32 phone connections.

The supplied systemd unit uses `DynamicUser`, `LoadCredential`, `NoNewPrivileges`, a read-only system filesystem, a private temporary directory, and a memory limit. Use systemd 247 or newer. `/etc/vibepier-relay/secret` stays root-only; systemd supplies it to the service through its credential directory.

## Retrieving the secret when sudo needs a password

On the server, create a temporary copy readable only by the SSH account. The shell expands `$USER` and `$HOME` before `sudo` starts:

```sh
sudo install -m 0600 -o "$USER" /etc/vibepier-relay/secret "$HOME/vibepier-relay-import.secret"
```

Back on the Mac:

```sh
umask 077
mkdir -p "$HOME/.config/vibepier"
scp "$RELAY_HOST:vibepier-relay-import.secret" "$HOME/.config/vibepier/relay-import.secret"
vibepier relay configure \
  --url "wss://$RELAY_DOMAIN/vibepier/relay" \
  --room 'my-mac' \
  --secret-file "$HOME/.config/vibepier/relay-import.secret"
rm "$HOME/.config/vibepier/relay-import.secret"
ssh "$RELAY_HOST" 'rm "$HOME/vibepier-relay-import.secret"'
```

Do not commit a relay secret, paste it into an issue, or include it in captured terminal logs. The configuration CLI does not print credentials.

## Verification and troubleshooting

```sh
# On the server:
sudo systemctl is-active vibepier-relay
sudo systemctl is-enabled vibepier-relay
sudo journalctl -u vibepier-relay -n 50 --no-pager
sudo nginx -t
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:47801/

# On the Mac:
vibepier relay status
curl -s -o /dev/null -w '%{http_code}\n' "https://$RELAY_DOMAIN/vibepier/relay"
```

| Result | Check next |
| --- | --- |
| Local HTTP 426 | Service is reachable; proceed to HTTPS and authenticated clients. |
| Public HTTP 404, redirect, or HTML | The exact relay location is missing from the correct HTTPS server block. |
| HTTP 502 | Service is stopped, wrong loopback port, or Nginx cannot reach the upstream. |
| TLS/certificate error | Domain, DNS, certificate chain, expiry, and firewall. Keep certificate verification enabled. |
| Authentication rejected | Compare the server secret with the configured Mac/phone settings; check clocks. |
| Mac waiting for phone | Keep the authorized phone on BLE to sync relay settings, then select cloud relay. |
| Direct path unavailable | The relay remains the fallback. NAT/firewall policy can prevent UDP direct paths. |

A 426 check is not a functional acceptance test. Verify real application-state synchronization, a supported session read, disconnection recovery, and cellular-only access separately.

## Optional Android DNS recovery

The default is system DNS only. If your phone's network cannot resolve or reach your relay through system DNS, you may explicitly allow AliDNS HTTPS recovery in the Mac relay window. The CLI accepts the same choice:

```sh
vibepier relay configure \
  --url "wss://$RELAY_DOMAIN/vibepier/relay" \
  --room 'my-mac' \
  --secret-file "$RELAY_SECRET_FILE" \
  --dns-recovery alidns
```

Use the private secret-file retrieval flow in the README before running this command, then delete the import file. Use `--dns-recovery system` to turn recovery off. Reconnect each approved phone over Bluetooth to sync the change before switching back to cloud relay. The optional pairing-code suffix is `dns=alidns`; a code without it uses system DNS only.

This setting applies only to public-hostname WSS relays. On failure, the phone can send the hostname to `dns.alidns.com` and cache validated IPv4 answers for their bounded TTL. Original hostname/SNI and certificate verification remain mandatory. It does not change system DNS or apply to arbitrary browsing. Resolver operators can see the requested relay hostname and client IP; enable it only when this tradeoff suits your network. See [privacy](PRIVACY.md).

## Proxy on the Mac

A Mac with a deliberately configured HTTP CONNECT proxy can use `VIBEPIER_RELAY_PROXY`, for example `http://127.0.0.1:8080`. This setting applies only to the relay URLSession. Set it in the VibePier LaunchAgent's `EnvironmentVariables`, then reload that launch agent. It does not disable TLS verification or configure the system-wide proxy. Do not copy another person's private proxy address into a public default.

## Upgrades and rollback

Run the same `services/relay/deploy.sh` command to update the binary and unit. The script preserves the existing secret. Before an operational upgrade, preserve the prior binary and Nginx site outside `/etc/nginx/sites-enabled`; files left in an included directory can be loaded as configuration.

To stop a service temporarily:

```sh
sudo systemctl stop vibepier-relay
```

To remove it from startup:

```sh
sudo systemctl disable --now vibepier-relay
```

For rollback, restore the previous compatible binary/unit, run `sudo systemctl daemon-reload`, restart the service, validate Nginx, and reload Nginx. Do not silently downgrade to the old VibeBar protocol. Keep the old deployment isolated if a historical restore is required.

## Secret rotation

Create a new 32–256-character secret in `/etc/vibepier-relay/secret` with mode 0600, restart the relay, and import that secret into the Mac using the README flow. Connect each approved phone over Bluetooth to refresh its relay settings before switching back to cloud relay. Rotation changes relay access; device revocation in the Mac app independently removes a phone's authorization.

## macOS packaging

```sh
make package-macos
```

Produces an Apple-silicon app ZIP and CLI archive under `dist/`. With no signing identity the app is an explicitly unnotarized ad-hoc preview. For public Developer ID signing, set `MACOS_SIGN_IDENTITY` to a `Developer ID Application:` identity. Development certificates are not used for public distribution. The optional notarization helper is [scripts/release/notarize-macos.sh](../scripts/release/notarize-macos.sh).

Build/package commands do not install the app, launch it, change permissions, or import certificates. Installation and system permissions are separate explicit operations.

### Optional Developer ID notarization

The initial preview does not require an Apple Developer account. For a later notarized distribution, use a Developer ID Application certificate in your local signing keychain. Store notarization credentials interactively so a password is not placed in shell history:

```sh
xcrun notarytool store-credentials vibepier-notary
export MACOS_SIGN_IDENTITY='Developer ID Application: YOUR_NAME (YOUR_TEAM_ID)'
export NOTARY_PROFILE='vibepier-notary'
./scripts/release/notarize-macos.sh
```

The helper builds/signs the arm64 app with hardened runtime, submits its ZIP and waits, staples and validates the app ticket, runs Gatekeeper assessment, then rebuilds the ZIP containing the stapled app. It extracts that final ZIP and checks its ticket/signature again. Regenerate checksums afterward. Credential setup and submission contact Apple's service; ordinary build/test commands do not. Keep certificates, private keys and notarization profiles outside the repository. This optional path has a checked script/CLI contract, but a successful Apple submission must be recorded separately for the exact release; it has not been performed for the initial preview. Apple's [stapling explanation](https://developer.apple.com/forums/thread/720093) describes why a bundled ticket matters for offline first launch.

This helper notarizes the **app ZIP only**. The separately packaged CLI archive is not included in that submission and must remain labeled as an unnotarized preview unless a separate signed/notarized CLI distribution is implemented and verified.

可选公证流程使用本机 Developer ID Application 证书和钥匙串 profile，交互录入凭据，不把密码写进命令。脚本等待公证、装订并检查票据后重新打包，再生成校验和。该流程仅覆盖应用 ZIP，不包括单独的 CLI 包。首个预览版仍明确标注未公证；有脚本不等于已通过 Apple 公证。

## Android signing

The release script requires these environment variables, sourced from private storage outside the repository:

```sh
export ANDROID_KEYSTORE_PATH='/private/path/android-release.jks'
# Set ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD
# using your private credential mechanism, without committing them or logging their values.
./scripts/release/android.sh
```

The output is `dist/VibePier-<VERSION>-android.apk`. Keep the release key and a secure independent backup: Android updates require the same signing identity. `designReview` is a separate debug-signed application with a `.review` suffix and is not a public release artifact.

## Relay archives

```sh
make package-relay
```

This produces Linux amd64 and arm64 archives, including the service unit, reverse-proxy snippet, license, and notice. Rebuild final artifacts from the exact published commit and publish SHA-256 checksums alongside them. This repository does not require Cloudflare or a component registry.
