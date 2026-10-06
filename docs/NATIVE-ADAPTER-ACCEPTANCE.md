# Native adapter acceptance / 原生适配器验收

Explicit opt-in XCTest seam; not phone E2E. No production installation, daemon,
device trust store, relay or Android changes. Ordinary tests skip before initializing native readers.
显式启用 XCTest，不安装生产应用、不启动主网关；未启用时跳过原生读取。

```sh
python3 scripts/check/native-adapter-acceptance.py --opt-in --probe catalogs
python3 scripts/check/native-adapter-acceptance.py --opt-in --probe creation-preflight
```

Catalogs uses the production Codex local cache reader and Claude model HTTP catalog,
including the user's configured credential helper. Credentials remain internal to the
Mac reader/helper. Only counts, fixed statuses and AXIsProcessTrusted() are printed;
no raw errors, HTTP responses, helper output or message bodies are logged. The AX check
never prompts. Catalog failure is a failing test, not fallback/default model success.
目录探测沿用生产认证配置，包括 helper；不输出秘密或正文，失败明确报错。

NativeAdapterAcceptanceHost is an in-process integration seam. Its read-only entry wires a
temporary AgentSessionCoordinator to real CodexBridge/ClaudeBridge instances, preserves
production project/history discovery, and uses temporary runtime, attachment, follow-up
and Claude settings paths. It does not attach global native event sinks. The read-only
runner only invokes newOptions for a freshly created temporary workspace. Separate,
explicitly authorized dedicated lifecycle tests are documented in
[NATIVE-LIFECYCLE-ACCEPTANCE.md](NATIVE-LIFECYCLE-ACCEPTANCE.md); they do not accept arbitrary
thread IDs or introduce a network listener.

Fresh workspaces generally do not satisfy existing production project registration
requirements. creation-preflight reports a failing test when either provider returns
ok != true. It never registers a project, seeds synthetic history or claims creation
acceptance from a rejected request. This probe uses the production history reader;
only run it with authorization for normal native project discovery. Responses stay in
memory and are not printed.
临时项目未注册时预检必须失败；不以拒绝结果冒充验收成功，不伪造项目或历史。

Catalog success establishes model discovery only. Later dedicated lifecycle runs separately
verified creation/send identities and a pending native approval; see the lifecycle document
for the exact scope. Phone integration still requires encrypted transport/device authorization
and a scoped lifecycle that cannot address pre-existing conversations.
模型目录成功不代表新建、发送、审批成功；后续原生验证的独立证据见生命周期文档。

If AX is false, the user must authorize the actual test host in macOS Accessibility
before desktop mutation. Production VibePier authorization is not inherited. No TCC
access/reset, Keychain export, screen capture or permission prompt is performed.

## Observed validation / 本轮验证

- Production catalogs: PASS; Codex local cache 7 models, Claude model API 9 models.
- AXIsProcessTrusted: true for this XCTest host; no additional AX authorization requested.
- Creation preflight: FAIL/BLOCKED for both providers on the fresh temporary workspace;
  two failing assertions, exit 1. No native session created or prompt submitted.
- Without opt-in: both tests skipped before native initialization.
- Swift compilation and diff whitespace checks passed. No production/Android installation,
  source gateway changes, long-term configuration changes or handoff writes.

Requested repeat with production discovery/authentication unchanged: catalogs passed
in 2.757 seconds (exit 0; AX true; Codex 7, Claude 9). Creation preflight failed in
2.042 seconds (exit 1; both providers creationOptionsAvailable=false, two assertions).
Both invocations used the runner's 180-second process-group deadline and completed
without timeout. This is a real Bridge newOptions preflight, not a native new/turn call;
creation/send/approval evidence remains outstanding. No phone connection was required.

Error classification repeat: 2.136 seconds, exit 1. Both providers returned
`creationCategory=project_not_known`. Classification compares known localized native
errors in memory and prints only fixed category names, never raw error text.

## Proposed loopback gateway seam / 待实现网关接缝

Feasible from current injection points; not implemented or exercised by these tests:

1. Opt-in XCTest owns a TCP listener bound only to 127.0.0.1, one enrolled test identity,
   bounded length-prefixed frames, deadlines, a private SessionPacketInbox and budgets.
   `adb -s <verified-emulator> reverse tcp:<phone-port> tcp:<host-port>` tunnels TCP only;
   it does not tunnel RemoteSender's existing UDP transport. An androidTest SessionTransport
   shim must bridge sendBinding/onSessionFrame; the production SessionClient encryption stays intact.
2. Generate a fresh 32-byte device root with a UUID identity. Store bootstrap material
   in a newly created 0600 host file under a 0700 directory. Stream through adb exec-in
   run-as into the debuggable review app's private file/stdin; instrumentation imports it
   with DeviceKeys.install, then removes bootstrap files. Never use production keys,
   command arguments, log output or /data/local/tmp. Verify the exact emulator and review
   package before injection; run-as alone does not install a key into Keystore.
3. Fix sender/client identity from the isolated enrollment, not request JSON. Feed the
   existing vibepier-session1 frames into SessionPacketInbox.receive. Decode authenticated
   agentRequest with AgentSessionProfile.decode, then AgentSessionService.perform.
   Replies/events use SessionEnvelope.seal and SessionEnvelope.frames and the phone's
   existing encrypted response inbox. Preserve packet replay tracking across reconnects.
4. Construct AgentSessionDirectory(file: temporary), SessionReceiptJournal(file: temporary)
   and AgentSessionService(directory:execute:journal:describe:freshMutationFailure:eventSink:).
   Bind Journal.read/reserve/complete/recordEvidence on one serial queue using the same
   client:operation key/existingKey mapping as SessionRemote+AgentRequests. Storage failure
   must remain failure/unknown. Do not replace the journal with an in-memory success stub.
5. execute delegates only allowed currentV1 adapters to coordinator.performCurrentV1;
   describe uses coordinator.describe; freshMutationFailure uses the coordinator gate.
   Wire native adapter events through coordinator to service.receiveCurrentV1Event and
   service eventSink back through encryption. Recheck test-device authorization and provider
   policy on dispatch/events. Apply ingress/execution/event budgets before service admission;
   these transport protections are not automatically supplied by AgentSessionService.
6. Allowlist the dedicated workspace and only newly created native session IDs at the
   execute boundary, including filtering list/project replies before service registration.
   Reject other native operations rather than exposing the user's existing conversations.
   The temporary service directory is an opaque protocol index, not native project
   registration; project_not_known must be solved separately before real creation testing.

This validates SessionClient packets + product service/coordinator + native adapters.
It does NOT validate SecureControlClient's outer UDP/BLE handshake, BLE enrollment,
RemoteListener, production SessionRemote routing or relay connectivity. No plaintext
production fallback is introduced. AX is currently true; the current blocker is the
native dedicated-workspace prerequisite, not system permission or phone connectivity.
