import Foundation

/// A failure after entering a desktop mutation boundary cannot prove that nothing happened.
/// Keep this semantic flag independent of the localized diagnostic supplied by the platform.
struct UnconfirmedDesktopMutation: Error, CustomStringConvertible, Sendable {
    let reason: String
    var description: String { L10n.text("control.unconfirmed_desktop_mutation", reason) }

    static func attempting<T>(_ action: () throws -> T) throws -> T {
        do { return try action() } catch let error as UnconfirmedDesktopMutation {
            throw error
        } catch {
            throw UnconfirmedDesktopMutation(reason: String(describing: error))
        }
    }
}

/// One request may change several controls. Any later failure must retain uncertainty about earlier effects.
final class DesktopMutationScope {
    private(set) var attempted = false

    func attempt<T>(_ action: () throws -> T) throws -> T {
        attempted = true
        return try action()
    }

    static func run<T>(_ body: (DesktopMutationScope) throws -> T) throws -> T {
        let scope = DesktopMutationScope()
        do { return try body(scope) } catch {
            if scope.attempted {
                return try UnconfirmedDesktopMutation.attempting { throw error }
            }
            throw error
        }
    }

    /// Prepare without side effects, recheck identity, submit once, then observe. Never fall back after submission.
    static func confirmedAction(
        isCurrent: () -> Bool, prepare: () throws -> (() throws -> Void)?,
        confirmed: () throws -> Bool, unavailable: String, unconfirmed: String
    ) throws {
        guard isCurrent(), let action = try prepare(), isCurrent() else { throw CLIError(unavailable) }
        try UnconfirmedDesktopMutation.attempting {
            try action()
            guard try confirmed() else { throw CLIError(unconfirmed) }
        }
    }
}

enum ProviderFailure {
    static func reply(_ error: Error, provider: String) -> [String: Any] {
        var result: [String: Any] = ["ok": false, "error": String(describing: error), "provider": provider]
        if error is UnconfirmedDesktopMutation { result["unknown"] = true }
        return result
    }
}
