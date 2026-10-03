import Darwin
import Foundation

/// Versioned, length-prefixed desktop coordination protocol. Never starts another executor.
final class CodexIPC: @unchecked Sendable {
    private final class Pending: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        var result: [String: Any]?
    }
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let connectionLock = NSLock()
    private var fd: Int32 = -1
    private var client = "initializing-client"
    private var generation = UUID()
    private var pending: [String: Pending] = [:]
    private var snapshots: [String: Data] = [:]
    var broadcast: (@Sendable (Data) -> Void)?
    var disconnected: (@Sendable () -> Void)?
    private let path: String
    init(
        path: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock")
            .path
    ) { self.path = path }

    func connect() throws {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if lock.withLock({ fd >= 0 }) { return }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
            info.st_mode & 0o077 == 0
        else { throw CLIError(L10n.text("session.open_codex_on_the_mac_first")) }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw CLIError(L10n.text("session.could_not_connect_to_codex")) }
        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var writeTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socketFD)
            throw CLIError(L10n.text("session.the_codex_socket_path_is_too_long"))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(socketFD)
            throw CLIError(L10n.text("session.codex_is_not_running_open_it_on_the_mac"))
        }
        let token = UUID()
        writeLock.withLock {
            lock.withLock {
                fd = socketFD
                client = "initializing-client"
                generation = token
            }
        }
        DispatchQueue(label: "vibepier.codex-ipc-reader").async { [weak self] in self?.readLoop(socketFD, token: token)
        }
        do {
            let response = try request("initialize", ["clientType": "vibebar"], version: 0)
            guard let value = (response["result"] as? [String: Any])?["clientId"] as? String, !value.isEmpty,
                value == response["handledByClientId"] as? String
            else {
                throw CLIError(L10n.text("session.the_current_codex_interface_is_incompatible"))
            }
            try lock.withLock {
                guard generation == token, fd >= 0 else { throw CLIError(L10n.text("session.codex_disconnected")) }
                client = value
            }
        } catch {
            close()
            throw error
        }
    }
    func close() {
        let replies = writeLock.withLock {
            let (old, replies) = lock.withLock { () -> (Int32, [Pending]) in
                let old = fd
                fd = -1
                generation = UUID()
                let replies = Array(pending.values)
                pending.removeAll()
                snapshots.removeAll()
                return (old, replies)
            }
            if old >= 0 { shutdown(old, SHUT_RDWR) }
            return replies
        }
        for reply in replies { reply.ready.signal() }
    }
    func latestSnapshot(_ thread: String) -> Data? { lock.withLock { snapshots[thread] } }
    func request(_ method: String, _ params: [String: Any], version: Int, target: String? = nil, timeout: Double = 12)
        throws -> [String: Any]
    {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw CLIError(L10n.text("core.invalid_request"))
        }
        let id = UUID().uuidString
        let waiting = Pending()
        let (source, token) = lock.withLock {
            pending[id] = waiting
            return (client, generation)
        }
        defer { _ = lock.withLock { pending.removeValue(forKey: id) } }
        var message: [String: Any] = [
            "type": "request", "requestId": id, "sourceClientId": source, "version": version, "method": method,
            "params": params, "timeoutMs": Int(timeout * 1000),
        ]
        if let target { message["targetClientId"] = target }
        return try DesktopMutationScope.run { scope in
            // Follower history hydration is read-only; every other follower request can change the native session.
            let mutable = method.hasPrefix("thread-follower-") && method != "thread-follower-load-complete-history"
            try send(message, generation: token, mutation: mutable ? scope : nil)
            guard waiting.ready.wait(timeout: .now() + timeout + 1) == .success,
                let reply = lock.withLock({ waiting.result })
            else {
                throw CLIError(L10n.text("session.the_codex_receipt_timed_out_the_send_result_needs_verification"))
            }
            guard reply["resultType"] as? String == "success" else {
                throw CLIError(reply["error"] as? String ?? L10n.text("session.codex_disconnected"))
            }
            // A successful response must belong to this method and the selected native owner.
            guard reply["method"] as? String == method,
                let owner = reply["handledByClientId"] as? String, !owner.isEmpty,
                target == nil || target == owner, let result = reply["result"] as? [String: Any]
            else { throw CLIError(L10n.text("core.invalid_receipt")) }
            try CodexNativeReceipt.validate(result, method: method, params: params)
            return reply
        }
    }
    func follow(_ thread: String, owner: String?, on: Bool) throws {
        var value: [String: Any] = [
            "type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
            "sourceClientId": lock.withLock { client },
            "params": ["hostId": "local", "conversationId": thread, "following": on],
        ]
        if let owner { value["targetClientIds"] = [owner] }
        try send(value)
    }
    private func send(_ object: [String: Any], generation token: UUID? = nil, mutation: DesktopMutationScope? = nil)
        throws
    {
        let body = try JSONSerialization.data(withJSONObject: object)
        guard body.count <= 64 * 1024 * 1024 else { throw CLIError(L10n.text("core.invalid_request")) }
        var size = UInt32(body.count).littleEndian
        var data = Data(bytes: &size, count: 4)
        data.append(body)
        try writeLock.withLock {
            let descriptor = lock.withLock { token == nil || generation == token ? fd : -1 }
            guard descriptor >= 0 else { throw CLIError(L10n.text("session.codex_disconnected")) }
            // From the first write attempt onward, disconnects and malformed/late replies cannot prove no effect.
            try mutation?.attempt {}
            try data.withUnsafeBytes { pointer in
                var written = 0
                while written < data.count {
                    let n = Darwin.send(descriptor, pointer.baseAddress!.advanced(by: written), data.count - written, 0)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else {
                        // A partial frame must never be followed by another request on this connection.
                        shutdown(descriptor, SHUT_RDWR)
                        throw CLIError(L10n.text("session.codex_disconnected"))
                    }
                    written += n
                }
            }
        }
    }
    private func readLoop(_ descriptor: Int32, token: UUID) {
        defer {
            let (current, replies) = writeLock.withLock {
                let value = lock.withLock { () -> (Bool, [Pending]) in
                    guard generation == token else { return (false, []) }
                    fd = -1
                    snapshots.removeAll()
                    let replies = Array(pending.values)
                    pending.removeAll()
                    return (true, replies)
                }
                Darwin.close(descriptor)
                return value
            }
            for reply in replies { reply.ready.signal() }
            if current { disconnected?() }
        }
        func read(_ size: Int) -> Data? {
            var data = Data(count: size)
            let ok = data.withUnsafeMutableBytes { bytes -> Bool in
                var offset = 0
                while offset < size {
                    let n = recv(descriptor, bytes.baseAddress!.advanced(by: offset), size - offset, 0)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { return false }
                    offset += n
                }
                return true
            }
            return ok ? data : nil
        }
        while let header = read(4) {
            let count = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard count > 0, count <= 64 * 1024 * 1024, let body = read(count),
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return }
            switch object["type"] as? String {
            case "response":
                let item = lock.withLock { () -> Pending? in
                    guard generation == token, let id = object["requestId"] as? String,
                        let item = pending[id], item.result == nil
                    else { return nil }
                    item.result = object
                    return item
                }
                if let item {
                    item.ready.signal()
                }
            case "client-discovery-request":
                if let id = object["requestId"] {
                    try? send(
                        ["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]],
                        generation: token)
                }
            case "broadcast":
                if object["method"] as? String == "thread-stream-state-changed",
                    let params = object["params"] as? [String: Any],
                    let thread = params["conversationId"] as? String,
                    (params["change"] as? [String: Any])?["type"] as? String == "snapshot"
                {
                    lock.withLock {
                        if snapshots.count >= 2 { snapshots.removeAll() }
                        snapshots[thread] = body
                    }
                }
                broadcast?(body)
            default: break
            }
        }
    }
}
