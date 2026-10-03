import Foundation

struct ScreenUnlockAttemptFailed: Error, CustomStringConvertible {
    let description = L10n.text("core.unlock_failed_further_attempts_are_stopped_unlock_the_mac_manually_o")
}

/// Serializes explicit lock/unlock with temporary desktop-action leases.
/// Injected system actions keep unit tests away from the real lock screen and password store.
final class ScreenLockController: @unchecked Sendable {
    private let mutex = NSRecursiveLock()
    private let isLocked: @Sendable () -> Bool
    private let unlock: @Sendable () throws -> Void
    private let lock: @Sendable () throws -> Void
    private var holds = 0
    private var unlockedByUs = false
    private var lastAttemptFailed = false
    init(
        isLocked: @escaping @Sendable () -> Bool, unlock: @escaping @Sendable () throws -> Void,
        lock: @escaping @Sendable () throws -> Void
    ) {
        self.isLocked = isLocked
        self.unlock = unlock
        self.lock = lock
    }
    var failed: Bool { mutex.withLock { lastAttemptFailed } }
    func resetFailure() { mutex.withLock { lastAttemptFailed = false } }
    private func unlockIfNeeded() throws -> Bool {
        guard isLocked() else { return false }
        guard !lastAttemptFailed else {
            throw CLIError(L10n.text("core.the_previous_unlock_failed_further_attempts_are_stopped_set_the_unlo"))
        }
        do { try unlock() } catch let error as ScreenUnlockAttemptFailed {
            lastAttemptFailed = true
            throw error
        }
        return true
    }
    func acquire() throws {
        try mutex.withLock {
            if try unlockIfNeeded() { unlockedByUs = true }
            holds += 1
        }
    }
    func release() {
        mutex.withLock {
            guard holds > 0 else { return }
            holds -= 1
            guard holds == 0, unlockedByUs else { return }
            unlockedByUs = false
            if !isLocked() { try? lock() }
        }
    }
    func lockNow() throws {
        try mutex.withLock {
            guard holds == 0 else {
                throw CLIError(L10n.text("core.the_mac_is_performing_a_desktop_action_wait_before_locking_it"))
            }
            if !isLocked() { try lock() }
            unlockedByUs = false
        }
    }
    func unlockNow() throws {
        try mutex.withLock {
            _ = try unlockIfNeeded()
            // An explicit unlock stays unlocked, including after an existing temporary lease ends.
            unlockedByUs = false
        }
    }
}
