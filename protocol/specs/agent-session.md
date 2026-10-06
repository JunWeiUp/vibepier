# Agent Session API profile 2 / Agent 会话 API profile 2

**Status: implemented in the development source; not installed on production devices.** Mac advertises profile 2 only with an available handler and valid private identity index. Both endpoints use the shared fixtures and strict field validation. See [architecture and rollout](../../docs/AGENT-CONTROL-ARCHITECTURE.md).

**状态：双端开发源码已实现。** 原生 Agent 的版本、归属和效果证据仍由各 adapter 独立校验；真实桌面验收不由单元测试代替。

## 1. Layers and versioning / 分层与版本

- Device enrollment, authenticated handshake, encryption, transport framing and replay protection retain the [secure control contract](secure-control.md). Relay retains its [routing contract](relay.md).
- Agent Session API is an inner application profile. `agentProtocol: 2` is independent of secure-control application protocol 1, handshake format 2, the product build number and each native provider protocol version. No existing version number or capability bit is reassigned by this profile.
- Profile 2 is carried inside an `agentRequest` RPC wrapper with the existing UUID `id`, runtime-generated finite `sentAt` and a `body` containing this profile's request. `body.requestId` must equal outer `id`. The current authenticated packet/assembly rules still apply. The branch is implemented in the development builds; previously installed builds do not recognize it.
- An authenticated host descriptor advertises supported agent profiles, minimum peer requirements and capabilities before any new-profile mutation. Missing or contradictory declarations disable the new profile. Selection stays bound to the authenticated host/connection generation.
- Compatibility fallback is an explicit profile choice before submission. A submitted or unknown operation never changes profile or driver to retry. Existing v1 pending operations keep their original bytes, IDs, scope and receipt path, including after upgrade.
- Unknown optional descriptive fields may be ignored. Unknown command fields, enum values, permission decisions, invalid types or conflicting identities are refused before effects. Unknown event entities trigger scoped refresh; they cannot establish completion or approval.
- No raw provider JSON-RPC forwarding or arbitrary runtime method names are exposed to the phone. MCP/tool transport is not a substitute for this user-to-agent control contract.

## 2. Identity and authority / 身份与权威

| Field | Meaning |
| --- | --- |
| `hostRef` | Stable host identity bound to the phone's current authorization |
| `adapterId` | Specific provider/backend integration, e.g. `codex.currentV1`, `codex.managedAppServer` or `claude.desktopMods` |
| `sessionRef` | Opaque Mac-issued mapping to host, adapter and verified native history identity |
| `ownershipEpoch` | Changes when the native writer/instance or selected driver changes |
| `capabilityRevision` | Current verified capability/configuration snapshot |
| `requestId` | One RPC attempt; replies echo it |
| `operationId` | One logical mutation; immutable semantic fingerprint and original scope |
| `controlLease` | Short-lived, Mac-issued permission bound to trusted device and target; session writes bind owner epoch, creation binds adapter/workspace/options revision |

Trusted phone identity comes from authenticated transport, never from payload. Every request is checked against that identity. A `sessionRef`, a media token or a control lease cannot expand device authorization. Native IDs and IDs supplied by plugins are observations to verify, not authority to control any matching session.

Session history identity may survive backend restart; its old control lease does not. Rebinding requires native verification and a new epoch. Previously submitted operations retain their original execution context for observational reconciliation. If a historical native result cannot be proved, it remains unknown.

## 3. Envelope / 信封

Example mutation; all IDs and text are synthetic:

```json
{
  "agentProtocol": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "operationId": "00000000-0000-4000-8000-000000000002",
  "method": "message.submit",
  "target": {
    "sessionRef": "session-demo-1",
    "ownershipEpoch": "owner-demo-1",
    "capabilityRevision": "caps-demo-1"
  },
  "controlLease": "00000000-0000-4000-8000-000000000003",
  "params": {
    "mode": "start",
    "content": [{"type": "text", "text": "Explain the synthetic fixture."}],
    "expectedTurnId": null
  }
}
```

