// SPDX-License-Identifier: MIT
import Foundation

enum ControlSocketIO {
    static func configure(_ fd: Int32) -> Bool {
        var enabled: Int32 = 1
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
            && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
            && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        return getpeereid(fd, &user, &group) == 0 && user == geteuid()
    }

    static func connect(_ fd: Int32, path: String, deadline: Double) -> Bool {
        var address = sockaddr_un()
        guard ControlSocket.fillAddress(&address, path) else { return false }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS, ready(fd, event: Int16(POLLOUT), deadline: deadline) else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
    }

    static func encode(_ object: [String: Any], limit: Int) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
            var data = try? JSONSerialization.data(withJSONObject: object), data.count <= limit
        else { return nil }
        data.append(10)
        return data
    }

    static func read(from fd: Int32, limit: Int, deadline: Double) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ready(fd, event: Int16(POLLIN), deadline: deadline) {
            let n = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard n > 0 else { return nil }
            if let newline = buffer[..<n].firstIndex(of: 10) {
                guard newline == n - 1, data.count + newline <= limit else { return nil }
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<n])
            guard data.count <= limit else { return nil }
        }
        return nil
    }

    static func write(_ data: Data, to fd: Int32, deadline: Double) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { bytes in
            while offset < data.count {
                guard ready(fd, event: Int16(POLLOUT), deadline: deadline) else { return false }
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    private static func ready(_ fd: Int32, event: Int16, deadline: Double) -> Bool {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining.isFinite, remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            // POLLIN may accompany HUP when the peer closes after its final bytes.
            return result > 0 && descriptor.revents & event != 0
        }
    }
}

/// A worker owns close(); stop only interrupts the descriptor under the same lock.
final class ControlSocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private var stopped = false
    private var handling = false
    init(_ fd: Int32) { self.fd = fd }
    var cancelled: Bool { lock.withLock { stopped } }
    func beginHandling() -> Bool {
        lock.withLock {
            guard !stopped, !handling else { return false }
            handling = true
            return true
        }
    }
    func cancel() {
        lock.withLock {
            stopped = true
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        }
    }
    func close() {
        lock.withLock {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
    }
    deinit { close() }
}

/// A private parent and a stable flock prevent concurrent starts from replacing the live socket.
final class ControlSocketEndpoint: @unchecked Sendable {
    private let path: String
    private let lockFD: Int32
    private let lock = NSLock()
    private var identity: (dev_t, ino_t)?

    init(path: String) throws {
        var address = sockaddr_un()
        guard ControlSocket.fillAddress(&address, path) else { throw POSIXError(.ENAMETOOLONG) }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var info = stat()
        guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw POSIXError(.EACCES) }
        let fd = open(path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0
        else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        self.path = path
        lockFD = fd
    }

    func bind(_ fd: Int32) throws {
        var previous = stat()
        if lstat(path, &previous) == 0 {
            guard previous.st_mode & S_IFMT == S_IFSOCK, previous.st_uid == geteuid() else {
                throw POSIXError(.EEXIST)
            }
            // Existing releases did not hold the lock file. Never unlink a listening old server.
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw POSIXError(.EIO) }
            defer { close(probe) }
            guard ControlSocketIO.configure(probe) else { throw POSIXError(.EIO) }
            var address = sockaddr_un()
            _ = ControlSocket.fillAddress(&address, path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result < 0 && errno == ECONNREFUSED else { throw POSIXError(.EADDRINUSE) }
            var current = stat()
            guard lstat(path, &current) == 0, current.st_dev == previous.st_dev, current.st_ino == previous.st_ino,
                unlink(path) == 0
            else { throw POSIXError(.EIO) }
        } else if errno != ENOENT {
            throw POSIXError(.EIO)
        }
        var address = sockaddr_un()
        _ = ControlSocket.fillAddress(&address, path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var current = stat()
        guard lstat(path, &current) == 0 else { throw POSIXError(.EIO) }
        identity = (current.st_dev, current.st_ino)
        guard chmod(path, 0o600) == 0 else { throw POSIXError(.EACCES) }
    }

    func removeSocket() {
        lock.withLock {
            guard let identity else { return }
            var current = stat()
            if lstat(path, &current) == 0, current.st_mode & S_IFMT == S_IFSOCK,
                current.st_uid == geteuid(), current.st_dev == identity.0, current.st_ino == identity.1
            {
                unlink(path)
            }
            self.identity = nil
        }
    }
    deinit {
        removeSocket()
        close(lockFD)
    }
}
