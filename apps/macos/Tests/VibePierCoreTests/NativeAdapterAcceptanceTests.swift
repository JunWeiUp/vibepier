import ApplicationServices
import Foundation
import XCTest

@testable import VibeLocalization
@testable import VibePierCore

/// Explicit native acceptance only. Ordinary `swift test` never initializes native Bridges.
/// No daemon, trust store, phone connection, global project registration or arbitrary thread input.
final class NativeAdapterAcceptanceTests: XCTestCase {
    func testReadOnlyModelCatalogs() throws {
        try requireOptIn()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        print("NATIVE_PROBE axTrusted=\(AXIsProcessTrusted())")  // No permission prompt.
        do {
            let rows = try CodexComposer().models(refresh: true)
            print("NATIVE_PROBE provider=codex models=\(rows.count) source=local-cache")
            XCTAssertFalse(rows.isEmpty, "Empty Codex model catalog")
        } catch { XCTFail("Codex model catalog unavailable (details suppressed)") }
        do {
            // Use the configured production reader/helper; never print credentials or responses.
            let catalog = ClaudeModelCatalog()
            let rows = try catalog.entries(cwd: directory.path, refresh: true)
            print("NATIVE_PROBE provider=claude models=\(rows.count) source=model-api")
            XCTAssertFalse(rows.isEmpty, "Empty Claude model catalog")
        } catch {
            XCTFail("Claude production model catalog unavailable (details suppressed)")
        }
    }

    @MainActor
    func testDedicatedNativeLifecycle() async throws {
        try requireOptIn()
        guard ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_LIFECYCLE"] == "1",
            let path = ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_RUN"],
            let provider = ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_PROVIDER"],
            ["codex", "claude"].contains(provider)
        else { throw XCTSkip("Dedicated lifecycle opt-in required") }
        XCTAssertTrue(AXIsProcessTrusted(), "AX permission unavailable in this test process")
        print("NATIVE_LIFECYCLE axTrusted=\(AXIsProcessTrusted()) screenLocked=\(ScreenLock.locked())")
        // Let the production Bridge enforce its normal unlock policy; do not fabricate a test-only blocker.
        guard AXIsProcessTrusted() else { throw NativeAdapterAcceptanceHost.Failure.scope }
        let host = try NativeAdapterAcceptanceHost(runDirectory: URL(fileURLWithPath: path))
        defer { host.stop() }
        try await host.verifyDedicatedLifecycle(provider: provider)
    }

    @MainActor
    func testClaudeNativeApproval() async throws {
        try requireOptIn()
        guard ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_LIFECYCLE"] == "1",
            let path = ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_RUN"]
        else { throw XCTSkip("Native run required") }
        let host = try NativeAdapterAcceptanceHost(runDirectory: URL(fileURLWithPath: path))
        defer { host.stop() }
        try await host.verifyClaudeApproval()
    }

    @MainActor
    func testNativeReplyEvidence() async throws {
        try requireOptIn()
        guard ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_LIFECYCLE"] == "1",
            let path = ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_RUN"]
        else { throw XCTSkip("Native run required") }
        let host = try NativeAdapterAcceptanceHost(runDirectory: URL(fileURLWithPath: path))
        defer { host.stop() }
        try host.verifyCodexReplies()
        try await host.verifyClaudeRepliesAndCleanup()
    }

    @MainActor
    func testNativeApprovalDecisions() async throws {
        try requireOptIn()
        guard ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_LIFECYCLE"] == "1",
            let path = ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_RUN"],
            let phase = ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_DECISION"],
            ["deny", "allow"].contains(phase)
        else { throw XCTSkip("Dedicated decision opt-in required") }
        let host = try NativeAdapterAcceptanceHost(runDirectory: URL(fileURLWithPath: path))
        defer { host.stop() }
        try await host.verifyCodexDecision(allow: phase == "allow")
    }

    @MainActor
    func testHarmlessNativeApproval() async throws {
        try requireOptIn()
        guard ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_LIFECYCLE"] == "1",
            let path = ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_RUN"]
        else {
            throw XCTSkip("Dedicated lifecycle opt-in required")
        }
        let host = try NativeAdapterAcceptanceHost(runDirectory: URL(fileURLWithPath: path))
        defer { host.stop() }
        try await host.verifyHarmlessApproval()
    }

    @MainActor
    func testRegisteredWorkspacePreflight() async throws {
        try requireOptIn()
        guard ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_LIFECYCLE"] == "1",
            let path = ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_RUN"]
        else {
            throw XCTSkip("Dedicated registered workspace required")
        }
        let host = try NativeAdapterAcceptanceHost(runDirectory: URL(fileURLWithPath: path))
        defer { host.stop() }
        for provider in ["codex", "claude"] {
            let reply = try await host.options(provider: provider)
            print("NATIVE_REGISTERED provider=\(provider) options=\(reply["ok"] as? Bool == true)")
            XCTAssertTrue(reply["ok"] as? Bool == true, "Registered native options unavailable")
        }
    }