The example above is the wrapper's `body`, not the full secure-control plaintext. Reads omit `operationId` and `controlLease`; methods that acquire a write route may return a new lease but do not submit a prompt. Mutations require a UUID logical operation ID; it is not generated again during recovery.

Targets are a tagged union: existing-session operations use `sessionRef + ownershipEpoch + capabilityRevision`; creation uses `adapterId + workspaceRef + draftId + optionsRevision` without a not-yet-existing sessionRef. An authorized `session.creationOptions` response issues a creation lease for that verified adapter/workspace/draft/options scope. The creation adapter revalidates this scope before effects and returns the new native identity when known. Initial input and attachments are bound to the original draft and immutable operation fingerprint.

Gateway canonicalization covers the method, selected profile, target, requested options, text, attachment identities/digests and action semantics; transient requestId/lease bytes are excluded. The canonical rules and cross-language vectors must be committed before implementation. The server separately binds this fingerprint to trusted device identity and the original execution epoch; changing owner does not authorize re-execution.

Reply example:

```json
{
  "agentProtocol": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "operationId": "00000000-0000-4000-8000-000000000002",
  "status": "confirmed",
  "effect": "message.submitted",
  "target": {"sessionRef": "session-demo-1", "ownershipEpoch": "owner-demo-1"},
  "result": {"messageId": "native-message-demo", "turnId": "native-turn-demo"}
}
```

Native evidence is verified by the adapter and bound to the journal. A truthy `accepted`, empty response or disappearance of a composer/approval cannot replace that evidence. Status fields use exact enums and JSON types, never diagnostic-text matching.

Replies wrap the body with outer UUID `id` and boolean `ok`. Confirmed mutations use `ok: true`; rejected mutations use `ok: false`; accepted/unknown mutations use `ok: false, unknown: true` until definitive evidence is saved. Successful reads use `ok: true` and a typed result body rather than a mutation status. Events use outer `event: agentEvent` and the profile event in `body`. Thus no `ok: true + unknown: true` contradiction reaches the existing assembly boundary. The new client decodes profile bodies before applying its typed lifecycle; it cannot treat an accepted reservation as a completed result.

The gateway classifies the inner method from a single generated catalog before budget/journal admission; the outer `agentRequest` name must not cause all reads to be treated as writes or mutations to bypass reservation. Outer UUID `id` tracks a transport attempt. The logical mutation key is trusted device plus operationId; profile, original target, execution epoch and semantic hash are immutable constraints on that record, not alternate lookup namespaces. Changing the target/profile with the same operation ID is a conflict, never fresh admission. Existing v1 journal keys remain intact; admission must also check legacy IDs/tombstones before a new-profile reservation, without copying an unknown operation into a fresh record.

Profile 2 requires a typed receipt validator for each method's native proof and target. A confirmed wrapper cannot be passed unchanged through the v1 `SessionProviderReply` accepted/threadId predicates. Both profiles retain durable saving and unknown-result rules, with separately verified evidence decoding.

## 4. Operation catalog / 操作目录

