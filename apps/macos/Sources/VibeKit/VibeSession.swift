// SPDX-License-Identifier: MIT
//
// Session management: the auth handshake, the keep-alive heartbeat, and a
// request queue that behaves like `-[KehwinDevice writeWorker]`.
//
// Behaviour of the vendor library, reproduced here:
//  * Until the dongle is authenticated, it sends the auth message every 1 s
//    with a random 32-bit code. The dongle answers `code ^ private_key[i]`.
//  * Once authenticated, it sends the heartbeat every 1 s.
//  * One request is in flight at a time. It is resent every 100 ms until a
//    matching reply arrives, or it fails after 3 s.
//  * Key-event and battery notices are only forwarded after authentication.

import Foundation
import VibeLocalization

public enum SessionError: Error, CustomStringConvertible {
    case timeout(String)
    case notReady
    case cancelled

    public var description: String {
        switch self {
        case .timeout(let what): return L10n.text("hardware.session_timeout", what)
        case .notReady: return L10n.text("hardware.session_not_ready")
        case .cancelled: return L10n.text("hardware.session_cancelled")
        }
    }
}

public enum SessionEvent: Sendable {
    case connected(HIDDeviceDescription)
    case authenticated
    case disconnected
    case message(VibeMessage, Frame)
}

public final class VibeSession: @unchecked Sendable {
    public let transport: any SessionTransport
    public var logFrames = false

