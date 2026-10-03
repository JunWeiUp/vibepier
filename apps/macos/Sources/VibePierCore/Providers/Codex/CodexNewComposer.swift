import AppKit
import ApplicationServices
import Foundation

/// Native selectors are the desktop's own English/Chinese accessibility labels,
/// not VibePier translations. Unknown/ambiguous layouts cannot submit.
enum CodexNewComposer {
    struct Evidence: Equatable {
        let draft: String
        let projectLabels: [String]
        let sendLabels: [String]
        let editableCount: Int
        let frontmost: Bool
        let focused: Bool
        var alternateExecution = false
    }

    static func accepts(_ value: Evidence, text: String, projectName: String) -> Bool {
        guard value.frontmost, value.focused, !value.alternateExecution, value.editableCount == 1, value.draft == text,
            value.projectLabels.count == 1, value.sendLabels.count == 1
        else { return false }
        guard let prefix = ["Change project: ", "切换项目："].first(where: value.projectLabels[0].hasPrefix) else {
            return false
        }
        let selectedName = String(value.projectLabels[0].dropFirst(prefix.count))
        return CodexCreationProject.labelIdentity(selectedName) == CodexCreationProject.labelIdentity(projectName)
            && ["Send", "发送"].contains(value.sendLabels[0])
    }

    final class Prepared: @unchecked Sendable {
        let application: AXUIElement
        let window: AXUIElement
        let field: AXUIElement
        let button: AXUIElement
        let text: String
        let project: String
        init(
            application: AXUIElement, window: AXUIElement, field: AXUIElement, button: AXUIElement,
            text: String, project: String
        ) {
            self.application = application
            self.window = window
            self.field = field
            self.button = button
            self.text = text
            self.project = project
        }
        func submit() throws {
            precondition(Thread.isMainThread)
            guard let current = CodexNewComposer.prepare(text: text, projectName: project),
                CFEqual(current.application, application), CFEqual(current.window, window),
                CFEqual(current.field, field), CFEqual(current.button, button)
            else { throw CLIError(L10n.text("session.codex_creation_composer_unverified")) }
            // A single element-bound action. Never fall back to Return, coordinates or another button.
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                throw CLIError(L10n.text("session.codex_creation_unconfirmed"))
            }
        }
    }

    static func prepare(text: String, projectName: String) -> Prepared? {
        precondition(Thread.isMainThread)
        guard !ScreenLock.locked(), AXIsProcessTrusted(),
            let running = NSWorkspace.shared.frontmostApplication, running.bundleIdentifier == "com.openai.codex"
        else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let window = element(app, kAXFocusedWindowAttribute),
            let focused = element(app, kAXFocusedUIElementAttribute),
            string(focused, kAXRoleAttribute) == kAXTextAreaRole,
            let nodes = inspect(window)
        else { return nil }
        let fields = nodes.filter { $0.role == kAXTextAreaRole }
        let projects = nodes.filter {
            [kAXComboBoxRole, kAXPopUpButtonRole, kAXButtonRole].contains($0.role)
                && ($0.label.hasPrefix("Change project: ") || $0.label.hasPrefix("切换项目："))
        }
        let buttons = nodes.filter {
            $0.role == kAXButtonRole && ["Send", "发送"].contains($0.label)
        }
        // Inspection crosses process boundaries. Re-read focus and labels after walking the tree.
        guard let currentWindow = element(app, kAXFocusedWindowAttribute), CFEqual(currentWindow, window),
            let currentFocus = element(app, kAXFocusedUIElementAttribute), CFEqual(currentFocus, focused)
        else { return nil }
        var evidence = Evidence(
            draft: string(focused, kAXValueAttribute), projectLabels: projects.map { label($0.element) },
            sendLabels: buttons.map { label($0.element) }, editableCount: fields.count,
            frontmost: !ScreenLock.locked()
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier,
            focused: fields.count == 1 && CFEqual(fields[0].element, focused))
        // The request targets the existing directory, not a new checkout requested by a retained composer mode.
        evidence.alternateExecution = nodes.contains {
            [kAXButtonRole, kAXComboBoxRole, kAXPopUpButtonRole].contains($0.role)
                && ["Remove worktree instructions", "移除工作树说明", "New local worktree", "新建本地工作树"].contains($0.label)
        }
        guard accepts(evidence, text: text, projectName: projectName), let button = buttons.first?.element,
            attribute(button, kAXEnabledAttribute) as? Bool == true,
            attribute(projects[0].element, kAXEnabledAttribute) as? Bool == true,
            supportsPress(button)
        else { return nil }
        return Prepared(
            application: app, window: window, field: focused, button: button, text: text, project: projectName)
    }

    private static func supportsPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success
            && (names as? [String] ?? []).contains(kAXPressAction)
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name) as CFTypeRef?, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }
    private static func label(_ element: AXUIElement) -> String {
        let description = string(element, kAXDescriptionAttribute)
        return description.isEmpty ? string(element, kAXTitleAttribute) : description
    }
    private struct Node {
        let element: AXUIElement
        let role: String
        let label: String
    }
    private static func inspect(_ root: AXUIElement) -> [Node]? {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        guard let nodes = DesktopAXTraversal.elements(root, limit: 2500, timeout: 1) else { return nil }
        var result: [Node] = []
        for node in nodes {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let role = string(node, kAXRoleAttribute)
            let control = [kAXButtonRole, kAXComboBoxRole, kAXPopUpButtonRole].contains(role)
            result.append(Node(element: node, role: role, label: control ? label(node) : ""))
        }
        return ProcessInfo.processInfo.systemUptime < deadline ? result : nil
    }
}