| Method | Class | Essential semantics |
| --- | --- | --- |
| `agent.describe` | Read | Verified runtime/configuration descriptors and reasons; no model turn for health probing |
| `workspace.list` | Read | Authorized workspace descriptors, independent of agent execution |
| `session.list` | Read | Bounded filtering/pagination; history listing does not prove writable ownership |
| `session.open` | Control setup | Verify native identity, read current capabilities/state, optionally issue a write lease; no model input |
| `session.snapshot` | Read | Bounded authoritative entities, completeness and stream cursor |
| `session.items` | Read | Turn/item pagination and completeness; large output references scoped to session |
| `session.observe` | Subscription | Start/resume observation; sequence gaps require resync |
| `session.unobserve` | Subscription | Release only caller's subscription, never stop a task |
| `session.create` | Mutation | Verified workspace/options and optional initial input; track creation and first-input effects separately |
| `session.configure` | Mutation | Adapter-issued option IDs/revision; exact scope and effective readback |
| `message.submit` | Mutation | Explicit `start`, `queue` or `steer`; supports only advertised native semantics |
| `queue.cancel` | Mutation | Native queued-input ID/revision; cannot retract an already submitted input |
| `queue.steer` | Mutation | Native queued-input ID, optional expected running turn; asks the native owner to send that queued input into the running turn now (Codex desktop). Confirmed by the owner's acceptance; a missing queued input is rejected before any effect |
| `turn.interrupt` | Mutation | Exact expected native turn and owner; native confirmation distinguishes requested from interrupted |
| `approval.resolve` | Mutation | Pending approval ID, fingerprint, revision and one advertised decision |
| `question.answer` | Mutation | Pending question ID/revision; schema-valid answers; distinct from tool approval |
| `operation.get` | Read | Reconcile original mutation without submitting it again; authorized receipts remain readable after provider disable |

`session.create` reports separate `sessionCreated` and `initialInput` evidence. A provider requiring a first input declares `createRequiresInitialInput`. Creation is confirmed only when every requested effect is proved; a known native session with unknown first input remains unknown with the known sessionRef retained. The phone must not send that first input again as a new message to recover. Existing v1 composite `new` behavior is wrapped, not silently split into two attempts.

`start` requires a suitable idle session; `steer` requires `expectedTurnId` matching the active turn; `queue` requires native queue support and returns a verified queue ID. Race-time native rejection is definitive only if it proves no submission. An upstream API that waits for idle is represented as a pending start, not secretly advertised as steer or a cancellable queue.

Cloud control, session takeover, archive/fork, Git mutations and generic tool invocation are outside the first profile. File/media, account, APK, lock/unlock and key/audio APIs retain their own service contracts.

## 5. Capabilities and options / 能力与选项

```json
{
  "adapterId": "claude.desktop",
  "backendKind": "desktopAttached",
  "capabilityRevision": "caps-demo-1",
  "actions": {
    "message.start": {"supported": true, "available": false, "reason": "native_interface_unavailable"},
    "message.steer": {"supported": false, "available": false, "reason": "unsupported"},
    "session.snapshot": {"supported": true, "available": true, "reason": "available"}
  }
}
```

The adapter contract, actual version/schema, runtime health, local Mac policy, device permission and session ownership all constrain availability. Missing actions default to unavailable. Phone caches are scoped to authorized host and adapter; cached capabilities cannot authorize a mutation. Server checks again immediately before execution.

Options include opaque option ID, native-backed display name, explanation, revision, allowed values, applicability and permission scope. A selected model/permission label does not imply equivalence across agents. Permission escalation requires the existing explicit UI confirmation and native enforcement. No arbitrary remote form execution, scripts or bypass flags are accepted.

## 6. Mutation lifecycle / 变更生命周期

| Status | Durable meaning | Recovery |
| --- | --- | --- |
| `rejected` | Verified refusal with no requested effects; explicit compound partial effects require unknown instead | Display reason; any new action follows fresh intent and state |
| `accepted` | Journal reservation succeeded and Mac owns the intent; does not prove native delivery | Query original operation |
| `confirmed` | All requested submission/configuration effects have verified native evidence, saved durably | Update draft/queue/UI; keep observing the turn |
| `unknown` | Effects may have happened or durable evidence is insufficient | Only observational reconciliation; never automatically resubmit |

Creation is confirmed by native identity: the session reference plus, when an initial message was sent, its native message and turn identity. Option readback (execution mode, service tier, permission mode) that cannot be matched is returned as bounded `warnings` with `executionModeState: "unverified"`; it no longer turns a proved creation into `unknown`. `session.configure` remains strict because the setting is its whole effect. A provider failure counts as `rejected` only when the adapter marks it `definitive` with native proof that the input was never submitted; such a creation may report the empty native session as `partialSession`. `operation.get` returns `notFound` when the device's journal has no record, so the phone may explicitly resend the identical body under the same operation ID; the journal deduplicates if the first copy arrived after all.

