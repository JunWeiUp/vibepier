import Darwin
import Foundation

/// The child may never read stdin. Keep its bounded payload off the provider queue and close on a deadline.
enum ClaudeProcessInput {
    static func write(
        _ data: Data, to handle: FileHandle, timeout: Double = 10,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let fd = handle.fileDescriptor
            defer { try? handle.close() }
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                fcntl(fd, F_SETNOSIGPIPE, 1) == 0
            else {
                completion(false)
                return
            }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let succeeded = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < data.count {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { return false }
                    var watch = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&watch, 1, Int32(min(50, max(1, remaining * 1000))))
                    if ready == 0 { continue }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    guard watch.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { return false }
                    let count = Darwin.write(
                        fd, buffer.baseAddress!.advanced(by: offset), min(64 * 1024, data.count - offset))
                    if count < 0 {
                        if errno == EAGAIN || errno == EINTR { continue }
                        return false
                    }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            completion(succeeded)
        }
    }
}
