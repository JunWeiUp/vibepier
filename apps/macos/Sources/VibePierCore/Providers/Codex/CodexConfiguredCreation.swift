import AppKit
import Foundation

/// Creates native metadata once, then submits the first message through its verified
/// desktop owner. The short-lived bootstrap process never executes a model turn.
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
        }
        private let lock = NSLock()
        private var bound: Bound?
        private var submitted = false
        func bind(_ thread: CodexThreadBootstrap.Created, nativeID: String, executionMode: String? = nil) {
            lock.withLock { bound = Bound(thread: thread, nativeID: nativeID, executionMode: executionMode) }
        }
        func arm() { lock.withLock { submitted = true } }
        func receipt(view: (String) throws -> View) throws -> [String: Any]? {
            guard let bound = lock.withLock({ submitted ? self.bound : nil }) else { return nil }
            let current = try view(bound.thread.id)
            guard current.state["cwd"] as? String == bound.thread.cwd,
                CodexQuestions.acceptedMessage(current.state, operation: bound.nativeID)
            else { return nil }
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
    }

    static func run(_ input: Input, services: Services, observation: Observation, arm: () -> Void) throws -> Data {
        let settings = try JSONSerialization.jsonObject(with: input.settings) as? [String: Any] ?? [:]
        let attached = try JSONSerialization.jsonObject(with: input.attachments) as? [String: Any] ?? [:]
        let parameters = try CodexThreadBootstrap.parameters(project: input.project, settings: settings)
        return try DesktopMutationScope.run { mutation in
            let started = try mutation.attempt { try services.start(parameters) }
            let created = try CodexThreadBootstrap.verified(started, project: input.project, settings: settings)
            let identity = try CodexMessageIdentity(
                client: input.client, thread: created.id, operation: input.operation)
            let executionMode = (settings["collaborationMode"] as? [String: Any])?["mode"] as? String
            observation.bind(created, nativeID: identity.nativeID, executionMode: executionMode)
            try services.open(created.id)
            let current = try services.view(created.id)
            guard current.state["cwd"] as? String == created.cwd, emptyHistory(current.state), !current.owner.isEmpty
            else {
                throw CLIError(L10n.text("session.codex_creation_composer_unverified"))
            }
            var request = settings.filter {
                ["model", "effort", "permissions", "approvalPolicy", "approvalsReviewer", "collaborationMode"].contains(
                    $0.key)
            }
            let text: [[String: Any]] =
                input.text.isEmpty ? [] : [["type": "text", "text": input.text, "text_elements": []]]
            request["threadId"] = created.id
            request["clientUserMessageId"] = identity.nativeID
            request["input"] = text + (attached["input"] as? [[String: Any]] ?? [])
            guard !(request["input"] as? [[String: Any]] ?? []).isEmpty else {
                throw CLIError(L10n.text("core.invalid_request"))
            }
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
            if let executionMode {
                let actual = try? services.view(created.id)
                guard let actual, actual.owner == current.owner, actual.state["cwd"] as? String == created.cwd,
                    CodexExecutionMode.selected(actual.state) == executionMode,
                    CodexExecutionMode.turnSelection(actual.state, turnID: turnID) == executionMode
                else {
                    confirmed["ok"] = false
                    confirmed["accepted"] = false
                    confirmed["unknown"] = true
                    confirmed["executionModeVerified"] = false
                    return try JSONSerialization.data(withJSONObject: confirmed)
                }
                confirmed["executionModeVerified"] = true
                confirmed["effectiveExecutionMode"] = executionMode
                confirmed["composer"] = CodexConversation.composer(actual.state)
            }
            return try JSONSerialization.data(withJSONObject: confirmed)
        }
    }

    static func perform(_ input: Input, observation: Observation, arm: () -> Void) throws -> Data {
        let ipc = CodexIPC()
        defer { ipc.close() }
        return try run(
            input,
            services: Services(
                start: { parameters in
                    let bootstrap = try CodexStdioRPC(purpose: .creation)
                    defer { bootstrap.close() }
                    let settings = try JSONSerialization.jsonObject(with: input.settings) as? [String: Any] ?? [:]
                    return try CodexThreadBootstrap.startPersisted(
                        parameters: parameters, project: input.project, settings: settings, title: input.text
                    ) { method, params in
                        try bootstrap.request(method, params: params, mutable: true)
                    }
                },
                open: { id in
                    guard let url = URL(string: "codex://threads/" + id),
                        DispatchQueue.main.sync(execute: { NSWorkspace.shared.open(url) })
                    else { throw CLIError(L10n.text("session.could_not_open_codex")) }
                },
                view: { try freshView($0) },
                send: { owner, parameters in
                    try ipc.connect()
                    return try ipc.request("thread-follower-start-turn", parameters, version: 2, target: owner)
                }), observation: observation, arm: arm)
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