The phone sends every write through this profile. Until the profile is negotiated on the current connection, a write is refused before any effect rather than falling back to a v1 mutation; existing v1 pending receipts remain read-only and are resolved through their original receipt lookup.

The device journal keeps a fixed 16 KiB reservation per unresolved record (at most 64 per device) instead of a worst-case result reservation, compacts oversized final results to their identity fields rather than failing after a native effect, and retires unresolved records older than 72 hours into tombstones that keep the fingerprint and still return `unknown`, never fresh admission.

Reserve before the first possible effect. Journal failure before execution prevents execution. Journal completion failure after native confirmation returns unknown. Repeated operation ID with identical fingerprint returns its existing result/state; conflicts are refused. Retired completed bodies retain operation markers and cannot authorize replay. Unknown reservations are never evicted to allow another mutation.

`confirmed` does not mean model inference succeeded. `turn.completed`, `turn.failed`, API/rate-limit blockers and a creation receipt are separate facts. Network timeout, missing transcript text and silence are not evidence of rejection. No end-to-end exactly-once guarantee is inferred from this gateway deduplication.

Stable errors include `unsupported`, `provider_disabled`, `protocol_incompatible`, `native_interface_unavailable`, `owned_elsewhere`, `owner_changed`, `stale_state`, `approval_expired`, `operation_conflict`, `capacity_exceeded`, `content_incomplete`, `resync_required` and `receipt_unknown`. Localized UI uses machine codes; sanitized human text is descriptive. Error code alone cannot change an already unknown mutation to retryable.

## 7. Observation and history / 观察与历史

```json
{
  "agentProtocol": 2,
  "subscriptionId": "observe-demo-1",
  "sessionRef": "session-demo-1",
  "streamEpoch": "stream-demo-1",
  "sequence": 42,
  "event": "item.updated",
  "entityRevision": 3,
  "data": {"itemId": "item-demo-1", "kind": "text", "text": "Synthetic response", "contentState": "complete"}
}
```

Canonical events: `session.stateChanged`, `capabilities.changed`, `turn.started`, `turn.updated`, `turn.completed`, `turn.failed`, `turn.interrupted`, `item.updated`, `approval.opened`, `approval.resolved`, `question.opened`, `question.resolved`, `operation.updated`, `resync.required`.

- Sequence is monotonic within a Mac stream epoch; event IDs/epoch are scoped to authorized host and session. Provider-native cursor remains inside the adapter.
- `session.observe` establishes buffering before taking the snapshot. Snapshot returns the same stream's `throughSequence`, `consistency` and bounded pagination. A strong snapshot requires a verified native revision/cursor barrier, not just serialization of gateway callbacks. When the native interface lacks an atomic barrier, the adapter brackets its history read with native revision/state checks and reconciles buffered entities by verified ID/revision; unstable reads are partial and require bounded resync. They cannot establish a destructive replacement or clear an unknown operation. Apply a verified snapshot then later events; reject old entity revisions and duplicate sequence. A gap or changed epoch causes a fresh snapshot, not guessed completion.
- Projection state, stream sequence and snapshot cuts are serialized together. `entityRevision` represents verified native/projection progress, not merely callback arrival order. An old native callback cannot acquire a newer revision and overwrite a newer snapshot. If ordering cannot be verified, treat the event as a dirty signal and reread authoritative state rather than blindly replacing the entity. Page cursors bind snapshot/history identity; a changed baseline starts a new pagination context.
- Every history page states `contentState: complete|partial|unavailable`, `nextCursor` and whether the requested range is authoritative. A partial page cannot erase unloaded messages. Text summary, tool steps and large body references are loaded separately. Cursor repetition is an error, not end-of-history.
- Ring retention is bounded by count, bytes and total host budget; overflow advertises resync. It does not evict unresolved operation identities or treat lost approval events as denial/approval.
- Page teardown cancels only its observation. Submitted operations and native tasks continue independently. A different phone's subscriptions and drafts remain isolated.
- History reconciliation binds original message/turn/native proof; it cannot infer success from similar text elsewhere. Content referenced by an item is acquired through the existing scoped media/file capability, without inline bulk base64.

