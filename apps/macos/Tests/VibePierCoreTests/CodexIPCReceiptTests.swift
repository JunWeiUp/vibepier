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

    func testPatchHydrationRequiresOneFreshFollowAtTheAcknowledgedRevision() throws {
        let initial = try JSONSerialization.data(
            withJSONObject: CodexHistoryReadbackTests.packet(
                state: CodexHistoryReadbackTests.state([3], complete: false), revision: 1))
        let hydrated = try JSONSerialization.data(
            withJSONObject: CodexHistoryReadbackTests.packet(
                state: CodexHistoryReadbackTests.state([0, 1, 2, 3]), revision: 5))
        let method = "thread-follower-load-complete-history"
        let server = try NativeIPCFixture { request in
            if request["method"] as? String == method {
                return .replies([
                    (try! JSONSerialization.jsonObject(with: initial)) as! [String: Any],
                    [
                        "type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
                        "sourceClientId": "owner",
                        "params": [
                            "hostId": "local", "conversationId": "native-thread",
                            "change": ["type": "patch", "baseRevision": 1, "revision": 4, "patches": []],
                        ],
                    ],
                    NativeIPCFixture.success(request, result: ["revision": 4]),
                ])
            }
            XCTAssertEqual(request["method"] as? String, "thread-stream-following-changed")
            XCTAssertEqual(request["type"] as? String, "broadcast")
            XCTAssertEqual(request["targetClientIds"] as? [String], ["owner"])
            XCTAssertEqual((request["params"] as? [String: Any])?["following"] as? Bool, true)
            return .reply((try! JSONSerialization.jsonObject(with: hydrated)) as! [String: Any])
        }
        let ipc = CodexIPC(path: server.path)
        defer {
            ipc.close()
            server.stop()
        }
        try ipc.connect()
        let reply = try ipc.request(method, ["conversationId": "native-thread"], version: 1, target: "owner")
        let revision = try CodexHistoryReadback.acknowledgedRevision(reply)
        XCTAssertNil(
            CodexHistoryReadback.snapshot(
                try XCTUnwrap(ipc.latestSnapshot("native-thread")), thread: "native-thread", owner: "owner",
                minimumRevision: revision))
        let fresh = try ipc.freshSnapshot("native-thread", owner: "owner", minimumRevision: revision, timeout: 1)
        XCTAssertEqual(fresh.revision, 5, "A subsequent native revision is valid; exact equality is not required")
        let window = try XCTUnwrap(
            ConversationReply.older(CodexConversation.turns(fresh.state).map(CodexConversation.messages), before: "u3"))
        XCTAssertEqual(window.rows.compactMap { $0["id"] as? String }, ["u0", "u1", "u2"])
        XCTAssertFalse(window.start > 0 || !CodexHistoryReadback.complete(fresh.state))
        XCTAssertEqual(
            server.methods, [method, "thread-stream-following-changed"],
            "One hydration and one read; no write or automatic retry")
    }

    func testFreshReadRejectsOldCachedArrivalWrongScopeAndStaleRevisionWithoutResending() throws {
        let cached = try JSONSerialization.data(
            withJSONObject: CodexHistoryReadbackTests.packet(state: CodexHistoryReadbackTests.state([0]), revision: 4))
        for scenario in ["silent", "owner", "thread", "body", "stale"] {
            var packet = CodexHistoryReadbackTests.packet(state: CodexHistoryReadbackTests.state([0]), revision: 4)
            var params = packet["params"] as? [String: Any] ?? [:]
            var change = params["change"] as? [String: Any] ?? [:]
            switch scenario {
            case "owner": packet["sourceClientId"] = "wrong-owner"
            case "thread": params["conversationId"] = "wrong-thread"
            case "body": change["conversationState"] = ["id": "wrong-thread"]
            case "stale": change["revision"] = 3
            default: break
            }
            params["change"] = change
            packet["params"] = params
            let invalid = try JSONSerialization.data(withJSONObject: packet)
            let server = try NativeIPCFixture { request in
                if request["method"] as? String == "fixture-cache" {
                    return .replies([
                        (try! JSONSerialization.jsonObject(with: cached)) as! [String: Any],
                        NativeIPCFixture.success(request, result: [:]),
                    ])
                }
                return scenario == "silent"
                    ? .silent : .reply((try! JSONSerialization.jsonObject(with: invalid)) as! [String: Any])
            }
            let ipc = CodexIPC(path: server.path)
            defer {
                ipc.close()
                server.stop()
            }
            try ipc.connect()
            _ = try ipc.request("fixture-cache", [:], version: 1, target: "owner")
            XCTAssertNotNil(ipc.latestSnapshot("native-thread"))
            XCTAssertThrowsError(
                try ipc.freshSnapshot("native-thread", owner: "owner", minimumRevision: 4, timeout: 0.05)
            ) {
                XCTAssertFalse($0 is UnconfirmedDesktopMutation, "Only reads were performed")
            }
            XCTAssertEqual(server.methods, ["fixture-cache", "thread-stream-following-changed"], scenario)
        }
    }

    func testBridgeSameViewWithMissingStateRefollowsOnlyItsSelectedThreadWithoutOpeningDesktopAgain() throws {
        final class Counts: @unchecked Sendable {
            let lock = NSLock()
            var follows = 0
            var opens: [String] = []
            func nextFollow() -> Int {
                lock.withLock {
                    follows += 1
                    return follows
                }
            }
            func open(_ thread: String) { lock.withLock { opens.append(thread) } }
        }
        let counts = Counts()
        let thread = "00000000-0000-4000-8000-000000000010"
        var nativeState = CodexHistoryReadbackTests.state([3])
        nativeState["id"] = thread
        var packet = CodexHistoryReadbackTests.packet(state: nativeState, revision: 1)
        var params = packet["params"] as! [String: Any]
        params["conversationId"] = thread
        packet["params"] = params
        let snapshot = try JSONSerialization.data(withJSONObject: packet)
        let server = try NativeIPCFixture { request in
            let method = request["method"] as? String
            if method == "thread-owner-discovery" {
                XCTAssertEqual((request["params"] as? [String: Any])?["conversationId"] as? String, thread)
                return .reply(NativeIPCFixture.success(request, result: [:]))
            }
            XCTAssertEqual(
                method, "thread-stream-following-changed", "Recovery never sends a native turn or other mutation")
            if (request["params"] as? [String: Any])?["following"] as? Bool == false { return .silent }
            return counts.nextFollow() == 1
                ? .silent : .reply((try! JSONSerialization.jsonObject(with: snapshot)) as! [String: Any])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ipc = CodexIPC(path: server.path)
        let bridge = CodexBridge(
            ipc: ipc, followUps: CodexFollowUps(file: root.appendingPathComponent("synthetic-queues.json")),
            attachments: nil, executionModeCatalog: { [] }, desktopBuild: { "12947" },
            openNativeThread: { counts.open($0) })
        defer {
            bridge.stopAll()
            ipc.close()
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let client = "synthetic-phone"
        let first = expectation(description: "initial subscription has no native state")
        let recovered = expectation(description: "same-view retry receives authoritative native state")
        bridge.event = { recipient, data in
            let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if recipient == client, page?["event"] as? String == "snapshot" {
                XCTAssertEqual(page?["threadId"] as? String, thread)
                XCTAssertEqual(page?["viewVersion"] as? Int, 7)
                recovered.fulfill()
            }
        }
        let open = try JSONSerialization.data(withJSONObject: ["op": "open", "threadId": thread, "viewVersion": 7])
        bridge.perform(open, client: client) { data in
            let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(reply?["opening"] as? Bool, true)
            first.fulfill()
        }
        wait(for: [first], timeout: 3)
        let retried = expectation(description: "same view can restart native observation")
        bridge.perform(open, client: client) { data in
            let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(reply?["ok"] as? Bool, true)
            retried.fulfill()
        }
        wait(for: [retried, recovered], timeout: 3)
        let ready = expectation(description: "restored same view can be read without refresh")
        bridge.perform(open, client: client) { data in
            let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(reply?["viewVersion"] as? Int, 7)
            XCTAssertEqual(reply?["canSend"] as? Bool, true)
            XCTAssertNotNil(reply?["nativeOwnerEpoch"])
            XCTAssertEqual((reply?["messages"] as? [[String: Any]])?.first?["id"] as? String, "u3")
            ready.fulfill()
        }
        wait(for: [ready], timeout: 3)
        let denied = expectation(description: "same view cannot redirect recovery to another thread")
        let other = try JSONSerialization.data(withJSONObject: [
            "op": "open", "threadId": UUID().uuidString, "viewVersion": 7,
        ])
        bridge.perform(other, client: client) { data in
            let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(reply?["ok"] as? Bool, false)
            denied.fulfill()
        }
        wait(for: [denied], timeout: 3)
        XCTAssertEqual(counts.lock.withLock { counts.opens }, [thread])
        XCTAssertEqual(
            server.methods,
            [
                "thread-owner-discovery", "thread-stream-following-changed", "thread-owner-discovery",
                "thread-stream-following-changed",
            ])
    }
}

/// A private temporary Unix socket exercises framing and the production client without running a provider.
private final class NativeIPCFixture: @unchecked Sendable {
    enum Response {
        case reply([String: Any])
        case replies([[String: Any]])
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
            let messages: [[String: Any]]
            switch response {
            case .disconnect: return
            case .silent: continue
            case .reply(let object): messages = [object]
            case .replies(let objects): messages = objects
            }
            for object in messages {
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
