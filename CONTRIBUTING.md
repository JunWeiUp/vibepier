# Contributing / 参与贡献

VibePier contains a macOS app, an Android companion, and an optional relay. Start with the [product scope](docs/PROJECT-SPEC.md), [architecture](docs/ARCHITECTURE.md), and [development commands](docs/DEVELOPMENT.md). Read [AGENTS.md](AGENTS.md) for repository and device-installation rules.

## Before changing behavior

Use an issue to describe a reproducible problem or a proposed user-visible outcome. Include the VibePier version, platform version, connection type, and provider when relevant. For Codex, include the desktop **build number**, not only its marketing version. A minimal synthetic conversation is more useful than a private transcript. Report security issues through [SECURITY.md](SECURITY.md).

Create a branch such as `fix/relay-reconnect` or `docs/android-setup`. Keep the change focused. A provider update needs evidence for the exact interface and target-session identity; adding a build number to an allowlist alone is not a compatibility fix. A new transport cannot bypass enrollment, authenticated encryption, or per-device input ownership.

## Implementation and review

Use the existing platform frameworks and [component boundaries](docs/COMPONENT-GUIDELINES.md). Add a dependency only when its value, license, platform support and release impact justify it. Preserve upstream copyright notices. Generated assets need their source or generation record.

For a pull request, explain the trigger, resulting behavior, relevant validation, and any remaining limitations. Include sanitized before/after screenshots for visual changes. Label fixture images as simulated. Update the relevant guide and [CHANGELOG.md](CHANGELOG.md); a feature is not documented by leaving notes in a private agent log.

Run checks for the affected platform, then the repository check:

```sh
make test-macos lint-macos          # Mac code
make test-android lint-android      # Android code
make test-relay lint-relay          # Relay code
python3 scripts/check/repository.py
```

Not every change needs a new test. Add meaningful coverage for changed state transitions, parsing, authorization, persistence, or failure recovery. UI wording and reversible document edits usually need inspection rather than tests that repeat the implementation. Build-only checks do not establish real-device behavior.

## Devices and credentials

Ordinary tests must not type into a real desktop, change microphone routing, enroll phones, or install APKs. Use isolated temporary data and the emulator review package. Real-device acceptance is a separate explicit step; see [setup](docs/SETUP.md) and the [release checklist](TODO.md).

Never commit signing keys, provider tokens, relay pairing codes, real conversation fixtures, private hostnames or home paths. Keep uncertain request receipts intact; do not make a failure appear successful by clearing data or resending under a new request ID. Do not recommend uninstalling a user's existing app to fix a signing mismatch.

## 中文说明

先说明具体问题和预期行为，再选择对应模块修改。分支使用 `fix/…`、`feat/…`、`docs/…` 等类型前缀。提交说明应包含变化、验证和限制；界面截图使用脱敏样本，模拟图明确标注。同步更新功能文档与更新记录。

提供版本、系统、连接方式和会话来源即可开始排障，不要上传私人会话、配对码或密码。Codex 兼容性需要桌面构建号和实际接口证据，不能只扩大白名单。普通测试使用临时数据与模拟器，不操纵真实桌面。签名不一致时保留原应用和数据，修正安装包来源或签名。
