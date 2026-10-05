import Darwin
import Foundation

/// Reports an observed file access refusal, never a guessed Full Disk Access state.
/// The local notification deliberately carries no paths, file contents or credentials.
public enum SessionFileAccess {
    public static let permissionDenied = Notification.Name("io.github.junweiup.vibepier.filePermissionDenied")

    public struct PermissionDenied: LocalizedError, CustomStringConvertible, Sendable {
        public var errorDescription: String? { L10n.text("mac.file_access_denied") }
        public var description: String { errorDescription ?? "" }
    }

    /// Call immediately after a failed system call so its original errno is preserved.
    static func failure(
        errno code: Int32, fallback: @autoclosure () -> String,
        notifications: NotificationCenter = .default, monitor: FileAccessMonitor = .shared, report: Bool = true
    ) -> Error {
        guard code == EPERM || code == EACCES else { return CLIError(fallback()) }
        if report {
            monitor.recordPermissionRequired()
            notifications.post(name: permissionDenied, object: nil)
        }
        return PermissionDenied()
    }
}

public enum FileAccessStatus: Sendable, Equatable {
    case unknown, checking, accessConfirmed, permissionRequired
}

/// Only checks the last file the application's normal authorized read path already
/// selected. A successful read does not establish access to all folders or the FDA switch.
public final class FileAccessMonitor: @unchecked Sendable {
    public static let shared = FileAccessMonitor()
    public static let statusChanged = Notification.Name("io.github.junweiup.vibepier.fileAccessStatusChanged")
    private let lock = NSLock()
    private let notifications: NotificationCenter
    private let timeout: Double
    private let worker = DispatchQueue(label: "vibepier.file-access-check", qos: .utility)
    private let timer = DispatchQueue(label: "vibepier.file-access-check-timeout")
    private var latestProbe: (@Sendable () throws -> Void)?
    private var probeVersion = 0
    private var resultVersion = 0
    private var running: UUID?
    private var value: FileAccessStatus = .unknown

    public init(notifications: NotificationCenter = .default, timeout: Double = 6) {
        self.notifications = notifications
        self.timeout = timeout
    }

    public var status: FileAccessStatus { lock.withLock { value } }
    public var checkInFlight: Bool { lock.withLock { running != nil } }

    struct ProbeToken: Sendable {
        let probe: Int
        let result: Int
    }
    @discardableResult
    func recordProbe(_ probe: @escaping @Sendable () throws -> Void) -> ProbeToken {
        let token = lock.withLock {
            latestProbe = probe
            probeVersion += 1
            resultVersion += 1
            value = .unknown
            return ProbeToken(probe: probeVersion, result: resultVersion)
        }
        notify()
        return token
    }

    func recordAccessConfirmed() { update(.accessConfirmed) }
    func recordPermissionRequired() { update(.permissionRequired) }
    @discardableResult
    func record(_ status: FileAccessStatus, for token: ProbeToken) -> Bool {
        let current = lock.withLock {
            guard probeVersion == token.probe, resultVersion == token.result else { return false }
            value = status
            resultVersion += 1
            return true
        }
        if current {
            notify()
            if status == .permissionRequired {
                notifications.post(name: SessionFileAccess.permissionDenied, object: nil)
            }
        }
        return current
    }
    private func update(_ status: FileAccessStatus) {
        lock.withLock {
            value = status
            resultVersion += 1
        }
        notify()
    }
    private func notify() { notifications.post(name: Self.statusChanged, object: nil) }

    /// At most one worker, including after its UI deadline expires. A blocked
    /// filesystem call cannot accumulate more workers by repeatedly clicking Check.
    @discardableResult
    public func check() -> Bool {
        let token = UUID()
        let (work, changed) = lock.withLock { () -> (((@Sendable () throws -> Void), Int, Int)?, Bool) in
            guard running == nil else { return (nil, false) }
            guard let latestProbe else {
                value = .unknown
                return (nil, true)
            }
            running = token
            value = .checking
            return ((latestProbe, probeVersion, resultVersion), true)
        }
        if changed { notify() }
        guard let (probe, version, result) = work else { return false }
        timer.asyncAfter(deadline: .now() + timeout) { [self] in
            let expired = lock.withLock {
                guard running == token, resultVersion == result, value == .checking else { return false }
                value = .unknown
                return true
            }
            if expired { notify() }
        }
        worker.async { [self] in
            let status: FileAccessStatus
            do {
                try probe()
                status = .accessConfirmed
            } catch is SessionFileAccess.PermissionDenied { status = .permissionRequired } catch { status = .unknown }
            let current = lock.withLock {
                running = nil
                guard probeVersion == version, resultVersion == result else { return false }
                value = status
                resultVersion += 1
                return true
            }
            notify()
            if current, status == .permissionRequired {
                notifications.post(name: SessionFileAccess.permissionDenied, object: nil)
            }
        }
        return true
    }
}
