import Foundation

/// Orders press preparation, the held shortcut, release, and heartbeat cleanup.
/// A release during preparation cancels that press rather than starting dictation late.
final class TalkKeyFlow: @unchecked Sendable {
    typealias Run = @Sendable (Bool, @escaping @Sendable () -> Bool) async -> Bool
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var down = false
    private var generation = 0
    private var active = false
    private var stopped = false

    func handle(
        pressed: Bool, prepare: @escaping @Sendable () async throws -> Void,
        run: @escaping Run, finish: @escaping @Sendable () -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        lock.withLock {
            guard !stopped, down != pressed else { return }
            down = pressed
            generation += 1
            let token = generation
            let previous = tail
            tail = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                if pressed {
                    guard self.isCurrentPress(token) else { return }
                    do {
                        try await prepare()
                        let executed = await run(true) { self.isCurrentPress(token) }
                        self.lock.withLock { self.active = executed }
                        if !executed { finish() }
                    } catch {
                        finish()
                        log("voice wake: \(error)")
                    }
                } else {
                    if self.lock.withLock({ self.active && !self.stopped }) {
                        _ = await run(false) { self.lock.withLock { !self.stopped } }
                    }
                    self.lock.withLock { self.active = false }
                    finish()
                }
            }
        }
    }

    private func isCurrentPress(_ token: Int) -> Bool {
        lock.withLock { !stopped && down && generation == token }
    }

    var isHolding: Bool { lock.withLock { down || active } }
    func stop() {
        lock.withLock {
            stopped = true
            down = false
            generation += 1
        }
    }
    func waitUntilIdle() async { await lock.withLock { tail }?.value }
}
