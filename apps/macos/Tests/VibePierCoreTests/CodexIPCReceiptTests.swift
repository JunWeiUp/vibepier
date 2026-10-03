import Darwin
import XCTest

@testable import VibePierCore

final class CodexIPCReceiptTests: XCTestCase {
    private let method = "thread-follower-update-thread-settings"

    func testNativeErrorsDisconnectAndTimeoutRemainUnknownWithoutResending() throws {
        for scenario in [
            "request-timeout", "client-disconnected", "diagnostic without reserved words", "未知错误", "disconnect",
            "silent",
        ] {
            let server = try NativeIPCFixture { request in
                if scenario == "disconnect" { return .disconnect }
                if scenario == "silent" { return .silent }
                return .reply([
                    "type": "response", "requestId": request["requestId"]!, "resultType": "error", "error": scenario,
                ])
            }
            let ipc = CodexIPC(path: server.path)
            defer {
                ipc.close()
                server.stop()
            }
            try ipc.connect()
            XCTAssertThrowsError(try ipc.request(method, [:], version: 2, target: "owner", timeout: 0.02)) { error in
                XCTAssertTrue(error is UnconfirmedDesktopMutation, scenario)
                XCTAssertEqual(ProviderFailure.reply(error, provider: "codex")["unknown"] as? Bool, true)
            }
            XCTAssertEqual(server.methods, [method], "An uncertain operation must never resend")
        }
    }

    func testWrongOwnerMethodAndMalformedSuccessCannotConfirmMutation() throws {
        for scenario in ["owner", "method", "missing-result", "missing-applied", "numeric-applied", "wrong-request"] {
            let server = try NativeIPCFixture { request in
                var reply = NativeIPCFixture.success(request, result: ["applied": true])
                switch scenario {
                case "owner": reply["handledByClientId"] = "another-owner"
                case "method": reply["method"] = "another-method"
                case "missing-result": reply.removeValue(forKey: "result")
                case "missing-applied": reply["result"] = [:] as [String: Any]
                case "numeric-applied": reply["result"] = ["applied": 1]
                default: reply["requestId"] = UUID().uuidString
                }
                return .reply(reply)
            }
            let ipc = CodexIPC(path: server.path)
            defer {
                ipc.close()
                server.stop()
            }
            try ipc.connect()
            XCTAssertThrowsError(try ipc.request(method, [:], version: 2, target: "owner", timeout: 0.02)) {
                XCTAssertTrue($0 is UnconfirmedDesktopMutation, scenario)
            }
            XCTAssertEqual(server.methods, [method])
        }
    }

    func testConfirmedAppliedAndExplicitConditionalRejectionRetainTheirMeaning() throws {
        for applied in [true, false] {
            let server = try NativeIPCFixture { .reply(NativeIPCFixture.success($0, result: ["applied": applied])) }
            let ipc = CodexIPC(path: server.path)
            defer {
                ipc.close()
                server.stop()
            }
            try ipc.connect()
            let reply = try ipc.request(method, [:], version: 2, target: "owner")
            XCTAssertEqual((reply["result"] as? [String: Any])?["applied"] as? Bool, applied)
            XCTAssertEqual(server.methods, [method])
        }
    }

    func testReadFailuresAndRequestsBeforeConnectionDoNotBecomeUnknownMutations() throws {
        let server = try NativeIPCFixture { _ in .disconnect }
        let ipc = CodexIPC(path: server.path)
        defer {
            ipc.close()
            server.stop()
        }
        XCTAssertThrowsError(try ipc.request(method, [:], version: 2)) {
            XCTAssertFalse($0 is UnconfirmedDesktopMutation)
        }
        for timeout in [Double.nan, .infinity, -1, 0, 301] {
            XCTAssertThrowsError(try ipc.request(method, [:], version: 2, timeout: timeout)) {
                XCTAssertFalse($0 is UnconfirmedDesktopMutation)
            }
        }
        try ipc.connect()
        XCTAssertThrowsError(try ipc.request("thread-follower-load-complete-history", [:], version: 1)) {
            XCTAssertFalse($0 is UnconfirmedDesktopMutation)
        }
        XCTAssertEqual(server.methods, ["thread-follower-load-complete-history"])
    }

