# Working on VibePier

VibePier connects an Android phone to AI coding sessions and controls on a Mac. Keep the macOS app, Android app, and self-hosted relay in this repository.

## Additional project guidance

Follow [agent.md](agent.md) for the current user-defined layout scope.

## Structure and dependencies

- `apps/macos`: Swift Package Manager project. `VibePierApp` and the `vibepier` CLI depend on `VibePierCore`; AU05 hardware support lives in `VibeKit`. `VibeLocalization` provides the shared embedded catalog without depending on either runtime or UI.
- `apps/android`: one native Android production application module; `test-fixtures/install-probe` is an emulator-only installation fixture. Organize source by feature and shared responsibility, not by file type.
- `services/relay`: independent Go module for the self-hosted relay.
- `protocol`: transport specifications and cross-platform test fixtures.
- `assets`: editable branding and public documentation images. Runtime assets belong to the platform resource directories.
- `scripts`: reproducible build, development, migration, and release tools.
- `docs`: product and contributor documentation. Never use documentation images as implicit test dependencies.

## Development

Use `<type>/<short-kebab-case-description>` for working branches, for example `fix/paired-control-session`. Do not use AI tool names as branch prefixes.

Run `make test` for platform unit tests and `make lint` for static checks. Platform tools remain usable directly: `swift test --package-path apps/macos`, `apps/android/gradlew -p apps/android testReleaseUnitTest`, and `go test -race ./...` inside `services/relay`.

Keep structural moves, behavior changes, and generated asset updates separate during development. Tests must use temporary directories and synthetic data. Hardware and desktop automation tests require explicit opt-in; ordinary tests must never type into applications, change audio routing, install packages, or change a user's existing configuration.

## Android APK 安装与下发

- **当前平台范围与交付流程**：Android 13（API 33）及以上。后续修复不再进行模拟器验证；完成必要的单元测试和静态检查后，直接正式签名打包并覆盖安装到真机，默认 Mi 10，保留数据与配置。用户明确指定其他设备时按当次要求执行。

- **当前真机交付状态**：Mi 10 和 25053RT47C 均已安装并授权新版 VibePier，云中继双手机在线已验证。旧 VibeBar 服务已退役；不再依赖旧应用转发或保留旧协议兼容。
- 后续安装、调试、更新和真机验收默认只考虑 **Mi 10**；用户明确指定其他设备时，按当次要求执行。指定 **25053RT47C（简称 250）** 并要求 Mac 下发时，通过应用的 APK 下发功能交付，不改用 ADB 安装。保留已完成的双机验证记录。
- 用户已明确授权后续需要更新或调试时直接使用 **Wi-Fi ADB**，优先复用已授权的无线连接，无需再次要求插 USB。每次现场核对 IP 和设备，不能假定上次地址永久有效。
- 为 Mi 10 选择安装方式：先用 `adb devices -l` 检查连接并核对型号。有可用且已授权的 ADB 连接（USB 或无线均可）时，用 `adb -s <serial> install -r <apk>` 直接覆盖安装，保留配置和数据；没有可用 ADB 连接时，通过 Mac 端应用的 APK 下发安装功能，选择已授权的 Mi 10 发送。
- ADB 序列号、无线地址及 Mac 端手机授权 ID 均须现场核对，不沿用历史值猜测。排除模拟器并确认目标为 Mi 10；同一手机同时有 USB 和无线连接时只安装一次，不使用未指定设备的 `adb install`。
- Mi 10 使用最新正式 release APK，按 `apps/android/app/build.gradle.kts` 的当前 `applicationId` 核对包名与签名；`.review` 测试包仅用于模拟器。安装失败时保留已有数据，不擅自卸载或清除配置。
- 核验并汇报 Mi 10 的结果：ADB 检查安装成功回执；Mac 下发检查手机接收和系统安装回执。传输完成、等待权限、等待系统确认和安装成功须明确区分。手机离线时说明等待接收，需要手机端操作时说明具体步骤，不静默跳过。
- 此规则适用于明确的安装或更新任务；普通构建、打包与测试命令仍不得自动安装或改变用户配置。

## Security and compatibility

Every control action requires an authorized device. Do not add plaintext or unauthenticated fallbacks. Keep provider credentials on the Mac. Never log pairing secrets, passwords, message bodies, or attachments. Preserve replay protection, request receipts, held-key cleanup, microphone restoration, and device isolation when refactoring.

Provider adapters must fail closed when the target session, interface version, or submitted result cannot be verified. Do not replace an unknown result with an automatic resend.

Build and package commands must not install, launch, modify user settings, or import signing keys. Installation and migration are explicit operations. Keep signing material out of Git.

## Documentation and assets

Keep English and Simplified Chinese user-facing material aligned. Update the corresponding product, architecture, design, development, distribution, or deployment document when behavior changes. Describe unsupported capabilities explicitly. Public screenshots use sanitized demonstration projects and must show supported behavior.

Preserve the upstream MIT copyright and provenance. Release notes and validation reports must distinguish unit tests, simulated UI evidence, and real-device checks.
