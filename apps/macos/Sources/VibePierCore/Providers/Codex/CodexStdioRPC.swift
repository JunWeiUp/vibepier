import AppKit
import Darwin
import Foundation

/// Bounded native stdio transport with an explicit purpose. The creation purpose only
/// bootstraps an empty thread; model turns remain owned by the desktop coordinator.
final class CodexStdioRPC {
    enum Purpose {
        case account, creation
        func allows(_ method: String, mutable: Bool) -> Bool {
            if method == "initialize" { return !mutable }
            switch self {
            case .account:
                return (method == "account/rateLimits/read" && !mutable)
                    || (method == "account/rateLimitResetCredit/consume" && mutable)
            case .creation:
                return ["thread/start", "thread/name/set", "thread/archive", "thread/unarchive"].contains(method)
                    && mutable
            }
        }
    }
    private let purpose: Purpose
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var sequence = 0
    private var closed = false
    private let deadline = ProcessInfo.processInfo.systemUptime + 40

    init(executable: URL? = nil, purpose: Purpose) throws {
        self.purpose = purpose
        let bundle =
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        let candidates = [
            executable,
            bundle?.appendingPathComponent("Contents/Resources/codex-cli/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex"),
        ].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CLIError(L10n.text("usage.codex_missing"))
        }
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                throw CLIError(L10n.text("usage.unavailable"))
            }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CLIError(L10n.text("usage.unavailable"))
        }
        do {
            try process.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            _ = try request(
                "initialize",
                params: [
                    "clientInfo": ["name": "vibepier", "title": "VibePier", "version": "0.1.0-beta.1"],
                    "capabilities": ["experimentalApi": true, "explicitGatewayOauth": true],
                ], mutable: false)
            try write(["method": "initialized", "params": [:] as [String: Any]])
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }
    func close() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
        let until = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning, ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func request(_ method: String, params: [String: Any], mutable: Bool = false) throws -> [String: Any] {
        guard purpose.allows(method, mutable: mutable), !closed
        else { throw CLIError(L10n.text("core.invalid_request")) }
        sequence += 1
        let id = sequence
        return try DesktopMutationScope.run { scope in
            if mutable { try scope.attempt {} }
            try write(["id": id, "method": method, "params": params])
            var total = 0
            while true {
                let line = try readLine()
                total += line.count
                guard total <= 4 * 1024 * 1024,
                    let value = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { throw CLIError(L10n.text("usage.unavailable")) }
                guard value["id"] as? Int == id else {
                    // Neither purpose authorizes interactive approvals or tool execution.
                    if value["method"] != nil, value["id"] != nil {
                        try write(["id": value["id"]!, "error": ["code": -32601, "message": "Unsupported request"]])
                    }
                    continue
                }
                guard value["error"] == nil, let result = value["result"] as? [String: Any] else {
                    throw CLIError(L10n.text("usage.unavailable"))
                }
                return result
            }
        }
    }

    private func wait(_ fd: Int32, events: Int16) throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw CLIError(L10n.text("usage.timeout")) }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
        if result < 0, errno != EINTR { throw CLIError(L10n.text("usage.unavailable")) }
    }
    private func write(_ object: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object)
        guard bytes.count <= 8192 else { throw CLIError(L10n.text("core.invalid_request")) }
        bytes.append(10)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            let fd = input.fileHandleForWriting.fileDescriptor
            while offset < bytes.count {
                try wait(fd, events: Int16(POLLOUT))
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw CLIError(L10n.text("usage.unavailable")) }
                offset += count
            }
        }
    }
    private func readLine() throws -> Data {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                guard line.count <= 2 * 1024 * 1024 else { throw CLIError(L10n.text("usage.unavailable")) }
                return line
            }
            guard buffer.count <= 2 * 1024 * 1024 else { throw CLIError(L10n.text("usage.unavailable")) }
            let fd = output.fileHandleForReading.fileDescriptor
            try wait(fd, events: Int16(POLLIN))
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw CLIError(L10n.text("usage.unavailable")) }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}
