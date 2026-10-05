import AppKit
import ApplicationServices
import CryptoKit
import Foundation

/// Operates the existing desktop task. Never starts a CLI or writes ZCode storage.
/// The native "Copy session ID" action is the final authority before a mutation.
enum ZCodeDesktop {
    static let bundleID = "dev.zcode.app"
    static var access: ZCodeBridge.DesktopAccess {
        .init(
            snapshot: { try snapshot($0) }, execute: { try execute($0, session: $1, cwd: $2, client: $3) },
            prepareSnapshot: { try prepareSnapshot($0) })
    }
    struct Choice: Sendable {
        let id: String
        let title: String
        let label: String
        let ordinal: Int
        let signature: String
        var object: [String: Any] {
            var value: [String: Any] = ["id": id, "name": title, "title": title, "label": title, "efforts": [String]()]
            if id == "yolo" {
                value["requiresConfirmation"] = true
                value["confirmationText"] = L10n.text(
                    "provider.full_access_lets_zcode_reduce_confirmations_for_file_changes_and_command_exe")
            }
            return value
        }
    }
    private static let cache = Cache()
    private static let ownership = VerifiedOwner<DesktopAXTraversal.Identity>()
    struct OwnerScope<Window: Equatable>: Equatable {
        let session: String
        let pid: Int32
        let launched: Date
        let window: Window
    }
    /// Pure cache: production binds only after the native Copy session ID result was verified.
    final class VerifiedOwner<Window: Equatable>: @unchecked Sendable {
        private let lock = NSLock()
        private var scope: OwnerScope<Window>?
        private var epoch: String?
        func bind(_ next: OwnerScope<Window>) -> String? {
            lock.withLock {
                guard Self.valid(next) else {
                    scope = nil
                    epoch = nil
                    return nil
                }
                if scope != next {
                    scope = next
                    epoch = UUID().uuidString.lowercased()
                }
                return epoch
            }
        }
        func current(_ observed: OwnerScope<Window>) -> String? {
            lock.withLock {
                guard Self.valid(observed), let verified = scope else { return nil }
                guard verified.pid == observed.pid, verified.launched == observed.launched,
                    verified.window == observed.window
                else {
                    scope = nil
                    epoch = nil
                    return nil
                }
                return verified.session == observed.session ? epoch : nil
            }
        }
        func invalidate() {
            lock.withLock {
                scope = nil
                epoch = nil
            }
        }
        private static func valid(_ value: OwnerScope<Window>) -> Bool {
            ZCodeDesktop.nativeID(value.session) != nil && value.pid > 0
                && value.launched.timeIntervalSince1970.isFinite && value.launched.timeIntervalSince1970 > 0
        }
    }
    static let modeLabels = ["plan": "计划模式", "build": "变更前确认", "edit": "自动编辑", "yolo": "完全访问"]
    /// Permission choices need known semantics; an opaque ordinal must never bypass full-access confirmation.
    static func nativeModeIDs(_ labels: [String]) throws -> [String] {
        let ids = try labels.map { label in
            let matches = modeLabels.filter { label.hasPrefix($0.value) }
            guard matches.count == 1, let id = matches.first?.key else {
                throw CLIError(L10n.text("provider.zcode_unrecognized_permission_choices"))
            }
            return id
        }
        guard !ids.isEmpty, Set(ids).count == ids.count else {
            throw CLIError(L10n.text("provider.zcode_unrecognized_permission_choices"))
        }
        return ids
    }
    static func draftIsEmpty(_ value: String) -> Bool {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").isEmpty
    }
    static func nativeID(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("sess_"), UUID(uuidString: String(text.dropFirst(5))) != nil else { return nil }
        return text
    }
    static func menuSignature(_ labels: [String]) -> String {
        SHA256.hash(data: Data(labels.joined(separator: "\u{0}").utf8)).prefix(12).map { String(format: "%02x", $0) }
            .joined()
    }
    static func confirmation(before: String?, userID: String, observed: String, expected: String) -> Bool {
        !userID.isEmpty && userID != before && observed == expected
    }
    static func nativeProviderOnly(_ providers: [String]) -> Bool { !providers.isEmpty && Set(providers) == ["glm"] }
    static func navigationSearch(label: String, placeholder: String) -> Bool {
        let prompts = ["搜索操作、任务或文件", "Search actions, tasks or files", "Search actions, tasks, or files"]
        return prompts.contains(placeholder) || prompts.contains(label)
    }
    static func composerPlaceholder(_ placeholder: String) -> Bool {
        ["提出后续修改要求", "向 ZCode 提问", "Ask ZCode", "Request follow-up changes"].contains(where: {
            placeholder.hasPrefix($0)
        })
    }
    static func projectSearch(label: String, placeholder: String) -> Bool {
        let prompts = ["搜索工作区", "Search workspaces", "Search workspace"]
        return prompts.contains(placeholder) || prompts.contains(label)
    }
    static func nativePopup(
        role: String, focusedMenuItem: Bool, selectedOption: Bool, searchField: Bool, focusedMenu: Bool = false
    ) -> Bool {
        if role == "AXMenu" { return searchField || focusedMenu || focusedMenuItem }
        if role == "AXList" { return focusedMenuItem && selectedOption }
        return false
    }
    static func selectableOption(kind: String, popupRole: String, hasValue: Bool, hasSelected: Bool) -> Bool {
        if kind == "model" || kind == "mode" { return hasValue }
        if kind == "effort" { return popupRole == "AXList" ? hasSelected : hasValue }
        return false
    }
    struct ProjectBinding: Equatable {
        let query: String
        let paths: [String]
        let labels: [String]
        let targetIndex: Int
    }
    /// The native picker searches full tab paths but renders only basenames and
    /// the first five matches. Bind those visible names back to the read-only
    /// native tab list; duplicate names or a hidden target cannot authorize it.
    static func projectBinding(cwd: String, workspaces: [[String: Any]]) -> ProjectBinding? {
        guard cwd.hasPrefix("/"), cwd != "/", cwd == cwd.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let query = cwd.lowercased()
        let matches = workspaces.filter { workspace in
            guard workspace["workspacePurpose"] as? String != "conversation",
                let path = workspace["workspacePath"] as? String, !path.isEmpty
            else { return false }
            let name = URL(fileURLWithPath: path).lastPathComponent
            return [name, workspace["label"] as? String ?? "", path, workspace["workspaceIdentity"] as? String ?? ""]
                .joined(separator: " ").lowercased().contains(query)
        }
        let target = matches.enumerated().filter { $0.element["workspacePath"] as? String == cwd }
        guard target.count == 1, let index = target.first?.offset, index < 5,
            matches.allSatisfy({
                $0["kind"] as? String == "local" && $0["workspaceIdentity"] == nil && $0["remoteSessionId"] == nil
                    && $0["remoteTarget"] == nil
            })
        else { return nil }
        let names = matches.compactMap {
            ($0["workspacePath"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        let name = names[index]
        guard !name.isEmpty, names.filter({ $0 == name }).count == 1 else { return nil }
        let visible = Array(matches.prefix(5))
        return ProjectBinding(
            query: cwd, paths: visible.compactMap { $0["workspacePath"] as? String }, labels: Array(names.prefix(5)),
            targetIndex: index)
    }
    struct StableResults {
        private var since: TimeInterval?
        mutating func reset() { since = nil }
        mutating func observe(
            query: String, expectedQuery: String, labels: [String], expectedLabels: [String], at: TimeInterval
        ) -> Bool {
            guard query == expectedQuery, labels == expectedLabels else {
                since = nil
                return false
            }
            if since == nil { since = at }
            return at - (since ?? at) >= 0.5
        }
    }
    private static func desktopSettings() -> [String: Any] {
        cache.desktopSettings(
            at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode/v2/setting.json"))
    }
    private static func activeDirectory() -> String? {
        let settings = desktopSettings()
        let workspaces = settings["lastWorkspaceSession"] as? [[String: Any]] ?? []
        guard let index = settings["lastActiveTabIndex"] as? Int, workspaces.indices.contains(index),
            workspaces[index]["kind"] as? String == "local"
        else { return nil }
        return workspaces[index]["workspacePath"] as? String
    }
    private static var supportsNew: Bool {
        nativeProviderOnly(desktopSettings()["enabledBuiltinAgentCliProviders"] as? [String] ?? [])
    }
    private static func user(_ store: ZCodeSessionStore, _ session: String) throws -> (id: String, text: String)? {
        try store.nativeUser(session)
    }
    private static func baseComposer(_ summary: [String: Any]) -> [String: Any] {
        let selection = summary["selection"] as? [String: Any] ?? [:]
        return [
            "model": selection["model"] as? String ?? "", "effort": selection["thoughtLevel"] as? String ?? "",
            "mode": selection["mode"] as? String ?? "", "canSend": false,
        ]
    }
    /// Owner-only diagnostic surface. Reads the same AX attributes used by the
    /// adapter without typing, navigating, copying IDs, or exposing draft text.
    static func diagnostics() throws -> [String: Any] {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        return try ScreenLock.unlocked {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                return ["running": false, "trusted": AXIsProcessTrusted()]
            }
            let previous = NSWorkspace.shared.frontmostApplication
            let app = AXUIElementCreateApplication(running.processIdentifier)
            let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            running.activate()
            defer { if frontmost(app), previous?.bundleIdentifier != bundleID { previous?.activate() } }
            let activated = wait(3, { frontmost(app) })
            let focused = elementAttribute(app, kAXFocusedWindowAttribute)
            let focusedElement = elementAttribute(app, kAXFocusedUIElementAttribute)
            func identity(_ node: AXUIElement) -> [String: Any] {
                let own =
                    [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(node, $0) as? String }.first {
                        !$0.isEmpty
                    } ?? ""
                // Editable values and descendant text are never diagnostic labels.
                return [
                    "role": role(node), "label": own,
                    "placeholder": attribute(node, "AXPlaceholderValue") as? String ?? "",
                    "subrole": attribute(node, kAXSubroleAttribute) as? String ?? "",
                    "axFocused": attribute(node, kAXFocusedAttribute) as? Bool ?? false,
                ]
            }
            var focusDetails: [String: Any] = [:]
            if let focusedElement {
                focusDetails = identity(focusedElement)
                var parents: [[String: Any]] = []
                var parent = elementAttribute(focusedElement, kAXParentAttribute)
                for _ in 0..<6 {
                    guard let node = parent else { break }
                    parents.append(identity(node))
                    parent = elementAttribute(node, kAXParentAttribute)
                }
                focusDetails["parents"] = parents
            }
            let root = focused ?? app
            var nodes: [(node: AXUIElement, parent: Int)] = [(root, -1)]
            var index = 0
            var records: [[String: Any]] = []
            var roles: [String: Int] = [:]
            let wanted = Set(["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXPopUpButton", "AXHeading"])
            while index < nodes.count && index < 12_000 {
                let current = nodes[index]
                let node = current.node
                let kind = role(node)
                roles[kind, default: 0] += 1
                let own =
                    [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(node, $0) as? String }.first {
                        !$0.isEmpty
                    } ?? ""
                let isText = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(kind)
                // Do not derive editable labels from text children: those can be a user's draft.
                let display = isText ? own : label(node)
                let action = kind == "AXButton" && ["更多", "More", "发送", "Send", "停止", "停止生成", "Stop"].contains(display)
                if wanted.contains(kind) || action {
                    var record: [String: Any] = [
                        "index": index, "parentIndex": current.parent, "role": kind,
                        "label": display, "enabled": enabled(node),
                        "subrole": attribute(node, kAXSubroleAttribute) as? String ?? "",
                        "placeholder": attribute(node, "AXPlaceholderValue") as? String ?? "",
                    ]
                    if isText {
                        record["axFocused"] = attribute(node, kAXFocusedAttribute) as? Bool ?? false
                        record["containsFocusedElement"] = focusedElement.map { contains(node, $0) } ?? false
                        let raw = attribute(node, kAXValueAttribute)
                        record["valuePresent"] = raw != nil
                        if let text = raw as? String {
                            record["valueLength"] = text.count
                            record["empty"] = draftIsEmpty(text)
                        }
                        if let raw { record["valueType"] = String(describing: type(of: raw)) }
                        var names: CFArray?
                        if AXUIElementCopyAttributeNames(node, &names) == .success {
                            record["attributeNames"] = names as? [String] ?? []
                        }
                    } else if kind == "AXHeading" {
                        let raw = attribute(node, kAXValueAttribute)
                        if let number = raw as? NSNumber { record["headingLevel"] = number.intValue }
                        if let raw { record["valueType"] = String(describing: type(of: raw)) }
                    }
                    if let raw = attribute(node, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
                        var position = CGPoint.zero
                        if AXValueGetValue(raw as! AXValue, .cgPoint, &position), position.x.isFinite,
                            position.y.isFinite
                        {
                            record["position"] = [Double(position.x), Double(position.y)]
                        }
                    }
                    records.append(record)
                }
                let parent = index
                index += 1
                nodes += (attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { ($0, parent) }
            }
            let candidates = composerFields(app)
            let searchMatches = records.filter {
                ["AXComboBox", "AXTextField", "AXSearchField"].contains($0["role"] as? String ?? "")
                    && navigationSearch(
                        label: $0["label"] as? String ?? "", placeholder: $0["placeholder"] as? String ?? "")
            }.count
            return [
                "running": true, "trusted": AXIsProcessTrusted(), "pid": Int(running.processIdentifier),
                "activated": activated, "frontmost": frontmost(app), "manualAccessibilityResult": Int(manual.rawValue),
                "hasFocusedWindow": focused != nil, "rootRole": role(root), "nodesSeen": index,
                "focusedUIElement": focusDetails,
                "truncated": index < nodes.count, "roleCounts": roles, "controls": records,
                "composerCandidateCount": candidates.count, "searchDialogMatches": searchMatches,
                "composerScopeFound": composerScope(app) != nil, "modelButtonFound": modelButton(app) != nil,
                "sendButtonFound": sendButton(app) != nil, "stopButtonFound": stopButton(app) != nil,
                "visibleMenuCount": visibleMenus(app).count, "activeDirectory": activeDirectory() ?? "",
            ]
        }
    }
    static func snapshot(_ session: String) throws -> [String: Any] {
        let store = ZCodeSessionStore()
        let summary = session.isEmpty ? [:] : try store.summary(session)
        var entry = cache.entry(session)
        let now = ProcessInfo.processInfo.systemUptime
        let available =
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil
            && AXIsProcessTrusted()
        let indexed = session.isEmpty || summary["selection"] as? [String: Any] != nil
        entry.composer = baseComposer(summary).merging(entry.composer) { _, cached in cached }
        var busy = summary["status"] as? String == "running"
        // Opening or subscribing does not activate ZCode, navigate, open menus, or copy IDs.
        if available, cache.isCurrent(session), now - entry.observed > 0.8,
            let app = application(), visibleTitle(app) == entry.title, let field = composer(app)
        {
            entry.composer.merge(readControls(app)) { _, fresh in fresh }
            busy = stopButton(app) != nil
            entry.draftEmpty = draftIsEmpty(value(field))
            entry.composer["canSend"] = !busy && entry.draftEmpty == true
            entry.observed = now
            cache.put(entry, id: session)
        } else if let app = application(), cache.isCurrent(session), visibleTitle(app) == entry.title {
            busy = stopButton(app) != nil
        }
        let flags: [String: Bool] = [
            "send": available && indexed, "new": available && supportsNew, "interrupt": available && indexed,
            "settings": available && indexed, "modelSelection": available && indexed,
            "permissionMode": available && indexed,
            "attachments": false, "approvals": false, "queue": false,
        ]
        let effortIDs = entry.efforts.map(\.id)
        let currentModel = entry.composer["model"] as? String ?? ""
        var models = entry.models.map { choice -> [String: Any] in
            var object = choice.object
            if choice.id == currentModel { object["efforts"] = effortIDs }
            return object
        }
        if !currentModel.isEmpty, !models.contains(where: { $0["id"] as? String == currentModel }) {
            models.insert(
                [
                    "id": currentModel, "name": entry.composer["modelLabel"] as? String ?? currentModel,
                    "efforts": effortIDs,
                ], at: 0)
        }
        var result: [String: Any] = [
            "capabilities": flags, "composer": entry.composer, "models": models,
            "permissionModes": entry.modes.map(\.object), "efforts": entry.efforts.map(\.object),
            "status": busy ? "running" : "idle",
            "canSend": available && indexed && !session.isEmpty && !busy && entry.draftEmpty != false,
            "readOnlyReason": available && indexed
                ? "" : L10n.text("provider.open_zcode_desktop_and_grant_vibepier_accessibility_permission_first"),
        ]
        if busy, let anchor = try? store.window(session, count: 1).turns.last?.userID {
            result["activeTurnId"] = anchor
        }
        if let app = application(), let owner = ownerScope(app, session: session) {
            let epoch = ownership.current(owner)
            if entry.verified, cache.isCurrent(session), visibleTitle(app) == entry.title,
                composer(app) != nil, let epoch
            {
                result["nativeOwnerEpoch"] = epoch
            }
        } else {
            ownership.invalidate()
        }
        return result
    }

    /// A fresh action may verify an already visible task; this does not activate, navigate or enter input.
    static func prepareSnapshot(_ session: String) throws -> [String: Any] {
        let summary = try ZCodeSessionStore().summary(session)
        guard !ScreenLock.locked(), AXIsProcessTrusted(), let app = application(), frontmost(app),
            visibleTitle(app) == summary["title"] as? String, composer(app) != nil,
            let before = ownerScope(app, session: session)
        else { return try snapshot(session) }
        if cache.isCurrent(session), cache.entry(session).verified, ownership.current(before) != nil {
            return try snapshot(session)
        }
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        guard frontmost(app), try copiedSessionID(app) == session,
            ownerScope(app, session: session) == before,
            visibleTitle(app) == summary["title"] as? String, composer(app) != nil
        else {
            ownership.invalidate()
            throw CLIError(L10n.text("provider.the_current_native_zcode_session_id_does_not_match_no_action_was_taken"))
        }
        _ = remember(app, session, summary["title"] as? String ?? "")
        return try snapshot(session)
    }

    private static func ownerScope(_ app: AXUIElement, session: String) -> OwnerScope<DesktopAXTraversal.Identity>? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, pid > 0,
            let running = NSRunningApplication(processIdentifier: pid), running.bundleIdentifier == bundleID,
            let launched = running.launchDate, launched.timeIntervalSince1970.isFinite,
            launched.timeIntervalSince1970 > 0
        else { return nil }
        let nativeWindow: AXUIElement
        if let focused = elementAttribute(app, kAXFocusedWindowAttribute), role(focused) == "AXWindow" {
            nativeWindow = focused
        } else {
            guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement], windows.count == 1,
                role(windows[0]) == "AXWindow"
            else { return nil }
            nativeWindow = windows[0]
        }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(nativeWindow, &windowPID) == .success, windowPID == pid else { return nil }
        return OwnerScope(session: session, pid: pid, launched: launched, window: .init(element: nativeWindow))
    }

    /// Navigate only; reveal verifies the copied native ID before reporting success.
    static func show(session: String) throws {
        guard !ScreenLock.locked() else { throw ScreenLock.lockedError }
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        let summary = try ZCodeSessionStore().summary(session)
        _ = try reveal(session, summary: summary)
    }

    static func receiptKey(client: String, session: String, operation: String) -> String {
        [client, session, operation].map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func execute(_ request: [String: Any], session: String, cwd: String, client: String) throws -> [String: Any]
    {
        let op = request["op"] as? String ?? ""
        let receiptKey = receiptKey(
            client: client, session: session,
            operation: request["operation"] as? String ?? request["id"] as? String ?? "")
        if op == "receiptCheck" {
            let nativeSession = cache.receipt(receiptKey)?["sessionId"] as? String ?? session
            let store = ZCodeSessionStore()
            if let pending = cache.pendingSubmission(receiptKey),
                pending.creationCwd == nil
                    || (try? store.summary(nativeSession)["cwd"] as? String) == pending.creationCwd,
                let latest = try? store.nativeUser(nativeSession, first: true, after: pending.before),
                confirmation(before: pending.before, userID: latest.id, observed: latest.text, expected: pending.text)
            {
                var result: [String: Any] = [
                    "accepted": true, "sessionId": nativeSession, "threadId": nativeSession, "messageId": latest.id,
                    "nativeMessageId": latest.id,
                ]
                if let cwd = pending.creationCwd { result["cwd"] = cwd }
                try cache.record(receiptKey, result)
                return result
            }
            return cache.receipt(receiptKey) ?? ["accepted": false, "unknown": true]
        }
        guard ["send", "new", "newOptions", "interrupt", "settings", "composerOptions"].contains(op) else {
            throw CLIError(L10n.text("provider.this_feature_is_not_yet_connected_to_native_zcode_desktop_sessions"))
        }
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        return try ScreenLock.unlocked {
            if op == "newOptions" { return try newOptions(request, cwd: cwd, client: client) }
            if op == "new" { return try createNew(request, cwd: cwd, receiptKey: receiptKey, client: client) }
            let store = ZCodeSessionStore()
            let summary = try store.summary(session)
            guard cwd.isEmpty || summary["cwd"] as? String == cwd else {
                throw CLIError(L10n.text("provider.the_zcode_session_project_changed_no_action_was_taken"))
            }
            let previous = NSWorkspace.shared.frontmostApplication
            let app = try reveal(session, summary: summary)
            defer { if frontmost(app), previous?.bundleIdentifier != bundleID { previous?.activate() } }
            if ["send", "settings", "interrupt"].contains(op), let expected = request["nativeOwnerEpoch"] {
                guard let expected = expected as? String, !expected.isEmpty,
                    let current = ownerScope(app, session: session), ownership.current(current) == expected
                else {
                    throw CLIError(
                        L10n.text("provider.the_current_native_zcode_session_id_does_not_match_no_action_was_taken"))
                }
            }
            switch op {
            case "composerOptions":
                return try options(app, session: session, summary: summary)
            case "settings":
                let result = try settings(request, app: app, session: session)
                return result
            case "interrupt":
                try verify(app, session)
                guard let expected = request["expectedTurnId"] as? String, let current = try user(store, session)?.id,
                    expected == current
                else {
                    throw CLIError(L10n.text("provider.the_running_zcode_turn_changed_no_stop_action_was_sent"))
                }
                guard let button = stopButton(app) else {
                    throw CLIError(L10n.text("provider.this_zcode_session_has_no_task_that_can_currently_be_stopped"))
                }
                return try UnconfirmedDesktopMutation.attempting {
                    try press(button, app: app)
                    guard
                        wait(
                            3,
                            {
                                frontmost(app) && visibleTitle(app) == summary["title"] as? String
                                    && composer(app) != nil && stopButton(app) == nil
                            })
                    else {
                        throw CLIError(
                            L10n.text("provider.stop_was_pressed_but_the_native_task_has_not_been_confirmed_as_ended"))
                    }
                    try verify(app, session)
                    guard try user(store, session)?.id == expected else {
                        throw CLIError(L10n.text("provider.the_running_zcode_turn_changed_no_stop_action_was_sent"))
                    }
                    return ["accepted": true, "interrupted": true]
                }
            default:
                let text = request["text"] as? String ?? ""
                guard !text.isEmpty, text.utf8.count <= 120_000 else {
                    throw CLIError(L10n.text("provider.the_message_is_empty_or_too_long"))
                }
                if let receipt = cache.receipt(receiptKey) { return receipt }
                guard request["attachments"] as? [Any] == nil || (request["attachments"] as? [Any])?.isEmpty == true
                else {
                    throw CLIError(
                        L10n.text("provider.zcode_desktop_attachments_are_not_yet_supported_nothing_was_sent"))
                }
                guard stopButton(app) == nil, let field = composer(app) else {
                    throw CLIError(
                        L10n.text("provider.zcode_is_running_or_its_composer_is_not_ready_retry_when_it_is_ready"))
                }
                guard draftIsEmpty(value(field)) else {
                    throw CLIError(L10n.text("provider.zcode_desktop_has_an_existing_draft_nothing_was_sent"))
                }
                let before = try user(store, session)?.id
                try verify(app, session)
                guard let freshField = composer(app), draftIsEmpty(value(freshField)), stopButton(app) == nil else {
                    throw CLIError(L10n.text("provider.zcode_desktop_input_state_changed_nothing_was_sent"))
                }
                try paste(text, into: freshField, app: app)
                guard frontmost(app), visibleTitle(app) == summary["title"] as? String else {
                    throw CLIError(L10n.text("provider.zcode_lost_focus_the_content_remains_in_the_desktop_draft"))
                }
                // Copying the native ID does not touch the draft; recheck immediately before Send.
                try verify(app, session)
                guard let send = sendButton(app), enabled(send), let finalField = composer(app),
                    sameDraft(value(finalField), text)
                else {
                    throw CLIError(
                        L10n.text(
                            "provider.the_native_zcode_send_button_and_draft_could_not_be_verified_the_content_rem"))
                }
                var receipt: [String: Any] = ["accepted": false, "unknown": true, "sessionId": session]
                // a lost acknowledgement must never automatically submit again
                try cache.record(receiptKey, receipt, before: before, text: text)
                try UnconfirmedDesktopMutation.attempting { try press(send, app: app) }
                var nativeMessage: String?
                let confirmed = wait(5) {
                    guard let latest = try? store.nativeUser(session, first: true, after: before),
                        confirmation(before: before, userID: latest.id, observed: latest.text, expected: text)
                    else { return false }
                    nativeMessage = latest.id
                    return true
                }
                if confirmed, let nativeMessage {
                    receipt = [
                        "accepted": true, "sessionId": session, "messageId": nativeMessage,
                        "nativeMessageId": nativeMessage,
                    ]
                    try cache.record(receiptKey, receipt)
                }
                return receipt
            }
        }
    }

    private static func createNew(_ request: [String: Any], cwd: String, receiptKey: String, client: String) throws
        -> [String: Any]
    {
        if let receipt = cache.receipt(receiptKey) { return receipt }
        let text = request["text"] as? String ?? ""
        guard !text.isEmpty, text.utf8.count <= 120_000
        else {
            throw CLIError(
                L10n.text("provider.open_a_local_project_in_the_native_zcode_agent_before_retrying_session_creat"))
        }
        guard (request["attachments"] as? [Any] ?? []).isEmpty else {
            throw CLIError(L10n.text("provider.attachments_for_new_zcode_sessions_are_not_yet_supported"))
        }
        return try withNewDraft(cwd: cwd) { app, _, priorIDs in
            if ["draftId", "model", "mode", "effort"].contains(where: { request[$0] != nil }) {
                let draft = try SessionCreationDraft(request, project: cwd, provider: "zcode")
                let key = Self.receiptKey(client: client, session: draft.scope, operation: "creation-options")
                let previous = cache.entry(key)
                let current = try readOptions(app, entry: Entry())
                _ = try creationSelection(request, previous: choices(previous), current: choices(current))
                cache.put(current, id: key)
                _ = try settings(request, app: app, session: key, verifyTarget: { try verifyNewDraft(app, cwd: cwd) })
            }
            try verifyNewDraft(app, cwd: cwd)
            let selection = readControls(app)
            guard let fresh = composer(app) else {
                throw CLIError(
                    L10n.text("provider.native_settings_for_the_new_zcode_task_are_unconfirmed_nothing_was_sent"))
            }
            try paste(text, into: fresh, app: app)
            guard frontmost(app), supportsNew, activeDirectory() == cwd, visibleTitle(app).isEmpty,
                NSDictionary(dictionary: readControls(app)).isEqual(NSDictionary(dictionary: selection)),
                let send = sendButton(app), enabled(send), let current = composer(app), sameDraft(value(current), text)
            else {
                throw CLIError(
                    L10n.text("provider.the_new_zcode_task_state_changed_the_content_remains_in_the_desktop_draft"))
            }
            var receipt: [String: Any] = ["accepted": false, "unknown": true]
            try cache.record(receiptKey, receipt, text: text, creationCwd: cwd)
            try UnconfirmedDesktopMutation.attempting { try press(send, app: app) }
            var nativeSession: String?
            _ = wait(
                5,
                {
                    guard !visibleTitle(app).isEmpty, let id = try? copiedSessionID(app), !priorIDs.contains(id) else {
                        return false
                    }
                    nativeSession = id
                    return true
                })
            if let nativeSession {
                receipt["sessionId"] = nativeSession
                receipt["threadId"] = nativeSession
                try cache.record(receiptKey, receipt, text: text, creationCwd: cwd)
                let store = ZCodeSessionStore()
                var nativeMessage: String?
                let confirmed = wait(
                    5,
                    {
                        guard let summary = try? store.summary(nativeSession), summary["cwd"] as? String == cwd,
                            let latest = try? store.nativeUser(nativeSession, first: true),
                            confirmation(before: nil, userID: latest.id, observed: latest.text, expected: text)
                        else { return false }
                        nativeMessage = latest.id
                        return true
                    })
                if confirmed, let nativeMessage {
                    receipt = [
                        "accepted": true, "threadId": nativeSession, "sessionId": nativeSession,
                        "messageId": nativeMessage,
                        "nativeMessageId": nativeMessage, "cwd": cwd,
                    ]
                    try cache.record(receiptKey, receipt)
                    _ = remember(app, nativeSession, (try? store.summary(nativeSession)["title"] as? String) ?? "")
                }
            }
            return receipt
        }
    }

    private static func withNewDraft<T>(
        cwd: String, action: (AXUIElement, AXUIElement, Set<String>) throws -> T
    ) throws -> T {
        guard supportsNew, AXIsProcessTrusted(), !cwd.isEmpty, cwd.hasPrefix("/"),
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else {
            throw CLIError(
                L10n.text("provider.open_a_local_project_in_the_native_zcode_agent_before_retrying_session_creat"))
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let app = AXUIElementCreateApplication(running.processIdentifier)
        defer { if frontmost(app), previous?.bundleIdentifier != bundleID { previous?.activate() } }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        running.activate()
        guard wait(3, { frontmost(app) }) else {
            throw CLIError(L10n.text("provider.could_not_activate_zcode_no_new_session_was_created"))
        }
        guard dismissNavigation(app), wait(2, { composer(app) != nil }) else {
            throw CLIError(L10n.text("provider.the_zcode_navigation_dialog_is_still_open_no_new_session_was_created"))
        }
        guard composer(app).map({ draftIsEmpty(value($0)) }) != false else {
            throw CLIError(L10n.text("provider.zcode_desktop_has_an_existing_draft_no_new_session_was_created"))
        }
        let priorIDs = try ZCodeSessionStore().existingSessionIDs()
        try DesktopInput.key(
            45, flags: .maskCommand,
            isCurrent: {
                frontmost(app) && composer(app).map { draftIsEmpty(value($0)) } == true
            })  // native New task creates an empty draft, not a CLI session
        guard wait(2, { visibleTitle(app).isEmpty && composer(app) != nil }), let field = composer(app),
            draftIsEmpty(value(field))
        else {
            throw CLIError(
                L10n.text("provider.could_not_verify_an_empty_draft_for_the_new_native_zcode_task_nothing_was_se"))
        }
        // Bind an already available project through the native picker. External
        // workspace URLs trigger a trust sheet, which the bridge must not accept.
        do {
            guard
                let binding = projectBinding(
                    cwd: cwd, workspaces: desktopSettings()["lastWorkspaceSession"] as? [[String: Any]] ?? [])
            else {
                throw CLIError(
                    L10n.text("provider.the_full_path_does_not_uniquely_identify_a_native_zcode_workspace_nothing_wa"))
            }
            guard
                let project = find(
                    window(app), { role($0) == "AXPopUpButton" && ["选择项目", "Select project"].contains(label($0)) }
                ).first
            else {
                throw CLIError(
                    L10n.text("provider.the_project_selector_for_the_new_zcode_task_could_not_be_verified_nothing_wa"))
            }
            try press(project, app: app)
            var search: AXUIElement?
            guard
                wait(
                    1.5,
                    {
                        search =
                            find(window(app)) { element in
                                let prompt = attribute(element, "AXPlaceholderValue") as? String ?? ""
                                return ["AXTextField", "AXSearchField", "AXComboBox"].contains(role(element))
                                    && projectSearch(label: label(element), placeholder: prompt)
                            }.first
                        return search != nil
                    }), let search
            else {
                dismissMenu(app)
                throw CLIError(L10n.text("provider.zcode_project_search_not_found_nothing_was_sent"))
            }
            let identity = FieldIdentity(search)
            try setSearchText(cwd, into: search, app: app)
            var choices: [AXUIElement] = []
            var stable = StableResults()
            guard
                wait(
                    3,
                    {
                        guard frontmost(app), let current = freshField(identity, app: app),
                            binding
                                == projectBinding(
                                    cwd: cwd,
                                    workspaces: desktopSettings()["lastWorkspaceSession"] as? [[String: Any]] ?? []),
                            let menu = visibleMenus(app).last, contains(menu, current)
                        else {
                            stable.reset()
                            return false
                        }
                        choices = Array(projectRows(menu).prefix(binding.labels.count))
                        return stable.observe(
                            query: value(current), expectedQuery: cwd, labels: choices.map(label),
                            expectedLabels: binding.labels, at: ProcessInfo.processInfo.systemUptime)
                    }), choices.indices.contains(binding.targetIndex), let current = freshField(identity, app: app),
                value(current) == cwd,
                let menu = visibleMenus(app).last,
                projectRows(menu).prefix(binding.labels.count).map(label) == binding.labels
            else {
                dismissMenu(app)
                throw CLIError(
                    L10n.text("provider.zcode_project_search_or_native_path_mapping_is_not_stable_nothing_was_sent"))
            }
            // Re-resolve the row after filtering; never press a stale pre-query result.
            try press(projectRows(menu)[binding.targetIndex], app: app)
            guard wait(8, { activeDirectory() == cwd && visibleTitle(app).isEmpty && visibleMenus(app).isEmpty }) else {
                throw CLIError(
                    L10n.text("provider.the_project_path_for_the_new_zcode_task_does_not_match_nothing_was_sent"))
            }
        }
        guard frontmost(app), supportsNew, activeDirectory() == cwd, visibleTitle(app).isEmpty,
            let fresh = composer(app), draftIsEmpty(value(fresh)), modelButton(app) != nil
        else {
            throw CLIError(
                L10n.text("provider.native_settings_for_the_new_zcode_task_are_unconfirmed_nothing_was_sent"))
        }
        return try action(app, fresh, priorIDs)
    }

    private static func verifyNewDraft(_ app: AXUIElement, cwd: String) throws {
        guard frontmost(app), supportsNew, activeDirectory() == cwd, visibleTitle(app).isEmpty,
            visibleMenus(app).isEmpty, stopButton(app) == nil,
            let field = composer(app), draftIsEmpty(value(field)), modelButton(app) != nil
        else {
            throw CLIError(
                L10n.text("provider.native_settings_for_the_new_zcode_task_are_unconfirmed_nothing_was_sent"))
        }
    }

    private static func choices(_ entry: Entry) -> [String: [Choice]] {
        ["model": entry.models, "mode": entry.modes, "effort": entry.efforts]
    }

    /// Choices must have been read for this trusted phone/project/draft and still identify the same native menu row.
    static func creationSelection(
        _ request: [String: Any], previous: [String: [Choice]], current: [String: [Choice]]
    ) throws -> [String: String] {
        guard let model = request["model"] as? String, !model.isEmpty,
            let mode = request["mode"] as? String, !mode.isEmpty,
            request["effort"] == nil || request["effort"] is String
        else { throw CLIError(L10n.text("provider.reopen_the_zcode_model_and_permission_options_first")) }
        if mode == "yolo", SessionProviderReply.boolean(request["confirmFullAccess"]) != true {
            throw CLIError(L10n.text("provider.confirm_zcode_full_access_mode_first"))
        }
        var selected: [String: String] = ["model": model, "mode": mode]
        if let effort = request["effort"] as? String { selected["effort"] = effort }
        for (kind, id) in selected {
            guard let old = previous[kind]?.first(where: { $0.id == id }),
                let fresh = current[kind]?.first(where: { $0.id == id }),
                old.signature == fresh.signature, old.ordinal == fresh.ordinal, old.label == fresh.label
            else { throw CLIError(L10n.text("provider.native_zcode_options_changed_no_selection_was_made")) }
        }
        return selected
    }

    private static func newOptions(_ request: [String: Any], cwd: String, client: String) throws -> [String: Any] {
        let draft = try SessionCreationDraft(request, project: cwd, provider: "zcode")
        return try withNewDraft(cwd: cwd) { app, _, _ in
            let entry = try readOptions(app, entry: Entry())
            try verifyNewDraft(app, cwd: cwd)
            guard let model = entry.composer["model"] as? String,
                entry.models.contains(where: { $0.id == model }),
                let mode = entry.composer["mode"] as? String, entry.modes.contains(where: { $0.id == mode })
            else {
                throw CLIError(
                    L10n.text("provider.native_settings_for_the_new_zcode_task_are_unconfirmed_nothing_was_sent"))
            }
            cache.put(entry, id: receiptKey(client: client, session: draft.scope, operation: "creation-options"))
            let models = entry.models.map { choice -> [String: Any] in
                var value = choice.object
                if choice.id == model {
                    value["efforts"] = entry.efforts.map(\.id)
                    value["defaultEffort"] = entry.composer["effort"]
                }
                return value
            }
            return [
                "creationVersion": 1, "draftId": draft.id, "composer": entry.composer, "models": models,
                "permissionModes": entry.modes.map(\.object), "efforts": entry.efforts.map(\.object),
                "capabilities": ["new": true, "attachments": false],
            ]
        }
    }

    private static func reveal(_ session: String, summary: [String: Any]) throws -> AXUIElement {
        guard AXIsProcessTrusted(), !ScreenLock.locked(),
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else {
            throw CLIError(L10n.text("provider.open_zcode_and_grant_vibepier_accessibility_permission_first"))
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if !frontmost(app) { running.activate() }
        guard wait(3, { frontmost(app) }) else {
            throw CLIError(L10n.text("provider.could_not_activate_zcode_no_action_was_taken"))
        }
        guard wait(3, { role(window(app)) == "AXWindow" }) else {
            throw CLIError(L10n.text("provider.open_zcode_and_grant_vibepier_accessibility_permission_first"))
        }
        guard dismissNavigation(app), wait(2, { composer(app) != nil }) else {
            throw CLIError(L10n.text("provider.the_zcode_navigation_view_is_still_open_check_on_the_mac"))
        }
        let targetTitle = summary["title"] as? String ?? ""
        if visibleTitle(app) == targetTitle, (try? copiedSessionID(app)) == session {
            guard composer(app) != nil else {
                throw CLIError(
                    L10n.text("provider.zcode_has_multiple_editing_areas_or_its_input_is_not_ready_no_action_was_tak"))
            }
            return remember(app, session, targetTitle)
        }
        guard !targetTitle.isEmpty else {
            throw CLIError(
                L10n.text("provider.the_session_has_no_identifiable_desktop_title_open_it_on_the_mac_before_retr"))
        }
        // Desktop Cmd+K searches tasks across its projects. It neither adds a
        // workspace nor accepts folder trust. The copied native ID authorizes
        // the later operation, even when titles happen to be identical.
        try key(40, flags: .maskCommand)
        var search: AXUIElement?
        guard
            wait(
                2,
                {
                    search =
                        find(window(app)) { element in
                            ["AXTextField", "AXComboBox", "AXSearchField"].contains(role(element))
                                && navigationSearch(
                                    label: label(element),
                                    placeholder: attribute(element, "AXPlaceholderValue") as? String ?? "")
                        }.first
                    return search != nil
                }), let search
        else {
            throw CLIError(
                L10n.text("provider.zcode_task_search_not_found_open_this_session_on_the_mac_before_retrying"))
        }
        let identity = FieldIdentity(search)
        try setSearchText(targetTitle, into: search, app: app)
        var targets: [AXUIElement] = []
        var stable = StableResults()
        guard
            wait(
                3,
                {
                    guard frontmost(app), let current = freshField(identity, app: app) else {
                        stable.reset()
                        return false
                    }
                    targets = distinct(
                        find(window(app)) { label($0) == targetTitle && role($0) != "AXTextArea" }.compactMap(pressable)
                    )
                    return stable.observe(
                        query: value(current), expectedQuery: targetTitle, labels: targets.map { _ in targetTitle },
                        expectedLabels: [targetTitle], at: ProcessInfo.processInfo.systemUptime)
                }), targets.count == 1
        else {
            dismissNavigation(app)
            throw CLIError(
                L10n.text("provider.the_desktop_search_result_is_not_unique_open_this_session_on_the_mac_before_"))
        }
        try press(targets[0], app: app)
        guard wait(4, { visibleTitle(app) == targetTitle && composer(app) != nil }) else {
            throw CLIError(L10n.text("provider.the_zcode_session_did_not_finish_opening_no_action_was_taken"))
        }
        try verify(app, session)
        return remember(app, session, targetTitle)
    }
    private static func remember(_ app: AXUIElement, _ session: String, _ title: String) -> AXUIElement {
        var entry = cache.entry(session)
        entry.title = title
        entry.verified = true
        entry.observed = 0
        entry.composer.merge(readControls(app)) { _, fresh in fresh }
        cache.put(entry, id: session)
        cache.verified(session)
        if let owner = ownerScope(app, session: session) { _ = ownership.bind(owner) } else { ownership.invalidate() }
        return app
    }
    private static func verify(_ app: AXUIElement, _ session: String) throws {
        guard frontmost(app), try copiedSessionID(app) == session else {
            throw CLIError(L10n.text("provider.the_current_native_zcode_session_id_does_not_match_no_action_was_taken"))
        }
        cache.verified(session)
        if let owner = ownerScope(app, session: session) { _ = ownership.bind(owner) } else { ownership.invalidate() }
    }
    private static func copiedSessionID(_ app: AXUIElement) throws -> String {
        guard frontmost(app),
            let more = find(
                window(app), limit: 500, { role($0) == "AXPopUpButton" && ["更多", "More"].contains(label($0)) }
            ).first
        else {
            throw CLIError(L10n.text("provider.the_native_zcode_session_id_menu_was_not_found"))
        }
        let board = NSPasteboard.general
        let clipboard = try DesktopClipboard(board)
        try clipboard.write("")
        defer { clipboard.restore() }
        try press(more, app: app)
        defer { dismissMenu(app) }
        var item: AXUIElement?
        guard
            wait(
                1.5,
                {
                    item =
                        find(window(app)) {
                            ["复制会话 ID", "Copy session ID"].contains(label($0)) && role($0) != "AXStaticText"
                        }.first
                    return item != nil
                }), let item
        else {
            throw CLIError(
                L10n.text("provider.this_zcode_version_has_no_verifiable_native_session_id_no_action_was_taken"))
        }
        try press(item, app: app)
        var id: String?
        guard
            wait(
                1.5,
                {
                    guard frontmost(app) else { return false }
                    let version = board.changeCount
                    let copied = board.string(forType: .string) ?? ""
                    guard let candidate = nativeID(copied), clipboard.adoptNativeCopy(copied, version: version) else {
                        return false
                    }
                    id = candidate
                    return true
                }), let id
        else {
            throw CLIError(L10n.text("provider.zcode_did_not_return_a_native_session_id_no_action_was_taken"))
        }
        guard dismissMenu(app) else {
            throw CLIError(L10n.text("provider.the_native_zcode_session_menu_is_still_open_no_action_was_taken"))
        }
        return id
    }

    private static func options(_ app: AXUIElement, session: String, summary: [String: Any]) throws -> [String: Any] {
        var entry = try readOptions(app, entry: cache.entry(session))
        entry.title = summary["title"] as? String ?? ""
        entry.observed = 0
        cache.put(entry, id: session)
        return try snapshot(session)
    }
    private static func readOptions(_ app: AXUIElement, entry source: Entry) throws -> Entry {
        var entry = source
        if let button = modelButton(app) {
            let menu = try readMenu(button, kind: "model", app: app)
            entry.models = menu.choices
            if menu.selectedOrdinals.count == 1, let index = menu.selectedOrdinals.first,
                menu.choices.indices.contains(index)
            {
                entry.composer["model"] = menu.choices[index].id
            }
        }
        if let button = modeButton(app) {
            let menu = try readMenu(button, kind: "mode", app: app)
            entry.modes = menu.choices
            if menu.selectedOrdinals.count == 1, let index = menu.selectedOrdinals.first,
                menu.choices.indices.contains(index)
            {
                entry.composer["mode"] = menu.choices[index].id
            }
        }
        if let button = effortButton(app) {
            let menu = try readMenu(button, kind: "effort", app: app)
            entry.efforts = menu.choices
            if menu.selectedOrdinals.count == 1, let index = menu.selectedOrdinals.first,
                menu.choices.indices.contains(index)
            {
                entry.composer["effort"] = menu.choices[index].id
            }
        }
        entry.composer.merge(readControls(app)) { _, fresh in fresh }
        return entry
    }

    private struct Menu {
        let choices: [Choice]
        let items: [AXUIElement]
        let selectedOrdinals: Set<Int>
    }
    private static func readMenu(_ button: AXUIElement, kind: String, app: AXUIElement, dismiss: Bool = true) throws
        -> Menu
    {
        let caption =
            [
                "model": L10n.text("provider.model"), "mode": L10n.text("provider.permission_mode"),
                "effort": L10n.text("provider.reasoning_effort"),
            ][kind] ?? kind
        try press(button, app: app)
        var finished = false
        defer { if !finished { dismissMenu(app) } }
        var menus: [AXUIElement] = []
        guard
            wait(
                1.5,
                {
                    menus = visibleMenus(app)
                    return !menus.isEmpty
                }), let menu = menus.last
        else { throw CLIError(L10n.text("provider.the_native_zcode_0_menu_is_not_ready_try_again", caption)) }
        let items = distinct(
            find(menu) {
                guard !CFEqual($0, menu), role($0) != "AXStaticText", enabled($0), hasPress($0), !label($0).isEmpty
                else { return false }
                // AXSelected=false is exposed on provider/action rows too. Native
                // model/mode choices alone have a numeric checkable AXValue.
                return selectableOption(
                    kind: kind, popupRole: role(menu), hasValue: attribute($0, kAXValueAttribute) is NSNumber,
                    hasSelected: attribute($0, kAXSelectedAttribute) is NSNumber)
            })
        guard !items.isEmpty else {
            throw CLIError(L10n.text("provider.the_native_zcode_0_menu_has_no_readable_options_1", caption, role(menu)))
        }
        let labels = items.map(label)
        let modeIDs = kind == "mode" ? try nativeModeIDs(labels) : nil
        // Bind to account/group headers as well as labels: two accounts can both
        // offer "GLM-5.3-Flash", and swapping their order must invalidate a choice.
        let signature = menuSignature(
            find(menu) { !CFEqual($0, menu) && role($0) == "AXStaticText" }.map(value) + labels)
        var groups: [String: String] = [:]
        var headings: [String] = []
        guard
            let ordered = DesktopAXTraversal.elements(
                menu, limit: 6000, depthFirst: true,
                descend: { node in
                    !items.contains(where: { CFEqual($0, node) })
                        && !(role(node) == "AXStaticText" && !value(node).isEmpty)
                })
        else {
            throw CLIError(L10n.text("provider.the_native_zcode_0_menu_has_no_readable_options_1", caption, role(menu)))
        }
        for node in ordered {
            if let ordinal = items.firstIndex(where: { CFEqual($0, node) }) {
                groups[String(ordinal)] = headings.suffix(2).joined(separator: " · ")
                continue
            }
            if role(node) == "AXStaticText", !value(node).isEmpty {
                headings.append(value(node))
                continue
            }
        }
        let choices = items.enumerated().map { index, element in
            let raw = label(element)
            let duplicates = labels.filter { $0 == raw }.count > 1
            let group = groups[String(index)] ?? ""
            let suffix = duplicates ? "（\(group.isEmpty ? L10n.text("provider.option_0", index + 1) : group)）" : ""
            let nativeMode = modeIDs?[index]
            let nativeEffort = kind == "effort" && raw == "最高" ? "max" : nil
            return Choice(
                id: nativeMode ?? nativeEffort ?? "zcode-\(kind)-\(signature)-\(index)", title: raw + suffix,
                label: raw, ordinal: index, signature: signature)
        }
        let result = Menu(
            choices: choices, items: items, selectedOrdinals: Set(items.indices.filter { selected(items[$0]) }))
        if dismiss, !dismissMenu(app) {
            throw CLIError(L10n.text("provider.the_native_zcode_0_menu_is_still_open_try_again", caption))
        }
        finished = true
        return result
    }
    private static func settings(
        _ request: [String: Any], app: AXUIElement, session: String, verifyTarget: (() throws -> Void)? = nil
    ) throws -> [String: Any] {
        try DesktopMutationScope.run { mutation in
            let entry = cache.entry(session)
            for (keyName, kind, choices) in [
                ("model", "model", entry.models),
                ("mode", "mode", entry.modes), ("effort", "effort", entry.efforts),
            ] {
                guard let target = request[keyName] as? String else { continue }
                if keyName == "mode", target == "yolo",
                    SessionProviderReply.boolean(request["confirmFullAccess"]) != true
                {
                    throw CLIError(L10n.text("provider.confirm_zcode_full_access_mode_first"))
                }
                if entry.composer[keyName] as? String == target { continue }
                let button = kind == "model" ? modelButton(app) : kind == "mode" ? modeButton(app) : effortButton(app)
                guard let choice = choices.first(where: { $0.id == target }), let button else {
                    throw CLIError(L10n.text("provider.reopen_the_zcode_model_and_permission_options_first"))
                }
                if let verifyTarget { try verifyTarget() } else { try verify(app, session) }
                let menu = try readMenu(button, kind: kind, app: app, dismiss: false)
                guard menu.choices.first?.signature == choice.signature, menu.items.indices.contains(choice.ordinal)
                else {
                    dismissMenu(app)
                    throw CLIError(L10n.text("provider.native_zcode_options_changed_no_selection_was_made"))
                }
                try mutation.attempt { try press(menu.items[choice.ordinal], app: app) }
                guard wait(2, { visibleMenus(app).isEmpty }) else {
                    throw CLIError(L10n.text("provider.the_zcode_option_change_did_not_finish"))
                }
                guard
                    let currentButton = kind == "model"
                        ? modelButton(app) : kind == "mode" ? modeButton(app) : effortButton(app)
                else { throw CLIError(L10n.text("provider.the_zcode_control_changed")) }
                let checked = try readMenu(currentButton, kind: kind, app: app)
                guard checked.choices.first?.signature == choice.signature,
                    checked.items.indices.contains(choice.ordinal),
                    checked.selectedOrdinals == Set([choice.ordinal])
                else {
                    throw CLIError(L10n.text("provider.the_native_zcode_option_change_is_unconfirmed_check_on_the_mac"))
                }
                if let verifyTarget { try verifyTarget() } else { try verify(app, session) }
            }
            var updated = cache.entry(session)
            updated.composer.merge(readControls(app)) { _, fresh in fresh }
            for key in ["model", "mode", "effort"] {
                if let value = request[key] as? String { updated.composer[key] = value }
            }
            cache.put(updated, id: session)
            return ["accepted": true, "applied": true, "composer": updated.composer]
        }
    }

    private static func application() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }
    private static func readControls(_ app: AXUIElement) -> [String: Any] {
        var result: [String: Any] = [:]
        if let button = modelButton(app) { result["modelLabel"] = label(button) }
        if let button = effortButton(app) { result["effortLabel"] = label(button) }
        if let button = modeButton(app) { result["modeLabel"] = label(button) }
        return result
    }
    private static func composer(_ app: AXUIElement) -> AXUIElement? {
        let fields = composerFields(app)
        return fields.count == 1 ? fields[0] : nil
    }
    private static func composerFields(_ app: AXUIElement) -> [AXUIElement] {
        distinct(
            find(window(app)) { element in
                let placeholder = attribute(element, "AXPlaceholderValue") as? String ?? ""
                return ["AXTextArea", "AXTextField"].contains(role(element)) && composerPlaceholder(placeholder)
            })
    }
    private static func visibleTitle(_ app: AXUIElement) -> String {
        find(window(app), limit: 900) {
            role($0) == "AXHeading" && (attribute($0, kAXValueAttribute) as? NSNumber)?.intValue == 1
        }.map(label).first ?? ""
    }
    /// Lexical's editable field sits in its own wrapper. The actual native
    /// footer is a sibling in the nearest enclosing composer container.
    /// A wider page/window with unrelated controls can never qualify.
    private static func composerScope(_ app: AXUIElement) -> AXUIElement? {
        guard let field = composer(app) else { return nil }
        var current = elementAttribute(field, kAXParentAttribute)
        for _ in 0..<6 {
            guard let scope = current else { return nil }
            if ["AXWindow", "AXWebArea", "AXApplication"].contains(role(scope)) { return nil }
            let modes = find(scope, limit: 400) {
                role($0) == "AXPopUpButton" && ["切换模式", "Switch mode"].contains(label($0))
            }
            let contexts = find(scope, limit: 400) {
                role($0) == "AXPopUpButton" && ["添加上下文", "Add context"].contains(label($0))
            }
            let actions = find(scope, limit: 400) {
                role($0) == "AXButton" && ["发送", "Send", "停止", "停止生成", "Stop"].contains(label($0))
            }
            let sends = actions.filter { ["发送", "Send"].contains(label($0)) }.count
            let stops = actions.filter { ["停止", "停止生成", "Stop"].contains(label($0)) }.count
            let fields = distinct(
                find(scope, limit: 400) {
                    ["AXTextArea", "AXTextField"].contains(role($0))
                        && composerPlaceholder(attribute($0, "AXPlaceholderValue") as? String ?? "")
                })
            if modes.count == 1, contexts.count == 1, !actions.isEmpty, sends <= 1, stops <= 1,
                fields.count == 1, CFEqual(fields[0], field)
            {
                return scope
            }
            current = elementAttribute(scope, kAXParentAttribute)
        }
        return nil
    }
    private static func modelButton(_ app: AXUIElement) -> AXUIElement? {
        guard let scope = composerScope(app) else { return nil }
        let models = find(scope, limit: 400) {
            role($0) == "AXPopUpButton"
                && !["添加上下文", "切换模式", "选择项目", "Add context", "Switch mode", "Select project"].contains(label($0))
        }
        return models.count == 1 ? models[0] : nil
    }
    private static func modeButton(_ app: AXUIElement) -> AXUIElement? {
        guard let scope = composerScope(app) else { return nil }
        return find(scope, limit: 400) { role($0) == "AXPopUpButton" && ["切换模式", "Switch mode"].contains(label($0)) }
            .first
    }
    private static func effortButton(_ app: AXUIElement) -> AXUIElement? {
        guard let scope = composerScope(app) else { return nil }
        let choices = find(scope, limit: 400) {
            role($0) == "AXComboBox"
                && !navigationSearch(
                    label: label($0), placeholder: attribute($0, "AXPlaceholderValue") as? String ?? "")
        }
        return choices.count == 1 ? choices[0] : nil
    }
    private static func actionButton(_ app: AXUIElement, labels: [String]) -> AXUIElement? {
        guard let scope = composerScope(app) else { return nil }
        let buttons = find(scope, limit: 400) { role($0) == "AXButton" && labels.contains(label($0)) }
        return buttons.count == 1 ? buttons[0] : nil
    }
    private static func sendButton(_ app: AXUIElement) -> AXUIElement? { actionButton(app, labels: ["发送", "Send"]) }
    private static func stopButton(_ app: AXUIElement) -> AXUIElement? {
        actionButton(app, labels: ["停止", "停止生成", "Stop"])
    }
    private static func sameDraft(_ actual: String, _ expected: String) -> Bool {
        actual.trimmingCharacters(in: .newlines) == expected.trimmingCharacters(in: .newlines)
    }
    private struct FieldIdentity {
        let role: String
        let placeholder: String
        init(_ field: AXUIElement) {
            role = ZCodeDesktop.role(field)
            placeholder = attribute(field, "AXPlaceholderValue") as? String ?? ""
        }
    }
    private static func freshField(_ identity: FieldIdentity, app: AXUIElement) -> AXUIElement? {
        guard !identity.placeholder.isEmpty else { return nil }
        let fields = distinct(
            find(window(app)) {
                role($0) == identity.role && attribute($0, "AXPlaceholderValue") as? String == identity.placeholder
            })
        return fields.count == 1 ? fields[0] : nil
    }
    private static func focused(_ field: AXUIElement, app: AXUIElement) -> Bool {
        guard let current = elementAttribute(app, kAXFocusedUIElementAttribute) else { return false }
        return contains(field, current)
    }
    private static func setSearchText(_ text: String, into field: AXUIElement, app: AXUIElement) throws {
        let identity = FieldIdentity(field)
        guard frontmost(app),
            navigationSearch(label: label(field), placeholder: identity.placeholder)
                || projectSearch(label: label(field), placeholder: identity.placeholder),
            let current = freshField(identity, app: app), enabled(current)
        else { throw CLIError(L10n.text("provider.the_zcode_search_field_changed_nothing_was_entered")) }
        // Native AXValue successfully updates this input without a clipboard or
        // focus race. Result-list validation below still confirms React applied it.
        if AXUIElementSetAttributeValue(current, kAXValueAttribute as CFString, text as CFString) == .success,
            wait(1, { frontmost(app) && freshField(identity, app: app).map({ value($0) == text }) == true })
        {
            return
        }
        guard frontmost(app), let fresh = freshField(identity, app: app) else {
            throw CLIError(L10n.text("provider.the_zcode_search_field_lost_focus_input_was_stopped"))
        }
        try paste(text, into: fresh, app: app, replace: true)
    }
    private static func paste(_ text: String, into field: AXUIElement, app: AXUIElement, replace: Bool = false) throws {
        let identity = FieldIdentity(field)
        guard frontmost(app), let current = freshField(identity, app: app), enabled(current) else {
            throw CLIError(L10n.text("provider.the_zcode_input_field_changed_or_lost_focus_nothing_was_entered"))
        }
        let hasFocus = {
            guard frontmost(app), let fresh = freshField(identity, app: app) else { return false }
            return focused(fresh, app: app)
        }
        // AXFocused alone can focus the accessibility node without focusing
        // Lexical's DOM editor. Always physically click the fresh hit-tested
        // editor before any clipboard key, even when AX already reports focus.
        try click(current, app: app, waitForFocus: hasFocus)
        guard hasFocus() else {
            throw CLIError(L10n.text("provider.actual_input_focus_in_zcode_could_not_be_verified_nothing_was_entered"))
        }
        if !replace {
            guard let fresh = freshField(identity, app: app), draftIsEmpty(value(fresh)) else {
                throw CLIError(L10n.text("provider.zcode_desktop_has_an_existing_draft_nothing_was_entered"))
            }
        }
        let clipboard = try DesktopClipboard(NSPasteboard.general)
        try clipboard.write(text)
        defer { clipboard.restore() }
        guard frontmost(app), clipboard.isCurrent, let fresh = freshField(identity, app: app), focused(fresh, app: app)
        else {
            throw CLIError(L10n.text("provider.zcode_input_focus_changed_nothing_was_entered"))
        }
        if replace { try key(0, flags: .maskCommand) }
        guard frontmost(app), clipboard.isCurrent, let fresh = freshField(identity, app: app), focused(fresh, app: app)
        else {
            throw CLIError(L10n.text("provider.zcode_input_focus_changed_nothing_was_pasted"))
        }
        try key(9, flags: .maskCommand)
        // HID events are asynchronous. Keep the pasted contents available even
        // when AX already reports them; an immediate restore races Electron.
        Thread.sleep(forTimeInterval: 0.35)
        guard
            wait(
                1.5,
                {
                    guard frontmost(app), clipboard.isCurrent,
                        let fresh = freshField(identity, app: app), focused(fresh, app: app)
                    else { return false }
                    return replace ? value(fresh) == text : sameDraft(value(fresh), text)
                })
        else {
            throw CLIError(
                L10n.text("provider.the_content_could_not_be_verified_in_the_current_zcode_composer_nothing_was_"))
        }
    }
    @discardableResult private static func dismissMenu(_ app: AXUIElement) -> Bool {
        guard let menu = visibleMenus(app).last else { return true }
        guard frontmost(app) else { return false }
        // Escape is the native Stop action. Closing any popup must never post it,
        // even when a stale accessibility menu survives its actual dismissal.
        _ = AXUIElementPerformAction(menu, "AXCancel" as CFString)
        if wait(0.4, { !popupPresent(menu, app: app) && visibleMenus(app).isEmpty }) { return true }
        guard frontmost(app) else { return false }
        var targets: [AXUIElement] = []
        if let field = composer(app), !contains(menu, field) { targets.append(field) }
        let headings = distinct(
            find(window(app)) {
                role($0) == "AXHeading" && (attribute($0, kAXValueAttribute) as? NSNumber)?.intValue == 1
                    && !contains(menu, $0)
            })
        if headings.count == 1 { targets.append(headings[0]) }
        for target in targets {
            // A dropdown covering the composer fails the exact hit-test; a
            // neutral task heading is the only other permitted outside target.
            do { try click(target, app: app) } catch { continue }
            if wait(1, { !popupPresent(menu, app: app) && visibleMenus(app).isEmpty }) { return true }
        }
        return false
    }
    private static func visibleMenus(_ app: AXUIElement) -> [AXUIElement] {
        let focus = elementAttribute(app, kAXFocusedUIElementAttribute)
        var focusedItem: AXUIElement?
        var current = focus
        for _ in 0..<6 {
            guard let node = current else { break }
            if role(node) == "AXMenuItem" {
                focusedItem = node
                break
            }
            current = elementAttribute(node, kAXParentAttribute)
        }
        return find(window(app)) { element in
            let kind = role(element)
            guard ["AXMenu", "AXList"].contains(kind) else { return false }
            let hasSearch = !find(
                element, limit: 300,
                { node in
                    ["AXTextField", "AXComboBox", "AXSearchField"].contains(role(node))
                        && (navigationSearch(
                            label: label(node), placeholder: attribute(node, "AXPlaceholderValue") as? String ?? "")
                            || projectSearch(
                                label: label(node), placeholder: attribute(node, "AXPlaceholderValue") as? String ?? ""))
                }
            ).isEmpty
            let hasSelection =
                kind == "AXList" && !find(element, limit: 300, { role($0) == "AXMenuItem" && selected($0) }).isEmpty
            return nativePopup(
                role: kind, focusedMenuItem: focusedItem.map { contains(element, $0) } ?? false,
                selectedOption: hasSelection, searchField: hasSearch,
                focusedMenu: focus.map { contains(element, $0) } ?? false)
        }
    }
    private static func popupPresent(_ menu: AXUIElement, app: AXUIElement) -> Bool {
        !find(window(app)) { ["AXMenu", "AXList"].contains(role($0)) && CFEqual($0, menu) }.isEmpty
    }
    private static func projectRows(_ menu: AXUIElement) -> [AXUIElement] {
        distinct(
            find(menu) {
                role($0) == "AXMenuItem" && hasPress($0) && enabled($0)
                    && (attribute($0, kAXValueAttribute) is NSNumber || attribute($0, kAXSelectedAttribute) is NSNumber)
            })
    }
    @discardableResult private static func dismissNavigation(_ app: AXUIElement) -> Bool {
        guard frontmost(app) else { return false }
        let searches = distinct(
            find(
                window(app), limit: 1200,
                { element in
                    ["AXComboBox", "AXTextField", "AXSearchField"].contains(role(element))
                        && navigationSearch(
                            label: label(element),
                            placeholder: attribute(element, "AXPlaceholderValue") as? String ?? "")
                }))
        if !searches.isEmpty {
            guard searches.count == 1, let focus = elementAttribute(app, kAXFocusedUIElementAttribute),
                contains(searches[0], focus)
                    || visibleMenus(app).contains(where: { contains($0, searches[0]) && contains($0, focus) })
            else { return false }
            // The native quick-open shortcut toggles its own confirmed dialog.
            // It cannot accidentally invoke conversation Stop after a close.
            do { try key(40, flags: .maskCommand) } catch { return false }
            return wait(
                1,
                {
                    find(
                        window(app), limit: 1200,
                        {
                            navigationSearch(
                                label: label($0), placeholder: attribute($0, "AXPlaceholderValue") as? String ?? "")
                        }
                    ).isEmpty && visibleMenus(app).isEmpty
                })
        }
        return dismissMenu(app)
    }
    private static func press(_ element: AXUIElement, app: AXUIElement) throws {
        try DesktopInput.perform(
            isCurrent: { frontmost(app) && enabled(element) }, supportsPress: hasPress(element),
            press: {
                guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                    throw CLIError(L10n.text("provider.desktop_input_changed"))
                }
            },
            prepareClick: {
                DesktopInput.prepareClick(element, application: app, isCurrent: { frontmost(app) && enabled(element) })
            })
    }
    private static func click(_ element: AXUIElement, app: AXUIElement, waitForFocus: (() -> Bool)? = nil) throws {
        guard
            let action = DesktopInput.prepareClick(
                element, application: app, isCurrent: { frontmost(app) && enabled(element) })
        else { throw CLIError(L10n.text("provider.the_zcode_control_moved_no_click_was_sent")) }
        try action()
        if let waitForFocus {
            guard wait(1, waitForFocus) else {
                throw UnconfirmedDesktopMutation(reason: L10n.text("provider.desktop_input_changed"))
            }
        }
    }
    private static func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        try DesktopInput.key(code, flags: flags)
    }
    private static func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < until
        return false
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func value(_ element: AXUIElement) -> String {
        attribute(element, kAXValueAttribute) as? String ?? ""
    }
    private static func label(_ element: AXUIElement) -> String {
        let own = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0) as? String }.first {
            !$0.isEmpty
        }
        if let own { return own }
        if let placeholder = attribute(element, "AXPlaceholderValue") as? String, !placeholder.isEmpty {
            return placeholder
        }
        return find(element, limit: 16) { role($0) == "AXStaticText" }.map(value).filter { !$0.isEmpty }.joined(
            separator: " ")
    }
    private static func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) as? String ?? "" }
    private static func enabled(_ element: AXUIElement) -> Bool {
        attribute(element, kAXEnabledAttribute) as? Bool ?? true
    }
    private static func selected(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXValueAttribute) as? NSNumber)?.boolValue == true
            || (attribute(element, kAXSelectedAttribute) as? NSNumber)?.boolValue == true
    }
    private static func window(_ app: AXUIElement) -> AXUIElement {
        if let focused = elementAttribute(app, kAXFocusedWindowAttribute) { return focused }
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.count == 1 ? windows[0] : app
    }
    private static func frontmost(_ app: AXUIElement) -> Bool { attribute(app, kAXFrontmostAttribute) as? Bool == true }
    private static func find(
        _ root: AXUIElement, limit: Int = 6000, descendIntoMatches: Bool = true,
        _ match: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        guard
            let nodes = DesktopAXTraversal.elements(
                root, limit: limit,
                descend: { descendIntoMatches || !match($0) })
        else { return [] }
        var matches: [AXUIElement] = []
        for node in nodes {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            if match(node) { matches.append(node) }
        }
        return ProcessInfo.processInfo.systemUptime < deadline ? matches : []
    }
    private static func hasPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success
            && (names as? [String] ?? []).contains(kAXPressAction as String)
    }
    private static func pressable(_ element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let node = current else { return nil }
            if hasPress(node) { return node }
            current = elementAttribute(node, kAXParentAttribute)
        }
        return nil
    }
    private static func distinct(_ elements: [AXUIElement]) -> [AXUIElement] {
        elements.reduce(into: []) { result, node in
            if !result.contains(where: { CFEqual($0, node) }) { result.append(node) }
        }
    }
    private static func elementAttribute(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func contains(_ ancestor: AXUIElement, _ descendant: AXUIElement) -> Bool {
        var current: AXUIElement? = descendant
        for _ in 0..<8 {
            guard let node = current else { return false }
            if CFEqual(node, ancestor) { return true }
            current = elementAttribute(node, kAXParentAttribute)
        }
        return false
    }
    private static func y(_ element: AXUIElement) -> CGFloat {
        guard let v = attribute(element, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return 0 }
        var point = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &point)
        return point.y
    }
}
