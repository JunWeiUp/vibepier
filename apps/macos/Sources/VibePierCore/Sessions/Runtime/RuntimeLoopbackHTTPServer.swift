import Foundation
import Network

/// Minimal single-request HTTP/1.1 listener, bound to IPv4 loopback. No CORS,
/// redirects, chunked bodies, pipelining, WebSockets or browser-origin requests.
final class RuntimeLoopbackHTTPServer: @unchecked Sendable {
    private struct Client {
        let connection: NWConnection
        var bytes = Data()
        let started: TimeInterval
    }
    private let handler: @Sendable (ClaudeModsBrokerDriver.HTTPRequest) -> ClaudeModsBrokerDriver.HTTPResponse
    private let queue = DispatchQueue(label: "vibepier.mods-loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var timer: DispatchSourceTimer?
    private var port: UInt16?
    init(handler: @escaping @Sendable (ClaudeModsBrokerDriver.HTTPRequest) -> ClaudeModsBrokerDriver.HTTPResponse) {
        self.handler = handler
    }
    deinit { stop() }
    func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let candidate = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            if case .ready = state {
                self?.lock.lock()
                self?.port = candidate?.port?.rawValue
                self?.lock.unlock()
                ready.signal()
            } else if case .failed = state {
                ready.signal()
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        lock.lock()
        listener = candidate
        lock.unlock()
        candidate.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success else {
            stop()
            throw RuntimeDriverError.timeout
        }
        lock.lock()
        let assigned = port
        lock.unlock()
        guard let assigned else {
            stop()
            throw RuntimeDriverError.unavailable
        }
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + 1, repeating: 1)
        deadline.setEventHandler { [weak self] in self?.expireClients() }
        lock.lock()
        timer = deadline
        lock.unlock()
        deadline.resume()
        return assigned
    }
    func stop() {
        lock.lock()
        let active = Array(clients.values)
        clients.removeAll()
        let old = listener
        listener = nil
        let deadline = timer
        timer = nil
        lock.unlock()
        deadline?.cancel()
        old?.cancel()
        for client in active { client.connection.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
            case .ipv4(let address) = host, address == IPv4Address("127.0.0.1")
        else {
            connection.cancel()
            return
        }
        lock.lock()
        guard clients.count < 16 else {
            lock.unlock()
            connection.cancel()
            return
        }
        let id = UUID()
        clients[id] = Client(connection: connection, started: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        connection.start(queue: queue)
        receive(id)
    }
    private func expireClients() {
        lock.lock()
        let expired = clients.filter { ProcessInfo.processInfo.systemUptime - $0.value.started > 5 }.map(\.key)
        let expiredClients = expired.compactMap { clients.removeValue(forKey: $0) }
        lock.unlock()
        for client in expiredClients { client.connection.cancel() }
    }
    private func receive(_ id: UUID) {
        lock.lock()
        let connection = clients[id]?.connection
        lock.unlock()
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            self?.received(id, data: data, done: done, error: error)
        }
    }
    private func received(_ id: UUID, data: Data?, done: Bool, error: NWError?) {
        lock.lock()
        guard var client = clients[id] else {
            lock.unlock()
            return
        }
        if let data { client.bytes.append(data) }
        clients[id] = client
        lock.unlock()
        guard client.bytes.count <= 308_192, error == nil else {
            finish(id, status: 400)
            return
        }
        do {
            if let request = try Self.parse(client.bytes) {
                let response = handler(request)
                finish(id, status: response.status, body: response.body)
            } else if done {
                finish(id, status: 400)
            } else {
                receive(id)
            }
        } catch { finish(id, status: 400) }
    }
    static func parse(_ data: Data) throws -> ClaudeModsBrokerDriver.HTTPRequest? {
        let marker = Data("\r\n\r\n".utf8)
        guard let boundary = data.range(of: marker) else {
            guard data.count <= 8192 else { throw RuntimeDriverError.invalidRequest }
            return nil
        }
        guard boundary.lowerBound <= 8192,
            let header = String(data: data.prefix(boundary.lowerBound), encoding: .utf8)
        else { throw RuntimeDriverError.invalidRequest }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].components(separatedBy: " ")
        guard first.count == 3, first[0] == "POST", first[2] == "HTTP/1.1",
            ["/v1/register", "/v1/poll", "/v1/events", "/v1/result", "/v1/end"].contains(first[1])
        else { throw RuntimeDriverError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t")
            else { throw RuntimeDriverError.invalidRequest }
            let key = line[..<separator].lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }), headers[key] == nil
            else { throw RuntimeDriverError.invalidRequest }
            headers[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil,
            let host = headers["host"], headers["content-type"] == "application/json",
            let lengthString = headers["content-length"], !lengthString.isEmpty,
            lengthString.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(lengthString), length <= 300_000
        else { throw RuntimeDriverError.invalidRequest }
        let bodyStart = boundary.upperBound
        if data.count < bodyStart + length { return nil }
        guard data.count == bodyStart + length else { throw RuntimeDriverError.invalidRequest }
        return ClaudeModsBrokerDriver.HTTPRequest(
            remoteAddress: "127.0.0.1", method: first[0], path: first[1],
            host: host, origin: headers["origin"], authorization: headers["authorization"],
            body: Data(data[bodyStart...]))
    }
    private func finish(_ id: UUID, status: Int, body: Data = Data("{}".utf8)) {
        lock.lock()
        let client = clients.removeValue(forKey: id)
        lock.unlock()
        guard let client else { return }
        let bounded = body.count <= 300_000 ? body : Data("{}".utf8)
        var response = Data(
            "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(bounded.count)\r\n\r\n"
                .utf8)
        response.append(bounded)
        client.connection.send(content: response, completion: .contentProcessed { _ in client.connection.cancel() })
    }
}