## 8. Approval integrity / 审批完整性

An approval includes native pending identity, turn/session, revision, fingerprint, `kind` (command/file/tool/network/other), displayable intent and explicit `allowedDecisions`. The normalized model keeps tool/file/network semantics rather than disguising every approval as a shell command. Single-use, session-wide and policy-changing decisions retain separate scopes.

The Mac checks original request is still pending on the same owner. Only one device/native client may resolve it; stale or already answered prompts cannot be answered again. Native submission evidence is required, and changed/disappeared UI is insufficient. A plugin's ability to override permission checks is not proof that it can safely resolve an existing native approval; that path requires its own contract and acceptance.

## 9. Contract implementation gate / 实现门槛

Before profile 2 is advertised, commit JSON schemas, the complete current-v1 operation inventory/mapping, deterministic fingerprint vectors and synthetic request/reply/event fixtures consumed by Swift and Kotlin. Generate operation classifications and enums from the same source; mutation/read membership must not diverge across layers. Native driver schemas/snapshots remain separately versioned.

Representative mapping: v1 `list/projects/open/send/new/interrupt/approve/receipt` maps to `session.list/workspace.list/session.open/message.submit/session.create/turn.interrupt/approval.resolve/operation.get`; settings/queue/question operations require their own exact field mapping. This table is a migration guide, not permission to translate an in-flight mutation. Existing journal IDs and tombstones survive.

Acceptance covers cross-language parsing, unsupported capability default, authorization isolation, repeated/conflicting mutation, timeout after submission, owner/turn mismatch, journal failure, late receipt, native approval races, cursor gaps, partial-history merge, ring/quota limits and revocation. Real-desktop delivery is a separate opt-in check, never inferred from fixtures or schema generation.

## English contract summary

The target profile normalizes user intent and observable results while preserving native identities, ownership and semantics in Mac adapters. A common gateway owns authorization, quotas and durable at-most-once admission; uncertain effects stay unknown. Capabilities are explicitly negotiated and rechecked. Snapshot/cursor recovery repairs observation without restarting work. Profile selection, receipt migration and actual provider compatibility are distinct gates; this document alone enables none of them.

## Implemented negotiation and creation / 当前协商与创建

The authenticated `providers` response advertises `agentProfiles: {versions:[2],minimumClientVersion:2,methods:[...]}` and capability version 1 adapters. The default currentV1 adapter and optional runtimes for the same provider have separate IDs. Missing declarations disable writes; backend selection never migrates pending mutations.

`session.creationOptions` uses an adapter target and `{workspaceRef,draftId}` params. It returns native option catalogs and `creationLease:{target,controlLease}`. `session.open` returns `{session,snapshot,controlLease,streamEpoch,throughSequence,consistency}`. Normalized approvals carry their native request fingerprint, revision and explicitly allowed single-use decisions. Requests use normalized IDs; only the Mac resolves them back to the native pending request.

Cross-platform vectors are in [agent-session-v2.json](../fixtures/agent-session-v2.json); executable request shapes are in [agent-session-v2.schema.json](../schemas/agent-session-v2.schema.json). Canonical mutation fingerprints exclude requestId and controlLease, use scalar key ordering and safe integers, and retain target, method, operationId and complete params. UTF-8 depth, size, field and content limits are checked at both endpoints.

The shared device journal retains verified partial native identities for unknown outcomes, including a created thread whose initial prompt is unresolved. `operation.get` is observational and never recreates the thread or re-submits the prompt. The lookup shares logical operation IDs with v1, including UUID letter-case variants; there is no separate retry namespace.

