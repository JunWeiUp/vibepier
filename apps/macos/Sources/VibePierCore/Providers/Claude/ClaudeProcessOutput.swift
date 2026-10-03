import Foundation

/// Bounded JSONL diagnostics. Never retain complete tool output or infer success before both pipes reach EOF.
final class ClaudeProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let ended = DispatchGroup()
    private let lineLimit: Int
    private var line = Data()
    private var stderr = Data()
    private var stdoutEnded = false
    private var stderrEnded = false
    private var discarding = false
    private var oversized = false
    private var malformed = false
    private var terminalSeen = false
    private var terminalError: String?
    private var incomplete = false

    init(lineLimit: Int = 8 * 1024 * 1024) {
        self.lineLimit = max(1, min(lineLimit, 8 * 1024 * 1024))
        ended.enter()
        ended.enter()
    }

    var bufferedBytes: Int { lock.withLock { line.count + stderr.count + (terminalError?.utf8.count ?? 0) } }

    func startReading(stdout: FileHandle, stderr: FileHandle) {
        stdout.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.append(data, error: false)
        }
        stderr.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.append(data, error: true)
        }
    }

    func stopReading(stdout: FileHandle, stderr: FileHandle) {
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        lock.withLock { incomplete = incomplete || !stdoutEnded || !stderrEnded }
        // Balance the group even when launch failed or a descendant kept a pipe open.
        append(Data(), error: false)
        append(Data(), error: true)
    }

    func append(_ data: Data, error: Bool) {
        lock.withLock {
            if data.isEmpty {
                if error {
                    guard !stderrEnded else { return }
                    stderrEnded = true
                } else {
                    guard !stdoutEnded else { return }
                    stdoutEnded = true
                    if !discarding && !line.isEmpty { consumeLine() }
                    line.removeAll(keepingCapacity: false)
                }
                ended.leave()
                return
            }
            guard !(error ? stderrEnded : stdoutEnded) else {
                malformed = true
                return
            }
            if error {
                if data.count >= 4096 {
                    stderr = Data(data.suffix(4096))
                } else {
                    stderr.append(data)
                    if stderr.count > 4096 { stderr = Data(stderr.suffix(4096)) }
                }
                return
            }
            var start = data.startIndex
            while start < data.endIndex {
                let newline = data[start...].firstIndex(of: 10)
                let end = newline ?? data.endIndex
                let count = data.distance(from: start, to: end)
                if !discarding {
                    if count <= lineLimit - line.count {
                        line.append(data[start..<end])
                    } else {
                        oversized = true
                        discarding = true
                        line.removeAll(keepingCapacity: false)
                    }
                }
                guard let newline else { break }
                if !discarding && !line.isEmpty { consumeLine() }
                line.removeAll(keepingCapacity: true)
                discarding = false
                start = data.index(after: newline)
            }
        }
    }

    private func consumeLine() {
        guard String(data: line, encoding: .utf8) != nil,
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String
        else {
            malformed = true
            return
        }
        guard type == "result" else { return }
        guard !terminalSeen, let failed = SessionProviderReply.boolean(object["is_error"]) else {
            malformed = true
            return
        }
        terminalSeen = true
        if failed {
            terminalError = Self.detail(
                object["result"] as? String ?? object["subtype"] as? String
                    ?? L10n.text("mac.unknown_error"))
        }
    }

    private static func detail(_ value: String) -> String {
        // A single extended grapheme can contain arbitrarily many combining scalars.
        // Bound bytes before applying the human-readable character limit.
        var bytes = Data(value.utf8.prefix(2400))
        while !bytes.isEmpty {
            if let text = String(data: bytes, encoding: .utf8) { return String(text.prefix(600)) }
            bytes.removeLast()
        }
        return ""
    }

    func failure(status: Int32, interrupted: Bool, wait: TimeInterval = 2) -> String? {
        let complete = ended.wait(timeout: .now() + max(0, min(wait, 2))) == .success
        return lock.withLock {
            if interrupted || status == 130 { return L10n.text("provider.current_task_stopped") }
            if oversized { return L10n.text("provider.claude_output_limit") }
            if let terminalError { return L10n.text("provider.claude_code_failed") + terminalError }
            if status != 0 {
                let detail = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return L10n.text("provider.claude_code_exited_0", status)
                    + (detail.isEmpty ? "" : "：" + String(detail.suffix(600)))
            }
            guard complete, !incomplete, !malformed, terminalSeen else {
                return L10n.text("provider.claude_output_unconfirmed")
            }
            return nil
        }
    }
}
