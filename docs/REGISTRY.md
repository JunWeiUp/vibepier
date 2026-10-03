# Build artifacts and distribution / 构建产物与分发

VibePier is distributed as applications, a CLI and relay archives. There is **no component registry, npm package, app-store submission or Cloudflare deployment**. This filename documents the actual artifact contract and release process.

## Artifact contract

`VERSION` contains the prerelease-aware version; `VERSION_CODE` contains the Android/Mac numeric build. Build from the repository root. Packaging does not install or launch anything.

| Command | Output in `dist/` | Contents / identity |
| --- | --- | --- |
| `make package-macos` | `VibePier-<VERSION>-macos-arm64.zip` | `VibePier.app`, `io.github.junweiup.vibepier`, icon, permission resources, LICENSE/NOTICE |
| Same command | `vibepier-<VERSION>-macos-arm64.tar.gz` | CLI binary, LICENSE/NOTICE |
| `make package-android` | `VibePier-<VERSION>-android.apk` | Signed production app, `io.github.junweiup.vibepier.remote` |
| Same Android command | `VibePier-<VERSION>-android.apk.json` | Public package/version/SHA-256 metadata; keep beside the APK |
| `make package-relay` | `vibepier-relay-<VERSION>-linux-{amd64,arm64}.tar.gz` | Relay binary, systemd unit, Nginx snippet, LICENSE/NOTICE |
| Explicit checksum step | `SHA256SUMS` | Hashes of the five archives/APK and Android metadata above |

The app's macOS short version uses the numeric prefix; the archive and CLI retain the beta suffix. SwiftPM's GUI product is `VibePierApp`, while the bundle executable is `VibePier`. Do not rename the SwiftPM product to collide with CLI `vibepier` on case-insensitive filesystems.

Public archives omit Finder/resource-fork sidecars and extended filesystem attributes. Verify extracted executable modes and code signatures; inspecting only the staging directory is insufficient. The optional notarization helper also validates the ticket and signature after extracting the final ZIP.

## Signing

Android release packaging requires the four private environment variables in [DEPLOYMENT.md](DEPLOYMENT.md#android-signing). No release credential means no signed release package; debug signing is not a fallback. Keep a secure independent backup and verify its recovery before relying on a key for updates.

With no `MACOS_SIGN_IDENTITY`, Mac packaging produces an ad-hoc **unnotarized preview**. Public Developer ID packaging accepts a `Developer ID Application:` identity and has an optional [notarization step](../scripts/release/notarize-macos.sh). Personal development signatures are not public distribution signatures. A successful local `codesign --verify` is not Apple notarization.

The optional submission covers the app ZIP, not the separate CLI archive; the latter remains an unnotarized preview. Do not transfer an app's notarization claim to a different download.

## Maintainer release sequence

1. Complete the focused release path in [TODO.md](../TODO.md), keeping deferred device/native acceptance explicit. Reuse passing checks for unchanged code rather than repeating the full compatibility matrix. Review the exact public file list and scan for secrets. Keep private signing material, backups and test logs outside tracked files.
2. For the initial publication, create one consolidated root commit with LICENSE/NOTICE intact. Verify `git rev-list --count HEAD` equals `1` and the root has no parents. Do not rewrite anyone else's existing repository to achieve this.
3. Build final artifacts from a clean checkout of that commit. Capture toolchain versions and the commit ID. Verify the Android signer and package, Mac signature/architecture, archive contents and CLI version. Retain truthful notes about skipped or device-only checks.
4. Generate checksums only after signing, notarization/stapling if used, and final packaging are complete. Publish a prerelease tag pointing to that same commit; upload the exact verified artifacts and checksums.
5. Verify hosted CI, fresh-clone source builds, one-commit history, README links and downloaded artifact hashes. Only then record publication complete.

Checksum generation from the repository root uses an explicit file list so stale staging files cannot enter the manifest:

```sh
release_version=$(cat VERSION)
(
  cd dist
  shasum -a 256 \
    "VibePier-$release_version-macos-arm64.zip" \
    "vibepier-$release_version-macos-arm64.tar.gz" \
    "VibePier-$release_version-android.apk" \
    "VibePier-$release_version-android.apk.json" \
    "vibepier-relay-$release_version-linux-amd64.tar.gz" \
    "vibepier-relay-$release_version-linux-arm64.tar.gz" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
```

Consumers run `shasum -a 256 -c SHA256SUMS` in the download directory (or `sha256sum -c SHA256SUMS` on Linux). A checksum verifies equality with the published bytes; it is not a substitute for checking the source of the release or its platform signature.

## 中文说明

实际分发包含 Mac 应用、CLI、Android 正式 APK、Linux 双架构中继和校验和，没有组件注册中心或云端网页平台。版本来自根目录版本文件，Mac 系统短版本保留数字部分，包名与 CLI 保留 beta 后缀。

首次发布必须保留来源许可、只有一个根提交，最终产物从该提交的洁净检出构建。Android 复用固定正式密钥；Mac 无 Developer ID 时明确标注未公证预览。校验签名与包内容后再生成 SHA256SUMS，发布后核对远端 CI、fresh clone 和下载哈希。当前准备状态及未完成项以 TODO 为准。