`session.items.kind` selects the native read projection. History uses an opaque string `before` message anchor; sequential parts use a nonnegative integer `before` sequence. Their shared vector prevents a string-only cursor assumption from breaking tool/body pagination. `session.unobserve` releases only the matching client's native view after its final subscription, invalidates its ephemeral write lease, and preserves other phones and running tasks. Successful authoritative snapshots renew the same unexpired lease for unchanged scope; an expired token is removed and a fresh snapshot issues a new token. Dirty events remove write authority until a refreshed snapshot. Before a new mutation enters the phone journal, the phone reads a fresh snapshot (or creation options) and validates the original authorization, adapter, session and view. The UI offers supported actions without gating them on cached availability or cached composer values. Standard Send resolves the current native start/queue behavior and inherits current settings; a caller that explicitly supplied start/queue retains that choice. Stop turn IDs, approval fingerprints/reviewed revisions and selected queue content remain bound. Explicit setting choices and FullAccess confirmation are preserved; omitted creation defaults come from the fresh catalog. Read recovery allows at most seven attempts over ten seconds, and never retries an admitted write. Unknown results use only the original operation receipt.

`session.stateChanged.data.controlDirty:false` marks a complete verified update with unchanged control semantics: content/token/progress changes require a new display read but preserve the control lease and epoch. Only a contiguous event in the current stream may take this path; a gap, changed epoch, missing flag, incomplete update or changed control semantics revokes authority. Native control comparison includes owner, turn, approvals, queue, composer choices/locks and actual capabilities. Snapshot/open reads for the same client/adapter/sessionRef/view coalesce (16 waiters maximum), with independent reply request IDs. A replaced scope rejects old replies, and same-scope reads do not create a new capability revision by themselves.

手机新操作先自动取得原生状态，旧页面的忙闲、模型或权限展示不能提前拒绝。普通发送按当前原生状态选择发送或原生队列，明确指定的模式及具体操作对象保持原值；新建缺省值使用本次可信目录。正文/进度更新不撤操作授权，真正控制变化、事件缺口或不完整数据仍撤权。同范围的后台同步与操作准备共享一次读取；写入开始后的未知结果只查询原回执。

`workspace.list` and `session.list` accept omitted or empty-string `search` for an unfiltered list. Search remains a string without NUL, bounded to 200 UTF-8 bytes; opaque identity fields stay nonempty. All requests include a target object, including `{}` for host-wide reads such as `operation.get`. The shared `empty-search-list` fixture and the encrypted `agent-open` probe cover fresh discovery before opening and refreshing a session.

项目/会话列表允许缺省或空字符串搜索，表示无过滤；搜索类型与大小、身份非空校验仍保持。主机级读取也必须携带空目标对象 `{}`；不会借此开放写权限或重发未知操作。

## Execution and plan modes / 执行与计划模式

`session.configure.params.options` and `session.create.params.options` accept `executionMode: "default" | "plan"` when the selected adapter advertises an available `executionMode` capability and a matching `executionModes` catalog. This is a native configuration option, separate from `message.submit.mode` (start/queue) and the `mode` permission option. Plan mode is never simulated by prepending instructions to a prompt.

For Codex, execution mode maps to the native collaboration mode and preserves the chosen permissions. For engines whose plan mode is a native permission mode, `executionModePermissionCoupled:true` and each catalog option's `permissionMode` describe the coupling. Plan selection disables the separate permission picker; conflicting plan plus nonplan permission requests are rejected. Returning to execution uses an explicitly selected nonplan permission or the advertised safe default, never an inferred unrestricted permission.

A confirmed configuration must contain `effectiveOptions.executionMode` matching the request, with independent native verification at the Mac adapter. A setter ACK alone, a stale composer or a mismatched mode leaves the mutation unknown. Creation applies and verifies an explicit mode before its initial turn; unresolved mode configuration preserves the created session and never repeats the first prompt. An unsupported native version, unavailable owner or incomplete catalog disables the control.

