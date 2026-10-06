# Dedicated native lifecycle / 专用原生生命周期验收

Run only with explicit authorization to create a dedicated native project and submit
real model turns. This is separate from the read-only catalog runner and phone transport.

```sh
python3 scripts/check/native-lifecycle-acceptance.py --opt-in-native
```

Each invocation creates a fresh `.local/native-lifecycle-<UUID>/workspace`, retained
in the native Agents by design. It never accepts an existing conversation ID or workspace.
Mac credentials are used in place and are never exported. Codex project/create creates
a project plus an empty named, archived/unarchived thread using approvalPolicy=on-request
and permissions=:workspace. Claude bootstrap uses a new --session-id, default permission
mode, no tools and a fixed harmless prompt. Native model output is consumed but never logged.

The XCTest phase uses the real coordinator and Bridges with dedicated transient state
files. It obtains creation options, creates one new session, requires native message
identity and exact cwd, opens only that newly returned session, waits boundedly for idle,
then sends one fixed harmless follow-up. It requires native send identity; an accepted
request without that evidence fails. This does not test approval resolution or phone E2E.

Before every write phase a private attempt marker is created. Bridge mutation markers
use O_EXCL; rerunning a phase in the same run directory cannot resubmit that operation.
No automatic resend follows unknown, failure or timeout. Persisted results contain only
identifiers, booleans and fixed error classes; prompts, response text and credentials
are excluded. Failed/uncertain runs and dedicated native projects are retained for diagnosis.

Bounds: Codex bootstrap RPC group 60 seconds / 8 MiB read budget per call; Claude bootstrap
90 seconds / 8 MiB; each provider XCTest process group 180 seconds. On expiry the runner
terminates only its own process group, then records uncertainty. The normal test suite
skips before initialization unless both native and lifecycle opt-ins are supplied.

AX is checked inside XCTest without prompting. Permission/profile choices here must not
be replaced with never/bypassPermissions for future approval acceptance. Test discovery
still uses the production known-project checks; this runner establishes real prerequisites
instead of weakening those checks or seeding synthetic history.

新建专用原生项目和会话可保留；普通测试默认跳过。未知操作不重复，失败不视为通过。

## Verified run / 本轮实际验证

Workspace: `/Users/mac/Documents/code/vibepier/.local/native-lifecycle-cde3a720-7e77-4672-850f-82ed364f7c92/workspace`.
Its parent holds `result.json`, provider evidence and exclusive attempt markers. No credentials were copied.

- Both registered Bridge creation-options paths passed (5.745 seconds).
- Codex create/open/send passed (11.652 seconds), with native message and turn IDs.
  Dedicated thread: `01a10eb5-079c-7840-bd38-2f6589691ce9`.
- Claude creation returned its native message anchor. The initial CLI turn encountered
  HTTP 429; bounded waiting failed and its exact dedicated CLI process was terminated.
  A separate first follow-up through Claude Desktop then passed (7.810 seconds), without
  repeating creation. Thread: `3311d91a-ddda-440f-b2e8-f7512120167c`.
- A single new Codex message requested approval for `/usr/bin/true`; the native pending
  command approval was observed (5.415 seconds). Approval ID 35, fingerprint and native
  turn are in `codex-approval-evidence.json`. The test left it pending for phone acceptance;
  approval resolution has not been tested. These checks prove native submission, not final
  model answer completion or phone E2E.
- AX was true in both the SwiftPM and isolated XCTest processes.

The first Codex runtime path exceeded the connector's socket-path limit (<100 UTF-8 bytes).
Test runtime now uses a random 0700 `/private/tmp/vpn-<UUID>` directory and records its path
privately. Keep phone gateway runtime paths short too. Two definitive pre-thread failures
were retained; only explicit new operation IDs after a changed condition were attempted.
Unknown operations were never retried. Initial bootstrap timeout/exit failures remain in
result.json history, while overall status reflects the subsequently verified phases.

