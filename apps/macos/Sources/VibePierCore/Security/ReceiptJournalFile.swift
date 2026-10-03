import Foundation

/// Bounded reads, same-directory atomic publication and optimistic revision checks under a stable file lock.
enum ReceiptJournalFile {
    static func read(_ file: URL, limit: Int) throws -> Data? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw failure()
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid(),
            info.st_size >= 0, info.st_size <= limit
        else { throw POSIXError(.EFBIG) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let size = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw failure() }
            if size == 0 { return data }
            data.append(contentsOf: buffer[..<size])
            guard data.count <= limit else { throw POSIXError(.EFBIG) }
        }
    }

    static func commit(_ data: Data, to file: URL, expected: Data?, limit: Int) throws {
        guard data.count <= limit else { throw POSIXError(.EFBIG) }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure() }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(), fchmod(parent, 0o700) == 0 else { throw failure() }
        let lockFD = open(file.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw failure() }
        defer { close(lockFD) }
        guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0
        else { throw POSIXError(.EAGAIN) }
        let current = try read(file, limit: limit).map(SessionReceiptJournal.digest)
        guard current == expected else { throw POSIXError(.ESTALE) }
        let temporary = directory.appendingPathComponent(".receipt-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        defer {
            close(fd)
            unlink(temporary.path)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw failure() }
        guard rename(temporary.path, file.path) == 0 else { throw failure() }
        guard fsync(parent) == 0 else { throw failure() }
    }

    private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
