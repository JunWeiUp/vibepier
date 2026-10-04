# Preview release review / 预览版发布检查

This is a maintainer review of the beta's implementation and evidence, not an independent security audit or a guarantee that every desktop version works. Runtime behavior, synthetic tests and unverified device checks are recorded separately.

## Reviewed boundaries

| Area | Implementation and evidence | Limit of the evidence |
| --- | --- | --- |
| Device authorization and transport | Per-device enrollment, authenticated encrypted transport, replay protection, revocation and bounded packet assembly; shared protocol fixtures and isolated transport tests. See [security](../SECURITY.md) and [protocol](../protocol/specs/secure-control.md). | A relay can still interrupt connectivity; authenticating the relay does not authorize desktop control. |
| Storage and diagnostics | Keychain/Keystore secrets, authenticated private Android storage, excluded backups, durable private mutation journal, redacted secret scanning and public-file checks. | A compromised operating-system account is outside the isolation boundary. |
| Request isolation | Fixed provider/account/control/receipt budgets, queued-request expiry, retained charges for running work and bounded desktop-lock waiting. Admission compares the actual deadline even when timer delivery is delayed. | A stalled provider can remain unavailable; running sends are not forcibly terminated or automatically repeated. |
| File previews and Claude subprocesses | Independent bounded file workers; bounded stdin/output processing, subprocess counts and pending prompt bytes. Tests use temporary files and synthetic children. | OS file permissions and the actual installed provider still matter. |
| Native actions and receipts | Single-submit policy, verified target identity, key release, clipboard ownership, first-message evidence, client-scoped receipts and preserved unknown results. | Synthetic policy tests do not prove recognition or delivery in a real desktop window. Real first-turn acceptance was explicitly skipped for this preview and remains unverified. |
| Distribution | One root commit, preserved MIT attribution, clean-checkout builds, fixed Android signer, extracted Mac signatures/architecture, archive contents and download checksums. | Ad-hoc signed Mac downloads are unnotarized previews. Signing-key backup and final publication are tracked separately. |

Earlier candidate [CI 37178989284](https://github.com/JunWeiUp/vibepier/actions/runs/37178989284) passed all five jobs. The final source run is linked from the release notes; earlier results are not presented as the final commit's run. Local UI evidence covers the new-session controls and receipt behavior, including a small display with large type. API 35 completed its earlier device suite. The latest API 33 runner failed to boot before executing application cases, and the remaining API 36 run was cancelled when validation was simplified. Those checks are not recorded as passing.

## Indexed local Claude history

Current build 11 streams transcript metadata into a private disposable offset/ID index. It decodes requested turns rather than retaining all history entries and projections. A shared body cache keeps at most 4 MiB of serialized source bytes (not a claim about total process RSS); records and requested pages are bounded to 8 MiB. Older messages, parts, images and native receipt evidence remain in the original JSONL and are read by their indexed identities. Oversized records/turns are explicitly unavailable on the phone instead of silently truncated. The summary reader streams records and its metadata cache is bounded.

Late desktop-send confirmation uses the original file incarnation and completed-byte boundary, checks the complete original prompt and rejects reused native IDs. Missing or ambiguous evidence remains unknown. This implementation must still be distinguished from physical-device and real native-window acceptance. See [project improvements](PROJECT-IMPROVEMENTS.md).

## Focused release scope

Reuse passing evidence for unchanged code. The manual device workflow defaults to one API 35 emulator and seven core probes. Repeat or broaden checks for an actual failure or a relevant code/compatibility change. Full multi-API/bilingual sweeps, long physical-device soak and provider demo captures remain recorded follow-ups; they are not silently reintroduced into every iteration. Current acceptance and publication state is in [TODO](../TODO.md).

## 中文

已核对授权与加密传输、敏感存储、日志、请求隔离、文件预览、Claude 子进程、原生单次操作和回执、签名与分发证据。模拟器、合成测试和真机结果分别记录；Mac 未公证预览包、尚未验收的原生首条发送均有明确说明。

build 11 已将 Claude 历史改为流式元数据索引和按轮读取，正文缓存共享原始字节预算；旧消息、附件和原生回执证据留在完整 JSONL。超大单轮明确提示手机无法加载，不静默截断。缓存/请求额度仍不能表述为整个进程的内存上限，真实设备与原生窗口验收另记。

按用户要求，后续默认只进行改动相关检查和一次核心冒烟，不重复完整矩阵；本次维护者明确选择跳过真实发送验收后发布；实际原生验收及指定真机安排作为未验证的后续工作保留。
