# Native UI previews / 原生界面预览

These images capture production Android widgets in the isolated `designReview` application on an API 37 emulator. The image files are original captures, with no compositing or edits. They use local fixture callbacks and synthetic data; they do not connect to a real Mac, change its app configuration or redeem an account credit.

| Files | Capture source | Demonstration data |
| --- | --- | --- |
| `android-app-picker-en.png`, `android-app-picker-zh-CN.png` | [ApplicationPickerProbe](../../apps/android/app/src/androidTest/java/io/github/junweiup/vibepier/remote/ApplicationPickerProbe.kt), selector `application-picker` | `demo.codex` / `demo.claude` catalog, empty first shortcut slot |
| `android-codex-usage-en.png`, `android-codex-usage-zh-CN.png` | [CodexUsageProbe](../../apps/android/app/src/androidTest/java/io/github/junweiup/vibepier/remote/CodexUsageProbe.kt), selector `codex-usage` | 7% remaining, three gifted cards, relative reset/expiry dates from the fixture clock |

The earlier picker and usage captures remain available as supporting images. Their production source hashes matched their capture manifests when they were added. Reproduce them using the emulator-only review workflow in [DEVELOPMENT.md](../../docs/DEVELOPMENT.md); never point fixture automation at an enrolled physical phone. The probes write `application-picker.png` and `codex-usage.png` into the review app's external cache.

Other files in this folder are earlier synthetic localization/layout previews. They are supporting visual material, not proof that every physical-device or provider workflow passed. Actual acceptance is tracked independently in [TODO.md](../../TODO.md).

这些截图来自 API 37 模拟器中的独立测试构建，直接使用产品原生控件和本地合成数据，保留原图。应用列表、额度、重置卡及时间均为演示值；没有改动真实 Mac 配置，也没有使用真实重置卡。英文与中文 README 分别展示对应语言版本，真机与会话来源的验收仍单独记录。

## README home and conversation / README 首页与会话

The current English and Chinese READMEs show the home remote and a conversation, captured by [ReadmePreviewProbe](../../apps/android/app/src/androidTest/java/io/github/junweiup/vibepier/remote/ReadmePreviewProbe.kt), selector `readme-previews`.

- **Home:** production shortcut controls, microphone button and application dock. `Studio Mac`, the connection status and `demo.*` application identities are local demonstration values. No Mac is contacted.
- **Conversation:** a fictional connection-flow task with localized user/assistant text, a file-change row and a completed tool step. The result text is example content, not a claim that those commands were run.
- **Capture:** API 37, 1080 × 2424 display, density 420, font scale 1.0. `PixelCopy` captures the actual native window viewport (1080 × 2219), excluding Android status/navigation bars. No generated UI, post-capture retouching or added device frame is used.
- Both language pairs share dimensions and a 340 px README display width. Only this capture probe is needed; no full regression matrix is required to reproduce the images.

After building and installing the isolated review APKs on an **emulator**, run once for each app locale (`en` and `zh-CN`):

```sh
adb -s EMULATOR_SERIAL shell cmd locale set-app-locales io.github.junweiup.vibepier.remote.review --locales en
adb -s EMULATOR_SERIAL shell am instrument -w -r -e test readme-previews \
  io.github.junweiup.vibepier.remote.review.test/io.github.junweiup.vibepier.remote.BindingSyncInstrumentation
adb -s EMULATOR_SERIAL pull /sdcard/Android/data/io.github.junweiup.vibepier.remote.review/files/readme-home.png
adb -s EMULATOR_SERIAL pull /sdcard/Android/data/io.github.junweiup.vibepier.remote.review/files/readme-conversation.png
```

Restore the emulator's previous locale afterward. Build/install instructions are in [DEVELOPMENT.md](../../docs/DEVELOPMENT.md). Never run fixture captures against an enrolled physical phone.

当前 README 使用首页与会话页的原生控件截图，中英文分别重拍。连接状态、应用和会话内容均为演示数据；不会连接 Mac 或执行示例中的命令。截图在采集时排除系统状态栏和导航栏，保留应用原始画面，以统一尺寸、较大展示宽度和简短说明改善排版，没有生成或修饰应用界面。

## SHA-256

- `android-app-picker-en.png`: `b19a802f04aa6b6711138e751368039b046ed1d066323e0b82b5c9e1e7c88bc9`
- `android-app-picker-zh-CN.png`: `04b8cd434f7f71c8ffeda08cdda7c3e424493e7e53592a56c7c43a5d6c107925`
- `android-codex-usage-en.png`: `c2b262e191c68c8cfa4abc4d07a2c472196aaa72a45fce23cfd6f6d4ee1a4ec2`
- `android-codex-usage-zh-CN.png`: `7dc0460bc47868e3119fde9692506259de5e022dbb867d314bf28a13e98446f6`

- `android-home-en.png`: `af6ef2159873bac09a0b448cd1f4880f4bdae4aa74a4e8ae3f097859ac5c572e`
- `android-conversation-en.png`: `b94f57c569fcec195108792dfa74136f592f9205481fdfad54b33b207a3e844f`
- `android-home-zh-CN.png`: `a8ee4ab9102355c6bcd8e00205fd0c91fbf1f9673a6d1b60b7633f5f04c6cebb`
- `android-conversation-zh-CN.png`: `fddf7a20fb3c08c04338042ccca16274598f19d1e501bad366a0bedb277a7c0b`
