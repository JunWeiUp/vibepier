// SPDX-License-Identifier: MIT
import Foundation

/// One newline-terminated JSON object per connection, restricted to the same local user.
enum ControlSocket {
    static let requestLimit = 1_048_576
    static let replyLimit = 8_388_608

    static func request(
        _ payload: [String: Any], path: String = Paths.socket.path,
        timeout: TimeInterval = 0.5
    ) -> [String: Any]? {
        guard timeout.isFinite, timeout > 0, timeout <= 300,
            let data = ControlSocketIO.encode(payload, limit: requestLimit)
        else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ControlSocketIO.configure(fd),
            ControlSocketIO.connect(fd, path: path, deadline: deadline),
            ControlSocketIO.sameUser(fd),
            ControlSocketIO.write(data, to: fd, deadline: deadline),
            let reply = ControlSocketIO.read(from: fd, limit: replyLimit, deadline: deadline)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }

    static func fillAddress(_ addr: inout sockaddr_un, _ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: addr.sun_path)
        else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: bytes)
        }
        return true
    }
}

final class ControlServer: @unchecked Sendable {
    typealias Handler = @Sendable ([String: Any]) async -> [String: Any]
    private let path: String
    private let handler: Handler
    private let maximumClients: Int
    private let ioTimeout: TimeInterval
    private let queue = DispatchQueue(label: "vibepier.control")
    private let workers = DispatchQueue(label: "vibepier.control.io", attributes: .concurrent)
    // All state below is confined to queue. A worker owns its descriptor until finish().
    private var source: DispatchSourceRead?
    private var endpoint: ControlSocketEndpoint?
    private var clients: [UUID: ControlSocketConnection] = [:]

    init(
        path: String = Paths.socket.path, maximumClients: Int = 16, ioTimeout: TimeInterval = 2,
        handler: @escaping Handler
    ) {
        self.path = path
        self.maximumClients = max(1, min(maximumClients, 16))
        self.ioTimeout = ioTimeout.isFinite ? max(0.01, min(ioTimeout, 30)) : 2
        self.handler = handler
    }

    func start() throws {
        try queue.sync {
            guard source == nil else { return }
            if URL(fileURLWithPath: path).deletingLastPathComponent() == Paths.supportDirectory {
                try Paths.ensureSupportDirectory()
            }
            let endpoint = try ControlSocketEndpoint(path: path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var succeeded = false
            defer { if !succeeded { close(fd) } }
            guard ControlSocketIO.configure(fd) else { throw POSIXError(.EIO) }
            try endpoint.bind(fd)
            guard listen(fd, 16) == 0 else { throw POSIXError(.EIO) }
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptClients(fd) }
            // Dispatch owns the listening descriptor until its last event finishes.
            src.setCancelHandler {
                close(fd)
                endpoint.removeSocket()
            }
            self.endpoint = endpoint
            source = src
            succeeded = true
            src.resume()
        }
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            endpoint?.removeSocket()
            endpoint = nil
            // shutdown interrupts I/O without closing/reusing a worker's descriptor.
            for client in clients.values { client.cancel() }
        }
    }

    private func acceptClients(_ fd: Int32) {
        // Limit each event so a connection flood cannot starve stop/completion work.
        for _ in 0..<16 {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard clients.count < maximumClients, ControlSocketIO.configure(client),
                ControlSocketIO.sameUser(client)
            else {
                close(client)
                continue
            }
            let id = UUID()
            let connection = ControlSocketConnection(client)
            clients[id] = connection
            let deadline = ProcessInfo.processInfo.systemUptime + ioTimeout
            workers.async { [self] in
                guard
                    let data = ControlSocketIO.read(
                        from: client, limit: ControlSocket.requestLimit, deadline: deadline),
                    let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    !connection.cancelled
                else {
                    finish(id, connection)
                    return
                }
                Task {
                    guard connection.beginHandling() else {
                        finish(id, connection)
                        return
                    }
                    // Do not cancel/retry a handler after it may have changed desktop state.
                    let reply = await handler(request)
                    let encoded = ControlSocketIO.encode(reply, limit: ControlSocket.replyLimit)
                    workers.async { [self] in
                        if !connection.cancelled, let data = encoded {
                            _ = ControlSocketIO.write(
                                data, to: client, deadline: ProcessInfo.processInfo.systemUptime + ioTimeout)
                        }
                        finish(id, connection)
                    }
                }
            }
        }
    }

    private func finish(_ id: UUID, _ connection: ControlSocketConnection) {
        connection.close()
        queue.async { [self] in clients.removeValue(forKey: id) }
    }
}