Claude's native `ExitPlanMode` is exposed as a single-use approval only for a complete bounded plan with no extra permission fields/rules and no nonempty `allowedPrompts`. The adapter supplies the explicit `planApprovalScope: "once"` after validating native input. The gateway still requires the original pending identity/fingerprint and native `once`/`deny` evidence. Other plan requests stay Mac-only; a plan marker does not authorize blanket permissions or a settings mutation.

手机会话输入区域与新建会话选项提供独立的计划/执行入口。当前模式来自 Mac 回读；缺少原生能力时不显示可用切换，不按 Agent 名称推断。更改模式后仍保留原来的未知回执和后端作用域。

### Phone speed selection

`session.configure.params.options.serviceTier` accepts `standard` or `priority` for existing Codex desktop sessions with a known native service tier. The model catalog exposes `serviceTiers`; `priority` is offered only when the Mac catalog advertises it. Standard maps to native `serviceTier: null`, priority to `serviceTier: "priority"`; omitted fields remain unchanged. The option applies to subsequent turns and may increase usage. Codex creation also accepts `session.create.params.options.serviceTier` when its fresh creation catalog advertises a known composer tier and the selected model lists the requested tier. The phone preserves this selection in its encrypted draft. The first desktop turn carries the explicit tier (including null for standard); success requires owner-bound native tier readback, otherwise the result remains unknown and is never resent automatically. Managed runtimes and other providers do not advertise this control.

The speed setting participates in control revisions and the operation journal. Confirmation requires fresh native readback matching the requested value; setter acknowledgements alone never confirm it, and unknown operations are not resent.

手机端现有 Codex 桌面会话的模型菜单支持加速开关；切换模型和推理强度后也可选择加速。仅在原生状态已知、模型目录支持时提供加速，用于后续请求，可能增加用量。不支持的模型可回到标准速度；新建会话、托管运行时及其他服务商暂不提供此入口。桌面回读不匹配时保留未知回执，不自动重试写入。


`session.creationOptions` accepts optional boolean `refreshOptions`; `session.items` accepts it only for `kind: composerOptions`. This is a read-only catalog refresh. Cached catalogs contain presentation choices, never control leases, target ownership or mutation receipts. Automatic reads reuse the launch catalog; mutation authorization and native result evidence remain separate.

`session.creationOptions` 的可选布尔参数 `refreshOptions` 用于只读刷新目录；`session.items` 仅在 `kind: composerOptions` 时接受该参数。缓存只保存展示选项，不能保存或代替控制租约、原生目标身份与操作回执。

### Codex command-rule approvals

For `codex.currentV1` command execution requests only, the Mac may advertise `allowSimilar` in `allowedDecisions` and supply `allowSimilarDescription`. The phone sends `approval.resolve.params.decision = "allowSimilar"` with the existing approval ID, fingerprint and revision; it never supplies rule bytes. The Mac re-reads the matching native request and submits exactly `{"acceptWithExecpolicyAmendment":{"execpolicy_amendment": proposedExecpolicyAmendment}}`. The bounded nonempty proposed prefix must come from that request; if native `availableDecisions` is present it must contain that exact structured decision. Network requests, absent/invalid rules, `acceptForSession`, file-wide grants and global permission changes are not mapped to this choice.

The default `decisionScope: "once"` remains the scope of ordinary allow/deny (including notifications). `decisionScopes` makes each advertised choice explicit: `allow: once`, `deny: once`, and `allowSimilar: commandRule`. Description displays the exact argument prefix as JSON, not a reconstructed shell command, and does not promise an unverified rule expiry. Native request identity and the rule are covered by the approval fingerprint; the full profile2 operation fingerprint includes the chosen decision. Confirmation of this new choice additionally requires a matching native request ID and echoed `decision: "allowSimilar"`; unknown native outcomes remain unknown and are not resent. Background Codex uses the same exact rule encoding but retains its existing conservative unknown result when resolution does not prove which decision was adopted. Other adapters do not advertise this choice.

仅 Codex 当前原生命令审批可声明“允许此类”。规则完全取自原请求，手机只提交选择，不能提交或扩大规则；一次性通知仍只允许或拒绝本次操作。
