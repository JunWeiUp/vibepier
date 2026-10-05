# Product specification / 产品说明

## Purpose

VibePier lets a person continue supported AI coding sessions and operate their own Mac from an Android phone. The Mac remains the execution environment: projects, provider accounts, desktop applications and model requests stay there. The phone supplies a compact reading, reply, approval and control surface.

The primary scenario is a short interaction away from the keyboard: inspect progress, answer a supported question, adjust the next message, or use a configured shortcut. A self-hosted relay adds cross-network connectivity; Bluetooth and local Wi-Fi work without a relay. AU05 hardware is optional.

## Scope

| Area | Included | Boundary |
| --- | --- | --- |
| Sessions | Provider/project lists, conversation pages, lazy tool output, supported attachments, drafts and receipts | Capabilities depend on the [provider adapter](COMPATIBILITY.md); unsupported actions stay unavailable. |
| Remote input | Six configurable controls, per-app bindings, application slots and hold/release semantics | Mac permissions apply. A connected phone is not an unrestricted network shell. |
| Voice | Mac microphone by default; optional phone capture and virtual-device routing | Phone audio needs BLE, local Wi-Fi or negotiated direct UDP; the relay does not forward it. |
| Screen state | Explicit lock/unlock and optional temporary unlock for desktop actions | User-configured password and permissions; no boot/FileVault bypass. |
| Connection | Per-phone approval, authenticated transport, reconnect and foreground-service ownership | No hosted account, managed relay subscription or availability guarantee. |
| Device settings | Optional AU05 settings, heartbeat and bindings | Always-on heartbeat is the verified default; experimental modes are labeled. |
| Maintenance | Signed APK delivery, settings export/import, source builds and self-hosting | Installation still requires the platform's normal confirmation. |

## Defaults and first use

Fresh phone installations start with Bluetooth. Discovery sends one authorization request for the Mac to approve; opening the session page is not required. Each phone gets its own authorization. Relay settings can then synchronize through the approved BLE channel.

Usage tracking, stored unlock password and phone microphone input are opt-in. The Mac microphone is the initial source. AU05 heartbeat is on; AI hardware lights/integration are off. The default configuration does not rewrite hardware settings or contain a relay endpoint, secret or personal server.

## Success criteria

A visible success must follow an observed result or durable receipt. A timeout with an unknown result must not become an automatic duplicate send. Navigation must retain the correct provider/thread scope, cancel obsolete reads, release held input and stop recording. Disconnecting or revoking a device must not leave its keys or audio active.

For the first public release, source and downloadable artifacts must correspond to one consolidated root commit; licenses, assets, instructions, signatures and checksums must be inspectable. The complete acceptance record is [TODO.md](../TODO.md), not a claim inferred from this specification.

## Not included

There is no iOS client, Windows/Linux desktop host, browser frontend, public relay service, component registry or Cloudflare deployment. This is not remote desktop video streaming, a replacement AI provider, a universal adapter for every future desktop release, or a tool that powers on a shut-down Mac. No independent security audit is claimed.

## 中文说明

目标是让用户短暂离开键盘后，仍能查看进度、回复会话、处理适配的审批及使用快捷键。代码、账户和模型执行环境留在 Mac；Android 提供操作界面，自建中继提供可选的跨网络通道，AU05 不是必需硬件。

首次蓝牙发现自动申请 Mac 确认，每台手机单独授权。用时统计、保存解锁密码和手机麦克风均需另行开启；默认使用 Mac 麦克风，AU05 心跳保持开启。会话能力按来源判断，未知回执不能自动重发，离开页面或断线必须释放输入、停止录音。

当前不提供 iOS、Windows/Linux 主机、网页客户端、公共中继或开机解锁。公开版本需完成整份验收清单，并以一个根提交及与其对应的产物发布。

## Phone model speed / 手机模型加速

Existing Codex desktop sessions expose Standard/Fast in the phone model menu when native state is known. Model and reasoning-effort selection also offers speed where supported by the Mac model catalog. Fast may increase usage and applies to subsequent requests; native readback is required before confirming a change. Other providers, managed runtimes and initial session creation do not currently expose speed selection.

现有 Codex 桌面会话在原生状态已知时，可从手机模型菜单开启或关闭加速；选模型及推理强度后也会提供模型支持的速度选项。加速可能增加用量，仅影响后续请求，回读桌面设置后才确认成功。其他服务商、托管运行时和新建会话暂不提供速度选择。
