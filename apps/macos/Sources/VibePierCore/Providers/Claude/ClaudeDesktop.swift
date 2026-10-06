import AppKit
import ApplicationServices
import Foundation

/// Finds which live Claude Code process owns a transcript, and types phone replies into the Claude desktop app
/// so they run in (and show up in) the desktop session instead of a separate headless process.
enum ClaudeDesktop {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".claude/sessions")
    struct Owner {
        let pid: Int32
        let host: String?
        let busy: Bool
        let entrypoint: String
        var desktop: Bool { host?.hasPrefix("local_") == true }
    }

    /// Live processes register in `~/.claude/sessions/<pid>.json`; stale files of exited processes are ignored.
    static func owners(_ session: String, excluding: Set<Int32> = []) -> [Owner] {
        live(excluding: excluding).filter { $0.session == session }.map(\.owner).sorted {
            ($0.desktop ? 0 : 1) < ($1.desktop ? 0 : 1)
        }
    }
    /// Every live registered process with the session it has open, read in one pass for list views.
    static func live(excluding: Set<Int32> = []) -> [(session: String, owner: Owner)] {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> (String, Owner)? in
            guard let data = try? Data(contentsOf: url),
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let session = value["sessionId"] as? String, let pid = (value["pid"] as? NSNumber)?.int32Value, pid > 0,
                !excluding.contains(pid),
                kill(pid, 0) == 0 || errno == EPERM
            else { return nil }
            return (
                session,
                Owner(
                    pid: pid, host: value["hostSessionId"] as? String, busy: value["status"] as? String == "busy",
                    entrypoint: value["entrypoint"] as? String ?? "")
            )
        }
    }

    /// Opens the session in the desktop app, confirms the visible route really is that session, then pastes and submits.
    static func deliver(
        _ text: String, host: String, willSubmit: () throws -> Void, confirmed: (Double) -> Bool
    ) throws {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        let (element, previous) = try reveal(host)
        defer { restore(previous) }
        var found: AXUIElement?
        if !wait(
            2,
            {
                found = composer(element)
                return found != nil
            })
        {
            found = try revise(element, host: host)
        }
        guard let field = found else {
            throw CLIError(L10n.text("provider.claude_desktop_composer_not_found_nothing_was_sent"))
        }
        func emptyDraft() -> Bool { (value(field) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let originalWindow = focusedWindow(element) else {
            throw CLIError(L10n.text("provider.desktop_input_changed"))
        }
        func focusedComposer() -> Bool {
            guard frontmost(element), matchesSession(host, address: route(element)),
                let window = focusedWindow(element), CFEqual(window, originalWindow),
                let current = composer(element), CFEqual(current, field),
                let focused = attribute(element, kAXFocusedUIElementAttribute),
                CFGetTypeID(focused) == AXUIElementGetTypeID()
            else { return false }
            return CFEqual(focused, field)
        }
        guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
            wait(1, focusedComposer)
        else { throw CLIError(L10n.text("provider.desktop_input_changed")) }
        func clearDraft() throws {
            try key(0, flags: .maskCommand)
            guard focusedComposer() else { throw CLIError(L10n.text("provider.desktop_input_changed")) }
            try key(51)
            guard wait(1, { focusedComposer() && emptyDraft() }) else {
                throw CLIError(L10n.text("provider.could_not_clear_the_claude_desktop_draft_nothing_was_sent"))
            }
        }
        // The phone message takes priority: discard a leftover draft rather than refusing to send.
        if !emptyDraft() { try clearDraft() }
        let clipboard = try DesktopClipboard(NSPasteboard.general)
        try clipboard.write(text)
        defer {
            Thread.sleep(forTimeInterval: 0.3)
            clipboard.restore()
        }
        guard focusedComposer(), clipboard.isCurrent else {
            throw CLIError(L10n.text("provider.desktop_input_changed"))
        }
        try key(9, flags: .maskCommand)
        let expected = ClaudeSendReceipt.normalized(text)
        func exactDraft() -> Bool { ClaudeSendReceipt.normalized(value(field) ?? "") == expected }
        guard wait(1.5, { focusedComposer() && clipboard.isCurrent && exactDraft() }) else {
            // Take back what was pasted so it does not block the next send as a stale draft.
            if focusedComposer() { try? clearDraft() }
            throw CLIError(L10n.text("provider.could_not_fill_the_claude_desktop_composer_nothing_was_sent"))
        }
        try DesktopMutationScope.confirmedAction(
            isCurrent: { focusedComposer() && clipboard.isCurrent && exactDraft() },
            prepare: {
                try willSubmit()
                return { try key(36) }
            }, confirmed: { confirmed(15) },
            unavailable: L10n.text("provider.claude_desktop_lost_focus_the_content_remains_in_the_composer_unsent"),
            unconfirmed: L10n.text(
                "provider.content_was_entered_on_the_desktop_but_sending_is_unconfirmed_check_on_the_m"))
    }

    struct Controls {
        let model: String
        let effort: String
        var models: [String]
        var mode: String = "default"
        var contextUsage: String = ""
        func withModels(_ choices: [String]) -> Controls {
            var copy = self
            copy.models = choices
            return copy
        }
    }
    static let modeTitles = [
        "auto": "Auto", "default": "Manual", "acceptEdits": "Accept edits", "plan": "Plan",
        "bypassPermissions": "Bypass permissions",
    ]
    static func modeID(_ title: String) -> String? { modeTitles.first { $0.value == title }?.key }
    private static func modeControl(_ application: AXUIElement) -> AXUIElement? {
        guard let window = focusedWindow(application) else { return nil }
        return find(window) { role($0) == "AXPopUpButton" && modeID(title($0)) != nil }.first
    }
    /// The native Effort slider exposes Low=0, Medium=1, High=2.
    static func effortValue(_ effort: String) -> Int? {
        ["low": 0, "medium": 1, "high": 2][effort]
    }
    static func efforts(for model: String) -> [String] {
        model.hasPrefix("Haiku ") ? ["default"] : ["low", "medium", "high"]
    }
    static func modelLabel(_ title: String) -> String? {
        guard let range = title.range(of: "^(?:Sonnet|Opus|Haiku) [0-9]+(?:\\.[0-9]+)*", options: .regularExpression)
        else { return nil }
        return String(title[range])
    }
    private static func title(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0) as? String }.first {
            !$0.isEmpty
        } ?? ""
    }
    private static func control(_ application: AXUIElement, prefix: String) -> AXUIElement? {
        guard let window = focusedWindow(application) else { return nil }
        return find(window) { role($0) == "AXPopUpButton" && title($0).hasPrefix(prefix) }.first
    }
    private static func press(_ element: AXUIElement, application: AXUIElement, host: String) throws {
        try DesktopInput.perform(
            isCurrent: {
                frontmost(application) && matchesSession(host, address: route(application)) && enabled(element)
            },
            supportsPress: DesktopInput.hasPress(element),
            press: {
                guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                    throw CLIError(L10n.text("provider.could_not_operate_the_claude_desktop_model_control"))
                }
            }, prepareClick: { nil })
    }
    private static func enabled(_ element: AXUIElement) -> Bool {
        attribute(element, kAXEnabledAttribute) as? Bool ?? true
    }
    private static func dismissMenu(_ application: AXUIElement, host: String) {
        guard frontmost(application), matchesSession(host, address: route(application)),
            let window = focusedWindow(application)
        else { return }
        let menus = find(window) { ["AXMenu", "AXPopover"].contains(role($0)) }
        guard menus.count == 1, let menu = menus.first else { return }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(menu, &actions) == .success,
            (actions as? [String] ?? []).contains(kAXCancelAction as String)
        else { return }
        // Escape also means Stop/Revise in Claude. Never send it merely to close a menu.
        _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }
    private static func readControls(_ application: AXUIElement, models: [String] = []) throws -> Controls {
        guard let button = control(application, prefix: "Model: ") else {
            throw CLIError(L10n.text("provider.claude_desktop_model_menu_not_found"))
        }
        let model = String(title(button).dropFirst("Model: ".count))
        let effort =
            control(application, prefix: "Effort: ").map { String(title($0).dropFirst("Effort: ".count)).lowercased() }
            ?? "default"
        var controls = Controls(model: model, effort: effort, models: models)
        controls.mode = modeControl(application).flatMap { modeID(title($0)) } ?? "default"
        controls.contextUsage =
            control(application, prefix: "Usage: ").map { String(title($0).dropFirst("Usage: ".count)) } ?? ""
        return controls
    }
    static func visibleControls(host: String) -> Controls? {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        guard matchesSession(host, address: route(element)) else { return nil }
        return try? readControls(element)
    }
    /// Read the gateway's actual model menu rather than CLI aliases, which desktop treats as unsupported.
    static func controls(host: String) throws -> Controls {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        let (application, previous) = try reveal(host)
        defer { restore(previous) }
        guard let button = control(application, prefix: "Model: ") else {
            throw CLIError(L10n.text("provider.claude_desktop_model_menu_not_found"))
        }
        let current = try readControls(application)
        try press(button, application: application, host: host)
        defer { dismissMenu(application, host: host) }
        var choices: [String] = []
        guard
            wait(
                2,
                {
                    guard let window = focusedWindow(application) else { return false }
                    choices = find(window) { role($0) == "AXMenuItem" }.compactMap { modelLabel(title($0)) }
                    return !choices.isEmpty
                })
        else { throw CLIError(L10n.text("provider.could_not_read_the_models_available_in_claude_desktop")) }
        return current.withModels(Array(NSOrderedSet(array: choices)) as? [String] ?? choices)
    }
    static func selectModel(_ model: String, host: String, mutation: DesktopMutationScope) throws -> Controls {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        let (application, previous) = try reveal(host)
        defer { restore(previous) }
        if let current = try? readControls(application), current.model == model { return current }
        guard let button = control(application, prefix: "Model: ") else {
            throw CLIError(L10n.text("provider.claude_desktop_model_menu_not_found"))
        }
        try press(button, application: application, host: host)
        var item: AXUIElement?
        guard
            wait(
                2,
                {
                    guard let window = focusedWindow(application) else { return false }
                    item = find(window) { role($0) == "AXMenuItem" && modelLabel(title($0)) == model }.first
                    return item != nil
                }), let item
        else {
            dismissMenu(application, host: host)
            throw CLIError(
                L10n.text("provider.the_selected_model_is_no_longer_available_on_the_desktop_reopen_the_model_me"))
        }
        try mutation.attempt { try press(item, application: application, host: host) }
        guard wait(2, { (try? readControls(application).model) == model }) else {
            throw CLIError(L10n.text("provider.claude_desktop_model_change_is_unconfirmed"))
        }
        return try readControls(application)
    }

    static func selectEffort(_ effort: String, host: String, mutation: DesktopMutationScope) throws -> Controls {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        guard let target = effortValue(effort) else {
            throw CLIError(L10n.text("provider.the_desktop_supports_low_medium_and_high_reasoning_effort"))
        }
        let (application, previous) = try reveal(host)
        defer { restore(previous) }
        let current = try readControls(application)
        if current.effort == effort { return current }
        guard let button = control(application, prefix: "Effort: ") else {
            throw CLIError(L10n.text("provider.the_current_desktop_model_has_no_reasoning_effort_control"))
        }
        try press(button, application: application, host: host)
        defer { dismissMenu(application, host: host) }
        var slider: AXUIElement?
        guard
            wait(
                2,
                {
                    guard let window = focusedWindow(application) else { return false }
                    slider = find(window) { role($0) == "AXSlider" && title($0) == "Effort" }.first
                    return slider != nil
                }), let slider
        else { throw CLIError(L10n.text("provider.claude_desktop_reasoning_effort_slider_not_found")) }
        // Native increment/decrement fires the UI's change handler; writing AXValue alone may not commit it.
        for _ in 0..<4 {
            guard frontmost(application), matchesSession(host, address: route(application)),
                let value = attribute(slider, kAXValueAttribute) as? NSNumber
            else { throw CLIError(L10n.text("provider.the_reasoning_effort_control_changed_the_change_was_stopped")) }
            let before = value.intValue
            if before == target { break }
            let action = before < target ? kAXIncrementAction : kAXDecrementAction
            let status = try mutation.attempt { AXUIElementPerformAction(slider, action as CFString) }
            guard status == .success,
                wait(1, { (attribute(slider, kAXValueAttribute) as? NSNumber)?.intValue != before })
            else {
                throw CLIError(L10n.text("provider.could_not_change_claude_desktop_reasoning_effort"))
            }
        }
        guard
            wait(
                2,
                {
                    guard let selected = try? readControls(application) else { return false }
                    return selected.model == current.model && selected.effort == effort
                })
        else { throw CLIError(L10n.text("provider.claude_desktop_reasoning_effort_change_is_unconfirmed")) }
        return try readControls(application)
    }

    static func selectMode(_ mode: String, host: String, mutation: DesktopMutationScope) throws -> Controls {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        guard let name = modeTitles[mode] else {
            throw CLIError(L10n.text("provider.this_permission_mode_is_not_supported"))
        }
        let (application, previous) = try reveal(host)
        defer { restore(previous) }
        let current = try readControls(application)
        if current.mode == mode { return current }
        guard let button = modeControl(application) else {
            throw CLIError(L10n.text("provider.claude_desktop_permission_mode_menu_not_found"))
        }
        try press(button, application: application, host: host)
        var item: AXUIElement?
        guard
            wait(
                2,
                {
                    guard let window = focusedWindow(application) else { return false }
                    item =
                        find(window) {
                            role($0) == "AXMenuItem" && (title($0) == name || title($0).hasPrefix(name + " "))
                        }.first
                    return item != nil
                }), let item
        else {
            dismissMenu(application, host: host)
            throw CLIError(L10n.text("provider.the_selected_permission_mode_is_unavailable_on_the_desktop"))
        }
        try mutation.attempt { try press(item, application: application, host: host) }
        guard wait(2, { (try? readControls(application).mode) == mode }) else {
            throw CLIError(
                L10n.text("provider.permission_mode_change_is_unconfirmed_if_claude_shows_a_confirmation_handle_"))
        }
        return try readControls(application)
    }
    static func contextUsage(host: String) throws -> (controls: Controls, detail: String) {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        let (application, previous) = try reveal(host)
        defer { restore(previous) }
        let current = try readControls(application)
        guard let button = control(application, prefix: "Usage: ") else {
            throw CLIError(L10n.text("provider.context_usage_is_unavailable_for_the_current_desktop_session"))
        }
        try press(button, application: application, host: host)
        defer { dismissMenu(application, host: host) }
        var detail = ""
        _ = wait(
            2,
            {
                guard let window = focusedWindow(application) else { return false }
                detail = find(window) { role($0) == "AXImage" && title($0).hasPrefix("Context window:") }.map(title)
                    .joined(separator: "\n")
                return !detail.isEmpty
            })
        return (current, detail)
    }

    /// Button text of the desktop permission card; a trailing shortcut hint may follow the label. The plan card's
    /// "Accept" keeps the current mode, unlike "Accept and auto mode"; its Esc means "Revise…", not reject.
    static func permissionButton(_ label: String, allow: Bool, plan: Bool = false) -> Bool {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if plan {
            let name = allow ? "Accept" : "Reject"
            if text == name { return true }
            guard text.hasPrefix(name + " ") else { return false }
            let shortcut = text.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed = CharacterSet(charactersIn: "⇧⌘⌥⌃↵⏎").union(.whitespaces)
            return !shortcut.isEmpty && shortcut.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        return allow
            ? text.hasPrefix("Allow once") || text == "Allow" || text.hasPrefix("允许一次")
            : text.hasPrefix("Deny") || text.hasPrefix("Decline") || text.hasPrefix("拒绝")
    }
    /// Answers the one permission card shown in the session; `confirmed` waits for the desktop to record it.
    /// Uses one verified real click; a delayed acknowledgment must never trigger another approval action.
    static func answerPermission(
        allow: Bool, plan: Bool = false, host: String, stillPending: @escaping () -> Bool, confirmed: (Double) -> Bool
    ) throws {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        let (application, previous) = try reveal(host)
        defer { restore(previous) }
        var buttons: [AXUIElement] = []
        guard
            wait(
                2,
                {
                    guard let window = focusedWindow(application) else { return false }
                    buttons = find(window, limit: 12000) {
                        role($0) == "AXButton" && permissionButton(label($0), allow: allow, plan: plan)
                    }
                    return !buttons.isEmpty
                })
        else {
            throw CLIError(L10n.text("provider.claude_desktop_approval_button_not_found_handle_the_request_on_the_mac"))
        }
        guard buttons.count == 1, let button = buttons.first else {
            throw CLIError(L10n.text("provider.multiple_approvals_are_visible_on_the_desktop_handle_them_on_the_mac"))
        }
        try submitApproval(
            button, application: application, host: host, stillPending: stillPending, confirmed: confirmed)
    }
    /// Answers an `AskUserQuestion` card by pressing the button labeled with the chosen option, the same way
    /// `answerPermission` presses Allow/Deny. Both perform only one verified click.
    static func answerQuestion(
        option: String, host: String, stillPending: @escaping () -> Bool, confirmed: (Double) -> Bool
    ) throws {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        let (application, previous) = try reveal(host)
        defer { restore(previous) }
        let target = option.trimmingCharacters(in: .whitespacesAndNewlines)
        var buttons: [AXUIElement] = []
        guard
            wait(
                2,
                {
                    guard let window = focusedWindow(application) else { return false }
                    buttons = find(window, limit: 12000) {
                        role($0) == "AXButton" && label($0).trimmingCharacters(in: .whitespacesAndNewlines) == target
                    }
                    return !buttons.isEmpty
                })
        else { throw CLIError(L10n.text("provider.claude_desktop_option_button_not_found_answer_on_the_mac")) }
        guard buttons.count == 1, let button = buttons.first else {
            throw CLIError(L10n.text("provider.multiple_desktop_options_have_the_same_label_answer_on_the_mac"))
        }
        try submitApproval(
            button, application: application, host: host, stillPending: stillPending, confirmed: confirmed)
    }
    private static func submitApproval(
        _ button: AXUIElement, application: AXUIElement, host: String,
        stillPending: @escaping () -> Bool, confirmed: (Double) -> Bool
    ) throws {
        try DesktopMutationScope.confirmedAction(
            isCurrent: {
                frontmost(application) && matchesSession(host, address: route(application)) && stillPending()
            },
            prepare: {
                DesktopInput.prepareClick(
                    button, application: application,
                    isCurrent: {
                        frontmost(application) && matchesSession(host, address: route(application)) && stillPending()
                            && enabled(button)
                    })
            }, confirmed: { confirmed(5) },
            unavailable: L10n.text("provider.claude_approval_not_current"),
            unconfirmed: L10n.text(
                "provider.the_desktop_approval_button_was_pressed_but_the_result_is_unconfirmed_check_"))
    }
    /// Chromium buttons may name themselves only through their text children.
    private static func label(_ element: AXUIElement) -> String {
        let own = title(element)
        if !own.isEmpty { return own }
        return find(element, limit: 12) { role($0) == "AXStaticText" }.compactMap(value).joined(separator: " ")
    }

    /// A proposed plan replaces the composer with its card; a message then means "Revise…", as typing feedback does on
    /// the desktop, so open that and hand back its text field. Nil when there is no plan card or it does not open.
    private static func revise(_ application: AXUIElement, host: String) throws -> AXUIElement? {
        guard let window = focusedWindow(application) else { return nil }
        let buttons = find(window, limit: 12000) {
            role($0) == "AXButton" && label($0).trimmingCharacters(in: .whitespaces).hasPrefix("Revise")
        }
        guard buttons.count == 1, let button = buttons.first else { return nil }
        func ready() -> Bool {
            frontmost(application) && matchesSession(host, address: route(application)) && enabled(button)
        }
        try DesktopInput.perform(
            isCurrent: ready, supportsPress: DesktopInput.hasPress(button),
            press: {
                guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                    throw CLIError(L10n.text("provider.desktop_input_changed"))
                }
            }, prepareClick: { DesktopInput.prepareClick(button, application: application, isCurrent: ready) })
        var field: AXUIElement?
        guard
            wait(
                1.5,
                {
                    guard frontmost(application), matchesSession(host, address: route(application)) else {
                        return false
                    }
                    field = composer(application)
                    return field != nil
                })
        else { throw UnconfirmedDesktopMutation(reason: L10n.text("provider.desktop_input_changed")) }
        return field
    }

    /// Presses Escape in the desktop session, which stops its running turn.
    static func interrupt(host: String, isCurrent: () -> Bool, confirmed: (Double) -> Bool) throws {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        let (element, previous) = try reveal(host)
        defer { restore(previous) }
        if let field = composer(element) {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        try DesktopMutationScope.confirmedAction(
            isCurrent: { frontmost(element) && matchesSession(host, address: route(element)) && isCurrent() },
            prepare: { { try key(53) } }, confirmed: { confirmed(5) },
            unavailable: L10n.text("session.the_running_task_changed_the_new_task_was_not_stopped"),
            unconfirmed: L10n.text("provider.claude_stop_unconfirmed"))
    }

    private static func reveal(_ host: String) throws -> (AXUIElement, NSRunningApplication?) {
        guard AXIsProcessTrusted() else {
            throw CLIError(L10n.text("provider.vibepier_needs_accessibility_permission_to_send_to_claude_desktop"))
        }
        // Callers that type or click unlock first (ScreenLock.unlocked); nothing may land on the lock screen.
        guard !ScreenLock.locked() else { throw ScreenLock.lockedError }
        guard host.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil,
            let url = URL(string: "claude://code/continue?session=" + host)
        else { throw CLIError(L10n.text("provider.invalid_desktop_session")) }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw CLIError(L10n.text("provider.claude_desktop_is_not_running"))
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let element = AXUIElementCreateApplication(application.processIdentifier)
        // Chromium only builds its accessibility tree for clients that ask for it.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if !frontmost(element) { application.activate() }
        guard wait(3, { frontmost(element) }) else {
            throw CLIError(L10n.text("provider.could_not_bring_claude_desktop_to_the_foreground_no_action_was_taken"))
        }
        if !matchesSession(host, address: route(element)) {
            // Builds with code entry points off log "deep link ignored", so fall back to the sidebar row.
            _ = NSWorkspace.shared.open(url)
            if !wait(1, { matchesSession(host, address: route(element)) }) { try select(host, in: element) }
        }
        guard wait(3, { frontmost(element) && matchesSession(host, address: route(element)) }) else {
            throw CLIError(
                L10n.text("provider.could_not_verify_that_claude_desktop_opened_this_session_no_action_was_taken"))
        }
        return (element, previous?.bundleIdentifier == bundleID ? nil : previous)
    }
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    /// Phone sessions belong in the desktop app; start it when it is installed but not running.
    static func launchIfNeeded() throws {
        if running { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw CLIError(L10n.text("provider.claude_desktop_is_not_running"))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        guard wait(15, { running }) else { throw CLIError(L10n.text("provider.claude_desktop_is_not_running")) }
        // The window and its session index need a moment after the process appears.
        Thread.sleep(forTimeInterval: 2)
    }
    /// Passive identity only: no activation, navigation, title guessing or permission prompt.
    static func visibleSessionHost() -> String? {
        guard AXIsProcessTrusted(), !ScreenLock.locked(),
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        guard frontmost(application) else { return nil }
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return sessionHost(from: route(application))
    }
    static func sessionHost(from address: String) -> String? {
        guard let url = URL(string: address), let host = url.pathComponents.last,
            host.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
        else { return nil }
        return host
    }
    static func matchesSession(_ host: String, address: String) -> Bool {
        sessionHost(from: address) == host
    }
    /// A menu-bar selection leaves this exact native session in front, without sending anything.
    static func show(session: String) throws {
        guard UUID(uuidString: session) != nil else {
            throw CLIError(L10n.text("provider.invalid_claude_code_session"))
        }
        guard !ScreenLock.locked() else { throw ScreenLock.lockedError }
        let host: String
        if let existing = ClaudeDesktop.host(forCLI: session) {
            host = existing
        } else {
            guard owners(session).isEmpty else {
                throw CLIError(
                    L10n.text("provider.this_claude_code_session_is_still_owned_by_a_terminal_view_it_in_that_termin"))
            }
            host = try adopt(session)
        }
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        _ = try reveal(host)
    }
    /// The desktop session that wraps a CLI transcript, from the desktop's local session records.
    static func host(forCLI session: String) -> String? {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support")
        for app in ["Claude-3p", "Claude"] {
            let root = support.appendingPathComponent(app).appendingPathComponent("claude-code-sessions")
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk
            where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                    let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    value["cliSessionId"] as? String == session, let host = value["sessionId"] as? String,
                    host.hasPrefix("local_")
                {
                    return host
                }
            }
        }
        return nil
    }
    /// Imports a transcript no process has open into the desktop app (`claude://resume`), so it is listed and continued there.
    /// The caller must make sure nothing else is writing it: the deep link does not check for a live writer.
    static func adopt(_ session: String, restoreFocus: Bool = false) throws -> String {
        try DesktopInteractions.acquire()
        defer { DesktopInteractions.lock.unlock() }
        if let host = host(forCLI: session) { return host }
        guard UUID(uuidString: session) != nil, let url = URL(string: "claude://resume?session=" + session) else {
            throw CLIError(L10n.text("provider.invalid_session"))
        }
        try launchIfNeeded()
        let previous = NSWorkspace.shared.frontmostApplication
        _ = NSWorkspace.shared.open(url)
        var found: String?
        let imported = wait(15) {
            found = host(forCLI: session)
            return found != nil
        }
        if restoreFocus, previous?.bundleIdentifier != bundleID {
            Thread.sleep(forTimeInterval: 0.5)
            restore(previous)
        }
        guard imported, let found else {
            throw CLIError(
                L10n.text("provider.claude_desktop_could_not_import_this_session_the_project_may_not_be_trusted_"))
        }
        return found
    }
    /// The desktop's own title for a session, from its local session records.
    static func sessionTitle(_ host: String) -> String? {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support")
        for app in ["Claude-3p", "Claude"] {
            let root = support.appendingPathComponent(app).appendingPathComponent("claude-code-sessions")
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.lastPathComponent == host + ".json" {
                if let data = try? Data(contentsOf: url),
                    let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let title = value["title"] as? String, !title.isEmpty
                {
                    return title
                }
            }
        }
        return nil
    }
    /// Opens the session from the sidebar: a link to it if one is exposed, else the one row titled like it.
    private static func select(_ host: String, in application: AXUIElement) throws {
        guard let window = focusedWindow(application) else {
            throw CLIError(L10n.text("provider.claude_desktop_window_not_found_no_action_was_taken"))
        }
        func url(_ element: AXUIElement) -> String {
            (attribute(element, "AXURL") as? URL)?.absoluteString ?? attribute(element, "AXURL") as? String ?? ""
        }
        var targets = find(window, limit: 15000) { role($0) == "AXLink" && matchesSession(host, address: url($0)) }
        if targets.isEmpty {
            guard let name = sessionTitle(host)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw CLIError(
                    L10n.text("provider.the_desktop_title_for_this_session_was_not_found_open_it_on_the_mac_before_r"))
            }
            let rows = find(window, limit: 15000) {
                ["AXButton", "AXLink", "AXStaticText", "AXRow", "AXCell"].contains(role($0))
                    && label($0).trimmingCharacters(in: .whitespacesAndNewlines) == name
            }
            for row in rows.compactMap(pressable) where !targets.contains(where: { CFEqual($0, row) }) {
                targets.append(row)
            }
            guard !targets.isEmpty else {
                throw CLIError(
                    L10n.text(
                        "provider.session_0_was_not_found_in_the_claude_desktop_sidebar_open_it_on_the_mac_bef", name))
            }
            guard targets.count == 1 else {
                throw CLIError(
                    L10n.text(
                        "provider.claude_desktop_has_multiple_sessions_named_0_open_the_intended_session_on_th", name))
            }
        }
        guard targets.count == 1, let row = targets.first else {
            throw CLIError(L10n.text("provider.desktop_input_changed"))
        }
        guard frontmost(application) else { throw CLIError(L10n.text("provider.desktop_input_changed")) }
        AXUIElementPerformAction(row, "AXScrollToVisible" as CFString)
        try DesktopInput.perform(
            isCurrent: { frontmost(application) && enabled(row) }, supportsPress: DesktopInput.hasPress(row),
            press: {
                guard AXUIElementPerformAction(row, kAXPressAction as CFString) == .success else {
                    throw CLIError(L10n.text("provider.desktop_input_changed"))
                }
            },
            prepareClick: {
                DesktopInput.prepareClick(
                    row, application: application, isCurrent: { frontmost(application) && enabled(row) })
            })
    }
    /// The element itself or its nearest ancestor that can be pressed, as a sidebar row's title text sits inside its button.
    private static func pressable(_ element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let node = current else { return nil }
            var names: CFArray?
            if AXUIElementCopyActionNames(node, &names) == .success,
                (names as? [String] ?? []).contains(kAXPressAction as String)
            {
                return node
            }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                return nil
            }
            current = (parent as! AXUIElement)
        }
        return nil
    }
    /// Read live through AX: `NSRunningApplication.isActive` only updates on the main run loop.
    private static func frontmost(_ application: AXUIElement) -> Bool {
        attribute(application, kAXFrontmostAttribute) as? Bool == true
    }
    private static func restore(_ previous: NSRunningApplication?) { previous?.activate() }
    private static func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        try DesktopInput.key(code, flags: flags)
    }
    private static func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func value(_ element: AXUIElement) -> String? { attribute(element, kAXValueAttribute) as? String }
    private static func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) as? String ?? "" }
    private static func focusedWindow(_ application: AXUIElement) -> AXUIElement? {
        guard let window = attribute(application, kAXFocusedWindowAttribute),
            CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return (window as! AXUIElement)
    }
    /// Breadth-first search bounded so a huge transcript view cannot stall the bridge.
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
    /// The page URL of the web area; desktop session routes end in `/<hostSessionId>`.
    private static func route(_ application: AXUIElement) -> String {
        guard let window = focusedWindow(application) else { return "" }
        return find(window, limit: 400, descendIntoMatches: false) { role($0) == "AXWebArea" }.compactMap {
            (attribute($0, "AXURL") as? URL)?.absoluteString ?? attribute($0, "AXURL") as? String
        }
        .first { $0.contains("local_") } ?? ""
    }
    /// Require a unique editable area in the current window. A focused unrelated text area
    /// or a bottom-most positional guess is not sufficient identity for remote typing.
    private static func composer(_ application: AXUIElement) -> AXUIElement? {
        guard let window = focusedWindow(application) else { return nil }
        let fields = find(window) { role($0) == "AXTextArea" && enabled($0) }
        return fields.count == 1 ? fields.first : nil
    }
}
