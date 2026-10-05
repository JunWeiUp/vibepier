import Foundation

/// Creates native metadata once, then submits through a verified owner. The phone
/// uses a persistent background App Server; desktop snapshots remain available for
/// existing desktop-owned conversations and their receipt checks.
enum CodexConfiguredCreation {
    struct Input: Sendable {
        let project: CodexCreationProject
        let settings: Data
        let attachments: Data
        let text: String
        let client: String
        let operation: String
    }
    struct View {
        let owner: String
        let state: [String: Any]
    }
    struct Services {
        let start: ([String: Any]) throws -> [String: Any]
        let open: (String) throws -> Void
        let view: (String) throws -> View
        let send: (String, [String: Any]) throws -> [String: Any]
    }
    final class Observation: @unchecked Sendable {
        private struct Bound: Sendable {
            let thread: CodexThreadBootstrap.Created
            let nativeID: String
            let executionMode: String?
            let serviceTier: String?
            let expectedInput: Data?
        }
        private let lock = NSLock()
        private var bound: Bound?
        private var submitted = false
        func bind(
            _ thread: CodexThreadBootstrap.Created, nativeID: String, executionMode: String? = nil,
            serviceTier: String? = nil, expectedInput: Data? = nil
        ) {
            lock.withLock {
                bound = Bound(
                    thread: thread, nativeID: nativeID, executionMode: executionMode, serviceTier: serviceTier,
                    expectedInput: expectedInput)
            }
        }
        func arm() { lock.withLock { submitted = true } }
        func receipt(view: (String) throws -> View) throws -> [String: Any]? {
            guard let bound = lock.withLock({ submitted ? self.bound : nil }) else { return nil }
            let current = try view(bound.thread.id)
            guard current.state["cwd"] as? String == bound.thread.cwd,
                CodexQuestions.acceptedMessage(current.state, operation: bound.nativeID)
            else { return nil }
            if let expected = bound.expectedInput {
                let matches = CodexConversation.turns(current.state).flatMap { $0["items"] as? [[String: Any]] ?? [] }
                    .filter {
                        $0["type"] as? String == "userMessage"
                            && ($0["clientId"] as? String ?? $0["clientUserMessageId"] as? String) == bound.nativeID
                    }
                guard matches.count == 1,
                    let content = matches[0]["content"] as? [[String: Any]] ?? matches[0]["input"] as? [[String: Any]],
                    Self.canonicalInput(content) == expected
                else { return nil }
            }
            if let tier = bound.serviceTier, CodexComposer.selection(current.state)["serviceTier"] as? String != tier {
                return nil
            }
            var result: [String: Any] = [
                "ok": true, "accepted": true, "threadId": bound.thread.id, "cwd": bound.thread.cwd,
                "nativeMessageId": bound.nativeID,
            ]
            if let mode = bound.executionMode {
                guard let turn = CodexExecutionMode.messageTurn(current.state, messageID: bound.nativeID),
                    CodexExecutionMode.turnSelection(current.state, turnID: turn) == mode
                else { return nil }
                result["executionModeVerified"] = true
                result["effectiveExecutionMode"] = mode
                result["nativeTurnId"] = turn
                result["composer"] = CodexConversation.composer(current.state)
            }
            return result
        }
        func nativeReceipt() throws -> [String: Any]? {
            return try receipt { try CodexConfiguredCreation.freshView($0) }
        }
        static func canonicalInput(_ input: [[String: Any]]) -> Data? {
            let normalized = input.map { row in
                var row = row
                for key in ["text_elements", "textElements"] where (row[key] as? [Any])?.isEmpty == true {
                    row.removeValue(forKey: key)
                }
                if ["image", "localImage"].contains(row["type"] as? String ?? ""), row["detail"] is NSNull {
                    row.removeValue(forKey: "detail")
                }
                return row
            }
            return try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
        }
    }

    /// Raised before any first-turn bytes were sent. The empty native thread may exist; the input definitely was not
    /// submitted, so the phone may edit and start again.
    struct NotSubmitted: Error, CustomStringConvertible {
        let thread: String?
        let cwd: String?
        let reason: String
        var description: String { reason }
    }