    func testNativeStopQueueAndSendRequireOperationSpecificIdentity() throws {
        let stop = "thread-follower-interrupt-turn"
        XCTAssertNoThrow(
            try CodexNativeReceipt.validate(
                ["ok": true, "interruptedTurnId": "turn"], method: stop, params: ["expectedTurnId": "turn"]))
        XCTAssertThrowsError(
            try CodexNativeReceipt.validate(
                ["ok": true, "interruptedTurnId": "new-turn"], method: stop, params: ["expectedTurnId": "turn"]))
        let remove = "thread-follower-remove-queued-message"
        XCTAssertNoThrow(
            try CodexNativeReceipt.validate(["removed": NSNull()], method: remove, params: ["messageId": "message"]))
        XCTAssertNoThrow(
            try CodexNativeReceipt.validate(
                ["removed": ["message": ["id": "message"]]], method: remove, params: ["messageId": "message"]))
        XCTAssertThrowsError(
            try CodexNativeReceipt.validate(
                ["removed": ["message": ["id": "other"]]], method: remove, params: ["messageId": "message"]))
        let start = "thread-follower-start-turn"
        XCTAssertNoThrow(
            try CodexNativeReceipt.validate(["result": ["turn": ["id": "native-turn"]]], method: start, params: [:]))
        XCTAssertThrowsError(
            try CodexNativeReceipt.validate(["result": ["turn": ["id": ""]]], method: start, params: [:]))
        for method in [
            "thread-follower-set-queued-follow-ups-state", "thread-follower-command-approval-decision",
            "thread-follower-file-approval-decision", "thread-follower-permissions-request-approval-response",
            "thread-follower-submit-user-input", "thread-follower-submit-mcp-server-elicitation-response",
        ] {
            XCTAssertNoThrow(try CodexNativeReceipt.validate(["ok": true], method: method, params: [:]))
            XCTAssertThrowsError(try CodexNativeReceipt.validate(["ok": 1], method: method, params: [:]))
            XCTAssertThrowsError(try CodexNativeReceipt.validate([:], method: method, params: [:]))
        }
    }
}

/// A private temporary Unix socket exercises framing and the production client without running a provider.
private final class NativeIPCFixture: @unchecked Sendable {
    enum Response {
        case reply([String: Any])
        case disconnect, silent
    }
    let path: String
    private let directory: URL
    private let listener: Int32
    private let lock = NSLock()
    private var peer: Int32 = -1
    private var stopped = false
    private var received: [String] = []
    private let finished = DispatchSemaphore(value: 0)
    private let respond: @Sendable ([String: Any]) -> Response
    var methods: [String] { lock.withLock { received } }

    init(_ respond: @escaping @Sendable ([String: Any]) -> Response) throws {
        self.respond = respond
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vpi-" + UUID().uuidString.prefix(8))
        path = directory.appendingPathComponent("ipc.sock").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard listener >= 0, bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw CLIError("fixture socket")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 1) == 0 else {
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directory)
            throw CLIError("fixture bind")
        }
        DispatchQueue(label: "vibepier.test-native-ipc").async { self.run() }
    }

    static func success(_ request: [String: Any], result: [String: Any]) -> [String: Any] {
        [
            "type": "response", "requestId": request["requestId"]!, "method": request["method"]!,
            "resultType": "success", "handledByClientId": "owner", "result": result,
        ]
    }

    func stop() {
        let first = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            shutdown(listener, SHUT_RDWR)
            if peer >= 0 { shutdown(peer, SHUT_RDWR) }
            return true
        }
        guard first else { return }
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
    }

    private func run() {
        defer { finished.signal() }
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        defer {
            lock.withLock {
                peer = -1
                Darwin.close(fd)
            }
        }
        guard
            lock.withLock({
                peer = fd
                return !stopped
            })
        else { return }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        while let header = read(fd, count: 4) {
            let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard length > 0, length < 1 << 20, let data = read(fd, count: length),
                let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let response: Response
            if request["method"] as? String == "initialize" {
                var reply = Self.success(request, result: ["clientId": "fixture-client"])
                reply["handledByClientId"] = "fixture-client"
                response = .reply(reply)
            } else {
                lock.withLock { received.append(request["method"] as? String ?? "") }
                response = respond(request)
            }
            switch response {
            case .disconnect: return
            case .silent: continue
            case .reply(let object):
                guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
                var size = UInt32(body.count).littleEndian
                var frame = Data(bytes: &size, count: 4)
                frame.append(body)
                let ok = frame.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { return false }
                        offset += count
                    }
                    return true
                }
                if !ok { return }
            }
        }
    }

    private func read(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let size = recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { return false }
                offset += size
            }
            return true
        }
        return ok ? data : nil
    }
}