    @MainActor
    func testFreshWorkspaceCreationPreflight() async throws {
        try requireOptIn()
        let host = try NativeAdapterAcceptanceHost()
        defer { host.stop() }
        for provider in ["codex", "claude"] {
            let reply = try await host.options(provider: provider)
            // Report fixed metadata only; errors/pages may contain private native data.
            print("NATIVE_PROBE provider=\(provider) creationOptionsAvailable=\(reply["ok"] as? Bool == true)")
            let classifications = [
                "session.codex_creation_project_unverified": "project_not_known",
                "session.codex_creation_requires_saved_project": "project_not_saved",
                "provider.not_a_known_claude_code_project": "project_not_known",
            ]
            let category =
                classifications.first { L10n.text($0.key) == reply["error"] as? String }?.value
                ?? (reply["ok"] as? Bool == true ? "available" : "unclassified_native_failure")
            print("NATIVE_PROBE provider=\(provider) creationCategory=\(category)")
            XCTAssertTrue(reply["ok"] as? Bool == true, "Native creation prerequisites blocked; no mutation attempted")
        }
        // This preflight intentionally does not create a native project or send a model turn.
    }

    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set VIBEPIER_NATIVE_ACCEPTANCE=1 for explicit native acceptance")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vibepier-native-\(UUID())")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }
}

/// In-process integration seam for a future phone harness. Not a network server or public RPC.
/// Production discovery plus a fileprivate, fixed dedicated lifecycle; no arbitrary thread operation.
@MainActor
final class NativeAdapterAcceptanceHost {
    enum Failure: Error { case disabled, scope }
    let directory: URL
    let workspace: URL
    private let client = UUID().uuidString
    private let draft = UUID().uuidString
    private let coordinator: AgentSessionCoordinator
    private let retained: Bool
    private let runtimeDirectory: URL