    /// Resend interval for requests, from the vendor worker loop (USB mode).
    public var retryInterval: TimeInterval = 0.1
    public var defaultTimeout: TimeInterval = 3.0
    public var authInterval: TimeInterval = 1.0
    public var heartbeatInterval: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "vibepier.session")
    private var timer: DispatchSourceTimer?
    private var timerWakeups = 0
    private var scheduledTick: Date?
    private var authCode: UInt32 = 0
    private var lastAuth = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var authenticated = false
    private var connected = false
    private var pending: [PendingRequest] = []
    private var listeners: [UUID: @Sendable (SessionEvent) -> Void] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var heartbeatEnabled = true
    private var heartbeatWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    private final class PendingRequest: @unchecked Sendable {
        let id = UUID()
        let request: Request
        let deadline: Date
        let resend: Bool
        var lastSent = Date.distantPast
        var continuation: CheckedContinuation<Frame, Error>?

        init(request: Request, timeout: TimeInterval, resend: Bool, continuation: CheckedContinuation<Frame, Error>) {
            self.request = request
            self.deadline = Date().addingTimeInterval(timeout)
            self.resend = resend
            self.continuation = continuation
        }
    }

    public init(transport: any SessionTransport = HIDTransport()) {
        self.transport = transport
        transport.onConnect = { [weak self] info in
            guard let self else { return }
            self.queue.async { self.handleConnect(info) }
        }
        transport.onDisconnect = { [weak self] in
            guard let self else { return }
            self.queue.async { self.handleDisconnect() }
        }
        transport.onReport = { [weak self] report in
            guard let self else { return }
            let frame = Frame(FrameCodec.decodeInputReport(report))
            self.queue.async { self.handleFrame(frame) }
        }
    }

    public var isAuthenticated: Bool { queue.sync { authenticated } }
    public var isConnected: Bool { queue.sync { connected } }
    /// Diagnostic counter for scheduled wakes, excluding incoming HID callbacks.
    public var timerWakeupCount: Int { queue.sync { timerWakeups } }

    /// Starts device matching. The one-shot timer sleeps until work is due.
    public func start() {
        queue.sync {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .distantFuture)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.timerWakeups += 1
                self.scheduledTick = nil
                self.tick()
            }
            timer = t
            t.resume()
        }
        transport.start()
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            scheduledTick = nil
            connected = false
            authenticated = false
            failAll(SessionError.cancelled)
        }
        transport.stop()
    }

    /// Pauses the heartbeat. The firmware updater uses this to keep the link quiet.
    public func setHeartbeatEnabled(_ on: Bool) {
        queue.async {
            self.heartbeatEnabled = on
            self.scheduleNextTick()
        }
    }

    /// Bounded diagnostics use nil to pause, then restore the production interval.
    public func configureHeartbeat(interval: TimeInterval?) {
        queue.async {
            self.heartbeatEnabled = interval != nil
            if let interval { self.heartbeatInterval = max(0.1, interval) }
            self.scheduleNextTick()
        }
    }

    /// Send the first heartbeat immediately and wait for the dongle's echo.
    /// The echo confirms transport receipt, not that an audio stream is ready.
    public func wakeHeartbeat(timeout: TimeInterval = 0.5) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.connected, self.authenticated else {
                    continuation.resume(throwing: SessionError.notReady)
                    return
                }
                guard self.heartbeatEnabled else {
                    continuation.resume(throwing: SessionError.cancelled)
                    return
                }
                let id = UUID()
                self.heartbeatWaiters[id] = continuation
                self.lastHeartbeat = Date()
                do { try self.sendNow(DongleRequest.heartbeat.bytes, name: "dongle.voiceWake") } catch {
                    self.heartbeatWaiters.removeValue(forKey: id)?.resume(throwing: error)
                }
                self.scheduleNextTick()
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.heartbeatWaiters.removeValue(forKey: id)?.resume(
                        throwing: SessionError.timeout("voice heartbeat"))
                }
            }
        }
    }

    @discardableResult
    public func addListener(_ fn: @escaping @Sendable (SessionEvent) -> Void) -> UUID {
        let id = UUID()
        queue.sync { listeners[id] = fn }
        return id
    }

    public func removeListener(_ id: UUID) {
        queue.sync { _ = listeners.removeValue(forKey: id) }
    }

    /// Waits until the dongle is connected and authenticated.
    public func waitUntilReady(timeout: TimeInterval = 5) async throws {
        if isAuthenticated { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    self.queue.async {
                        if self.authenticated {
                            c.resume()
                        } else {
                            self.readyWaiters.append(c)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SessionError.notReady
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                self.queue.async {
                    let waiters = self.readyWaiters
                    self.readyWaiters.removeAll()
                    for w in waiters { w.resume(throwing: SessionError.notReady) }
                }
                throw error
            }
        }
    }

    /// Sends a request and returns the first matching reply.
    public func send(_ request: Request, timeout: TimeInterval? = nil, resend: Bool = true) async throws -> Frame {
        guard request.reply != nil else {
            try sendNow(request.bytes, name: request.name)
            return Frame(request.bytes)
        }
        let t = timeout ?? defaultTimeout
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Frame, Error>) in
            queue.async {
                let p = PendingRequest(request: request, timeout: t, resend: resend, continuation: c)
                self.pending.append(p)
                self.pump()
            }
        }
    }

    /// Sends a request, then collects every matching frame for `window` seconds.
    /// Used for replies that arrive in several chunks, such as the mic serial number.
    public func collect(_ request: Request, window: TimeInterval = 0.8) async throws -> [Frame] {
        guard let match = request.reply else { return [] }
        let box = FrameBox()
        let id = addListener { event in
            if case .message(_, let f) = event, match.matches(f) { box.append(f) }
        }
        defer { removeListener(id) }
        _ = try await send(request)
        try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
        return box.frames
    }

    /// Sends raw plaintext bytes once, without waiting for a reply.
    public func sendNow(_ bytes: [UInt8], name: String = "raw") throws {
        if logFrames {
            FileHandle.standardError.write(Data(">> \(name): \(Frame(bytes).shortHex)\n".utf8))
        }
        try transport.send(report: FrameCodec.outputReport(for: bytes))
    }

    // MARK: Internals (session queue only)

    private func handleConnect(_ info: HIDDeviceDescription) {
        connected = true
        authenticated = false
        lastAuth = .distantPast
        emit(.connected(info))
        tick()
    }

    private func handleDisconnect() {
        connected = false
        authenticated = false
        failAll(SessionError.cancelled)
        scheduleNextTick()
        emit(.disconnected)
    }

    private func failAll(_ error: Error) {
        let heartbeatWaiters = self.heartbeatWaiters
        self.heartbeatWaiters.removeAll()
        for waiter in heartbeatWaiters.values { waiter.resume(throwing: error) }
        let items = pending
        pending.removeAll()
        for p in items {
            p.continuation?.resume(throwing: error)
            p.continuation = nil
        }
    }

    private func tick() {
        defer { scheduleNextTick() }
        guard connected else { return }
        let now = Date()
        if !authenticated {
            if now.timeIntervalSince(lastAuth) >= authInterval {
                authCode = UInt32.random(in: 0...UInt32.max)
                lastAuth = now
                try? sendNow(DongleRequest.auth(code: authCode).bytes, name: "dongle.auth")
            }
            return
        }
        if heartbeatEnabled, now.timeIntervalSince(lastHeartbeat) >= heartbeatInterval {
            lastHeartbeat = now
            try? sendNow(DongleRequest.heartbeat.bytes, name: "dongle.heartbeat")
        }
        pump()
    }

    /// Sends or resends the request at the head of the queue, and expires it on timeout.
    private func pump() {
        defer { scheduleNextTick() }
        guard connected, authenticated, let head = pending.first else { return }
        let now = Date()
        if now >= head.deadline {
            pending.removeFirst()
            head.continuation?.resume(throwing: SessionError.timeout(head.request.name))
            head.continuation = nil
            pump()
            return
        }
        let due =
            head.lastSent == .distantPast || (head.resend && now.timeIntervalSince(head.lastSent) >= retryInterval)
        if due {
            head.lastSent = now
            do {
                try sendNow(head.request.bytes, name: head.request.name)
            } catch {
                pending.removeFirst()
                head.continuation?.resume(throwing: error)
                head.continuation = nil
                pump()
            }
        }
    }

    private func handleFrame(_ frame: Frame) {
        defer { scheduleNextTick() }
        if logFrames {
            FileHandle.standardError.write(Data("<< \(frame.shortHex)\n".utf8))
        }
        let message = VibeMessage.parse(frame)
        if case .heartbeat = message {
            let waiters = heartbeatWaiters
            heartbeatWaiters.removeAll()
            for waiter in waiters.values { waiter.resume() }
        }
        if case .authReply(_, let code) = message {
            if !authenticated, code == authCode {
                authenticated = true
                lastHeartbeat = .distantPast
                let waiters = readyWaiters
                readyWaiters.removeAll()
                for w in waiters { w.resume() }
                emit(.authenticated)
            }
        }
        if let i = pending.firstIndex(where: { $0.request.reply?.matches(frame) == true }) {
            let p = pending.remove(at: i)
            p.continuation?.resume(returning: frame)
            p.continuation = nil
            pump()
        }
        // The vendor library drops notices until the dongle is authenticated.
        if case .keyEvent = message, !authenticated { return }
        emit(.message(message, frame))
    }

    /// HID input drives replies and key events immediately. Only auth, keepalive,
    /// request retries and deadlines need a timer; an absent dongle needs none.
    private func scheduleNextTick() {
        guard connected else {
            armTimer(at: nil)
            return
        }
        var due: Date?
        if !authenticated {
            due = lastAuth.addingTimeInterval(authInterval)
        } else {
            if heartbeatEnabled { due = lastHeartbeat.addingTimeInterval(heartbeatInterval) }
            if let head = pending.first {
                var requestDue = head.deadline
                if head.resend || head.lastSent == .distantPast {
                    requestDue = min(requestDue, head.lastSent.addingTimeInterval(retryInterval))
                }
                due = due.map { min($0, requestDue) } ?? requestDue
            }
        }
        armTimer(at: due)
    }

    private func armTimer(at due: Date?) {
        guard let timer, due != scheduledTick else { return }
        scheduledTick = due
        guard let due else {
            timer.schedule(deadline: .distantFuture)
            return
        }
        timer.schedule(deadline: .now() + max(0.001, due.timeIntervalSinceNow), leeway: .milliseconds(5))
    }

    private func emit(_ event: SessionEvent) {
        for fn in listeners.values { fn(event) }
    }
}

final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Frame] = []

    func append(_ f: Frame) {
        lock.lock()
        items.append(f)
        lock.unlock()
    }

    var frames: [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
