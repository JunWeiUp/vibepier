# Development and verification / 开发与验证

Clone the entire repository: macOS, Android and Go tests share files under `protocol/fixtures`. Ordinary tests use synthetic data and must not interact with a user's real desktop, audio routing, phone authorization or provider sessions.

Ordinary Swift tests must inject device keys, session routing and provider-policy snapshots instead of reading the installed app's Keychain. An `xctest` prompt for `io.github.junweiup.vibepier.devices.v1` indicates a missing test dependency; cancel it and fix the injection. Granting permanent Keychain access to the test runner is not part of verification.

普通 Swift 测试须注入模拟设备密钥、会话路由和服务商策略，不读取已安装应用的钥匙串。若 `xctest` 请求访问 `io.github.junweiup.vibepier.devices.v1`，说明测试遗漏了依赖注入，应取消提示并修复测试；无需授予测试程序永久钥匙串访问权限。

## Toolchain

- macOS 14+ and Xcode with Swift 6 for the Mac app and CLI.
- JDK 17 and Android SDK platform/build-tools 35 for the Android project. Gradle wrapper versions are committed.
- Go 1.22+ for the relay and the file helper bundled with the Mac app/CLI. The module has no external runtime dependency. Mac CI explicitly installs Go 1.27 before building the helper.
- Python 3.9+ for repository/Markdown/fixture checks.
- Optional local checks: `actionlint` and Gitleaks 8.30.1, matching the pinned CI scanner.

The Android CI job invokes `sdkmanager` from `$ANDROID_HOME/cmdline-tools/latest/bin`, as installed by the [official Ubuntu runner image](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md), rather than assuming it is on `PATH`. Official JavaScript actions are pinned to Node 24 releases. The Mac CI job selects Xcode 16.4 explicitly on `macos-15`; it does not rely on the runner's default Xcode. The relay matrix checks the declared Go 1.22 minimum and Go 1.27. For production relay binaries, use a supported, patched Go release. Runner availability is documented in the [official macOS image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md), and current Go releases are listed by the [Go project](https://go.dev/dl/).

Create `<type>/<short-kebab-case>` branches. Keep provider behavior fixes, structural refactors and generated artwork changes reviewable. Do not add private machine addresses, local home paths, credentials or personal diagnostics to public source/docs. See [AGENTS.md](../AGENTS.md).

## Fast checks

Default to checks for the changed platform and behavior. Reuse successful evidence for unchanged code; do not repeat full builds, both languages or the complete emulator matrix after every small edit. A release candidate needs one build, the affected unit/static checks, and one core emulator smoke run. Expand checks only for a concrete failure, a changed compatibility boundary, or an explicit full audit. Record deferred device/desktop acceptance separately; a smoke pass does not prove those flows.

默认只验证改动的平台和功能，未变更代码复用已有通过记录。发布候选保留一次构建、相关单元/静态检查和一轮核心模拟器冒烟；不再每次重复双语全量回归、多版本矩阵或长时间真机测试。遇到具体失败或兼容性改动再扩大范围；未完成的真机和原生桌面验收单独注明。

The manual **Android device checks** workflow defaults to API 35 and `suite=smoke`: six English transport/session/receipt checks plus a Chinese new-session check on a small screen with large type. Select `suite=full` and, when needed, `api=all` explicitly for the full compatibility matrix. The CLI has the same `--suite smoke|full` selection. Neither suite targets physical phones.

For a requested full audit, run from the repository root on a Mac with all platform tools:

```sh
make test
make lint
python3 scripts/check/repository.py
```

Or run only the affected platforms:

```sh
swift test --package-path apps/macos
swift format lint --strict -r apps/macos/Sources apps/macos/Tests apps/macos/Package.swift
./apps/android/gradlew -p apps/android :app:testReleaseUnitTest :app:lintRelease
python3 scripts/check/android-lint.py
(cd services/relay && go test -race ./... && go vet ./...)
```

A JVM test is not an Android Keystore test; an instrumentation APK build is not a device run. Swift tests that need a real desktop, hardware, or audio routing are opt-in and are skipped in ordinary CI. Report those limits with results.

`CodexIPCReceiptTests` uses a private temporary Unix socket to exercise the production client: disconnects, timeouts, unrelated diagnostics, incorrect owner/method/request IDs and malformed acknowledgments must not cause a resend. `SessionProviderReplyTests` checks durable unknown receipts across restart, operation/session matching, receipt reconciliation, payload limits and explicit lock states. `ScreenLockControllerTests` injects screen actions; these tests never lock or unlock the real Mac.