    init(runDirectory: URL? = nil) throws {
        guard ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_ACCEPTANCE"] == "1" else {
            throw Failure.disabled
        }
        retained = runDirectory != nil
        directory =
            runDirectory?.resolvingSymlinksInPath()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("vibepier-native-\(UUID())")
        workspace = directory.appendingPathComponent("workspace")
        runtimeDirectory = URL(fileURLWithPath: "/private/tmp/vpn-" + UUID().uuidString.lowercased())
        if runDirectory != nil {
            guard ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_LIFECYCLE"] == "1",
                directory.lastPathComponent.hasPrefix("native-lifecycle-"),
                let manifest = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any],
                manifest["purpose"] as? String == "dedicated-native-acceptance",
                manifest["workspace"] as? String == workspace.path,
                workspace.resolvingSymlinksInPath().path == workspace.path
            else { throw Failure.scope }
        } else {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        }
        let followups = directory.appendingPathComponent("followups.json")
        try FileManager.default.createDirectory(
            at: runtimeDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        if retained {
            try Data(runtimeDirectory.path.utf8).write(
                to: directory.appendingPathComponent("runtime-path.txt"), options: .atomic)
        }
        try Data("{\"queued-follow-ups\":{}}".utf8).write(to: followups)
        let codex = CodexBridge(
            followUps: CodexFollowUps(file: followups),
            attachments: try CodexAttachments(root: directory.appendingPathComponent("codex-attachments")),
            background: CodexBackgroundSessions(directory: runtimeDirectory))
        // Preserve production project discovery and model authentication. Replies stay in memory.
        let claude = ClaudeBridge(
            settingsFile: directory.appendingPathComponent("claude-settings.json"),
            attachmentRoot: directory.appendingPathComponent("claude-attachments"))
        let a = CurrentV1AgentAdapter(
            provider: "codex", backendKinds: ["desktopAttached"],
            execute: { codex.perform($0, client: $1, completion: $2) },
            stop: { codex.stop($0) }, stopAll: { codex.stopAll() })
        let b = CurrentV1AgentAdapter(
            provider: "claude", backendKinds: ["desktopAttached"],
            execute: { claude.perform($0, client: $1, completion: $2) },
            stop: { claude.stop($0) }, stopAll: { claude.stopAll() })
        // Do not subscribe to global native pages. Explicit replies remain private to this host.
        coordinator = AgentSessionCoordinator(registry: try AgentAdapterRegistry([a, b]))
        _ = coordinator.describe(client: client, requestedVersion: 1, policy: SessionProviderPolicy())
    }

    func options(provider: String) async throws -> [String: Any] {
        let reply = try await call(provider, ["op": "newOptions", "cwd": workspace.path, "draftId": draft])
        return reply
    }

    private func call(_ provider: String, _ request: [String: Any]) async throws -> [String: Any] {
        guard ["codex", "claude"].contains(provider) else {
            throw Failure.scope
        }
        let data = try JSONSerialization.data(withJSONObject: request)
        let reply: Data = await withCheckedContinuation { continuation in
            coordinator.performCurrentV1(data, provider: provider, trustedClient: client) {
                continuation.resume(returning: $0)
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw Failure.scope
        }
        return object
    }

    func stop() {
        coordinator.stopAllObservations()
        if !retained {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: runtimeDirectory)
        }
    }

    /// Fixed lifecycle, no caller-supplied thread or prompt. Invoked only by the dedicated opt-in test.
    fileprivate func verifyDedicatedLifecycle(provider: String) async throws {
        guard retained, ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_LIFECYCLE"] == "1" else {
            throw Failure.scope
        }
        var evidence: [String: Any] = ["provider": provider, "axTrusted": AXIsProcessTrusted()]
        var resumedCreation: [String: Any]?
        if ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_CLAUDE_FOLLOWUP"] == "1" {
            guard provider == "claude",
                let previous = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: directory.appendingPathComponent("claude-evidence.json"))) as? [String: Any],
                let created = previous["create"] as? [String: Any],
                created["ok"] as? Bool == true, created["accepted"] as? Bool == true,
                created["cwd"] as? String == workspace.path,
                previous["send"] == nil
            else { throw Failure.scope }
            resumedCreation = created
            evidence = previous
        }
        var createPhase = "create"
        if let retry = ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_DEFINITIVE_RETRY"] {
            guard ["1", "path-fix"].contains(retry) else { throw Failure.scope }
            guard provider == "codex", !ScreenLock.locked(),
                let previous = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: directory.appendingPathComponent("codex-evidence.json"))) as? [String: Any],
                let failed = previous["create"] as? [String: Any],
                failed["ok"] as? Bool == false, failed["definitive"] as? Bool == true,
                failed["threadId"] == nil, failed["unknown"] as? Bool != true
            else { throw Failure.scope }
            evidence["previousDefinitiveFailure"] = previous
            createPhase = retry == "1" ? "create-after-definitive" : "create-after-path-fix"
        }
        func record(_ phase: String, _ reply: [String: Any]) throws {
            var proof: [String: Any] = ["ok": reply["ok"] as? Bool == true]
            for key in ["accepted", "unknown", "definitive", "submitted", "queued"] {
                if let value = reply[key] as? Bool { proof[key] = value }
            }
            for key in ["threadId", "cwd", "turnId", "nativeTurnId", "nativeMessageId", "turnIdentityKind"] {
                if let value = reply[key] as? String { proof[key] = value }
            }
            let keys = [
                "session.codex_creation_project_unverified", "session.codex_creation_requires_saved_project",
                "provider.not_a_known_claude_code_project", "core.invalid_receipt",
                "provider.claude_send_receipt_missing",
                "session.codex_disconnected_open_codex_on_the_mac_and_retry", "provider.desktop_input_changed",
                "session.the_session_is_not_ready_reopen_it",
                "provider.claude_code_is_working_wait_for_it_to_finish_or_stop_it_first",
                "provider.claude_code_could_not_create_a_new_session", "session.codex_creation_settings_unverified",
            ]
            if reply["error"] != nil {
                let error = reply["error"] as? String ?? ""
                proof["errorCategory"] =
                    keys.first { L10n.text($0) == error }
                    ?? LocalizationCatalog.entries.first(where: { $0.value.contains(error) })?.key
                    ?? [
                        "disabled", "incompatibleVersion", "invalidRequest", "unauthorized", "staleOwner",
                        "unavailable", "timeout", "quotaExceeded", "storageUnavailable", "operationConflict",
                    ].first(where: { $0 == error })
                    ?? "unclassified_native_failure"
            }
            evidence[phase] = proof
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(provider + "-evidence.json"), options: .atomic)
            print("NATIVE_LIFECYCLE provider=\(provider) phase=\(phase) ok=\(reply["ok"] as? Bool == true)")
        }
        func mutation(_ phase: String, fields: [String: Any], page: [String: Any]) async throws -> [String: Any] {
            guard let caps = page["agentCapabilities"] as? [String: Any] else { throw Failure.scope }
            var request = fields
            request["id"] = UUID().uuidString
            request["provider"] = provider
            request["agentCapabilityVersion"] = caps["version"]
            request["agentAdapterId"] = caps["adapterId"]
            request["agentCapabilityRevision"] = caps["revision"]
            guard coordinator.freshMutationFailure(request, client: client) == nil else { throw Failure.scope }
            // O_EXCL creates a durable attempt guard before dispatch, even if the process later times out.
            let marker = directory.appendingPathComponent(provider + "-" + phase + "-attempt")
            let fd = open(marker.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw Failure.scope }
            let markerData = try JSONSerialization.data(withJSONObject: ["operation": request["id"]!, "phase": phase])
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: markerData)
            try handle.synchronize()
            try handle.close()
            return try await call(provider, request)
        }
        let options = try await options(provider: provider)
        try record("options", options)
        guard options["ok"] as? Bool == true else { throw Failure.scope }
        var fields: [String: Any] = [
            "op": "new", "cwd": workspace.path, "draftId": draft,
            "text": "Dedicated VibePier native acceptance. Reply READY only. Do not use tools or modify files.",
        ]
        if let composer = options["composer"] as? [String: Any] {
            for key in ["model", "effort"] { fields[key] = composer[key] }
        }
        fields["mode"] = provider == "codex" ? "auto" : "default"
        let created: [String: Any]
        if let resumedCreation {
            created = resumedCreation
        } else {
            created = try await mutation(createPhase, fields: fields, page: options)
        }
        try record("create", created)
        guard created["ok"] as? Bool == true, created["accepted"] as? Bool == true,
            let thread = created["threadId"] as? String, UUID(uuidString: thread) != nil,
            created["cwd"] as? String == workspace.path,
            !(created["nativeMessageId"] as? String ?? "").isEmpty
        else { throw Failure.scope }
        // Only this freshly returned thread can reach open/send. Poll reads, never repeat a mutation.
        var page: [String: Any] = [:]
        for _ in 0..<40 {
            page = try await call(provider, ["op": "open", "threadId": thread, "viewVersion": 1])
            if page["threadId"] as? String == thread, page["status"] as? String == "idle",
                page["canSend"] as? Bool == true
            {
                break
            }
            try await Task.sleep(for: .seconds(1))
        }
        try record("open", page)
        guard page["threadId"] as? String == thread, page["status"] as? String == "idle",
            page["canSend"] as? Bool == true
        else { throw Failure.scope }
        let sent = try await mutation(
            "send",
            fields: [
                "op": "send", "threadId": thread, "viewVersion": 1,
                "text": "Dedicated VibePier acceptance follow-up. Reply ACK only. Do not use tools or modify files.",
            ], page: page)
        try record("send", sent)
        guard sent["ok"] as? Bool == true, sent["accepted"] as? Bool == true,
            sent["threadId"] as? String == thread,
            !(sent["nativeMessageId"] as? String ?? "").isEmpty
        else { throw Failure.scope }
    }

    /// Submit one new harmless approval trigger only in this run's successfully created Codex session.
    /// Leave a verified pending native request for phone approval testing; never auto-approve it.
    fileprivate func verifyHarmlessApproval() async throws {
        guard retained, AXIsProcessTrusted(),
            let prior = try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("codex-evidence.json"))) as? [String: Any],
            let created = prior["create"] as? [String: Any], created["accepted"] as? Bool == true,
            let thread = created["threadId"] as? String, UUID(uuidString: thread) != nil,
            let priorSend = prior["send"] as? [String: Any], priorSend["accepted"] as? Bool == true,
            priorSend["threadId"] as? String == thread
        else { throw Failure.scope }
        let provider = "codex"
        var page: [String: Any] = [:]
        for _ in 0..<40 {
            page = try await call(provider, ["op": "open", "threadId": thread, "viewVersion": 1])
            if page["threadId"] as? String == thread, page["status"] as? String == "idle",
                page["canSend"] as? Bool == true
            {
                break
            }
            try await Task.sleep(for: .seconds(1))
        }
        guard page["threadId"] as? String == thread, page["status"] as? String == "idle",
            let caps = page["agentCapabilities"] as? [String: Any]
        else { throw Failure.scope }
        let operation = UUID().uuidString
        let request: [String: Any] = [
            "op": "send", "id": operation, "provider": provider,
            "threadId": thread, "viewVersion": 1,
            "agentCapabilityVersion": caps["version"] ?? 1,
            "agentAdapterId": caps["adapterId"] ?? "", "agentCapabilityRevision": caps["revision"] ?? "",
            "text":
                "Dedicated VibePier approval test: request user approval to execute exactly /usr/bin/true using sandbox_permissions=require_escalated and justification 'Harmless VibePier approval test'. Wait for that approval. Do not run another command, write files, use the network, or perform any other action. If escalation is unavailable, explain without running anything.",
        ]
        guard coordinator.freshMutationFailure(request, client: client) == nil else { throw Failure.scope }
        let marker = directory.appendingPathComponent("codex-approval-trigger-attempt")
        let fd = open(marker.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Failure.scope }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(operation.utf8))
        try handle.synchronize()
        try handle.close()
        let reply = try await call(provider, request)
        var evidence: [String: Any] = [
            "threadId": thread, "operation": operation,
            "triggerAccepted": reply["accepted"] as? Bool == true,
            "unknown": reply["unknown"] as? Bool == true, "pendingObserved": false,
        ]
        for key in ["nativeMessageId", "turnId"] { evidence[key] = reply[key] }
        let output = directory.appendingPathComponent("codex-approval-evidence.json")
        func save() throws {
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: output, options: .atomic)
        }
        try save()
        guard reply["ok"] as? Bool == true, reply["accepted"] as? Bool == true,
            reply["threadId"] as? String == thread, reply["turnId"] is String
        else { throw Failure.scope }
        for _ in 0..<60 {
            page = try await call(provider, ["op": "open", "threadId": thread, "viewVersion": 1])
            if page["threadId"] as? String == thread,
                let approvals = page["approvals"] as? [[String: Any]],
                let approval = approvals.first(where: {
                    $0["canDecide"] as? Bool == true && $0["kind"] as? String != "questions"
                }),
                let fingerprint = approval["fingerprint"] as? String, !fingerprint.isEmpty
            {
                evidence["pendingObserved"] = true
                evidence["fingerprint"] = fingerprint
                evidence["approvalId"] = approval["id"]
                evidence["method"] = approval["method"]
                try save()
                print("NATIVE_APPROVAL pendingObserved=true; left pending for phone acceptance")
                return
            }
            if page["status"] as? String == "idle" { break }
            try await Task.sleep(for: .seconds(1))
        }
        evidence["category"] = "native_turn_did_not_expose_pending_approval"
        try save()
        XCTFail("Native pending approval not observed; trigger was not resent")
    }

    fileprivate func verifyCodexDecision(allow: Bool) async throws {
        guard retained, AXIsProcessTrusted(),
            let existing = try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("codex-approval-evidence.json")))
                as? [String: Any],
            let thread = existing["threadId"] as? String, UUID(uuidString: thread) != nil
        else { throw Failure.scope }
        let phase = allow ? "allow" : "deny"
        let output = directory.appendingPathComponent("codex-" + phase + "-evidence.json")
        var proof: [String: Any] = [
            "threadId": thread, "decision": phase, "submitted": false, "resolutionVerified": false,
        ]
        func save() throws {
            try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(
                to: output, options: .atomic)
        }
        func once(_ name: String, operation: String) throws {
            let fd = open(directory.appendingPathComponent(name + "-attempt").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw Failure.scope }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: Data(operation.utf8))
            try handle.synchronize()
            try handle.close()
        }
        func opened() async throws -> [String: Any] {
            for _ in 0..<20 {
                let page = try await call("codex", ["op": "open", "threadId": thread, "viewVersion": 1])
                if page["threadId"] as? String == thread, page["agentCapabilities"] != nil,
                    page["canSend"] as? Bool == true,
                    ["idle", "active"].contains(page["status"] as? String ?? "")
                {
                    return page
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw Failure.scope
        }
        func mutate(_ op: String, fields: [String: Any], page: [String: Any], marker: String) async throws -> [String:
            Any]
        {
            guard let caps = page["agentCapabilities"] as? [String: Any] else { throw Failure.scope }
            let operation = UUID().uuidString
            var request = fields
            request.merge([
                "op": op, "id": operation, "provider": "codex", "threadId": thread, "viewVersion": 1,
                "agentCapabilityVersion": caps["version"] ?? 1, "agentAdapterId": caps["adapterId"] ?? "",
                "agentCapabilityRevision": caps["revision"] ?? "",
            ]) { _, new in new }
            if let failure = coordinator.freshMutationFailure(request, client: client) {
                proof["admissionFailure"] = failure
                try save()
                throw Failure.scope
            }
            try once(marker, operation: operation)
            proof[marker + "Operation"] = operation
            try save()
            return try await call("codex", request)
        }
        var expected = existing
        var markerFile = workspace.appendingPathComponent(
            "approval-allowed-" + UUID().uuidString.lowercased() + ".marker")
        var existingTrigger: String?
        if allow, FileManager.default.fileExists(atPath: output.path) {
            guard let prior = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any],
                prior["triggerAccepted"] as? Bool == true, prior["unknown"] as? Bool == false,
                prior["submitted"] as? Bool == false, let turn = prior["triggerTurnId"] as? String,
                let path = prior["markerFile"] as? String,
                path.hasPrefix(workspace.path + "/approval-allowed-"), path.hasSuffix(".marker"),
                URL(fileURLWithPath: path).deletingLastPathComponent().path == workspace.path
            else { throw Failure.scope }
            existingTrigger = turn
            markerFile = URL(fileURLWithPath: path)
            proof = prior
            proof["priorMatchingFailure"] = prior["category"]
        }
        var page = try await opened()
        if allow {
            guard
                let denial = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: directory.appendingPathComponent("codex-deny-evidence.json")))
                    as? [String: Any],
                denial["resolutionVerified"] as? Bool == true,
                !FileManager.default.fileExists(atPath: markerFile.path)
            else { throw Failure.scope }
            if existingTrigger == nil {
                for _ in 0..<30 {
                    if page["status"] as? String == "idle" { break }
                    try await Task.sleep(for: .seconds(1))
                    page = try await opened()
                }
                guard page["status"] as? String == "idle" else { throw Failure.scope }
            }
            let command = "/usr/bin/touch " + markerFile.path
            proof["markerFile"] = markerFile.path
            let sent: [String: Any]
            if let existingTrigger {
                sent = ["ok": true, "accepted": true, "turnId": existingTrigger]
            } else {
                sent = try await mutate(
                    "send",
                    fields: [
                        "text":
                            "Independent VibePier approval acceptance: request approval using sandbox_permissions=require_escalated to run exactly `\(command)`. Wait for user approval. Once allowed execute that exact command once and reply DONE. Do not run other commands, write other files, access the network, or retry a rejected request."
                    ], page: page, marker: "codex-allow-trigger")
            }
            proof["triggerAccepted"] = sent["accepted"] as? Bool == true
            proof["unknown"] = sent["unknown"] as? Bool == true
            proof["triggerTurnId"] = sent["turnId"]
            try save()
            guard sent["ok"] as? Bool == true, sent["accepted"] as? Bool == true,
                let turn = sent["turnId"] as? String
            else { throw Failure.scope }
            var found: [String: Any]?
            for _ in 0..<45 {
                let state = try CodexConfiguredCreation.freshView(thread).state
                guard state["cwd"] as? String == workspace.path else { throw Failure.scope }
                let approvals = CodexConversation.approvals(state)
                let requests = state["requests"] as? [[String: Any]] ?? []
                for candidate in approvals where candidate["canDecide"] as? Bool == true {
                    guard
                        let native = requests.first(where: { ($0["id"] as? NSObject) == (candidate["id"] as? NSObject) }
                        ),
                        let params = native["params"] as? [String: Any], params["turnId"] as? String == turn,
                        native["method"] as? String == "item/commandExecution/requestApproval",
                        [command, "/bin/zsh -lc '" + command + "'"].contains(
                            (params["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    else { continue }
                    found = [
                        "fingerprint": candidate["fingerprint"] ?? "", "approvalId": candidate["id"] ?? "",
                        "turnId": turn, "method": native["method"] ?? "",
                    ]
                }
                if found != nil { break }
                try await Task.sleep(for: .seconds(1))
            }
            guard let found else {
                proof["category"] = "exact_marker_command_approval_not_found"
                try save()
                throw Failure.scope
            }
            expected = found
            proof["matchedPending"] = found
            try save()
            page = try await opened()
        }
        guard let fingerprint = expected["fingerprint"] as? String, let turn = expected["turnId"] as? String else {
            throw Failure.scope
        }
        let before = try CodexConfiguredCreation.freshView(thread).state
        guard before["cwd"] as? String == workspace.path,
            let approval = CodexConversation.approvals(before).first(where: {
                $0["fingerprint"] as? String == fingerprint
                    && ($0["id"] as? NSObject) == (expected["approvalId"] as? NSObject)
            }),
            approval["canDecide"] as? Bool == true,
            let native = (before["requests"] as? [[String: Any]])?.first(where: {
                ($0["id"] as? NSObject) == (expected["approvalId"] as? NSObject)
            }),
            let params = native["params"] as? [String: Any], params["turnId"] as? String == turn,
            let item = params["itemId"] as? String
        else {
            proof["category"] = "original_approval_identity_changed_or_resolved"
            try save()
            throw Failure.scope
        }
        proof["fingerprint"] = fingerprint
        proof["turnId"] = turn
        proof["itemId"] = item
        proof["approvalId"] = expected["approvalId"]
        let reply = try await mutate(
            "approve", fields: ["fingerprint": fingerprint, "allow": allow], page: page, marker: "codex-" + phase)
        proof["submitted"] = reply["submitted"] as? Bool == true
        proof["unknown"] = reply["unknown"] as? Bool == true
        if let error = reply["error"] as? String {
            proof["errorCategory"] =
                LocalizationCatalog.entries.first(where: { $0.value.contains(error) })?.key
                ?? "unclassified_native_failure"
        }
        try save()
        // Reconcile by native reads even after a rejection/unknown; never dispatch approve again.
        for _ in 0..<35 {
            let state = try CodexConfiguredCreation.freshView(thread).state
            let pending = CodexConversation.approvals(state).contains { $0["fingerprint"] as? String == fingerprint }
            let nativeTurn = CodexConversation.turns(state).first {
                ($0["turnId"] as? String ?? $0["id"] as? String) == turn
            }
            let command = (nativeTurn?["items"] as? [[String: Any]])?.first { $0["id"] as? String == item }
            let status = command?["status"] as? String ?? ""
            proof["pendingRemaining"] = pending
            proof["itemStatus"] = status
            proof["turnStatus"] = nativeTurn?["status"]
            proof["exitCode"] = command?["exitCode"]
            if allow {
                let attributes = try? FileManager.default.attributesOfItem(atPath: markerFile.path)
                let markerMatches =
                    attributes?[.type] as? FileAttributeType == .typeRegular
                    && (attributes?[.size] as? NSNumber)?.intValue == 0
                proof["markerVerified"] = markerMatches
                proof["resolutionVerified"] =
                    !pending && status == "completed" && (command?["exitCode"] as? NSNumber)?.intValue == 0
                    && markerMatches
            } else {
                proof["resolutionVerified"] = !pending && status == "declined"
            }
            try save()
            if proof["resolutionVerified"] as? Bool == true {
                proof["category"] = "native_decision_verified"
                try save()
                print("NATIVE_DECISION phase=\(phase) resolutionVerified=true")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        proof["category"] = "decision_native_evidence_incomplete_no_retry"
        try save()
        XCTFail("Native approval decision unverified; original operation was not resent")
    }

    fileprivate func verifyCodexReplies() throws {
        let prior =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("codex-evidence.json"))) as! [String: Any]
        let created = prior["create"] as! [String: Any]
        let sent = prior["send"] as! [String: Any]
        guard let thread = created["threadId"] as? String,
            let initialTurn = created["nativeTurnId"] as? String, let followupTurn = sent["turnId"] as? String
        else { throw Failure.scope }
        let state = try CodexConfiguredCreation.freshView(thread).state
        guard state["cwd"] as? String == workspace.path else { throw Failure.scope }
        var evidence: [String: Any] = [:]
        for (phase, id, expected) in [("initial", initialTurn, "READY"), ("followup", followupTurn, "ACK")] {
            guard
                let turn = CodexConversation.turns(state).first(where: {
                    ($0["turnId"] as? String ?? $0["id"] as? String) == id
                })
            else { throw Failure.scope }
            let messages = (turn["items"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "agentMessage" }
            let matched = messages.contains {
                ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == expected
            }
            evidence[phase] = [
                "turnId": id, "status": turn["status"] as? String ?? "", "assistantMessages": messages.count,
                "expectedReplyMatched": matched, "hasNativeError": turn["error"] is [String: Any],
            ]
            XCTAssertTrue(matched && turn["status"] as? String == "completed", "Dedicated native reply not verified")
        }
        evidence["pendingApprovals"] = CodexConversation.approvals(state).count
        // Also reconcile approval turns to terminal state without mutating them again.
        for phase in ["deny", "allow"] {
            let file = directory.appendingPathComponent("codex-" + phase + "-evidence.json")
            guard var decision = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                let id = decision["turnId"] as? String
            else { continue }
            let turn = CodexConversation.turns(state).first { ($0["turnId"] as? String ?? $0["id"] as? String) == id }
            decision["finalTurnStatus"] = turn?["status"]
            try JSONSerialization.data(withJSONObject: decision, options: [.prettyPrinted, .sortedKeys]).write(
                to: file, options: .atomic)
        }
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("codex-replies-evidence.json"), options: .atomic)
        print("NATIVE_REPLIES captured dedicated Codex initial/followup identities and terminal statuses")
    }

    fileprivate func verifyClaudeApproval() async throws {
        guard retained, AXIsProcessTrusted(),
            let prior = try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("claude-evidence.json"))) as? [String: Any],
            let created = prior["create"] as? [String: Any], created["accepted"] as? Bool == true,
            let thread = created["threadId"] as? String, UUID(uuidString: thread) != nil
        else { throw Failure.scope }
        var proof: [String: Any] = ["threadId": thread, "pendingObserved": false, "resolutionVerified": false]
        let output = directory.appendingPathComponent("claude-approval-evidence.json")
        func save() throws {
            try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(
                to: output, options: .atomic)
        }
        func mutate(_ op: String, fields: [String: Any], page: [String: Any], marker: String) async throws -> [String:
            Any]
        {
            guard let caps = page["agentCapabilities"] as? [String: Any] else { throw Failure.scope }
            var request = fields
            let operation = UUID().uuidString
            request.merge([
                "op": op, "id": operation, "provider": "claude", "threadId": thread, "viewVersion": 1,
                "agentCapabilityVersion": caps["version"] ?? 1, "agentAdapterId": caps["adapterId"] ?? "",
                "agentCapabilityRevision": caps["revision"] ?? "",
            ]) { _, new in new }
            if let code = coordinator.freshMutationFailure(request, client: client) {
                proof["admissionFailure"] = code
                try save()
                throw Failure.scope
            }
            let fd = open(
                directory.appendingPathComponent(marker + "-attempt").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw Failure.scope }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: Data(operation.utf8))
            try handle.synchronize()
            try handle.close()
            proof[marker + "Operation"] = operation
            try save()
            return try await call("claude", request)
        }
        var page: [String: Any] = [:]
        for _ in 0..<30 {
            page = try await call("claude", ["op": "open", "threadId": thread, "viewVersion": 1])
            if page["status"] as? String == "idle", page["canSend"] as? Bool == true { break }
            try await Task.sleep(for: .seconds(1))
        }
        guard page["status"] as? String == "idle" else {
            proof["category"] = "native_session_busy"
            try save()
            throw Failure.scope
        }
        let sent = try await mutate(
            "send",
            fields: [
                "text":
                    "Dedicated VibePier approval test. Use Bash to run exactly /usr/bin/true, requesting explicit tool permission first and waiting for the user decision. Do not modify files, access the network, run other commands, or retry a rejected request."
            ], page: page, marker: "claude-approval-trigger")
        proof["triggerAccepted"] = sent["accepted"] as? Bool == true
        proof["unknown"] = sent["unknown"] as? Bool == true
        proof["nativeMessageId"] = sent["nativeMessageId"]
        proof["turnId"] = sent["turnId"]
        try save()
        guard sent["ok"] as? Bool == true, sent["accepted"] as? Bool == true,
            let message = sent["nativeMessageId"] as? String
        else { throw Failure.scope }
        for _ in 0..<60 {
            page = try await call("claude", ["op": "open", "threadId": thread, "viewVersion": 1])
            if let rows = page["messages"] as? [[String: Any]],
                rows.contains(where: { $0["id"] as? String == message }),
                let blocker = page["blocker"] as? [String: Any], blocker["code"] as? String == "rateLimit"
            {
                proof["category"] = "native_rate_limit_after_exact_trigger"
                proof["blockerCode"] = "rateLimit"
                proof["pendingRemaining"] = (page["approvals"] as? [Any] ?? []).count
                try save()
                if page["status"] as? String == "active", let active = page["activeTurnId"] as? String,
                    active == sent["turnId"] as? String
                {
                    let stopped = try await mutate(
                        "interrupt", fields: ["expectedTurnId": active], page: page, marker: "claude-approval-interrupt"
                    )
                    proof["interruptAccepted"] = stopped["accepted"] as? Bool == true
                    proof["interruptUnknown"] = stopped["unknown"] as? Bool == true
                    try save()
                }
                XCTFail("Claude approval generation blocked by native rateLimit after this exact trigger; not resent")
                return
            }
            let approvals = page["approvals"] as? [[String: Any]] ?? []
            if approvals.count == 1, let approval = approvals.first, approval["canDecide"] as? Bool == true,
                let fingerprint = approval["fingerprint"] as? String
            {
                proof["pendingObserved"] = true
                proof["fingerprint"] = fingerprint
                proof["approvalId"] = approval["requestId"]
                try save()
                let decided = try await mutate(
                    "approve", fields: ["fingerprint": fingerprint, "allow": false], page: page, marker: "claude-deny")
                proof["submitted"] = decided["submitted"] as? Bool == true
                proof["unknown"] = decided["unknown"] as? Bool == true
                // Production ClaudeBridge only returns submitted after its exact native permission log confirms deny.
                proof["resolutionVerified"] = decided["ok"] as? Bool == true && decided["submitted"] as? Bool == true
                if let error = decided["error"] as? String {
                    proof["errorCategory"] =
                        LocalizationCatalog.entries.first(where: { $0.value.contains(error) })?.key
                        ?? "unclassified_native_failure"
                }
                try save()
                XCTAssertTrue(proof["resolutionVerified"] as? Bool == true, "Claude native denial unverified")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        proof["category"] = "no_decidable_native_approval_within_deadline"
        proof["pendingRemaining"] = (page["approvals"] as? [Any] ?? []).count
        try save()
        XCTFail("Claude native approval not observed; no trigger resend")
    }

    fileprivate func verifyClaudeRepliesAndCleanup() async throws {
        let prior =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("claude-evidence.json"))) as! [String: Any]
        let created = prior["create"] as! [String: Any]
        let sent = prior["send"] as! [String: Any]
        let approvalFile = directory.appendingPathComponent("claude-approval-evidence.json")
        var approval = try JSONSerialization.jsonObject(with: Data(contentsOf: approvalFile)) as! [String: Any]
        guard let thread = created["threadId"] as? String, UUID(uuidString: thread) != nil,
            let firstMessage = created["nativeMessageId"] as? String,
            let followupMessage = sent["nativeMessageId"] as? String,
            let approvalMessage = approval["nativeMessageId"] as? String
        else { throw Failure.scope }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let projects = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let files = projects.map { $0.appendingPathComponent(thread + ".jsonl") }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard files.count == 1 else { throw Failure.scope }
        let file = try FileHandle(forReadingFrom: files[0])
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 8 * 1024 * 1024 else { throw Failure.scope }
        let rows = try bytes.split(separator: 10).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        }
        var evidence: [String: Any] = ["threadId": thread]
        let ids = [firstMessage, followupMessage, approvalMessage]
        let phases = ["initial", "followup", "approvalTrigger"]
        let starts = try ids.map { id -> Int in
            guard
                let i = rows.firstIndex(where: { $0["uuid"] as? String == id && $0["sessionId"] as? String == thread })
            else { throw Failure.scope }
            return i
        }
        guard starts == starts.sorted() else { throw Failure.scope }
        for i in 0..<ids.count {
            let segment = rows[(starts[i] + 1)..<(i + 1 < starts.count ? starts[i + 1] : rows.count)]
            let errors = segment.filter { $0["type"] as? String == "system" && $0["subtype"] as? String == "api_error" }
            let statuses = errors.compactMap { ($0["error"] as? [String: Any])?["status"] as? Int }
            let messages = segment.filter { $0["type"] as? String == "assistant" }
            let normal = messages.filter { $0["isApiErrorMessage"] as? Bool != true && $0["error"] == nil }
            let expected = i == 0 ? "READY" : "ACK"
            let matched =
                i < 2
                && normal.contains {
                    let text = (($0["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [])
                        .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                    return text.trimmingCharacters(in: .whitespacesAndNewlines) == expected
                }
            evidence[phases[i]] = [
                "nativeMessageId": ids[i], "apiHTTPStatuses": statuses,
                "assistantCount": messages.count, "normalAssistantCount": normal.count,
                "expectedReplyMatched": matched,
                "finalApiErrorStatuses": messages.filter { $0["isApiErrorMessage"] as? Bool == true }.compactMap {
                    $0["apiErrorStatus"] as? Int
                },
                "status": matched ? "reply_verified" : statuses.contains(429) ? "native_http_429" : "unverified",
            ]
        }
        var page: [String: Any] = [:]
        for _ in 0..<10 {
            page = try await call("claude", ["op": "open", "threadId": thread, "viewVersion": 1])
            if page["status"] as? String == "idle" { break }
            try await Task.sleep(for: .seconds(1))
        }
        evidence["finalSessionStatus"] = page["status"]
        let remaining = (page["approvals"] as? [Any] ?? []).count
        evidence["pendingApprovals"] = remaining
        approval["finalSessionStatus"] = page["status"]
        approval["pendingRemaining"] = remaining
        approval["interruptVerifiedByIdleState"] =
            approval["interruptAccepted"] as? Bool == true && page["status"] as? String == "idle"
        try JSONSerialization.data(withJSONObject: approval, options: [.prettyPrinted, .sortedKeys]).write(
            to: approvalFile, options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("claude-replies-evidence.json"), options: .atomic)
        XCTAssertTrue(
            page["status"] as? String == "idle" && remaining == 0,
            "Dedicated Claude test work remains active or pending")
        print("NATIVE_CLAUDE_REPLIES captured exact message segments and final cleanup state; no bodies logged")
    }
}
