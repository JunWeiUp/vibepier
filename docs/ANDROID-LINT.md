# Android Lint decisions

CI runs `lintRelease`, retains its HTML/XML report, and then runs `scripts/check/android-lint.py`. Errors and unreviewed warnings fail the check. The following update notices remain visible because the initial beta uses an explicitly pinned, tested toolchain; no whole-project Lint disable or baseline hides unrelated findings.

| Notice | Exact scope | Decision |
| --- | --- | --- |
| `OldTargetApi` | `targetSdk = 35` in the app build file | This direct-APK phone beta targets API 35. A target change requires permissions, foreground-service, large-screen and gesture-lifecycle acceptance. It is not a claim of current Google Play submission compliance. |
| `GradleDependency` | `compileSdk = 35` notice only | Keep compile and target API aligned for this first tested build. New warnings for other dependencies are not accepted by this exception. |
| `AndroidGradlePluginVersion` | Gradle 8.13 wrapper update notice | AGP 8.11.1/Gradle 8.13/JDK 17 are pinned together; the distribution checksum is pinned from the official Gradle endpoint. Upgrade and revalidate as one toolchain change. |
| `NewerVersionAvailable` | `org.json:json:20250517` in `testImplementation` only | JVM-only reader for shared test vectors. It does not ship in the APK; Android uses platform JSON. Updates to other libraries are not covered. |

The checker matches the issue ID, file, notice and current declaration; changes to these pins require reconsidering the exception. Dependency security advisories need separate review: a version-update exception is not approval of a known vulnerability.

## Narrow source annotations

- `ViewConstructor`: nine programmatically constructed views require a runtime model or callbacks. They are never inflated from XML. Adding an unused constructor would conceal an invalid initialization path.
- `ClickableViewAccessibility` on `AppShortcutView.onTouchEvent`: it delegates touch delivery to `View`; normal click and accessibility actions both use its `performClick` override. That override checks that a foreground-app update has not changed activation into hiding.
- `RtlHardcoded` on `CanvasLabel.onMeasure`: the comparison is against absolute gravity after resolving `START`/`END` using the current layout direction.
- `tools:targetApi="31"` on the scan permission: `neverForLocation` is meaningful on Android 12+; older phones follow their platform-specific permission path.
- Portrait on the main Activity is intentional for the phone control surface while buttons are held. The two orientation warnings are suppressed on that Activity only. Tablet/desktop adaptive layout and future target-SDK behavior require separate acceptance.

## Fixed findings

Drawing code reuses paths/rectangles/dash effects and precomputes usage tick labels and app colors. Conversation crop geometry updates when the image or measured size changes. The adaptive launcher resource no longer has an unnecessary API-26 folder qualifier. Relay address racing uses fixed-delay scheduling so suspension cannot cause a burst of overdue retries.

Installation-state writes check synchronous persistence before continuing or reporting state. Failed storage pauses reception instead of pretending the state was saved. Relay migration checks removal of the old credential, and attachment persistence returns its result to the UI.

These decisions follow [Android's documented support for scoped Lint configuration](https://developer.android.com/studio/write/lint). They should be revisited when the affected feature or toolchain changes.

## 中文说明

已消除绘图临时对象分配、重复定时追赶及忽略持久化结果等问题。自绘视图、按键点击和方向布局的少量注解逐处说明原因；四条工具链升级提示继续保留在报告中。CI 只接受上表列出的明确位置和版本声明，新增警告仍会失败。API 35 是当前 beta 的目标版本，不代表满足未来应用商店的新提交规则。

`BinaryFileClient.route` locally suppresses `CustomX509TrustManager`: direct HTTPS trusts only the exact certificate digest delivered through the authorized encrypted session, checks certificate validity, and verifies the same pin in the connection hostname verifier. Public HTTPS keeps platform trust validation. Invalid-pin refusal is exercised by the synthetic binary network probe. No global trust policy is changed.
