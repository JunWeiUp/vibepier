import CryptoKit
import Foundation

/// Issues file-only capabilities through a private child-process pipe. Provider/session
/// authorization stays in SessionRemote; the child never receives pairing keys or credentials.
final class BinaryFileTransfers: @unchecked Sendable {
    static let shared = BinaryFileTransfers()
    private let control = DispatchQueue(label: "vibepier.files.control")
    private let responses = NSCondition()
    private var replies: [String: [String: Any]] = [:]
    private var process: Process?
    private var input: FileHandle?
    private var ready = false
    private var offers: [String: [String: Any]] = [:]
    private var mediaSnapshots: [String: URL] = [:]
    private var apkRequests: [String: String] = [:]
    private var observer: NSObjectProtocol?
    private let executableOverride: URL?
    private let stagingRoot: URL
    private let authorized: @Sendable (String) -> Bool
    init(
        executable: URL? = nil,
        stagingRoot: URL = Paths.supportDirectory.appendingPathComponent("binary-file-staging").appendingPathComponent(
            UUID().uuidString),
        authorized: @escaping @Sendable (String) -> Bool = { DeviceTrustStore.shared.key(for: $0) != nil }
    ) {
        self.executableOverride = executable
        self.stagingRoot = stagingRoot
        self.authorized = authorized
        observer = NotificationCenter.default.addObserver(forName: DeviceTrustStore.changed, object: nil, queue: nil) {
            [weak self] _ in
            // Invalidate all capabilities on a trust change, including in-flight sockets.
            self?.control.async { [weak self] in
                guard let self else { return }
                _ = self.command(["op": "cancel"])
                for file in self.mediaSnapshots.values {
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                }
                self.mediaSnapshots.removeAll()
                self.offers.removeAll()
                self.apkRequests.removeAll()
            }
        }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        for file in mediaSnapshots.values { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }
    func configure(_ settings: RelaySettings?) {
        control.async { [weak self] in
            guard let self else { return }
            self.start()
            var request: [String: Any] = ["op": "configure"]
            if let settings, var url = URLComponents(url: settings.url, resolvingAgainstBaseURL: false),
                url.scheme == "wss"
            {
                url.scheme = "https"
                url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                url.path = "/" + url.path + "/files"
                request["url"] = url.string
                request["room"] = settings.room
                request["secret"] = settings.secret
            }
            _ = self.command(request)
        }
    }
    private func start() {
        guard process?.isRunning != true else { return }
        responses.lock()
        ready = false
        responses.unlock()
        for file in mediaSnapshots.values { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        mediaSnapshots.removeAll()
        offers.removeAll()
        apkRequests.removeAll()
        let executable =
            executableOverride
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("VibePierFileServer")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let task = Process()
        let incoming = Pipe()
        let outgoing = Pipe()
        task.executableURL = executable
        task.arguments = [stagingRoot.path]
        task.standardInput = incoming
        task.standardOutput = outgoing
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return }
        process = task
        input = incoming.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let bytes = outgoing.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                buffer.append(bytes)
                guard buffer.count <= 128 * 1024 else {
                    task.terminate()
                    break
                }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let self else {
                        continue
                    }
                    self.responses.lock()
                    if value["ready"] as? Bool == true { self.ready = true }
                    if let id = value["request"] as? String { self.replies[id] = value }
                    self.responses.broadcast()
                    self.responses.unlock()
                }
            }
            self?.responses.lock()
            self?.ready = false
            self?.responses.broadcast()
            self?.responses.unlock()
        }
        responses.lock()
        let until = Date().addingTimeInterval(3)
        while !ready && Date() < until { _ = responses.wait(until: until) }
        responses.unlock()
    }
    private func command(_ fields: [String: Any]) -> [String: Any]? {
        guard process?.isRunning == true, let input else { return nil }
        let id = UUID().uuidString
        var fields = fields
        fields["request"] = id
        guard var bytes = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        bytes.append(10)
        do { try input.write(contentsOf: bytes) } catch { return nil }
        responses.lock()
        defer { responses.unlock() }
        let until = Date().addingTimeInterval(3)
        while replies[id] == nil && process?.isRunning == true && Date() < until { _ = responses.wait(until: until) }
        guard let reply = replies.removeValue(forKey: id), reply["ok"] as? Bool == true else { return nil }
        return reply
    }
    var available: Bool { control.sync { process?.isRunning == true } }
    private func key(_ device: String, _ scope: String) -> String { device + "\u{0}" + scope }
    func uploadOffer(device: String, scope: String, id: String, size: Int) -> [String: Any]? {
        control.sync {
            guard authorized(device) else { return nil }
            let scope = scope + "|" + id.lowercased()
            let cache = key(device, scope)
            if let old = offers[cache] { return old }
            guard
                let profile = command([
                    "op": "offer", "kind": "upload", "device": device, "scope": scope,
                    "size": size, "offset": 0,
                ])?["profile"] as? [String: Any]
            else { return nil }
            offers[cache] = profile
            return profile
        }
    }
    func claimUpload(device: String, scope: String, id: String, ticket: String, size: Int) throws -> URL {
        try control.sync {
            let scope = scope + "|" + id.lowercased()
            guard authorized(device), offers[key(device, scope)]?["id"] as? String == ticket
            else { throw CLIError(L10n.text("core.invalid_request")) }
            // The cloud pipe can finish transmitting just before the receiving worker's fsync.
            let until = Date().addingTimeInterval(2)
            repeat {
                guard let state = command(["op": "status", "id": ticket]), state["failed"] as? Bool != true,
                    state["device"] as? String == device, state["scope"] as? String == scope,
                    state["size"] as? Int == size
                else { throw CLIError(L10n.text("core.invalid_request")) }
                if state["complete"] as? Bool == true, let path = state["file"] as? String {
                    return URL(fileURLWithPath: path)
                }
                Thread.sleep(forTimeInterval: 0.01)
            } while Date() < until
            throw CLIError(L10n.text("session.attachment_chunks_are_missing_upload_it_again"))
        }
    }
    func cancelTicket(device: String, ticket: String) {
        control.sync {
            let matching = offers.filter { $0.key.hasPrefix(device + "\u{0}") && $0.value["id"] as? String == ticket }
                .map(\.key)
            for cache in matching {
                offers.removeValue(forKey: cache)
                apkRequests.removeValue(forKey: cache)
                if let file = mediaSnapshots.removeValue(forKey: cache) {
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                }
            }
            if !matching.isEmpty { _ = command(["op": "cancel", "id": ticket]) }
        }
    }
    func cancelUpload(device: String, scope: String, id: String) {
        cancel(device: device, scope: scope + "|" + id.lowercased())
    }
    func apkOffer(device: String, transfer: String, file: URL, size: Int, offset: Int, requestID: String) -> [String:
        Any]?
    {
        control.sync {
            guard authorized(device) else { return nil }
            let scope = "apk:" + transfer
            let cache = key(device, scope)
            if apkRequests[cache] == requestID, let old = offers[cache], old["offset"] as? Int == offset { return old }
            cancelOnControl(device: device, scope: scope)
            guard
                let profile = command([
                    "op": "offer", "kind": "apk", "device": device, "scope": scope,
                    "file": file.path, "size": size, "offset": offset,
                ])?["profile"] as? [String: Any]
            else { return nil }
            offers[key(device, scope)] = profile
            apkRequests[key(device, scope)] = requestID
            return profile
        }
    }
    func mediaOffer(device: String, scope: String, file: URL, size: Int, mime: String, digest: String) -> [String: Any]?
    {
        control.sync {
            guard authorized(device), size > 0, size <= 128 * 1024 * 1024 else { return nil }
            let scope = "media:" + scope
            let cache = key(device, scope)
            guard
                let profile = command([
                    "op": "offer", "kind": "media", "device": device, "scope": scope,
                    "file": file.path, "size": size, "offset": 0,
                ])?["profile"] as? [String: Any]
            else { return nil }
            offers[cache] = profile
            mediaSnapshots[cache] = file
            control.asyncAfter(deadline: .now() + 600) { [weak self] in
                self?.cancelOnControl(device: device, scope: scope)
            }
            return profile.merging(["mime": mime, "sha256": digest]) { $1 }
        }
    }
    func cancelMedia(device: String) {
        control.sync {
            let prefix = key(device, "media:")
            let scopes = offers.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(device.count + 1)) }
            for scope in scopes { cancelOnControl(device: device, scope: scope) }
        }
    }
    func ownsAPKTicket(device: String, transfer: String, ticket: String) -> Bool {
        control.sync { offers[key(device, "apk:" + transfer)]?["id"] as? String == ticket && authorized(device) }
    }
    func cancelAPK(device: String, transfer: String) { cancel(device: device, scope: "apk:" + transfer) }
    private func cancel(device: String, scope: String) {
        control.sync { cancelOnControl(device: device, scope: scope) }
    }
    private func cancelOnControl(device: String, scope: String) {
        if let file = mediaSnapshots.removeValue(forKey: key(device, scope)) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        apkRequests.removeValue(forKey: key(device, scope))
        if let profile = offers.removeValue(forKey: key(device, scope)), let id = profile["id"] as? String {
            _ = command(["op": "cancel", "id": id])
        }
    }
}
