import Foundation

/// Bounds work waiting on one provider's serial state queue. An expired queued mutation is never
/// executed later. Running work is not cancelled or uncharged: its original callback owns the result.
final class SessionRequestAdmission: @unchecked Sendable {
    private enum State { case waiting, running, expired, stalled }
    private struct Entry {
        var state: State = .waiting
        let timer: DispatchSourceTimer
        let rejected: @Sendable () -> Void
        var deadline: Double
    }
    private let lock = NSLock()
    private let timers: DispatchQueue
    private var entries: [UUID: Entry] = [:]
    private let limit: Int
    private let waitTimeout: Double
    private let runningTimeout: Double

    init(
        limit: Int = 16, waitTimeout: Double = 6, runningTimeout: Double = 30,
        timers: DispatchQueue = DispatchQueue(label: "vibepier.provider-admission")
    ) {
        self.limit = limit
        self.waitTimeout = waitTimeout
        self.runningTimeout = runningTimeout
        self.timers = timers
    }

    func submit(
        on queue: DispatchQueue, rejected: @escaping @Sendable () -> Void,
        work: @escaping @Sendable () -> Void
    ) {
        let id = UUID()
        let timer = DispatchSource.makeTimerSource(queue: timers)
        timer.setEventHandler { [weak self] in self?.expire(id) }
        // Activate even a rejected timer so its release cannot leave a suspended dispatch source.
        timer.activate()
        let accepted = lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard entries.count < limit,
                !entries.values.contains(where: {
                    $0.state == .expired || $0.state == .stalled || now >= $0.deadline
                })
            else { return false }
            entries[id] = Entry(
                timer: timer, rejected: rejected, deadline: ProcessInfo.processInfo.systemUptime + waitTimeout)
            timer.schedule(deadline: .now() + waitTimeout)
            return true
        }
        guard accepted else {
            timer.cancel()
            rejected()
            return
        }
        queue.async { [self] in
            var rejectExpired = false
            let start = lock.withLock {
                guard var entry = entries[id] else { return false }
                guard entry.state == .waiting else {
                    entries.removeValue(forKey: id)?.timer.cancel()
                    return false
                }
                guard ProcessInfo.processInfo.systemUptime < entry.deadline else {
                    entries.removeValue(forKey: id)?.timer.cancel()
                    rejectExpired = true
                    return false
                }
                entry.state = .running
                entry.deadline = ProcessInfo.processInfo.systemUptime + runningTimeout
                entries[id] = entry
                entry.timer.schedule(deadline: .now() + runningTimeout)
                return true
            }
            guard start else {
                if rejectExpired { rejected() }
                return
            }
            defer { lock.withLock { entries.removeValue(forKey: id)?.timer.cancel() } }
            work()
        }
    }

    private func expire(_ id: UUID) {
        let reject: (@Sendable () -> Void)? = lock.withLock {
            guard var entry = entries[id] else { return nil }
            let remaining = entry.deadline - ProcessInfo.processInfo.systemUptime
            guard remaining <= 0 else {
                entry.timer.schedule(deadline: .now() + remaining)
                return nil
            }
            switch entry.state {
            case .waiting:
                entry.state = .expired
                entries[id] = entry
                entry.timer.cancel()
                // Keep this tombstone until the queue consumes it. It trips admission rather than
                // allowing repeated timeouts to accumulate an unbounded number of queued closures.
                return entry.rejected
            case .running:
                entry.state = .stalled
                entries[id] = entry
                entry.timer.cancel()
                return nil
            case .expired, .stalled: return nil
            }
        }
        reject?()
    }

    static func rejection(provider: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "ok": false, "provider": provider, "retryable": true,
            "error": L10n.text("session.provider_queue_busy"),
        ])) ?? Data()
    }
}
