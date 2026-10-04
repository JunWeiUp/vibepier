import Combine
import Foundation
import VibePierCore

/// Compatibility facade for the views; commands now execute within VibePier.
@MainActor
enum AppCommands {
    typealias Result = DriverResult
    static func run(_ arguments: [String]) async -> Result {
        await EmbeddedDriver.shared.run(arguments)
    }
    @discardableResult
    static func runQuiet(_ arguments: [String]) async -> Result {
        let token = feedback.begin(title(arguments))
        let result = await run(arguments)
        feedback.finish(token, result: result)
        return result
    }
    static let feedback = CommandFeedback()
    static var lastError: String? {
        get { feedback.error }
        set { feedback.record(error: newValue) }
    }
    static func clearError() { feedback.record(error: nil) }
    static func report(_ result: Result, operation: String) {
        feedback.record(
            error: result.success ? nil : (result.stderr.isEmpty ? result.stdout : result.stderr), operation: operation)
    }
    private static func title(_ arguments: [String]) -> String {
        switch arguments.first {
        case "hooks":
            return L10n.text(arguments.dropFirst().first == "install" ? "mac.install_hooks" : "mac.uninstall_hooks")
        case "reload": return L10n.text("mac.reload_configuration")
        default: return L10n.text("mac.operation")
        }
    }
}

@MainActor
final class CommandFeedback: ObservableObject {
    enum Phase { case running, success, failure }
    @Published private(set) var operation = ""
    @Published private(set) var phase: Phase?
    @Published private(set) var error: String?
    private var token = UUID()
    func begin(_ title: String) -> UUID {
        token = UUID()
        operation = title
        phase = .running
        error = nil
        return token
    }
    func finish(_ expected: UUID, result: DriverResult) {
        guard expected == token else { return }
        phase = result.success ? .success : .failure
        error = result.success ? nil : (result.stderr.isEmpty ? result.stdout : result.stderr)
    }
    func record(error: String?, operation: String? = nil) {
        token = UUID()
        self.error = error
        if error == nil {
            self.operation = ""
            phase = nil
        } else {
            self.operation = operation ?? L10n.text("mac.operation")
            phase = .failure
        }
    }
}
