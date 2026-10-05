import Foundation

/// Local command routing. Desktop/session operations do not own the dongle or transport lifetime.
/// The fallback runs inside Daemon, where shared runtime state and locking remain private.
enum RuntimeCommands {
    static func handle(
        _ req: [String: Any], runtime: ([String: Any]) async -> [String: Any]
    ) async -> [String: Any] {
        switch req["cmd"] as? String ?? "" {
        case "agent-runtime":
            guard let request = req["request"] as? [String: Any] else {
                return ["ok": false, "code": "invalid_request"]
            }
            let bytes: Data = await withCheckedContinuation { continuation in
                SessionRemote.shared.agentRuntimeCommand(request) { continuation.resume(returning: $0) }
            }
            return (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [
                "ok": false, "code": "invalid_result",
            ]
        case "task-open":
            guard let provider = req["provider"] as? String, let id = req["id"] as? String else {
                return ["ok": false, "error": L10n.text("core.missing_task_session")]
            }
            do {
                try await ConversationActivity.shared.open(provider: provider, id: id)
                return ["ok": true]
            } catch { return ["ok": false, "error": String(describing: error)] }
        case "task-clear-unread":
            guard let keys = req["keys"] as? [String], !keys.isEmpty else {
                return ["ok": false, "error": L10n.text("core.missing_unviewed_tasks")]
            }
            return ["ok": true, "cleared": ConversationActivity.shared.markAllViewed(keys: Set(keys))]
        case "screen-unlock-diagnostics":
            return ScreenLock.diagnostics()
        case "zcode-ax-state":
            let recent: [String: Any] = [
                "recentCreationReads": ZCodeBridge.recentCreationReads(),
                "recentMutations": ZCodeBridge.recentMutations(),
            ]
            do {
                return try ZCodeDesktop.diagnostics().merging(recent.merging(["ok": true]) { _, fresh in fresh }) {
                    _, fresh in fresh
                }
            } catch {
                return recent.merging(["ok": false, "error": String(describing: error)]) { _, fresh in fresh }
            }
        case "zcode-creation-prepare":
            guard let cwd = req["cwd"] as? String, let execution = req["executionMode"] as? String else {
                return ["ok": false, "error": L10n.text("core.invalid_request")]
            }
            do { return try ZCodeDesktop.prepareCreationDiagnostics(cwd: cwd, execution: execution) } catch {
                return ["ok": false, "error": String(describing: error)]
            }
        case "zcode-request":
            // Local diagnostics use the existing owner-only (0600) control socket
            // and the signed app's desktop permissions. Never opened over a network.
            guard var request = req["request"] as? [String: Any],
                let op = request["op"] as? String,
                [
                    "list", "projects", "open", "sync", "history", "parts", "message", "image", "composerOptions",
                    "newOptions", "new", "send", "settings", "interrupt", "receiptCheck",
                ].contains(op)
            else { return ["ok": false, "error": L10n.text("core.invalid_local_zcode_request")] }
            request["id"] = request["id"] ?? UUID().uuidString
            request["viewVersion"] = 1
            let bridge = ZCodeBridge(desktop: ZCodeDesktop.access)
            let client = "local-" + UUID().uuidString
            defer { bridge.stopAll() }
            func perform(_ value: [String: Any]) async -> [String: Any] {
                guard let data = try? JSONSerialization.data(withJSONObject: value) else {
                    return ["ok": false, "error": L10n.text("core.invalid_request")]
                }
                let reply: Data = await withCheckedContinuation { continuation in
                    bridge.perform(data, client: client) { continuation.resume(returning: $0) }
                }
                return (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [
                    "ok": false, "error": L10n.text("core.invalid_receipt"),
                ]
            }
            if !["list", "projects", "newOptions", "new", "open"].contains(op) {
                guard let session = request["threadId"] as? String else {
                    return ["ok": false, "error": L10n.text("core.missing_session_id")]
                }
                let opened = await perform(["op": "open", "threadId": session, "viewVersion": 1])
                guard opened["ok"] as? Bool == true else { return opened }
            }
            return await perform(request)
        case "android-update-publish":
            guard let path = req["path"] as? String, path.hasPrefix("/") else {
                return ["ok": false, "error": L10n.text("updates.invalid_metadata")]
            }
            let error: String? = await withCheckedContinuation { continuation in
                SessionRemote.shared.publishAndroidUpdate(URL(fileURLWithPath: path)) {
                    continuation.resume(returning: $0)
                }
            }
            if let error { return ["ok": false, "error": error] }
            return ["ok": true, "latest": SessionRemote.shared.latestAndroidVersion() ?? [:]]
        case "phone-apk-list":
            return [
                "ok": true,
                "phones": SessionRemote.shared.authorizedPhones().map {
                    ["id": $0.id, "name": $0.name, "installed": SessionRemote.shared.phoneAppVersion($0.id) ?? [:]]
                        as [String: Any]
                }, "latest": SessionRemote.shared.latestAndroidVersion() ?? [:],
            ]
        case "phone-apk-stage", "phone-apk-status", "phone-apk-cancel":
            let phones = SessionRemote.shared.authorizedPhones()
            let device = req["device"] as? String ?? (phones.count == 1 ? phones[0].id : "")
            guard phones.contains(where: { $0.id == device }) else {
                return [
                    "ok": false, "error": L10n.text("core.run_phone_install_list_then_specify_an_authorized_phone_id"),
                ]
            }
            if req["cmd"] as? String == "phone-apk-cancel" {
                SessionRemote.shared.cancelAPK(device)
                return ["ok": true]
            }
            if req["cmd"] as? String == "phone-apk-stage" {
                guard let path = req["path"] as? String, path.hasPrefix("/") else {
                    return ["ok": false, "error": L10n.text("core.provide_an_absolute_path_to_the_apk")]
                }
                let message: String? = await withCheckedContinuation { continuation in
                    SessionRemote.shared.stageAPK(URL(fileURLWithPath: path), device: device) {
                        continuation.resume(returning: $0)
                    }
                }
                if let message { return ["ok": false, "error": message] }
            }
            guard let status = SessionRemote.shared.apkStatus(device) else {
                return ["ok": true, "device": device, "state": L10n.text("core.no_installation_task")]
            }
            return [
                "ok": true, "device": device, "transfer": status.transfer, "name": status.name,
                "size": status.size, "received": status.received, "state": status.state,
                "phase": status.phase.rawValue,
            ]
        default: return await runtime(req)
        }
    }
}
