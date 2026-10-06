import AppKit
import Foundation

enum ConversationTaskOpener {
    private final class ReadConfirmation: @unchecked Sendable {
        private let lock = NSLock()
        private var confirmed = false
        func confirm() { lock.withLock { confirmed = true } }
        var value: Bool { lock.withLock { confirmed } }
    }

    static func open(provider: String, id: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard !ScreenLock.locked() else { throw ScreenLock.lockedError }
                    switch provider {
                    case "codex": try showCodex(id)
                    case "claude": try ClaudeDesktop.show(session: id)
                    default: throw CLIError(L10n.text("session.unsupported_task_provider"))
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func showCodex(_ id: String) throws {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        guard UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/\(id)"),
            let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
            let bundle = Bundle(url: appURL)?.bundleIdentifier
        else { throw CLIError(L10n.text("session.the_codex_desktop_app_was_not_found_or_the_session_is_invalid")) }
        let wasUnread = (ConversationActivity.shared.snapshot["sessions"] as? [[String: Any]] ?? []).contains {
            $0["provider"] as? String == "codex" && $0["id"] as? String == id && $0["isUnread"] as? Bool == true
        }
        let read = ReadConfirmation()
        let ipc = CodexIPC()
        ipc.broadcast = { data in
            guard let packet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                packet["method"] as? String == "thread-read-state-changed", packet["version"] as? Int == 3,
                let params = packet["params"] as? [String: Any], params["conversationId"] as? String == id,
                params["hostId"] as? String == "local", params["hasUnreadTurn"] as? Bool == false,
                ConversationActivity.shared.acceptsCodexContext(params)
            else { return }
            read.confirm()
        }
        try ipc.connect()
        defer { ipc.close() }
        var accepted = false
        DispatchQueue.main.sync { accepted = NSWorkspace.shared.open(url) }
        guard accepted else {
            throw CLIError(L10n.text("session.codex_did_not_accept_the_request_to_open_this_session"))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let inFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle
            if inFront && read.value { return }
            if inFront && !wasUnread,
                let reply = try? ipc.request(
                    "thread-owner-discovery", ["hostId": "local", "conversationId": id], version: 1, timeout: 0.5),
                reply["handledByClientId"] is String
            {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CLIError(L10n.text("session.could_not_confirm_that_codex_opened_this_session_check_the_desktop_b"))
    }
}