`swift test --package-path apps/macos --filter 'ControlSocketTests|SessionPacketInboxTests'` uses private temporary sockets and synthetic encrypted messages. It exercises large/partial writes, malformed or incomplete requests, absolute deadlines, capacity saturation, preservation of live listeners/files, multi-phone assembly fairness, conflicting duplicates and replay expiry. It never starts the production daemon, initializes its Keychain or sends desktop input. A custom `VIBEPIER_SOCKET` must be an absolute path inside an existing directory owned by the current user with mode `0700`; use a private subdirectory rather than a socket directly under `/tmp`. The adjacent `.lock` file persists across restarts and must not be deleted while a server is running.

本地 socket 和会话分片测试只使用临时目录及合成加密数据，不操作实际 Mac、手机或钥匙串。自定义 socket 路径须置于当前用户拥有的私有目录；不要删除运行中实例的 `.lock` 文件。

`swift test --package-path apps/macos --filter 'SessionReceiptJournalTests|SessionWorkBudgetTests|SessionProviderReplyTests'` uses temporary files, injected publication failures and synthetic work/cache entries. It covers completion-space reservation, per-device/global budgets, record caps, retained retired IDs, immutable results, corrupt/oversized/non-regular stores, lock symlinks, stale writers, pre/post-publication errors and unknown replies after save failure. Work tests exercise concurrent admission, exclusive password verification, callback claiming, exact lease release and pending-cache preservation. They do not initialize `SessionRemote.shared`, access real Keychain data or run provider actions; real transport/provider acceptance remains separate.

`swift test --package-path apps/macos --filter 'DesktopInputTests|DesktopClipboardTests|DesktopMutationTests|ZCodeBridgeTests|ZCodeDesktopTests'` injects pointer/action callbacks, uses uniquely named private pasteboards, and creates temporary native-schema SQLite fixtures. It checks single submission, balanced release on focus loss, conditional clipboard cleanup, complete first/next-message receipts, cross-project creation baselines, and trusted client routing. These tests never post real input, touch the general clipboard, or mutate provider databases. Actual accessibility recognition, menu cancellation and delivery must still be exercised separately with explicit opt-in.

上述输入测试只使用注入事件、独立命名剪贴板和临时数据库，不点击真实应用、不修改系统剪贴板；模拟通过不能替代原生桌面验收。

`swift test --package-path apps/macos --filter 'ProviderOperationReceiptsTests|ClaudeCreationReceiptTests|ZCodeBridgeTests|SessionProviderReplyTests'` checks client/request isolation, in-flight replay, quota refusal, completed-body retirement without identity loss, immutable final results, observer admission/arming, two-phone late creation without another submission, and native first-message/session/directory confirmation. Fixtures use temporary JSONL/SQLite files and injected provider responses; a real native delivery is still a separate opt-in acceptance step.

进程内回执测试覆盖两机隔离、容量不足时拒绝新操作、旧正文退役后仍不重执行、迟到新建回执和审批指纹校验；只读查询不会发送新消息。原生窗口和应用升级验收仍单独完成。

`swift test --package-path apps/macos --filter 'ClaudeProcessOutputTests|SessionSchedulingTests'` verifies bounded chunked CLI output, UTF-8/terminal-result validation, delayed EOF and cancellation, and a fixed synthetic `printf` child with real pipes. No Claude process or desktop interaction is launched. Retry scheduling tests make the mock transport reply only after observing a retry, then independently check timeout and absence of idle polling; they do not require multiple timer deliveries within a 90 ms wall-clock window on a loaded CI runner.

Claude 输出测试使用合成 JSONL 和固定内容的 `printf` 子进程，覆盖超大行、组合字符、丢失结果和退出前管道读取，不启动真实 Claude。Android CI 为 AVD 创建器和模拟器显式设置同一临时目录，并确认设备可被发现后才启动；AVD 数据盘不上传为测试证据。

## Clean-checkout verification

Run this from a fresh clone, with the declared Xcode, JDK and Android SDK installed. The checkout must contain the shared `protocol` directory. Do not copy `local.properties`, personal Gradle initialization scripts, provider data or signing files into it. The commands allocate new build and dependency directories:

