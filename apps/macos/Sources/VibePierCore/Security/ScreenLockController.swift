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
    private let relockGrace: Double
    private let schedule: @Sendable (Double, @escaping @Sendable () -> Void) -> Void
    private let localIdleSeconds: @Sendable () -> Double
    private var holds = 0
    private var unlockedByUs = false
    private var lastAttemptFailed = false
    private var relockGeneration = 0
    init(
        isLocked: @escaping @Sendable () -> Bool, unlock: @escaping @Sendable () throws -> Void,
        lock: @escaping @Sendable () throws -> Void, relockGrace: Double = 0,
        schedule: @escaping @Sendable (Double, @escaping @Sendable () -> Void) -> Void = { _, work in work() },
        localIdleSeconds: @escaping @Sendable () -> Double = { .infinity }
    ) {
        self.isLocked = isLocked
        self.unlock = unlock
        self.lock = lock
        self.relockGrace = relockGrace
        self.schedule = schedule
        self.localIdleSeconds = localIdleSeconds
    }
    var failed: Bool {
        mutex.withLock {
            if !isLocked() { lastAttemptFailed = false }
            return lastAttemptFailed
        }
    }
    func resetFailure() { mutex.withLock { lastAttemptFailed = false } }
    private func unlockIfNeeded() throws -> Bool {
        guard isLocked() else {
            lastAttemptFailed = false
            return false
        }
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
            relockGeneration &+= 1
            if try unlockIfNeeded() { unlockedByUs = true }
            holds += 1
        }
    }
    func release() {
        let pending: Int? = mutex.withLock {
            guard holds > 0 else { return nil }
            holds -= 1
            guard holds == 0, unlockedByUs else { return nil }
            guard relockGrace > 0 else {
                unlockedByUs = false
                if !isLocked() { try? lock() }
                return nil
            }
            relockGeneration &+= 1
            return relockGeneration
        }
        guard let pending else { return }
        schedule(relockGrace) { [weak self] in self?.relockIfIdle(pending) }
    }
    /// A later lease, explicit lock/unlock, or local keyboard/mouse use since the release cancels the grace relock.
    private func relockIfIdle(_ generation: Int) {
        mutex.withLock {
            guard generation == relockGeneration, holds == 0, unlockedByUs else { return }
            unlockedByUs = false
            guard !isLocked(), localIdleSeconds() >= relockGrace * 0.9 else { return }
            try? lock()
        }
    }
    func lockNow() throws {
        try mutex.withLock {
            guard holds == 0 else {
                throw CLIError(L10n.text("core.the_mac_is_performing_a_desktop_action_wait_before_locking_it"))
            }
            if !isLocked() {
                lastAttemptFailed = false
                try lock()
            }
            unlockedByUs = false
            relockGeneration &+= 1
        }
    }
    func unlockNow() throws {
        try mutex.withLock {
            _ = try unlockIfNeeded()
            // An explicit unlock stays unlocked, including after an existing temporary lease ends.
            unlockedByUs = false
            relockGeneration &+= 1
        }
    }
}