    static func run(_ input: Input, services: Services, observation: Observation, arm: () -> Void) throws -> Data {
        let settings = try JSONSerialization.jsonObject(with: input.settings) as? [String: Any] ?? [:]
        let attached = try JSONSerialization.jsonObject(with: input.attachments) as? [String: Any] ?? [:]
        let parameters = try CodexThreadBootstrap.parameters(project: input.project, settings: settings)
        let created: CodexThreadBootstrap.Created
        do {
            created = try CodexThreadBootstrap.verified(
                try services.start(parameters), project: input.project, settings: settings)
        } catch {
            throw NotSubmitted(thread: nil, cwd: nil, reason: String(describing: error))
        }
        let identity = try CodexMessageIdentity(client: input.client, thread: created.id, operation: input.operation)
        let executionMode = (settings["collaborationMode"] as? [String: Any])?["mode"] as? String
        let serviceTier = settings["serviceTier"].map { $0 is NSNull ? "standard" : ($0 as? String ?? "") }
        let text: [[String: Any]] =
            input.text.isEmpty ? [] : [["type": "text", "text": input.text, "text_elements": []]]
        let initialInput = text + (attached["input"] as? [[String: Any]] ?? [])
        var request = settings.filter {
            [
                "model", "effort", "permissions", "approvalPolicy", "approvalsReviewer", "collaborationMode",
                "serviceTier",
            ].contains($0.key)
        }
        request["threadId"] = created.id
        request["clientUserMessageId"] = identity.nativeID
        request["input"] = initialInput
        let current: View
        do {
            guard !initialInput.isEmpty else { throw CLIError(L10n.text("core.invalid_request")) }
            observation.bind(
                created, nativeID: identity.nativeID, executionMode: executionMode, serviceTier: serviceTier,
                expectedInput: Observation.canonicalInput(initialInput))
            try services.open(created.id)
            current = try services.view(created.id)
            guard current.state["cwd"] as? String == created.cwd, emptyHistory(current.state), !current.owner.isEmpty
            else { throw CLIError(L10n.text("session.codex_creation_composer_unverified")) }
        } catch {
            throw NotSubmitted(thread: created.id, cwd: created.cwd, reason: String(describing: error))
        }
        return try UnconfirmedDesktopMutation.attempting {
            observation.arm()
            arm()
            let reply = try services.send(
                current.owner,
                [
                    "conversationId": created.id,
                    "turnStart": [
                        "request": request,
                        "context": [
                            "inheritThreadSettings": true, "attachments": attached["files"] as? [[String: Any]] ?? [],
                        ],
                    ],
                ])
            guard let result = reply["result"] as? [String: Any],
                let response = result["result"] as? [String: Any],
                let turn = response["turn"] as? [String: Any], let turnID = turn["id"] as? String,
                UUID(uuidString: turnID) != nil
            else { throw CLIError(L10n.text("core.invalid_receipt")) }
            var confirmed: [String: Any] = [
                "ok": true, "accepted": true, "threadId": created.id, "cwd": created.cwd,
                "title": String(input.text.prefix(80)), "nativeTurnId": turnID,
                "nativeMessageId": identity.nativeID,
            ]
            // The turn ACK proves the thread and first input. Option readback mismatches are reported, not unknown.
            var warnings: [[String: Any]] = []
            if serviceTier != nil || executionMode != nil {
                let actual = try? services.view(created.id)
                let scoped = actual.flatMap {
                    $0.owner == current.owner && $0.state["cwd"] as? String == created.cwd ? $0 : nil
                }
                if let serviceTier {
                    let observed = scoped.flatMap { CodexComposer.selection($0.state)["serviceTier"] as? String }
                    if observed != serviceTier {
                        warnings.append(
                            ["field": "serviceTier", "requested": serviceTier, "observed": observed ?? "unknown"])
                    }
                }
                if let executionMode {
                    let verified =
                        scoped.map {
                            CodexExecutionMode.selected($0.state) == executionMode
                                && CodexExecutionMode.turnSelection($0.state, turnID: turnID) == executionMode
                        } ?? false
                    confirmed["executionModeVerified"] = verified
                    if verified {
                        confirmed["effectiveExecutionMode"] = executionMode
                    } else {
                        warnings.append(["field": "executionMode", "requested": executionMode])
                    }
                }
                if let scoped { confirmed["composer"] = CodexConversation.composer(scoped.state) }
            }
            if !warnings.isEmpty { confirmed["warnings"] = warnings }
            return try JSONSerialization.data(withJSONObject: confirmed)
        }
    }

    static func emptyHistory(_ state: [String: Any]) -> Bool {
        if let history = (state["turnHistory"] as? [String: Any])?["history"] as? [String: Any] {
            guard let entities = history["entitiesByKey"] as? [String: Any], entities.isEmpty,
                let islands = history["islands"] as? [[String: Any]]
            else { return false }
            return islands.allSatisfy { ($0["entries"] as? [Any])?.isEmpty == true }
        }
        return (state["turns"] as? [Any])?.isEmpty == true
    }

    static func snapshot(_ bytes: Data, thread: String, owner: String) -> View? {
        guard let packet = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            packet["method"] as? String == "thread-stream-state-changed", packet["version"] as? Int == 11,
            packet["sourceClientId"] as? String == owner,
            let params = packet["params"] as? [String: Any], params["hostId"] as? String == "local",
            params["conversationId"] as? String == thread, let change = params["change"] as? [String: Any],
            change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any]
        else { return nil }
        return View(owner: owner, state: state)
    }

    static func freshView(_ thread: String, expectedOwner: String? = nil) throws -> View {
        let ipc = CodexIPC()
        defer { ipc.close() }
        let result = try view(thread, ipc: ipc)
        guard expectedOwner == nil || expectedOwner == result.owner else {
            throw CLIError(L10n.text("session.the_session_view_changed"))
        }
        return result
    }

    /// The desktop may need to launch and load the thread after a deep link; keep rediscovering its owner until the deadline.
    static func awaitDesktopView(_ thread: String, timeout: TimeInterval = 20) throws -> View {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do { return try freshView(thread) } catch {
                guard Date() < deadline else { throw error }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private static func view(_ thread: String, ipc: CodexIPC) throws -> View {
        try ipc.connect()
        for _ in 0..<8 {
            if let discovery = try? ipc.request(
                "thread-owner-discovery", ["hostId": "local", "conversationId": thread], version: 1, timeout: 0.5),
                let owner = discovery["handledByClientId"] as? String, !owner.isEmpty
            {
                try ipc.follow(thread, owner: owner, on: true)
                for _ in 0..<5 {
                    if let bytes = ipc.latestSnapshot(thread), let view = snapshot(bytes, thread: thread, owner: owner)
                    {
                        return view
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw CLIError(L10n.text("session.open_this_session_on_the_mac_then_retry"))
    }
}
