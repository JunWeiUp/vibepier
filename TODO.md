# VibePier initial release

This checklist records implemented work and follow-ups for the first public preview. The maintainer explicitly chose to skip real sending acceptance and publish; unchecked device/provider items below are deferred, not successful tests.

## Release / 发布

- Source branch: `main`, one consolidated initial commit.
- Release: [v0.1.0-beta.1](https://github.com/JunWeiUp/vibepier/releases/tag/v0.1.0-beta.1), package build 8.
- Distribution and verification: [REGISTRY](docs/REGISTRY.md); boundaries and open findings: [RELEASE-REVIEW](docs/RELEASE-REVIEW.md).
- The release notes record the published artifacts, source commit, checksum verification and CI. Existing passing checks are reused; no expanded emulator or physical-device matrix is required for this preview.

维护者已明确要求跳过真实发送验收并直接发布。下面未勾选的真机、原生发送和长期运行检查作为后续工作保留，不表示已经通过；build 11 源码已修复整段 Claude 历史驻留问题；公开 build 8 不包含这次改动。

Current source build 11 improvements and validation boundaries: [PROJECT-IMPROVEMENTS](docs/PROJECT-IMPROVEMENTS.md). Existing public release artifacts remain unchanged.

## Repository and architecture

- [x] Back up upstream Git history and every tracked/untracked source and resource file; verify hashes and bundle integrity outside the new repository.
- [x] Create an independent workspace with `apps/macos`, `apps/android`, and `services/relay`.
- [x] Group Swift responsibilities and Android feature packages; detach Android test resources from documentation.
- [x] Restore all platform builds and tests after the move and generic session naming changes.
- [x] Split runtime/command orchestration, Android navigation/voice coordination, and conversation presentation responsibilities.
- [x] Separate Go entrypoint, authentication, and relay routing within one module.
- [x] Move review fixtures to review-only builds; exclude test paths and personal tooling from production.

## Authentication, storage, and defaults

- [x] Use one explicit BLE-to-Mac device enrollment for all remote functionality.
- [x] Encrypt/authenticate controls, application metadata, configuration, and microphone transport; reject legacy plaintext controls without downgrade.
- [x] Add signed protocol/capability negotiation, replay tests, per-device routing and immediate revocation behavior. Shared Swift/Android vectors and boundary tests pass; two-phone UDP/relay tests verify key removal/rotation and prompt cleanup without disrupting the other phone. English/Chinese emulator probes verify incompatibility notices, recovery and held-key release across capability changes. Real BLE and full physical-device acceptance remain separate below.
- [x] Move relay credentials into secure platform storage; encrypt sensitive phone caches and disable system backup of private content.
- [x] Keep automatic unlock opt-in, usage tracking off by default, and system confirmation for APK installation. Source guards and 17 isolated Mac policy tests verified; the API 37 emulator APK probe completed system confirmation, normal Play Protect flow, actual installation and persisted success acknowledgment. This does not replace the remaining real-device/API acceptance.
- [x] Remove the personal relay/DNS special case; self-hosted relay only, optional explicit DNS recovery.
- [x] Default AU05 heartbeat to the verified always-on mode; keep experimental behavior clearly identified.
- [x] Complete the scoped code/resource review of secrets/logging, input bounds, input/audio recovery, transport, native receipts and provider work. Evidence and limitations are recorded in [release review](docs/RELEASE-REVIEW.md). This is not an independent security audit. Aggregate Claude history retention was reviewed and remains an open performance finding below; request quotas do not imply bounded total process memory.
- [x] Build 11 indexes Claude metadata and requested turns, bounds the shared body cache, preserves old ID/attachment access and native receipt evidence, and reports oversized turns explicitly. Process RSS and real-device performance remain separate measurements.

## New product identity and migration

- [x] Use the VibePier app/CLI names, new bundle/package IDs, support paths, key namespaces, and launch agent.
- [x] Add non-sensitive settings export/import without copying passwords, device keys, or conversation content.
- [x] User-directed switch: retire the old Mac service/app with a recoverable backup and install the independent VibePier Mac app. Do not retain old protocol compatibility.
- [x] Align English and Simplified Chinese UI resources, errors, permission explanations, and documentation. Android presentation/runtime resources and Mac UI/runtime/providers/hardware/CLI notices are migrated with bilingual tests and catalog checks. Native provider selectors, user content and technical identifiers retain their original form; see [LOCALIZATION.md](docs/LOCALIZATION.md). Real-device language/layout/accessibility acceptance remains in the validation gates below.

## Brand and documentation

- [x] Create editable logo, macOS app/menu icons, Android adaptive/monochrome icons; verify small-size and light/dark rendering. Inspected extracted ICNS 16/32px assets and production menu fixtures; native Android drawable probe verifies 16/32/48/96px, themed monochrome and safe-circle bounds. Synthetic fixture provenance is in assets/brand/previews.
- [x] Generate two original graphite/mint illustrations, a social preview, and launch cover.
- [ ] Capture current supported behavior using sanitized demo projects; distinguish simulation and real-device evidence. Both READMEs show native home/conversation captures with synthetic data and explicit provenance; real provider demo-session captures are deferred with native acceptance.
- [x] Finish provider capability matrix and contributor navigation for the redesigned English/Chinese README; both versions now include original illustrations and complete relay deployment/connect/verify commands.
- [x] Complete AGENTS, DESIGN, CHANGELOG, product specification, architecture, component guidelines, page structure, development, distribution, and deployment documents. Navigation is in [docs/README.md](docs/README.md); revise with later implementation changes.
- [x] Complete contributing, security, privacy, provenance, setup, migration, self-hosting, and compatibility guides.
- [x] Write Chinese launch article, English launch article, and Chinese/English community short posts; do not post them automatically. Drafts and covers are linked in [docs/launch/community-posts.md](docs/launch/community-posts.md).
- [x] Preserve upstream MIT copyright and public provenance; remove private diagnostic history and unsupported claims. LICENSE matches the verified upstream backup byte-for-byte; NOTICE/source material provenance and independent-product wording are present. Published-file checks exclude local diagnostics/configuration; capability claims distinguish implementation from remaining native acceptance.

## Background connection and first phone delivery

- [x] Preserve the Mac connection while Android is backgrounded; share one transport across the Activity and a connected-device foreground service. See [background connection](docs/BACKGROUND-CONNECTION.md).
- [ ] Validate long-running background behavior on the physical device the user later designates; current work is emulator-only. Mi 10 runs Android 13 and meets the updated minimum; retain earlier two-phone evidence as historical results.
- [x] First signed APK installed on both phones: Mi 10 confirmed by ADB, 250 confirmed by system installation receipt and user. Both phones now use the new relay; future installs/debugging prefer authorized Wi-Fi ADB. Full-project release acceptance remains separate.
- [x] Install new Mac app/service, authorize Mi 10, and verify encrypted BLE application state on the real phone.
- [x] Automatically request initial authorization on BLE discovery; confirm only on the Mac and preserve existing enrollment across updates.
- [x] Configure the new self-hosted relay, store credentials securely on Mac/Android, sync setup over approved BLE, and verify both phones online simultaneously through the relay, with direct UDP connectivity. See [connections](docs/CONNECTIONS.md).

## Additional requested controls

- [ ] Accept model/reasoning, approval mode and image/file selection when creating a phone session. Implementation now covers Codex, Claude and ZCode first-turn settings; ZCode attachments remain unsupported. Phone controls, encrypted draft recovery, late receipt cleanup, scoped upload and small/large-type layouts have emulator coverage. Claude inline images have isolated subprocess/transcript coverage; Codex ownership/receipt and ZCode menu identity/selection have synthetic coverage. Actual native-provider acceptance is deferred for this preview; it is not inferred from synthetic tests or APK delivery.
- [x] Move the home Delete button below the voice panel into the fixed bottom dock. Native emulator controls and visual inspection passed; the new APK has not been installed on a physical phone.
- [x] Add cancellable Android relay recovery on default-network changes and stale peer liveness. Encrypted loopback validates a fresh connection, old-worker shutdown and rejection of stale callbacks; the user recovered the separate mobile-carrier outage by toggling mobile data. Updated APK delivery remains pending the designated phone.
- [x] Prevent a blocked file read/provider from exhausting all session requests. Directory/Markdown reads use bounded asynchronous workers and six-second deadlines; fixed provider/account/control/receipt partitions preserve the original aggregate request/memory bounds. Mac build 4 is installed and both relay phones reconnected; synthetic blocked-I/O and bilingual regression tests passed. The old unknown Claude send remains unresolved and was not replayed.

- [x] Add lock/unlock actions to the phone session-list menu; keep explicit unlock persistent, guard in-flight desktop actions, persist mutation receipts, and deploy to Mac + both phones over Wi-Fi ADB. Core/UI tests passed; real lock-screen interaction remains user-operated.

- [x] Add Codex remaining usage, reset time and confirmed gifted-reset cards. Signed build 2 was delivered from the Mac to 250; the user confirmed installation and all three sections in the live panel. Mac companion updated, native account reads and synthetic redemption/unknown-result checks passed; no real reset credit was consumed during testing.

## Validation and release

- [x] Make build/package commands side-effect free; separate installation and migration.
- [x] Add CI for Swift tests/format, Android tests/Lint, Go race/vet, secrets, docs, and shared protocol fixtures. The private pre-release repository has passed the full hosted matrix; repeat it on the final published source as required below. Manual API 33/35/36 emulator checks are also wired separately; their execution is not implied by a green build matrix.
- [x] Resolve format failures and Lint warnings or document narrow justified exceptions.
- [x] Verify clean builds without private paths, caches, signing material, or installed companion software. An isolated public-source snapshot compiled both Mac products and passed 351 tests (11 intentional skips); Android completed 187 fresh tasks, 123 JVM tests and Lint with unsigned release output and a temporary debug key; Go race/vet and both Linux architectures passed. The Go 1.22 test on a newer macOS used the external linker. Personal project/config/cache/key directories and companion app bundles were denied during builds. Final public-clone/hosted-CI validation remains a separate gate below; see [clean-checkout verification](docs/DEVELOPMENT.md#clean-checkout-verification).
- [ ] Verify BLE/Wi-Fi/relay, disconnection/revocation, microphone restore, provider delivery/approvals, and version mismatch behavior on the user-designated physical phone; that device is currently pending. Keep multi-device isolation regression tests and earlier two-phone evidence; no further operation on the second physical phone is required. Codex creation now has single-submit and exact native-receipt logic with isolated tests; verify its actual new-composer/project/execution-mode recognition and delivery before treating that workflow as accepted.
- [x] Finish focused release checks: reuse the completed API 35 suite and unchanged core probes, verify the final new-session label/control change in the local Chinese small-screen/large-type probe, and pass the five-job source CI. API 33 boot failures and other unverified compatibility/accessibility cases remain recorded; full API 33/35/36, both-language, screen-reader and desktop-layout sweeps are deferred unless a concrete regression requires them.
- [x] Reuse the stable Android release key and back it up in the owner's specified private directory outside the repository; verify byte equality and signing recovery from that copy. Produce a signed APK, explicitly unnotarized Mac app/CLI, Linux relay binaries and SHA-256 checksums from a clean candidate checkout. Release packaging includes the APK version/digest sidecar and a checksum manifest; uploaded/downloaded artifacts are verified during publication. The owner-selected backup is on the same Mac, not an off-device disaster-recovery copy. The release page records publication and download verification.
- [x] Prepare optional Developer ID/notarization workflow without using development certificates for public distribution. Script syntax/CLI contract checked; actual Apple submission is not performed or claimed. Scope is the app ZIP; separate CLI remains a preview.

- [x] Prevent image file reads from blocking session queues. Bounded shared preview workers and timeouts are tested; the updated Mac restored the 250 relay session, confirmed by the user. OS folder authorization remains required for protected image paths.
- [x] Add a phone-side Mac application picker with search, shared dock updates and stale/source-change protection. EN/zh/small UI probes and native read-only catalog passed; signed build 3 was delivered to 250 via Mac and reported installed by Android.
