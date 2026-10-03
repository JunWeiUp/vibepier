# Android background connection / Android 后台连接

## Behavior / 行为

VibePier keeps its existing Wi-Fi, Bluetooth, or relay connection when its screen moves to the background. A `connectedDevice` foreground service shares one transport with the Activity; returning to or recreating the Activity reuses that transport and its peer identity. Backgrounding releases held keys and stops microphone capture. Conversation rendering and APK installation prompts remain foreground-only.

VibePier 进入后台时保留已有 Wi-Fi、蓝牙或中继连接。`connectedDevice` 前台服务与界面共享同一个传输实例，返回应用或重建界面不重复建立连接。退后台仍会释放按住的快捷键并停止录音；会话界面更新、APK 接收及系统安装确认继续遵循原有前台策略。

The service starts only when the user opens the app. It does not start on boot or automatically revive a force-stopped app. “Disconnect” in the foreground-service notification or removing the app from Recents stops the connection; opening the app again reconnects. When Android suppresses notifications, the foreground service remains visible through the system's active-app controls. Network loss, force-stop, and system/OEM power management can still interrupt connectivity.

服务仅随用户打开应用启动，不开机自启，也不在被强行停止后自动复活。连接服务通知中的「断开连接」或从最近任务划掉应用会停止连接，再次打开应用后重连。系统禁用通知时，可从系统的活动应用入口停止服务。断网、强行停止与系统/厂商省电策略仍可能中断连接。

## Implementation / 实现

- `core/transport/RemoteConnectionService.kt`: owns the foreground-service lifetime and notification; unexported, `connectedDevice` type.
- `core/transport/ConnectionLifetime.kt`: one transport shared across Activity owners and service; detaches destroyed UI callbacks and disposes exactly once when unused.
- `MainActivity.kt`: suspends UI and releases input on pause without stopping network or reporting a fabricated disconnect.
- `RemoteSender.kt`: replays current cached UI state when reattached; Wi-Fi scheduling uses fixed delay to avoid a burst of catch-up heartbeats after suspension.

参考 Android 官方文档：[Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types)、[Bluetooth background communication](https://developer.android.com/develop/connectivity/bluetooth/ble/background)、[Cached apps freezer](https://source.android.com/docs/core/perf/cached-apps-freezer)。

## Validation / 验证

Five ownership lifecycle unit tests cover Activity recreation, overlapping Activity owners, explicit stop, cleanup, and refusing an unprompted background start. The opt-in `background-connection` instrumentation test runs only in an emulator with an authenticated AES-GCM loopback host, verifies heartbeats past the 12-second peer timeout, stable peer identity, transport reuse after Activity destruction, and explicit disconnect. It never controls the real desktop. Real-device Bluetooth/relay and long-duration background behavior remain part of the full project's acceptance testing.

5项资源生命周期单测覆盖界面重建、旧界面不清理新界面回调、主动停止、仅清理一次，以及不由后台自行创建连接。模拟器专项测试使用真实加密握手的本地回环模拟 Mac，覆盖超过12秒超时窗口仍续订、设备身份不变、界面销毁重开复用连接、主动停止后断开。真机蓝牙/中继和长时间后台表现待新项目整体验收。

```sh
apps/android/gradlew -p apps/android testReleaseUnitTest lintRelease assembleRelease
# Explicit, isolated emulator test; never target either real phone here.
apps/android/gradlew -p apps/android assembleDesignReview assembleDesignReviewAndroidTest
adb -s <emulator-serial> install -r apps/android/app/build/outputs/apk/designReview/app-designReview.apk
adb -s <emulator-serial> install -r apps/android/app/build/outputs/apk/androidTest/designReview/app-designReview-androidTest.apk
adb -s <emulator-serial> shell am instrument -w -e test background-connection io.github.junweiup.vibepier.remote.review.test/io.github.junweiup.vibepier.remote.BindingSyncInstrumentation
```

## Installation / 安装

Use the new VibePier Mac and Android apps. Update a phone with the same release signing key to preserve its data and authorization. Installation is an explicit action, separate from build/package commands; it does not prove full release acceptance. See [Android setup](../apps/android/README.md#构建和验证). No old companion app or protocol is required.

使用新版 VibePier 两端；手机更新须保持 release 签名不变，以保留数据与授权。安装与构建/打包分开，不代表全部发布验收已完成。无需旧版应用或旧协议。
