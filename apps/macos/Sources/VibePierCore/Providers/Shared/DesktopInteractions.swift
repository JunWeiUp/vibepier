import Foundation

/// Desktop composers share focus and the clipboard. Serialize active interactions
/// across providers and phones; nested helpers may re-enter the same operation.
enum DesktopInteractions {
    static let lock = NSRecursiveLock()

    /// Never let one stalled app make every other provider wait indefinitely for desktop focus.
    static func acquire(_ target: NSRecursiveLock = lock, timeout: Double = 2) throws {
        guard target.lock(before: Date().addingTimeInterval(timeout)) else {
            throw CLIError(L10n.text("session.desktop_busy"))
        }
    }

    static func perform<T>(_ body: () throws -> T) throws -> T {
        try acquire()
        defer { lock.unlock() }
        return try body()
    }
}
