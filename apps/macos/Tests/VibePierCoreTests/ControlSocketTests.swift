import Foundation
import XCTest

@testable import VibePierCore

final class ControlSocketTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/vp-socket-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func server(
        path: String? = nil, maximumClients: Int = 16, timeout: Double = 0.3,
        handler: @escaping ControlServer.Handler = { $0 }
    ) throws -> (ControlServer, String) {
        let path = try path ?? directory().appendingPathComponent("control.sock").path
        let server = ControlServer(path: path, maximumClients: maximumClients, ioTimeout: timeout, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }
        return (server, path)
    }
    private func client(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        guard ControlSocketIO.configure(fd), ControlSocketIO.connect(fd, path: path, deadline: now + 1) else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        XCTAssertTrue(ControlSocketIO.configure(fds[0]))
        XCTAssertTrue(ControlSocketIO.configure(fds[1]))
        return (fds[0], fds[1])
    }

    func testLargeRoundTripAndPrivateSocket() throws {
        let (_, path) = try server(timeout: 2)
        let value = String(repeating: "中文 + C++\n", count: 30_000)
        let reply = try XCTUnwrap(ControlSocket.request(["text": value], path: path, timeout: 3))
        XCTAssertEqual(reply["text"] as? String, value)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let fd = try client(path)
        defer { close(fd) }
        XCTAssertTrue(ControlSocketIO.sameUser(fd))
    }

    func testMalformedIncompleteAndMultipleRequestsNeverReachHandler() throws {
        let calls = Counter()
        let (_, path) = try server { _ in
            calls.increment()
            return ["ok": true]
        }
        for text in ["{}", "[1]\n", "not-json\n", "{}\n{}\n", "{\"cmd\":\"status\"}"] {
            let fd = try client(path)
            XCTAssertTrue(ControlSocketIO.write(Data(text.utf8), to: fd, deadline: now + 1))
            shutdown(fd, SHUT_WR)
            XCTAssertNil(ControlSocketIO.read(from: fd, limit: 1024, deadline: now + 1))
            close(fd)
        }
        XCTAssertEqual(calls.count, 0)
        XCTAssertNotNil(ControlSocket.request(["cmd": "valid"], path: path, timeout: 1))
        XCTAssertEqual(calls.count, 1)
    }

    func testSlowReaderDoesNotBlockOtherClientsAndHasAbsoluteDeadline() throws {
        let calls = Counter()
        let (_, path) = try server(maximumClients: 2, timeout: 0.2) { request in
            calls.increment()
            return request
        }
        let slow = try client(path)
        defer { close(slow) }
        XCTAssertTrue(ControlSocketIO.write(Data("{".utf8), to: slow, deadline: now + 1))
        XCTAssertNotNil(ControlSocket.request(["ok": true], path: path, timeout: 1))
        let started = now
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 0.07)
            _ = ControlSocketIO.write(Data(" ".utf8), to: slow, deadline: now + 0.1)
        }
        XCTAssertFalse(ControlSocketIO.write(Data("}\n".utf8), to: slow, deadline: now + 0.1))
        XCTAssertLessThan(now - started, 0.8)
        XCTAssertEqual(calls.count, 1)
    }

    func testInFlightHandlersCountAgainstCapacity() throws {
        let entered = expectation(description: "handler entered")
        let finished = DispatchSemaphore(value: 0)
        let release = Counter()
        let calls = Counter()
        let (_, path) = try server(maximumClients: 1, timeout: 0.5) { request in
            calls.increment()
            if request["wait"] as? Bool == true {
                entered.fulfill()
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while release.count == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            return ["ok": true]
        }
        defer { release.increment() }
        DispatchQueue.global().async {
            _ = ControlSocket.request(["wait": true], path: path, timeout: 2)
            finished.signal()
        }
        wait(for: [entered], timeout: 1)
        XCTAssertNil(ControlSocket.request(["second": true], path: path, timeout: 0.3))
        XCTAssertEqual(calls.count, 1)
        release.increment()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        var accepted = false
        for _ in 0..<10 {
            if ControlSocket.request(["third": true], path: path, timeout: 0.3) != nil {
                accepted = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(calls.count, 2)
    }

    func testOversizedRequestAndReplyFailWithoutPartialSuccess() throws {
        let calls = Counter()
        let (_, path) = try server(timeout: 1) { _ in
            calls.increment()
            return ["text": String(repeating: "x", count: ControlSocket.replyLimit)]
        }
        XCTAssertNil(
            ControlSocket.request(["text": String(repeating: "x", count: ControlSocket.requestLimit)], path: path))
        XCTAssertEqual(calls.count, 0)
        let fd = try client(path)
        _ = ControlSocketIO.write(
            Data(repeating: 120, count: ControlSocket.requestLimit + 10), to: fd, deadline: now + 2)
        XCTAssertNil(ControlSocketIO.read(from: fd, limit: 1024, deadline: now + 1))
        close(fd)
        XCTAssertEqual(calls.count, 0)
        XCTAssertNil(ControlSocket.request(["valid": true], path: path, timeout: 3))
        XCTAssertEqual(calls.count, 1)
    }

    func testReadLimitIncludesExactBoundaryAndRequiresNewline() throws {
        for (data, expected) in [("1234\n", "1234"), ("12345\n", nil), ("1234", nil), ("12\n34", nil)]
            as [(String, String?)]
        {
            let (writer, reader) = try pair()
            XCTAssertTrue(ControlSocketIO.write(Data(data.utf8), to: writer, deadline: now + 1))
            shutdown(writer, SHUT_WR)
            let reply = ControlSocketIO.read(from: reader, limit: 4, deadline: now + 1)
            XCTAssertEqual(reply.flatMap { String(data: $0, encoding: .utf8) }, expected)
            close(writer)
            close(reader)
        }
    }

    func testBlockedWriteTimesOutAndClosedPeerDoesNotRaiseSIGPIPE() throws {
        let (writer, reader) = try pair()
        defer { close(writer) }
        var size: Int32 = 4096
        XCTAssertEqual(setsockopt(writer, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)), 0)
        let started = now
        XCTAssertFalse(ControlSocketIO.write(Data(repeating: 120, count: 2_000_000), to: writer, deadline: now + 0.1))
        XCTAssertLessThan(now - started, 0.7)
        close(reader)
        XCTAssertFalse(ControlSocketIO.write(Data("{}\n".utf8), to: writer, deadline: now + 0.1))
    }

    func testInvalidTimeoutAndPathsFailBeforeIO() {
        for timeout in [-1, 0, Double.nan, Double.infinity, 301] {
            XCTAssertNil(ControlSocket.request([:], path: "/no-server", timeout: timeout))
        }
        for path in ["relative.sock", "/tmp/nul\0suffix", "/" + String(repeating: "a", count: 104)] {
            var address = sockaddr_un()
            XCTAssertFalse(ControlSocket.fillAddress(&address, path))
            XCTAssertThrowsError(try ControlServer(path: path) { _ in [:] }.start())
        }
    }

    func testConcurrentStartCannotReplaceLiveServer() throws {
        let (_, path) = try server { _ in ["owner": "first"] }
        let second = ControlServer(path: path) { _ in ["owner": "second"] }
        XCTAssertThrowsError(try second.start())
        second.stop()
        XCTAssertEqual(ControlSocket.request([:], path: path)?["owner"] as? String, "first")
    }

    func testExistingFileSymlinkAndPublicParentArePreserved() throws {
        let root = try directory()
        let path = root.appendingPathComponent("control.sock").path
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        let server = ControlServer(path: path) { _ in [:] }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "keep")
        try FileManager.default.removeItem(atPath: path)
        let target = root.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        XCTAssertEqual(symlink(target.path, path), 0)
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertThrowsError(try server.start())
    }

    func testStaleSocketRecoveryAndStopPreservesReplacement() throws {
        let root = try directory()
        let path = root.appendingPathComponent("control.sock").path
        var endpoint: ControlSocketEndpoint? = try ControlSocketEndpoint(path: path)
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        try endpoint!.bind(stale)
        close(stale)
        // Release the endpoint without deleting the deliberately stale socket: replace its identity first.
        let moved = root.appendingPathComponent("stale.sock").path
        XCTAssertEqual(rename(path, moved), 0)
        endpoint = nil
        XCTAssertEqual(rename(moved, path), 0)
        let (server, _) = try self.server(path: path)
        XCTAssertNotNil(ControlSocket.request([:], path: path))
        XCTAssertEqual(unlink(path), 0)
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: path))
        server.stop()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "replacement")
    }

    func testOldListeningSocketWithoutLockCannotBeReplaced() throws {
        let root = try directory()
        let path = root.appendingPathComponent("control.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_un()
        XCTAssertTrue(ControlSocket.fillAddress(&address, path))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)
        XCTAssertEqual(listen(listener, 4), 0)
        var before = stat()
        XCTAssertEqual(lstat(path, &before), 0)
        let candidate = ControlServer(path: path) { _ in [:] }
        XCTAssertThrowsError(try candidate.start())
        var after = stat()
        XCTAssertEqual(lstat(path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
    }

    func testCancelledConnectionNeverBeginsHandler() throws {
        let (fd, peer) = try pair()
        defer { close(peer) }
        let connection = ControlSocketConnection(fd)
        connection.cancel()
        XCTAssertFalse(connection.beginHandling())
        connection.close()
        connection.cancel()
        XCTAssertTrue(connection.cancelled)
    }

    func testClientDeadlineIncludesHandlerWaitAndNoRetry() throws {
        let calls = Counter()
        let done = expectation(description: "original handler completes")
        let (_, path) = try server(timeout: 1) { _ in
            calls.increment()
            try? await Task.sleep(for: .milliseconds(250))
            done.fulfill()
            return ["ok": true]
        }
        let started = now
        XCTAssertNil(ControlSocket.request(["cmd": "fixture"], path: path, timeout: 0.08))
        XCTAssertLessThan(now - started, 0.7)
        wait(for: [done], timeout: 1)
        XCTAssertEqual(calls.count, 1)
    }

    func testStopInterruptsIncompleteClientWithoutDispatch() throws {
        let calls = Counter()
        let (server, path) = try self.server(timeout: 2) { _ in
            calls.increment()
            return [:]
        }
        let fd = try client(path)
        defer { close(fd) }
        XCTAssertTrue(ControlSocketIO.write(Data("{".utf8), to: fd, deadline: now + 1))
        server.stop()
        XCTAssertNil(ControlSocketIO.read(from: fd, limit: 1024, deadline: now + 0.5))
        XCTAssertEqual(calls.count, 0)
    }
}