```sh
VIBEPIER_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vibepier-check.XXXXXX")

swift test --package-path apps/macos \
  --scratch-path "$VIBEPIER_CHECK_DIR/swift-build" \
  --cache-path "$VIBEPIER_CHECK_DIR/swift-cache" \
  --config-path "$VIBEPIER_CHECK_DIR/swift-config" \
  --security-path "$VIBEPIER_CHECK_DIR/swift-security"

env -u ANDROID_KEYSTORE_PATH -u ANDROID_KEYSTORE_PASSWORD \
  -u ANDROID_KEY_ALIAS -u ANDROID_KEY_PASSWORD \
  GRADLE_USER_HOME="$VIBEPIER_CHECK_DIR/gradle" \
  ANDROID_USER_HOME="$VIBEPIER_CHECK_DIR/android-user" \
  ./apps/android/gradlew -p apps/android \
  --project-cache-dir "$VIBEPIER_CHECK_DIR/gradle-project" \
  --no-daemon --no-build-cache --no-configuration-cache \
  :app:testReleaseUnitTest :app:lintRelease :app:assembleDebug :app:assembleRelease \
  :app:assembleDesignReview :app:assembleDesignReviewAndroidTest --console=plain
python3 scripts/check/android-lint.py

(cd services/relay && \
  GOCACHE="$VIBEPIER_CHECK_DIR/go-cache" \
  GOMODCACHE="$VIBEPIER_CHECK_DIR/go-modules" \
  GOENV=off go test -race -count=1 ./...)
```

