# Component guidelines / 组件开发规范

These are native platform applications. There is no web component library, CSS framework, shared JavaScript runtime or component publishing registry. Reuse platform-specific primitives and share protocol contracts and test fixtures across platforms.

## Android

Shared drawing and control primitives live under `core/ui`; feature widgets live with their feature. [Ui](../apps/android/app/src/main/java/io/github/junweiup/vibepier/remote/core/ui/Ui.kt) owns typography, labels, buttons, tabs and surfaces. [ControlView](../apps/android/app/src/main/java/io/github/junweiup/vibepier/remote/core/ui/ControlView.kt) is the input base; [Palette](../apps/android/app/src/main/java/io/github/junweiup/vibepier/remote/features/remote/Pads.kt) owns color tokens. Use existing primitives before introducing another custom view.

Views receive models/callbacks; they do not construct provider bridges or independently start transports. `MainActivity` adapts permissions and platform APIs. `ConversationNavigation`, `PhoneVoiceController` and `SessionClient` own their respective lifecycles. Constructing a header can refresh state before the root layout is attached, so root-view dependencies must be obtained lazily.

Keep drawing allocation-free in hot paths: cache paints, paths and rectangles, recompute geometry on size/content changes, and recycle or bound bitmap memory. Image requests/decode results carry a conversation scope and generation. Detaching or hiding a view cancels work before a completion callback can issue another request.

Custom controls must expose click/selection/description semantics and use `performClick` for ordinary clicks. Preserve pointer ownership and all cancellation paths for held controls. Avoid assigning the same accessibility meaning to both a container and its decorative child. Programmatic-only constructors can use a narrow, explained Lint suppression; global Lint disablement is not acceptable.

New user-visible strings go in default English and Simplified Chinese Android resources with matching arguments/plurals. Keep wire operation names and provider identifiers untranslated. Existing unmigrated literals are tracked work, not a pattern for new code.

## macOS

Keep SwiftUI presentation in `VibePierApp`, reusable behavior in `VibePierCore`, and AU05 protocol logic in `VibeKit`. Shared text and language selection belong in `VibeLocalization`, which must not acquire app/runtime dependencies. UI models publish observed state on the main actor. Views submit explicit commands; they do not acquire transport/Keychain/hardware ownership during rendering.

Use `VibeAppearance`, `IconBadge` and shared group styles. Keep window sizing stable on first layout; a measurement-driven resize after showing a menu can move the popover away from its anchor. Test short and overflowing content. Menu task marks are composed by the production AppKit drawing code rather than reimplemented in preview tests.

Inject system boundaries for tests: screen lock, process execution, transport routing, file roots, audio devices and time where relevant. A unit test must not initialize a live provider singleton or prompt for access to the user's Keychain. Balance every input/audio/temporary-unlock acquisition with cleanup on all exits.

## Protocol and persistence

Validate at the receiving boundary, not only in the UI. Bound strings, frame sizes, chunk counts, memory and cached files. Bind requests and callbacks to device/session/provider identity. Reuse operation IDs after uncertainty; never discard durable receipts just to make a retry possible.

Use the platform secure-store abstractions. A failed synchronous save is a failure to record state: do not report success or advance a transfer. Credentials do not belong in ordinary JSON, logs or serialized view models. See [security](../SECURITY.md) and [privacy](PRIVACY.md).

## Dependencies and changes

Prefer SDK facilities unless a dependency solves a demonstrated problem. Check license, version pin, runtime/binary impact and supported OS levels. Test-only dependencies belong to test configurations. Public samples are synthetic and review data is compiled only into the `.review` package.

For a changed component, verify the relevant interaction and failure state, large text and accessibility semantics. Update [DESIGN.md](../DESIGN.md), [page structure](PAGE-STRUCTURE.md) or [architecture](ARCHITECTURE.md) when their contracts change. Use [DEVELOPMENT.md](DEVELOPMENT.md) for commands.

## 中文说明

按功能归属放置组件，复用原生 UI 基元。界面不自行持有连接或凭据；导航、语音和 RPC 分别由已有控制器管理。绘图热路径复用对象，图片异步结果必须校验会话与代次。离开页面先取消工作，再清理视图。

按住控件必须覆盖松手、滑出、多指、失焦和断线的释放；普通点击保留无障碍动作。新增文字同时维护中英文资源，协议标识不翻译。持久化失败不能假装成功，未知回执不能丢弃重发。普通测试通过依赖注入隔离真实设备、桌面、钥匙串和音频。