Concurrent phone-test compilation temporarily failed independently. To avoid modifying that
file, `run-isolated-native-test.py` builds only this test source against already-built Core
objects. This verifies those Core objects, not arbitrary later source edits; rebuild Core
before using the helper to validate changed production code. It bounds each test to 180 seconds
and cleans up only that test's process group, including descendant CLI processes.

```sh
python3 scripts/check/run-isolated-native-test.py --opt-in-native \
  --run .local/native-lifecycle-cde3a720-7e77-4672-850f-82ed364f7c92 \
  --phase registered-options
```

`claude-followup` and `codex-approval` are mutation phases with exclusive markers; they are
not commands to rerun against this already-verified run. Do not resend an old trigger.

## Decision resolution and reply verification / 决定与回复最终验收

This supersedes the earlier pending-only checkpoint. `result.json` now reports
`partial_codex_complete_claude_native_http_429`, `leftPending=false` and zero pending approvals.
The original checkpoint and all failures remain in its history.

- Codex denial: exact approval 35/fingerprint/native turn matched, one decline submitted.
  Request disappeared, command item became `declined`, and its turn subsequently completed.
- Codex allow: one independent message requested `/usr/bin/touch` for a fresh marker inside
  the dedicated workspace. Initial matching rejected the native `/bin/zsh -lc '…'` wrapper;
  no decision was submitted then. Read-only inspection established the exact wrapper and
  the same pending request was allowed once, without resending the trigger. Approval 39
  disappeared, command item `completed`, exit 0, regular zero-byte marker verified, turn completed.
  Path is recorded in `codex-allow-evidence.json`; no unrelated file was modified.
- Codex initial and follow-up model replies matched READY and ACK exactly; both native
  turns completed without a native error. Body text is not logged in evidence.
- Claude initial/follow-up native submissions remain verified, but reply segments contain
  HTTP 429; follow-up has an explicit native API-error assistant record with status 429.
  These are not successful model responses.
- Claude approval was actually attempted with a fresh harmless trigger. Its exact native
  message then produced a rateLimit blocker / HTTP 429, with zero approvals. The test
  interrupted only that exact native active turn, got a confirmed receipt, and verified
  final `idle` with zero pending approvals. Claude deny/allow decisions remain unexercised
  because the model could not produce an approval request. This is a concrete provider
  failure, not an AX or project-registration blocker. No automatic retry was performed.

Evidence: `codex-deny-evidence.json`, `codex-allow-evidence.json`,
`codex-replies-evidence.json`, `claude-approval-evidence.json`, `claude-replies-evidence.json`.
The registered scripts expose explicit `codex-deny`, `codex-allow`, `claude-approval`
mutation phases and a read-only `reply-evidence` phase. Exclusive operation markers
prevent replay. Approval mutation failures/unknown results are followed only by native
readback; permission decisions are never automatically resent.

Codex 拒绝、允许、标记文件与两轮模型回复均已验证；Claude 审批实际触发后被 429 阻塞，
本次活动轮次已精确中断并核实 idle。没有遗留待审批，不把 Claude 决定路径计为通过。

## Final source validation / 源码收尾

Applied `swift format -i` to NativeAdapterAcceptanceTests.swift. Its strict format lint
passes. `swift test --package-path apps/macos --filter NativeAdapterAcceptanceTests`
builds successfully: 8 tests skipped without opt-in, 0 failures. This is validation of
the default safety gate, not a replay of native acceptance. Python helper syntax and
diff whitespace checks pass. `make lint-macos` still reports formatting errors in the
parallel NativePhoneGatewayTests.swift; that file was not modified by this task.

No real prompt, approval, bootstrap or unknown operation was resent during formatting.
Final native outcome remains partial: Codex create/send/replies/deny/allow/marker verified;
Claude native submission verified, approval and model replies blocked by evidenced HTTP 429.
Original receipts/failures remain intact; both dedicated sessions have no pending test approvals.