Gradle needs access to Google Maven, Maven Central, the Gradle Plugin Portal and the Gradle distribution host. If your network requires a proxy, configure it for that build process using [Gradle's JVM proxy properties](https://docs.gradle.org/current/userguide/networking.html); keep credentials and machine-specific proxy settings outside the repository. Never bypass TLS certificate verification to get a dependency download working. An empty dependency directory tests reproducibility; a failed download does not verify compilation.

With release credentials absent, `assembleRelease` must produce an **unsigned** APK. Debug/review builds generate their own temporary debug key under the isolated Android user directory. These artifacts are not production updates. A full release audit also compiles the Mac release products, packages both Linux relay architectures, and verifies that companion applications and personal configuration/cache directories are inaccessible during compilation and ordinary tests. Record source hashes and distinguish this audit from the separate final public-clone/CI and real-device acceptance gates.

## Build without installation

```sh
./scripts/build/macos.sh
./apps/android/gradlew -p apps/android :app:assembleDebug
make package-relay
```

The Mac staging output is `dist/staging/VibePier.app`; public packaging is described in [DEPLOYMENT.md](DEPLOYMENT.md). Android `assembleRelease` is unsigned unless explicit release credentials are supplied. The release-packaging script requires those credentials and never falls back to debug signing. Build and package commands do not install/launch apps or edit system configuration.

An explicit local Mac update uses `python3 scripts/install/macos.py --dry-run` and then `--apply` when installation is intended; see [Mac updates](MACOS-UPDATES.md). This updater preserves the installed app directory and checks signing compatibility before replacement. Its isolated Python tests run in repository checks without signing, installing or stopping production apps.

本机 Mac 更新使用独立显式脚本，先 `--dry-run` 只读核验，需要安装时才执行 `--apply`；详见 [Mac 更新与权限](MACOS-UPDATES.md)。隔离 Python 测试不签名、安装或停止生产应用。

Lint decisions and the four retained toolchain notices are documented in [ANDROID-LINT.md](ANDROID-LINT.md). CI rejects any new, unreviewed warning.

## Emulator verification

The manually dispatched **Android device checks** workflow runs API 33, API 35 and API 36 Google APIs x86_64 images on disposable Linux/KVM runners. It builds and installs only the review app, instrumentation and generated no-code installation fixture. It runs the core selectors in English, additional Chinese cases on all three APIs, and 320 dp / 1.5 font-scale cases on each API. The exact selector list is maintained in `scripts/check/android-emulator.py`; newly added usage, app-picker and brand checks participate in that matrix. The uploaded `summary.json`, per-probe logs and menu/failure screenshots distinguish actual API execution from JVM tests.

```sh
gh workflow run android-emulator.yml --ref YOUR_BRANCH
```

The runner script deliberately refuses local/non-Linux execution and any pre-existing ADB target. It resets the disposable review app between cases, requires an explicit successful instrumentation code plus the expected probe and locale, and stops its own emulator afterward. An APK build, ADB exit code zero, unknown selector falling back to another probe, or missing result is not a pass. No real phone, Mac controls or release signing material is used. The setup uses the SDK's documented [AVD manager](https://developer.android.com/tools/avdmanager) and [emulator startup options](https://developer.android.com/studio/run/emulator-commandline). Physical BLE/microphone behavior, OEM background behavior and manual screen-reader acceptance remain separate gates.

可手动运行 Android device checks 验证最低 API 33、目标 API 35 和较新 API 36；脚本仅允许临时 Linux CI 环境，拒绝已有 ADB 设备。每项测试重置独立 review 包，核对实际探针名称、语言及成功回执，保存报告并关闭模拟器。小屏、大字与中文有独立用例；真机蓝牙、OEM 后台、真实收音和人工读屏验收仍单独完成。

Use the isolated `designReview` package, never a real phone's production package. List and explicitly select the emulator:

```sh
adb devices -l
./apps/android/gradlew -p apps/android :app:assembleDesignReview :app:assembleDesignReviewAndroidTest
adb -s EMULATOR_SERIAL install -r apps/android/app/build/outputs/apk/designReview/app-designReview.apk
adb -s EMULATOR_SERIAL install -r apps/android/app/build/outputs/apk/androidTest/designReview/app-designReview-androidTest.apk
adb -s EMULATOR_SERIAL shell am instrument -w -e test screen-controls io.github.junweiup.vibepier.remote.review.test/io.github.junweiup.vibepier.remote.BindingSyncInstrumentation
```

Useful selectors: `codex` (full session/receipt regression), `composer`, `codex-panel`, `providers`, `plan-mode`, `conversation-images`, `screen-controls`, `new-session-receipts`, `session-response`, `markdown`, `tool-groups`, `private-storage`, `relay-store`, `enrollment`, `app-usage`, `background-connection`, `protocol-negotiation`, `relay-framing`. Inspect the emitted result: a crashed instrumentation process can still leave ADB with exit code zero. Passing logs explicitly contain `PASS` or a Chinese success message.

`plan-mode` uses an isolated encrypted synthetic Mac and the production composer/new-session controls. It verifies native capability/catalog gates, Execute → Plan → Execute readback, first-message mode options without rewriting text, independent/coupled permissions and advertised safe-default disclosure. Run once per English/Chinese app locale and restore the original locale. Screenshot assertions wait for selected menus to dismiss/detach and exit animations to finish. Swift `ProviderExecutionModeTests`, `AgentSessionServiceTests` and runtime tests separately verify native mode/first-input evidence and unknown-result preservation; they do not launch real Agents.

`plan-mode` 探针使用隔离加密模拟 Mac，验证已有/新建原生模式、权限联动与安全默认提示；中英各跑一次并恢复应用语言。截图等待菜单关闭及动画结束；普通 Swift 测试注入原生接口，不启动真实 Agent，不把模拟通过当成实际原生验收。

`agent-open` starts a fresh isolated encrypted client without cached references, discovers all three current providers with empty search, opens by the returned opaque identity, handles a partial opening page and refreshes to complete content. It also verifies host-wide `operation.get` uses `target:{}`. Swift's discovery-to-open regression must decode the exact phone request first; injected native replies alone cannot catch a gateway rejection before dispatch.

`agent-open` 从无缓存的隔离加密客户端验证三助手空搜索发现、身份绑定、打开与刷新。Swift 回归必须先解码手机实际请求，避免只测试注入原生回复而漏掉入口校验错误。

`session-response` uses an isolated preference namespace and real Android Keystore with a synthetic host. It verifies malformed booleans/foreign receipts preserving the unknown result and draft, valid reconciliation, late native creation identity, a 270 KB out-of-order reply burst, active request/byte/callback/receipt limits, corrupt receipt preservation, and one-shot password verification without persistence. It never contacts a real Mac or types a password. Run it in both app languages alongside `codex`, `providers`, `new-session-receipts` and `screen-controls`. JVM `SessionResponseInboxTest` separately checks packet bounds, conflicting duplicates, absolute expiry, timer generations, replay capacity, UTF-8, authentication and operation-specific receipt evidence. Synthetic host frames must include the production `type` and recipient-bound `sender` fields; do not relax production validation to fit an incomplete fixture.

`protocol-negotiation` requires an unenrolled, disposable review emulator. It installs a temporary fixture key, uses an encrypted loopback host, checks the localized incompatibility notice, recovers baseline/audio capabilities, and verifies that a voice hold still releases its original Mac key after capability changes. It restores preferences and removes the fixture key afterward; it never sends controls to a real Mac or records audio. Run it in both languages. `TransportRevocationTests` uses two synthetic phones to verify that key removal/rotation clears only the affected UDP/relay peer, including held keys and injected audio, before lease expiry.

`relay-framing` also requires an unenrolled review emulator. It exercises the production RelayLink socket/Keystore path against a temporary loopback relay/host fixture, including HTTP admission, fragmented encrypted messages, interleaved ping, rejection of a fragmented control frame, and reconnect with a new secure session. It uses no real relay, desktop input or microphone. JVM tests separately verify frame bounds, UTF-8/continuation rules, sanitized diagnostics and bounded writer saturation; Go tests cover server admission capacity/deadlines and matching frame rules.

`swift test --package-path apps/macos --filter CodexCreationTests` uses temporary native-shaped SQLite/JSONL fixtures and injected actions. It checks complete-body and first-human-message receipts, moved/foreign/ambiguous threads, project identity, timeout boundaries and single submission. It never opens Codex, unlocks the screen, presses a button or reads a real conversation. Actual composer recognition and delivery require a separately authorized native-desktop acceptance run; do not count these isolated tests as that evidence.

On an API 33+ emulator, run the session-localization probes (`screen-controls`, `composer`, `markdown`, `tool-groups`) once per app locale. Set it before starting instrumentation, using `adb -s EMULATOR_SERIAL shell cmd locale set-app-locales io.github.junweiup.vibepier.remote.review --locales en` or `--locales zh-CN`; record the original value with `get-app-locales` and restore it afterward. Do not change the locale while a probe is running. Raw fixture messages intentionally remain untranslated. The `new-session-receipts` probe checks fresh timeouts, dialog reopen, unknown/complete receipts, and explicit same-ID retry after `notFound`; run it in both languages too. The full `codex` probe separately verifies encrypted new-session persistence across client recreation for Codex, Claude and ZCode, and proves that a timeout does not automatically retransmit.

`controls-localization` covers English/Chinese resources and real key editing at small/normal widths and normal/large type. The resource contract and remaining migration scope are described in [LOCALIZATION.md](LOCALIZATION.md).

The `apk` probe installs only the generated `io.github.junweiup.vibepier.installprobe` fixture, which has no executable code or permissions. Gradle builds its deterministic multi-chunk payload and bundles the APK only in the instrumentation package. Before the explicit emulator-only test, allow installation for the review app using `adb -s EMULATOR_SERIAL shell appops set io.github.junweiup.vibepier.remote.review REQUEST_INSTALL_PACKAGES allow`; the test still confirms the system installer UI. Uninstall the fixture after the run.

A Google Play emulator can add a first-install Play Protect scan prompt after system confirmation. The probe recognizes the observed Simplified Chinese scan prompt from `com.android.vending` only when it names `VibePier Install Probe`, and requests the normal scan of that generated no-code/no-permission APK. It never disables protection or selects an install-without-scanning option. An unfamiliar prompt or pending scan is not a pass. The API 37 Google Play emulator run completed actual PackageInstaller installation and the persisted success acknowledgment. Other system versions/locales require separate verification. Do not run a separate `uiautomator dump` while instrumentation owns `UiAutomation`.

The background probe requires an unenrolled disposable review app. It installs a temporary synthetic Keystore root, talks only to an authenticated loopback host, checks more than one peer-timeout window, and removes the temporary key. Other review screens do not automatically start a real Bluetooth connection or request real enrollment.

Navigation tests must use `MainActivity.sessionNavigation`; they should not depend on removed Activity backing fields. Preference tests use the production encrypted storage API and isolated namespaces. For the `.review` application, `Activity.localClassName` is fully qualified; using bare `MainActivity` writes a different preference store.

## Shared protocol checks

`relay-hello.json` is consumed directly by Swift, JVM and Go tests. `control-v1.properties` contains independently generated HKDF/HMAC/AES-GCM samples consumed by Swift/JVM. The repository checker independently recomputes relay HMAC and control HKDF keys. Update all affected implementations and fixtures together when changing a protocol.

## CI and secrets

[CI workflow](../.github/workflows/ci.yml) runs macOS tests/format/build, Android tests/Lint/builds, Go race/vet/packaging, and repository/secret checks. Actions are pinned to full commit hashes with read-only repository permissions; checkout credentials are not retained. No release signing material is required. The Android reports are retained briefly as CI artifacts, not distributed as release APKs.

```sh
actionlint .github/workflows/ci.yml
# After a commit exists, scan history using the same command as CI:
gitleaks git --redact --no-banner .
```

The secret-scanner allowlist covers only exact public test-key values in named fixture/test files. It does not exclude the tests directory or disable default rules. Do not add a broad exception to make a secret scan green. Before the first commit, scan an isolated copy of `git ls-files --cached --others --exclude-standard` files so ignored credentials, build caches and private local logs are neither published nor inadvertently printed in a scan report.

## 中文要点

普通构建与测试不能安装应用、发送真实会话消息或修改桌面/音频状态。真机更新需单独执行并核对每台设备及安装回执；同一手机 USB/Wi-Fi ADB 去重。未完成真实验收的内容不要用编译成功或模拟器样本代替。

洁净构建使用完整的新克隆及独立 Swift/Gradle/Go 目录，不导入个人配置、服务商数据或正式签名凭据。上方命令会生成未签名 release APK 和使用临时调试密钥的 debug/review APK，均不能当作正式真机更新。受限网络可为单次构建配置代理，不提交个人代理地址或绕过 TLS 校验。CI 明确选择 `macos-15` / Xcode 16.4，并检查 Go 1.22 与 1.27；Mac 打包也需要 Go 来构建文件助手，CI 显式安装 Go 1.27；最终公开仓库的克隆、远端 CI 和真机验收仍需分别完成。

Codex 回执测试使用临时 Unix socket 运行真实客户端，覆盖断线、超时、错误实例/方法/请求 ID 和无效确认；通用回执测试验证未知状态在重启后保留、会话匹配、传输上限和锁屏结果。锁屏控制器测试注入系统动作，不操作真实 Mac 屏幕。

项目已拆出运行命令、设备设置/按键回放、手机导航/语音会话以及消息/图片呈现模块。新增代码放到对应职责模块，不继续把独立状态机堆进主页面。提交前至少跑相关单测和平台静态检查；发布前完成 [TODO](../TODO.md) 的完整门槛。

## Mac language checks

The generated Mac catalog is checked alongside repository resources by `make lint-repository`. Regenerate it with `python3 scripts/dev/localize-macos.py` after editing `apps/macos/Localization/Strings.json`. Run Swift tests once with `VIBEPIER_LANGUAGE=en` and once with `VIBEPIER_LANGUAGE=zh-Hans`. Native connection/relay layout fixtures use injected status; see [LOCALIZATION.md](LOCALIZATION.md#macos-catalog). These tests must not initialize real session authorization just to draw a view. CLI boundary tests reject overflowing duration suffixes and negative/non-finite delays before opening hardware. Standalone smoke checks can safely run `help`, `version`, invalid `bind` syntax, or `raw --wait -1`; do not invoke valid hardware operations as routine build verification.

## Account usage checks / 账户用量验证

`swift test --package-path apps/macos --filter CodexUsageTests` uses injected account replies for quota projection, unknown values, confirmation, account/card changes, expiry, scoped idempotency, duplicate requests and uncertain outcomes. `VIBEPIER_CODEX_USAGE_SMOKE=1` opts into the separate **read-only** native account check; it never calls consume. The `codex-usage` Android instrumentation probe uses synthetic replies and verifies the actual menu/dialog, bilingual remaining/reset/card labels, cancellation, single submission and unknown-receipt protection. Run it with `am instrument -w -r` so raw result codes, selector and locale are observable. Test redemption must stay synthetic.

Android update deliveries must increment `VERSION_CODE`; see [Android version registration](ANDROID-UPDATES.md) and `agent.md`. APK metadata generation is build-only; registration and installation are explicit operations.

## APK relay throughput experiment

Run `VIBEPIER_APK_BENCHMARK=1 go -C services/relay test ./internal/relay -run TestAPKRelayThroughput -v`. Optionally set `VIBEPIER_APK_BENCHMARK_OUTPUT` to a local JSON output path. Ordinary tests skip this timed experiment. It uses generated 2 MiB data, temporary synced files, authenticated isolated relay connections and synthetic AES-GCM endpoints; it never installs an APK, reads signing keys or contacts the deployed relay. The synthetic endpoints model the two encryption layers and production frame/window sizes; this is not a full Mac-to-Android or real-device benchmark.

For 20/100/200 ms injected request-to-response delay, report elapsed time, MiB/s, encrypted frame count, peak reserved blocks and file write/sync time. Compare 900-character/one-block and 7200-character/four-block profiles. Require at least 2× at 100 ms and verify the final SHA-256. Production logic has separate Swift/JVM tests for negotiation, envelope budgets, pending-request binding, reordered replies, duplicate rejection, legacy/BLE resume, cancellation and stale disk writes.

隔离中继测试模拟云链路往返延迟，记录吞吐、帧数、窗口峰值和落盘耗时；不能将模拟端点的提速倍数当作真机承诺。真机验收须另行指定设备，分别记录传输、校验、等待系统确认和安装成功。

### Focused improvement checks / 改进验证

`make lint-repository` includes temporary dummy-artifact publication checks. Related Android PRs run the existing API 35 device workflow with its normal smoke cases plus `audit-runtime`, `audit-conversation` and `apk`. The new review probes use synthetic audio/pages and encrypted loopback where applicable; they do not operate a real Mac/provider. Manual full suites remain optional; ordinary smoke no longer changes to a special small-screen layout.

Packaging snapshots the public source fingerprint before building, verifies it again before each immutable publication, and writes `dist/build-<VERSION_CODE>/` with per-artifact `.build.json` provenance. Do not edit source during packaging or overwrite different bytes under an existing build number. A local dirty build records that state; it cannot claim to correspond exactly to its parent commit.

相关 PR 只运行单 API 35 核心冒烟及运行恢复/会话/APK 专项，不自动扩展矩阵。普通检查不操作真机、原生服务商或真实音频；本地模拟器结果和远端工作流结果分别记录。产物按构建号保存，打包期间源码变化会拒绝；dirty 产物明确记录，不能声称完全对应父提交。

### MP4 preview validation / MP4 预览验证

Conversation playback links also recognize standalone MP4 paths inside inline code; fenced examples, commands and network URLs remain excluded. Missing relative video paths may remove an exact repeated suffix of the session workspace, with the same realpath/symlink checks. `MarkdownFileLinksTest` and `testVideoRepairsRepeatedWorkspaceSuffixWithoutEscaping` cover these cases.

会话中的行内反引号独立 MP4 路径也显示播放入口；围栏代码、命令和网络 URL 不识别。缺失的相对视频路径可移除与会话项目末尾完全一致的重复目录前缀，仍执行原有真实路径与符号链接校验；上述单测覆盖入口识别和越界拒绝。

`SessionProjectFilesTests.testVideoChunksAreBoundedVersionedAndWorkspaceScoped` checks encrypted RPC chunk bounds, complete reconstruction, file mutation, traversal/symlink escape and the 128 MiB limit using synthetic temporary files. The `video-preview` designReview instrumentation probe checks multi-chunk download, exact SHA-256, manual H.264/AAC playback, pause/seek and cleanup for synthetic Claude/Codex hosts. It does not call either provider or validate a real phone. Its test-only fixture can be regenerated with:

```sh
ffmpeg -f lavfi -i testsrc2=size=320x240:rate=24 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 4 -c:v libx264 -g 24 -pix_fmt yuv420p -c:a aac -movflags +faststart -y apps/android/app/src/androidTest/assets/video-preview.mp4
```

Swift 测试仅使用临时合成文件，覆盖分块、完整重组、文件变更、目录穿越/符号链接越界和大小上限。`video-preview` 模拟器探针使用上述测试专属合成视频与虚构 Claude/Codex 主机，验证摘要、播放、暂停/拖动和清理；不调用真实 AI 会话，不等于真机验收。

### Permission setup validation / 权限引导验收

`MacPermissionsGuideTests` validates first-installed-launch, repeat/development launch policy and repair prompts after a real permission denial using injected presentation actions. File-access status tests use injected checks and temporary synthetic files to cover success, denial, missing files, concurrent clicks and bounded timeouts. They do not open settings, read TCC databases or modify real permissions. Manual acceptance requires authorizing the installed app in System Settings, reopening it, reading a protected-folder image and using the status button; an update acceptance also verifies the same signing identity and installed bundle directory. This manual grant is separate from unit tests; closing the guide is not authorization.

单测通过注入界面操作与读取检查覆盖首次/重复/开发启动、已展示后的权限拒绝提示、成功/拒绝/文件缺失/重复点击/超时，不读 TCC 数据库、不修改真实权限。人工验收需手动授权安装版、重启后读取受保护文件并检查状态；更新还需核验签名身份与安装目录保持。关闭引导不算授权。

### Conversation image lifecycle / 会话图片加载生命周期

The `conversation-images` emulator probe now exercises the production `ConversationMedia` dialog with synthetic replies: retained thumbnail across body-version changes, cancellation followed by retry, late cancelled replies, synchronous cached large-image display, and a missing-response deadline. No Mac or production phone is involved. Image reads use a 30-second UI deadline and return a retry state when cancelled; they never remain indefinitely loading.

`conversation-images` 模拟器探针使用合成回包验证真实大图弹窗：正文版本改变仍保留可见缩略图、取消后重试、旧回包隔离、同步缓存命中和无回包超时。图片读取在30秒界面期限或取消后显示重试，不涉及真实Mac或手机。

The `image-zoom` emulator probe uses synthetic bitmaps and injected touch events with the production full-screen image host. Check the viewport fills most of the screen, fitted opening/reset, pinch limits, pan bounds, double-tap zoom/reset, large-image replacement and both Close/Back dismissal. It must not read a provider's real images or change production-phone data. The `agent-open` encrypted loopback also checks two earlier-history pages per adapter, their exact `before` message anchors, and the oldest-page `hasOlder: false` boundary.

`image-zoom` 通过合成位图及模拟器触摸事件验证真实全屏图片入口：图片区域占屏幕主要空间、完整画面、缩放/拖动边界、双击及重开重置、大图替换、关闭和系统返回；不读取真实会话图片或修改真机数据。`agent-open` 加密 loopback 还验证各适配器两页旧消息、精确的 `before` 锚点与最后一页 `hasOlder: false`。

ZCode composer controls show loading feedback while reading native options and display failures in a dialog. When the focused AX window is missing, the adapter may use a unique native window; ambiguous or unavailable windows do not permit settings changes.

ZCode 会话配置按钮读取原生选项时显示加载提示，失败时弹出原因。AX 焦点窗口缺失时仅允许使用唯一原生窗口；窗口不可用或存在歧义时不执行设置变更。

The opt-in `binary-media` API37 probe uses a synthetic helper profile file to verify raw HTTPS JPEG/MP4 bytes, digest mismatch refusal, native conversation-image dialog/cache hits and single-offer video playback/seek. `BinaryMediaFilesTests` verifies private snapshots and device-scoped cancellation; the Go helper tests include local and cloud media capabilities. These are synthetic loopback/emulator results, not a public IPv6/NAT or real-phone throughput measurement.

`binary-media` API37 探针使用合成文件助手验证二进制图片/视频、摘要拒绝、真实大图缓存和单次视频下载播放；Swift/Go验证私有快照、设备隔离和本地/云媒体凭据。不能把模拟器结果称作公网IPv6/NAT打洞或真机速度验收。

### Assistant visibility checks / 助手可见范围验证

Run Swift `SessionProviderPolicyTests`/`SessionProviderModelTests`, Kotlin `SessionProviderAccessTest`, and the emulator-only `provider-access` instrumentation probe for new policy changes. `LocalizationPreviewTests/testSessionProviderMenuLayout` renders a synthetic native menu card with `VIBEPIER_PREVIEW_DIR`. No normal unit/build command installs or changes production applications.

开关验证覆盖全关闭、迟到回复、旧修订、保存失败、草稿和未知回执保留；安装生产端仍是单独明确操作。

## Agent contract and driver validation

`make test` additionally runs the isolated Claude Mods JavaScript tests and requires Node.js 22+. `make lint-repository` checks the generated Swift/Kotlin v1 operation manifest. Update `protocol/contracts/session-v1.json`, regenerate with `python3 scripts/dev/generate-session-contract.py`, and update shared fixtures together. Profile 2 schemas and canonical fingerprint vectors live in `protocol/schemas` and `protocol/fixtures`.

Agent unit tests inject adapters, native JSON-RPC and temporary directories. They cover journal-before-effect, native owner and capability changes, late callbacks, approval races, bounded replay gaps and partial evidence across restart. They do not use production provider homes, load a real Mods plugin or start a model turn. Optional runtime configuration is owner-only and disabled until explicitly enabled; native and real-device acceptance remain separate. See [Agent control](AGENT-CONTROL-ARCHITECTURE.md).

统一 Agent 的普通验证仅使用合成数据、临时目录与注入接口；当前生产端不会由测试或构建自动更新。双端新写操作需要协商成功，未确定操作不迁移后端重发。
